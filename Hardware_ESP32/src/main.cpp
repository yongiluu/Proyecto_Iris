// Los firmwares de captura de datos (audio_capture.cpp, photo_capture.cpp) tienen su propio setup/loop
#if !defined(IRIS_AUDIO_CAPTURE) && !defined(IRIS_PHOTO_CAPTURE)

#include <Arduino.h>
#include "config.h"
#include <esp_heap_caps.h>
#include <esp_system.h>
#include "camera_driver.h"
#include "audio_events.h"
#include "audio_player.h"
#include "ble_manager.h"
#include "mic_driver.h"
#include "photo_transfer.h"
#include "proximity.h"
#include "tflite_vision.h"
#include "vision_task.h"
#include "ota_update.h"

namespace {
constexpr uint32_t kDebounceMs = 50;
constexpr uint32_t kStopFlushDelayMs = 80;

volatile bool beepRequested = false;
// Cercania (0 libre, 1 cerca, 2 muy cerca): la escribe la tarea de vision, el loop pita.
volatile int proximityLevel = 0;
uint32_t lastProximityBeepMs = 0;
bool isTransmitting = false;
// Modo recoleccion de datos (pantalla "Misiones" de la app): manda el microfono crudo sin apretar el boton.
volatile bool collectingAudio = false;
// Pedido de actualizacion por WiFi (CMD_OTA_WIFI llega en el hilo BLE; el loop lo atiende).
volatile bool otaRequested = false;
// Boton de hablar en la pantalla de la app (prototipo sin boton): CMD_APP_PTT_START / STOP.
volatile bool appPttStartRequested = false;
volatile bool appPttStopRequested = false;

// Wake word "Oye Iris": la tarea de audio avisa y el loop arranca la pregunta (como el boton).
volatile int wakePercent = 0;   // != 0: hay un "Oye Iris" pendiente
bool wakeSession = false;       // pregunta iniciada por wake word: corta sola cuando dejas de hablar
bool heardSpeech = false;
uint32_t wakeStartMs = 0;
uint32_t lastVoiceMs = 0;
float noiseFloor = 200.0f;      // RMS del ambiente; se mide mientras no se le habla a Iris

// Cola de audio hacia la app. Sin transmitir guarda los ultimos WAKE_PREROLL_MS (lo que dijiste justo
// antes de que se detectara "Oye Iris"); al transmitir los manda primero y se pone al dia a doble velocidad.
constexpr size_t kPrerollSamples = AUDIO_SAMPLE_RATE * WAKE_PREROLL_MS / 1000;
// Al transmitir sale el doble de lo que entra, asi que la cola nunca pasa del audio previo + unos bloques.
// En PSRAM: si el BLE se atrasa, el audio se acumula aqui (hasta 3 s) en vez de perderse.
constexpr size_t kTxQueueSamples = AUDIO_SAMPLE_RATE * 3;
int16_t* txQueue = nullptr;
size_t txHead = 0;   // muestra mas antigua
size_t txCount = 0;

void queuePush(const int16_t* samples, size_t count, size_t maxKeep) {
  if (txQueue == nullptr) return;
  for (size_t i = 0; i < count; i++) {
    txQueue[(txHead + txCount) % kTxQueueSamples] = samples[i];
    if (txCount < kTxQueueSamples) txCount++;
    else txHead = (txHead + 1) % kTxQueueSamples;
  }
  while (txCount > maxKeep) {
    txHead = (txHead + 1) % kTxQueueSamples;
    txCount--;
  }
}

size_t queuePop(int16_t* out, size_t maxCount) {
  if (txQueue == nullptr) return 0;
  size_t count = txCount < maxCount ? txCount : maxCount;
  for (size_t i = 0; i < count; i++) out[i] = txQueue[(txHead + i) % kTxQueueSamples];
  txHead = (txHead + count) % kTxQueueSamples;
  txCount -= count;
  return count;
}

void flushTxQueue() {
  int16_t out[2 * kMicMaxSamples];
  size_t count;
  while ((count = queuePop(out, 2 * kMicMaxSamples)) > 0) {
    bleManager.sendAudioChunkWaiting((const uint8_t*)out, count * sizeof(int16_t));
  }
}

float rmsOf(const int16_t* samples, size_t count) {
  float sum = 0.0f;
  for (size_t i = 0; i < count; i++) sum += (float)samples[i] * samples[i];
  return sqrtf(sum / (count ? count : 1));
}

// Se ejecuta en el hilo BLE: solo encolar, nunca bloquear.
void onAudioReceived(const uint8_t* data, size_t length) {
  playAudioBuffer(data, length);
}

void onCommandReceived(const char* command) {
  if (strcmp(command, "CMD_TAKE_PHOTO") == 0) {
    requestPhotoCapture();
  } else if (strcmp(command, "CMD_BEEP_THINKING") == 0) {
    beepRequested = true;
  } else if (strcmp(command, "CMD_COLLECT_AUDIO_START") == 0) {
    collectingAudio = true;
  } else if (strcmp(command, "CMD_COLLECT_AUDIO_STOP") == 0) {
    collectingAudio = false;
  } else if (strcmp(command, "CMD_COLLECT_FRAME") == 0) {
    requestGrayFrameCapture();
  } else if (strncmp(command, "CMD_AUDIO_BEGIN:", 16) == 0) {
    beginAudioStream((size_t)strtoul(command + 16, nullptr, 10));
  } else if (strcmp(command, "CMD_OTA_WIFI") == 0) {
    otaRequested = true;
  } else if (strcmp(command, "CMD_APP_PTT_START") == 0) {
    appPttStartRequested = true;
  } else if (strcmp(command, "CMD_APP_PTT_STOP") == 0) {
    appPttStopRequested = true;
  } else {
    Serial.printf("[BLE] Comando desconocido: %s\n", command);
  }
}

// Se ejecuta en la tarea de inferencia de audio. Formato: CMD_AUDIO_EVENT:<clase>:<porcentaje>
void onAudioEvent(const char* label, int confidencePercent) {
  if (isIrisSpeaking()) return;  // no cortar la respuesta de Iris
  char command[48];
  snprintf(command, sizeof(command), "CMD_AUDIO_EVENT:%s:%d", label, confidencePercent);
  bleManager.sendCommand(command);
}

// Se ejecuta en la tarea de vision. Formato: CMD_VISION_EVENT:<clase>:<porcentaje>
void onVisionEvent(const char* label, int confidencePercent) {
  if (isIrisSpeaking()) return;  // no cortar la respuesta de Iris
  char command[48];
  snprintf(command, sizeof(command), "CMD_VISION_EVENT:%s:%d", label, confidencePercent);
  bleManager.sendCommand(command);
}

// Contexto silencioso (cada AMBIENT_CONTEXT_PERIOD_MS). Formato: CMD_AUDIO_CONTEXT:<clase>:<%>
void onAudioContext(const char* label, int percent) {
  char command[48];
  snprintf(command, sizeof(command), "CMD_AUDIO_CONTEXT:%s:%d", label, percent);
  bleManager.sendCommand(command);
}

// Formato: CMD_VISION_CONTEXT:<clase>:<%>
void onVisionContext(const char* label, int percent) {
  char command[48];
  snprintf(command, sizeof(command), "CMD_VISION_CONTEXT:%s:%d", label, percent);
  bleManager.sendCommand(command);
}

// Se ejecuta en la tarea de vision cuando cambia el nivel. Formato: CMD_PROXIMITY:<nivel>:<porcentaje>
void onProximityChange(int level, int percent) {
  proximityLevel = level;
  char command[40];
  snprintf(command, sizeof(command), "CMD_PROXIMITY:%d:%d", level, percent);
  bleManager.sendCommand(command);
  Serial.printf("[Cercania IA] Nivel %d (%d%%)\n", level, percent);
}

// Pitidos como el sensor de retroceso de un auto: mas rapidos y agudos mientras mas cerca.
void handleProximityBeeps() {
  const int level = proximityLevel;
  if (!PROXIMITY_BEEPS_ENABLED || level == 0 || isTransmitting) return;
  const uint32_t interval = level == 2 ? PROXIMITY_BEEP_VERY_NEAR_MS : PROXIMITY_BEEP_NEAR_MS;
  if (millis() - lastProximityBeepMs < interval) return;
  lastProximityBeepMs = millis();
  playTone(level == 2 ? 1760.0f : 1175.0f, 70);
}

// Se ejecuta en la tarea de inferencia de audio: solo avisa al loop.
void onWakeWord(int confidencePercent) {
  if (isIrisSpeaking()) return;  // el microfono oye la voz de Iris por el parlante
  wakePercent = confidencePercent > 0 ? confidencePercent : 1;
}

void startPushToTalk() {
  if (isTransmitting) {  // ya se estaba mandando por "Oye Iris": desde ahora manda el boton
    wakeSession = false;
    return;
  }
  Serial.println("Boton Presionado -> CMD_PTT_START");
  stopPlayback();  // si Iris estaba hablando, se calla para escuchar la pregunta nueva
  txCount = 0;  // con el boton no se manda el audio de antes
  isTransmitting = true;
  setVisionPaused(true);
  setAudioEventsPaused(true);
  bleManager.sendCommand("CMD_PTT_START");
}

void stopPushToTalk() {
  Serial.println("Boton Soltado -> CMD_PTT_STOP");
  isTransmitting = false;
  wakeSession = false;
  flushTxQueue();
  setVisionPaused(false);
  setAudioEventsPaused(false);
  delay(kStopFlushDelayMs); // deja vaciar la cola BLE de audio antes del STOP
  bleManager.sendCommand("CMD_PTT_STOP");
  // En las pruebas con la app el STOP a veces no llegaba (cola BLE llena con el ultimo audio) y la app
  // quedaba "escuchando". Se repite: la app ignora el segundo (ya no esta escuchando).
  delay(150);
  bleManager.sendCommand("CMD_PTT_STOP");
}

// "Oye Iris": igual que apretar el boton, mas un tono corto para saber que Iris escucha.
void startWakeSession(int percent) {
  if (isTransmitting || collectingAudio || !bleManager.isConnected()) {
    Serial.printf("[Wake word] Oye Iris (%d%%) ignorado: %s\n", percent,
                  bleManager.isConnected() ? "ya se esta transmitiendo" : "sin conexion BLE");
    return;
  }
  Serial.printf("Oye Iris (%d%%) -> CMD_PTT_START\n", percent);
  char command[32];
  snprintf(command, sizeof(command), "CMD_WAKE_WORD:%d", percent);
  bleManager.sendCommand(command);
  isTransmitting = true;
  wakeSession = true;
  heardSpeech = false;
  wakeStartMs = lastVoiceMs = millis();
  setVisionPaused(true);
  setAudioEventsPaused(true);
  bleManager.sendCommand("CMD_PTT_START");
  playTone(1320.0f, 60);
}

// Fin de la pregunta por wake word: silencio despues de hablar, nadie hablo, o tope de tiempo.
void updateWakeSession(const int16_t* samples, size_t count) {
  const uint32_t now = millis();
  if (rmsOf(samples, count) > noiseFloor * 3.0f + 150.0f) {
    heardSpeech = true;
    lastVoiceMs = now;
  }
  const uint32_t elapsed = now - wakeStartMs;
  if (elapsed >= WAKE_MAX_MS || (!heardSpeech && elapsed >= WAKE_WAIT_SPEECH_MS) ||
      (heardSpeech && now - lastVoiceMs >= WAKE_END_SILENCE_MS)) {
    Serial.printf("[Wake word] Fin de la pregunta (%.1f s)\n", elapsed / 1000.0f);
    stopPushToTalk();
  }
}

// Modo actualizacion por WiFi: se detiene todo, la placa crea su red y espera el firmware nuevo.
// Tres tonos subiendo = listo para recibir; un tono grave = no se pudo.
void enterOtaMode(const char* reason) {
  Serial.printf("[OTA] Modo actualizacion por WiFi (%s)\n", reason);
  if (isTransmitting) stopPushToTalk();
  collectingAudio = false;
  setVisionPaused(true);
  setAudioEventsPaused(true);
  shutdownCamera();
  if (startOtaUpdate()) {
    bleManager.sendCommand("CMD_OTA_READY:" OTA_AP_SSID);
    playTone(880.0f, 120);
    playTone(1175.0f, 120);
    playTone(1568.0f, 200);
    // Bluetooth apagado mientras se escribe la flash: con BLE activo algunas subidas se cortaban a la
    // mitad ("Connection was reset"). Al terminar (o a los 10 min) la placa se reinicia y vuelve.
    delay(300);
    NimBLEDevice::deinit(true);
  } else {
    bleManager.sendCommand("CMD_OTA_ERROR");
    playTone(330.0f, 600);
    delay(700);
    ESP.restart();  // vuelve al modo normal con la camara
  }
}

// Escribir OTA (y Enter) en el monitor serial tambien activa la actualizacion por WiFi.
void handleSerialCommands() {
  static char line[16];
  static size_t length = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\r' || c == '\n') {
      line[length] = 0;
      if (strcasecmp(line, "OTA") == 0) otaRequested = true;
      length = 0;
    } else if (length < sizeof(line) - 1) {
      line[length++] = c;
    }
  }
}

