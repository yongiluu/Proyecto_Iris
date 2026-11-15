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
#include "light_task.h"
#include "light_meter.h"
#include "model_store.h"
#include "ocr_task.h"
#include "scene_task.h"
#include "ota_update.h"
#include "button_gestures.h"
#include "power_manager.h"
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

namespace {
constexpr uint32_t kDebounceMs = 30;
constexpr uint32_t kStopFlushDelayMs = 80;

volatile bool beepRequested = false;
bool isTransmitting = false;
bool sceneReady = false;        // la descripcion de escenas arranco (modelo "escena" en la particion)
bool ocrReady = false;          // el lector de texto arranco (sus modelos estan en la particion)
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
  powerActivity();
  playAudioBuffer(data, length);
}

void onCommandReceived(const char* command) {
  powerActivity();  // la app la esta usando: no dormirse
  if (strcmp(command, "CMD_TAKE_PHOTO") == 0) {
    requestPhotoCapture();
  } else if (strcmp(command, "CMD_BEEP_THINKING") == 0) {
    beepRequested = true;
  } else if (strcmp(command, "CMD_COLLECT_AUDIO_START") == 0) {
    collectingAudio = true;
  } else if (strcmp(command, "CMD_COLLECT_AUDIO_STOP") == 0) {
    collectingAudio = false;
  } else if (strcmp(command, "CMD_COLLECT_FRAME") == 0) {
    requestColorFrameCapture();
  } else if (strncmp(command, "CMD_VOLUME:", 11) == 0) {
    setVolumePercent(atoi(command + 11));
  } else if (strncmp(command, "CMD_AUDIO_BEGIN:", 16) == 0) {
    beginAudioStream((size_t)strtoul(command + 16, nullptr, 10));
  } else if (strcmp(command, "CMD_OTA_WIFI") == 0) {
    otaRequested = true;
  } else if (strcmp(command, "CMD_APP_PTT_START") == 0) {
    appPttStartRequested = true;
  } else if (strcmp(command, "CMD_APP_PTT_STOP") == 0) {
    appPttStopRequested = true;
  } else if (strcmp(command, "CMD_LIGHT_ON") == 0) {
    requestLightMeter(true);
  } else if (strcmp(command, "CMD_LIGHT_OFF") == 0) {
    requestLightMeter(false);
  } else if (strcmp(command, "CMD_LIVE_ON") == 0 || strcmp(command, "CMD_LIVE_OFF") == 0) {
    // Modo en vivo: la placa describe sola cada cambio de la escena (CMD_SCENE_LIVE:<frase>).
    const bool on = command[9] == 'O' && command[10] == 'N';
    bleManager.sendCommand(setSceneLive(on) && on ? "CMD_LIVE:ON" : "CMD_LIVE:OFF");
  } else if (strcmp(command, "CMD_DESCRIBE") == 0) {
    if (sceneReady) {
      requestDescribeScene();
    } else {
      bleManager.sendCommand("CMD_SCENE:");  // sin modelo: la app no espera y usa la nube
    }
#ifdef IRIS_OCR
  } else if (strcmp(command, "CMD_READ_TEXT") == 0) {
    requestReadText();
#endif
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

// Se ejecuta en la tarea de escenas. Formato: CMD_SCENE:<frase> (vacia si no pudo).
// Modo en vivo: la escena cambio. Formato: CMD_SCENE_LIVE:<frase>.
void onSceneLive(const char* sentence) {
  static char command[440];
  snprintf(command, sizeof(command), "CMD_SCENE_LIVE:%s", sentence);
  bleManager.sendCommand(command);
}

// ─── Respuestas que la placa da por su cuenta (pedidas con el boton, sin que la app pregunte) ───
// Formato: CMD_SAY:<frase>. La app la muestra y la dice. Si la app todavia no se conecto (la placa
// acaba de despertar), la frase espera hasta SAY_HOLD_MS.
char pendingSay[440];
volatile bool sayPending = false;
volatile uint32_t sayQueuedMs = 0;
volatile bool buttonDescribe = false;  // la descripcion en curso la pidio el boton
volatile bool buttonRead = false;      // la lectura en curso la pidio el boton

void queueSay(const char* text) {
  sayPending = false;
  snprintf(pendingSay, sizeof(pendingSay), "CMD_SAY:%s", text);
  sayQueuedMs = millis();
  sayPending = true;
  powerActivity();
}

void onSceneDescribed(const char* sentence) {
  if (buttonDescribe) {
    buttonDescribe = false;
    queueSay(sentence[0] ? sentence : "No pude ver bien. Intenta de nuevo.");
    return;
  }
  static char command[440];
  snprintf(command, sizeof(command), "CMD_SCENE:%s", sentence);
  bleManager.sendCommand(command);
}

#ifdef IRIS_OCR
// Se ejecuta en la tarea del lector de texto. Formato: CMD_TEXT:<texto> (vacio si no encontro texto).
void onTextRead(const char* text) {
  if (buttonRead) {
    buttonRead = false;
    static char sentence[430];
    if (text[0]) {
      snprintf(sentence, sizeof(sentence), "Dice: %s", text);
      queueSay(sentence);
    } else {
      queueSay("No encontré texto. Acerca un poco el letrero.");
    }
    return;
  }
  static char command[440];
  snprintf(command, sizeof(command), "CMD_TEXT:%s", text);
  bleManager.sendCommand(command);
}
#endif

// Contexto silencioso (cada AMBIENT_CONTEXT_PERIOD_MS). Formato: CMD_AUDIO_CONTEXT:<clase>:<%>
void onAudioContext(const char* label, int percent) {
  char command[48];
  snprintf(command, sizeof(command), "CMD_AUDIO_CONTEXT:%s:%d", label, percent);
  bleManager.sendCommand(command);
}

// Se ejecuta en la tarea de inferencia de audio: solo avisa al loop.
void onWakeWord(int confidencePercent) {
  if (isIrisSpeaking()) return;  // el microfono oye la voz de Iris por el parlante
  wakePercent = confidencePercent > 0 ? confidencePercent : 1;
}

// [keepPreroll]: mandar tambien el audio de justo antes (lo que se dijo en los ~0,35 s que tarda en
// reconocerse que el boton se esta manteniendo).
void startPushToTalk(bool keepPreroll = false) {
  if (isTransmitting) {  // ya se estaba mandando por "Oye Iris": desde ahora manda el boton
    wakeSession = false;
    return;
  }
  Serial.println("Boton Presionado -> CMD_PTT_START");
  stopPlayback();  // si Iris estaba hablando, se calla para escuchar la pregunta nueva
  if (!keepPreroll) txCount = 0;
  isTransmitting = true;
  setLightPaused(true);
  setAudioEventsPaused(true);
  bleManager.sendCommand("CMD_PTT_START");
}

void stopPushToTalk() {
  Serial.println("Boton Soltado -> CMD_PTT_STOP");
  isTransmitting = false;
  wakeSession = false;
  flushTxQueue();
  setLightPaused(false);
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
  setLightPaused(true);
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
  requestLightMeter(false);
  setLightPaused(true);
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
    bleManager.shutdown();
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

// ─── Boton: gestos (button_gestures.h) ───
// Una tarea propia mira el boton cada 5 ms desde el primer instante: asi no se pierden toques
// mientras setup() enciende la camara y carga los modelos (la placa acaba de despertar).
ButtonGestures gestures;
QueueHandle_t buttonEvents = nullptr;
volatile bool gestureBusy = false;
volatile bool buttonDown = false;

bool readButtonPressed() {
  bool reading = digitalRead(BUTTON_PIN);
#ifdef BUTTON_PIN_BOOT
  reading = reading && digitalRead(BUTTON_PIN_BOOT);  // apretado (LOW) si cualquiera de los dos lo esta
#endif
  return reading == LOW;
}

void buttonTask(void*) {
  bool stable = readButtonPressed();
  bool last = stable;
  uint32_t lastChangeMs = millis();
  // El apreton que desperto a la placa es el primero del gesto.
  if (powerWokeByButton()) gestures.beginFromWake(stable, millis());
  for (;;) {
    const uint32_t now = millis();
    const bool reading = readButtonPressed();
    if (reading != last) {
      last = reading;
      lastChangeMs = now;
    }
    if (reading != stable && now - lastChangeMs >= kDebounceMs) stable = reading;
    const ButtonEvent event = gestures.update(stable, now);
    if (event != ButtonEvent::None) xQueueSend(buttonEvents, &event, 0);
    buttonDown = stable;
    gestureBusy = gestures.busy();
    if (gestureBusy) powerActivity();
    vTaskDelay(pdMS_TO_TICKS(5));
  }
}

bool talkActive = false;    // se esta manteniendo el boton para hablar
bool talkOffline = false;   // ...pero sin la app conectada: al soltar responde el modelo de la placa
uint32_t talkStartMs = 0;

// Un toque: la placa describe lo que ve con su propio modelo, sin celular ni internet.
void describeLocally() {
  playTone(1320.0f, 50);
  if (!sceneReady) {
    queueSay("Esta placa no tiene instalado el modelo para describir.");
    return;
  }
  buttonDescribe = true;
  requestDescribeScene();
}

// Tres toques: leer el texto de adelante.
void readLocally() {
  for (int i = 0; i < 3; i++) playTone(1320.0f, 40);
#ifdef IRIS_OCR
  if (ocrReady) {
    queueSay("Déjame leerlo.");
    buttonRead = true;
    requestReadText();
    return;
  }
#endif
  queueSay("Esta placa no tiene instalado el lector de texto.");
}

void handleButtonEvent(ButtonEvent event) {
  powerActivity();
  switch (event) {
    case ButtonEvent::TalkStart:
    case ButtonEvent::CloudTalkStart:
      talkActive = true;
      talkStartMs = millis();
      if (bleManager.commandsReady()) {
        talkOffline = false;
        // Toque + mantener: esta pregunta va directo a la nube (la app no prueba primero lo local).
        if (event == ButtonEvent::CloudTalkStart) bleManager.sendCommand("CMD_CLOUD_NEXT");
        startPushToTalk(/*keepPreroll=*/true);
      } else {
        // Sin celular nadie puede entender la pregunta: al soltar responde el modelo de la placa.
        talkOffline = true;
        playTone(880.0f, 60);
      }
      break;
    case ButtonEvent::TalkStop:
      talkActive = false;
      if (talkOffline) {
        talkOffline = false;
        describeLocally();
      } else if (isTransmitting) {
        stopPushToTalk();
      }
      break;
    case ButtonEvent::Tap1:
      describeLocally();
      break;
    case ButtonEvent::Tap2:
      // Dos toques: descripcion detallada de la nube (la pide la app). Sin app, la local.
      if (bleManager.commandsReady()) {
        playTone(1320.0f, 40);
        playTone(1320.0f, 40);
        bleManager.sendCommand("CMD_CLOUD_DESCRIBE");
      } else {
        describeLocally();
      }
      break;
    case ButtonEvent::Tap3:
      readLocally();
      break;
    case ButtonEvent::None:
      break;
  }
}

// Apaga todo y duerme la placa hasta el proximo toque del boton.
void enterSleep(const char* reason) {
  Serial.printf("[Energia] Durmiendo (%s)\n", reason);
  if (isTransmitting) stopPushToTalk();
  collectingAudio = false;
  requestLightMeter(false);
  setSceneLive(false);
  bleManager.sendCommand("CMD_SLEEP");  // la app sabe que no es una desconexion por error
  delay(200);
  setLightPaused(true);
  setAudioEventsPaused(true);
  shutdownCamera();
  bleManager.shutdown();
  powerDeepSleep();
}

// Modo en vivo: gasta como la placa siempre encendida, asi que se apaga solo a los LIVE_MAX_MS.
void handleLiveLimit() {
  static bool wasOn = false;
  static uint32_t sinceMs = 0;
  const bool on = sceneLiveActive();
  if (on && !wasOn) sinceMs = millis();
  wasOn = on;
  if (on && millis() - sinceMs >= LIVE_MAX_MS) {
    setSceneLive(false);
    wasOn = false;
    bleManager.sendCommand("CMD_LIVE:OFF");
    queueSay("Apagué el modo en vivo para cuidar la batería.");
  }
}

// Bateria (solo con el divisor de voltaje puesto: BATTERY_SENSE_ENABLED).
void handleBattery(bool justConnected) {
  if (!BATTERY_SENSE_ENABLED) return;
  static uint32_t lastCheckMs = 0;
  static bool lowAnnounced = false;
  static int lastMv = 0;
  const uint32_t now = millis();
  const bool due = lastCheckMs == 0 || now - lastCheckMs >= BATTERY_CHECK_MS;
  if (due) {
    lastCheckMs = now;
    lastMv = batteryMillivolts();
  }
  if ((due || justConnected) && bleManager.commandsReady()) {
    char command[40];
    snprintf(command, sizeof(command), "CMD_BATTERY:%d:%d", lastMv, batteryPercent(lastMv));
    bleManager.sendCommand(command);
  }
  if (!due) return;
  const BatteryLevel level = batteryLevel(lastMv);
  if (level == BatteryLevel::Critical) {
    // Tres tonos bajando: se acabo la pila. Dormida gasta casi nada hasta que la carguen.
    playTone(660.0f, 120);
    playTone(440.0f, 120);
    playTone(330.0f, 250);
    delay(700);
    enterSleep("bateria agotada");
  } else if (level == BatteryLevel::Low && !lowAnnounced) {
    lowAnnounced = true;
    playTone(440.0f, 120);
    playTone(330.0f, 200);
    queueSay("Queda poca batería. Carga la placa pronto.");
  }
}

void handleButton() {
  ButtonEvent event;
  while (xQueueReceive(buttonEvents, &event, 0) == pdTRUE) handleButtonEvent(event);

  // Mantenerlo apretado OTA_BUTTON_HOLD_MS (nadie habla tanto con el boton): actualizar por WiFi.
  static uint32_t holdHandledFor = 0;  // una sola vez por cada vez que se mantiene
  if (talkActive && buttonDown && millis() - talkStartMs >= OTA_BUTTON_HOLD_MS && holdHandledFor != talkStartMs) {
    holdHandledFor = talkStartMs;
    talkActive = false;
    talkOffline = false;
    enterOtaMode("boton mantenido");
  }
}
}

void setup() {
  powerBegin();
  pinMode(BUTTON_PIN, INPUT_PULLUP);
#ifdef BUTTON_PIN_BOOT
  pinMode(BUTTON_PIN_BOOT, INPUT_PULLUP);
#endif
  // Lo primero: mirar el boton (el toque que desperto a la placa puede ser el inicio de un gesto).
  buttonEvents = xQueueCreate(8, sizeof(ButtonEvent));
  xTaskCreatePinnedToCore(buttonTask, "boton", 3072, nullptr, 4, nullptr, 1);

  Serial.begin(115200);
  txQueue = (int16_t*)heap_caps_malloc(kTxQueueSamples * sizeof(int16_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#if ARDUINO_USB_CDC_ON_BOOT
  // Con USB nativo (XIAO) lo que se imprime antes de abrir el monitor se pierde: espera un poco al PC
  // para que se vean los autotests. Sin cable sigue a los 2,5 s. Al despertar con el boton no se
  // espera: la persona esta esperando su respuesta.
  while (!powerWokeByButton() && !Serial && millis() < 2500) delay(10);
#endif

  if (!initCamera()) Serial.println("Error al inicializar la camara");
  if (!initAudioPlayer()) Serial.println("Error al inicializar el reproductor de audio");
  if (!initMic()) Serial.println("Error al inicializar el microfono");

  if (!startAudioEvents(onAudioEvent, onAudioContext, onWakeWord)) Serial.println("Error al iniciar la deteccion de audio");

  bleManager.init(onAudioReceived, onCommandReceived);

  if (!startPhotoTask()) Serial.println("Error al crear la tarea de fotos");
  if (!startLightTask()) Serial.println("Error al crear la tarea del detector de luz");
  modelStoreBegin();  // modelos fuera del programa (lector de texto...); solo informa lo que hay
  sceneReady = startSceneTask(onSceneDescribed, onSceneLive);
  if (!sceneReady) Serial.println("Descripcion de escenas apagada (falta su modelo): la app describe con la nube");
#ifdef IRIS_OCR
  ocrReady = startOcrTask(onTextRead);
  if (!ocrReady) Serial.println("Lector de texto apagado (faltan sus modelos): la app lee con el celular");
#endif

  Serial.printf("[Memoria] RAM interna libre %u bytes (bloque mayor %u), PSRAM libre %u bytes\n",
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
  Serial.printf("Iris ESP32 listo en %lu ms%s. Esperando conexion BLE...\n", (unsigned long)millis(),
                powerWokeByButton() ? " (desperto con el boton)" : "");
  powerActivity();
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
  handleLiveLimit();

  // Respuesta pendiente de la placa: sale apenas la app escucha; si no llega nadie, se descarta.
  if (sayPending) {
    if (bleManager.commandsReady()) {
      sayPending = false;
      bleManager.sendCommand(pendingSay);
    } else if (millis() - sayQueuedMs >= SAY_HOLD_MS) {
      sayPending = false;
      Serial.println("[Boton] Nadie conectado: la respuesta se descarto");
    }
  }

  // Mientras alguien la usa, la placa sigue despierta; despues de POWER_IDLE_SLEEP_MS quieta, duerme.
  if (isTransmitting || collectingAudio || gestureBusy || sayPending || buttonDescribe || buttonRead ||
      isIrisSpeaking() || sceneLiveActive() || lightMeterActive()) {
    powerActivity();
  }
  if (powerShouldSleep()) enterSleep("sin uso");

  if (appPttStartRequested) {
    appPttStartRequested = false;
    startPushToTalk();
  }
  if (appPttStopRequested) {
    appPttStopRequested = false;
    if (isTransmitting) stopPushToTalk();
  }

  if (beepRequested) {
    beepRequested = false;
    playThinkingBeep();
  }

  // Al conectarse la app: cuanto lleva encendida la placa y por que se reinicio la ultima vez (con la
  // caja cerrada no hay monitor serial; asi se distingue un reinicio de una desconexion BLE).
  // CMD_HELLO:<segundos encendida>:<motivo del ultimo reinicio>:<RAM interna libre>:<volumen>:<funciones>:<camara>
  // <funciones>: lo que sabe hacer este firmware ("luz,ocr"), para que la app no espere una
  // respuesta que nunca va a llegar (ej. "¿que dice aqui?" a una placa sin el lector).
  static bool wasConnected = false;
  static uint32_t connectedSinceMs = 0;
  static bool helloSent = false;
  const bool connectedNow = bleManager.isConnected();
  if (connectedNow && !wasConnected) {
    connectedSinceMs = millis();
    helloSent = false;
    powerActivity();
  }
  handleBattery(connectedNow && !wasConnected);
  if (connectedNow && !helloSent && millis() - connectedSinceMs > 3000) {  // la app ya se suscribio
    helloSent = true;
    static const char* const kReasons[] = {"?", "encendido", "externo", "software", "panic",
                                           "watchdog_int", "watchdog_tarea", "watchdog", "sueno",
                                           "bajo_voltaje", "sdio"};
    const int reason = (int)esp_reset_reason();
    // "ocr" solo si el lector arranco de verdad (con sus modelos en la particion).
    char kFeatures[32];
    snprintf(kFeatures, sizeof(kFeatures), "luz%s%s", ocrReady ? ",ocr" : "", sceneReady ? ",escena,vivo" : "");
    char hello[112];
    snprintf(hello, sizeof(hello), "CMD_HELLO:%lu:%s:%u:%d:%s:%s", (unsigned long)(millis() / 1000),
             reason >= 0 && reason <= 10 ? kReasons[reason] : "?",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL), getVolumePercent(), kFeatures,
             cameraSensorName());
    bleManager.sendCommand(hello);
  }
  // Sin app no hay quien escuche: el modo en vivo se apaga al desconectarse.
  if (!connectedNow && wasConnected && sceneLiveActive()) setSceneLive(false);
  wasConnected = connectedNow;

  // Si el telefono se desconecta con el boton apretado, no quedarse "transmitiendo"
  if (isTransmitting && !bleManager.isConnected()) {
    isTransmitting = false;
    wakeSession = false;
    setLightPaused(false);
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
    if (!speaking) {
      // Diagnostico: cuanta voz salio de verdad por el amplificador (la app lo registra).
      char log[48];
      snprintf(log, sizeof(log), "CMD_LOG:voz_reproducida:%u", (unsigned)takePlayedBytes());
      bleManager.sendCommand(log);
    }
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