void handleButton() {
  static bool stableState = HIGH;
  static bool lastReading = HIGH;
  static uint32_t lastChangeMs = 0;
  static uint32_t pressedSinceMs = 0;

  bool reading = digitalRead(BUTTON_PIN);
#ifdef BUTTON_PIN_BOOT
  reading = reading && digitalRead(BUTTON_PIN_BOOT);  // apretado (LOW) si cualquiera de los dos lo esta
#endif
  if (reading != lastReading) {
    lastReading = reading;
    lastChangeMs = millis();
  }

  if (reading != stableState && millis() - lastChangeMs >= kDebounceMs) {
    stableState = reading;
    if (stableState == LOW) {
      pressedSinceMs = millis();
      startPushToTalk();
    } else {
      stopPushToTalk();
    }
  }
  // Mantenerlo apretado OTA_BUTTON_HOLD_MS (nadie habla tanto con el boton): actualizar por WiFi.
  static uint32_t holdHandledFor = 0;  // una sola vez por cada vez que se aprieta
  if (stableState == LOW && millis() - pressedSinceMs >= OTA_BUTTON_HOLD_MS && holdHandledFor != pressedSinceMs) {
    holdHandledFor = pressedSinceMs;
    enterOtaMode("boton mantenido");
  }
}
}

void setup() {
  Serial.begin(115200);
  txQueue = (int16_t*)heap_caps_malloc(kTxQueueSamples * sizeof(int16_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#if ARDUINO_USB_CDC_ON_BOOT
  // Con USB nativo (XIAO) lo que se imprime antes de abrir el monitor se pierde: espera un poco al PC
  // para que se vean los autotests. Sin cable sigue a los 2,5 s.
  while (!Serial && millis() < 2500) delay(10);
#endif
  pinMode(BUTTON_PIN, INPUT_PULLUP);
#ifdef BUTTON_PIN_BOOT
  pinMode(BUTTON_PIN_BOOT, INPUT_PULLUP);
#endif

  if (!initCamera()) Serial.println("Error al inicializar la camara");
  if (!initAudioPlayer()) Serial.println("Error al inicializar el reproductor de audio");
  if (!initMic()) Serial.println("Error al inicializar el microfono");

  if (!initVisionAI(onVisionEvent, onVisionContext)) Serial.println("Error al iniciar la vision local");
  if (!initProximityAI(onProximityChange)) Serial.println("Error al iniciar la deteccion de cercania");
  if (!startAudioEvents(onAudioEvent, onAudioContext, onWakeWord)) Serial.println("Error al iniciar la deteccion de audio");

  bleManager.init(onAudioReceived, onCommandReceived);

  if (!startPhotoTask()) Serial.println("Error al crear la tarea de fotos");
  if (!startVisionTask()) Serial.println("Error al crear la tarea de vision");

  Serial.printf("[Memoria] RAM interna libre %u bytes (bloque mayor %u), PSRAM libre %u bytes\n",
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
  Serial.println("Iris ESP32 listo. Esperando conexion BLE...");
}

void loop() {
  if (otaActive()) {
    handleOtaUpdate();
    return;
  }
  handleSerialCommands();
  if (otaRequested) {
    otaRequested = false;
    enterOtaMode("pedido de la app o del serial");
    return;
  }

  handleButton();
  if (appPttStartRequested) {
    appPttStartRequested = false;
    startPushToTalk();
  }
  if (appPttStopRequested) {
    appPttStopRequested = false;
    if (isTransmitting) stopPushToTalk();
  }

  handleProximityBeeps();

  if (beepRequested) {
    beepRequested = false;
    playThinkingBeep();
  }

  // Al conectarse la app: cuanto lleva encendida la placa y por que se reinicio la ultima vez (con la
  // caja cerrada no hay monitor serial; asi se distingue un reinicio de una desconexion BLE).
  // CMD_HELLO:<segundos encendida>:<motivo del ultimo reinicio>:<RAM interna libre>
  static bool wasConnected = false;
  static uint32_t connectedSinceMs = 0;
  static bool helloSent = false;
  const bool connectedNow = bleManager.isConnected();
  if (connectedNow && !wasConnected) {
    connectedSinceMs = millis();
    helloSent = false;
  }
  if (connectedNow && !helloSent && millis() - connectedSinceMs > 3000) {  // la app ya se suscribio
    helloSent = true;
    static const char* const kReasons[] = {"?", "encendido", "externo", "software", "panic",
                                           "watchdog_int", "watchdog_tarea", "watchdog", "sueno",
                                           "bajo_voltaje", "sdio"};
    const int reason = (int)esp_reset_reason();
    char hello[64];
    snprintf(hello, sizeof(hello), "CMD_HELLO:%lu:%s:%u", (unsigned long)(millis() / 1000),
             reason >= 0 && reason <= 10 ? kReasons[reason] : "?",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    bleManager.sendCommand(hello);
  }
  wasConnected = connectedNow;

  // Si el telefono se desconecta con el boton apretado, no quedarse "transmitiendo"
  if (isTransmitting && !bleManager.isConnected()) {
    isTransmitting = false;
    wakeSession = false;
    setVisionPaused(false);
    setAudioEventsPaused(false);
  }
  if (collectingAudio && !bleManager.isConnected()) collectingAudio = false;

  int16_t samples[kMicMaxSamples];
  size_t sampleCount = readMicSamples(samples, kMicMaxSamples);
  if (sampleCount == 0) return;

  const size_t byteCount = sampleCount * sizeof(int16_t);

  // 1. Procesamiento local (Edge AI audio). Mientras Iris habla no se escucha: el microfono oiria su voz.
  static bool wasSpeaking = false;
  const bool speaking = isIrisSpeaking();
  if (speaking != wasSpeaking && !isTransmitting) {
    setAudioEventsPaused(speaking);
    wasSpeaking = speaking;
  }
  feedAudioEvents(samples, sampleCount);

  // 2. Transmision Bluetooth (push-to-talk / "Oye Iris" o recoleccion de datos)
  if (isTransmitting) {
    queuePush(samples, sampleCount, kTxQueueSamples);
    // Doble velocidad hasta vaciar el audio previo. Si el BLE esta ocupado no se espera: queda en la
    // cola y sale en las proximas vueltas (esperar aqui cortaba la lectura del microfono).
    // Nunca se bota la voz: si el BLE no tiene buffers libres, queda en la cola de 3 s (PSRAM) y sale
    // en las proximas vueltas (sin esperar: el loop debe seguir leyendo el microfono).
    if (bleManager.canSendNow()) {
      int16_t out[2 * kMicMaxSamples];
      const size_t count = queuePop(out, 2 * kMicMaxSamples);
      if (count > 0) bleManager.sendAudioChunk((const uint8_t*)out, count * sizeof(int16_t));
    }
    if (wakeSession) updateWakeSession(samples, sampleCount);
  } else {
    queuePush(samples, sampleCount, kPrerollSamples);
    // Ruido de ambiente: baja rapido y sube lento (la voz de otros no lo infla tanto).
    const float level = rmsOf(samples, sampleCount);
    noiseFloor += (level < noiseFloor ? 0.1f : 0.001f) * (level - noiseFloor);
    if (collectingAudio) bleManager.sendAudioChunk((const uint8_t*)samples, byteCount);
  }

  // Cuanto audio de la respuesta llego (diagnostico de paquetes BLE perdidos).
  size_t audioReceived, audioExpected;
  if (takeAudioStreamReport(&audioReceived, &audioExpected)) {
    char report[48];
    snprintf(report, sizeof(report), "CMD_AUDIO_RX:%u:%u", (unsigned)audioReceived, (unsigned)audioExpected);
    bleManager.sendCommand(report);
    Serial.printf("[Audio] Respuesta: %u de %u bytes\n", (unsigned)audioReceived, (unsigned)audioExpected);
  }

  // 3. "Oye Iris" detectado por la tarea de audio
  if (wakePercent != 0) {
    const int percent = wakePercent;
    wakePercent = 0;
    startWakeSession(percent);
  }
}

#endif
