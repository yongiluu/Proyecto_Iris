// Los firmwares de captura de datos (audio_capture.cpp, photo_capture.cpp) tienen su propio setup/loop
#if !defined(IRIS_AUDIO_CAPTURE) && !defined(IRIS_PHOTO_CAPTURE)

#include <Arduino.h>
#include "config.h"
#include "camera_driver.h"
#include "audio_events.h"
#include "audio_player.h"
#include "ble_manager.h"
#include "mic_driver.h"
#include "photo_transfer.h"
#include "tflite_vision.h"
#include "vision_task.h"

namespace {
constexpr uint32_t kDebounceMs = 50;
constexpr uint32_t kStopFlushDelayMs = 20;

volatile bool beepRequested = false;
bool isTransmitting = false;
// Modo recoleccion de datos (pantalla "Misiones" de la app): manda el microfono crudo sin apretar el boton.
volatile bool collectingAudio = false;

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
  } else {
    Serial.printf("[BLE] Comando desconocido: %s\n", command);
  }
}

// Se ejecuta en la tarea de inferencia de audio. Formato: CMD_AUDIO_EVENT:<clase>:<porcentaje>
void onAudioEvent(const char* label, int confidencePercent) {
  char command[48];
  snprintf(command, sizeof(command), "CMD_AUDIO_EVENT:%s:%d", label, confidencePercent);
  bleManager.sendCommand(command);
}

// Se ejecuta en la tarea de vision. Formato: CMD_VISION_EVENT:<clase>:<porcentaje>
void onVisionEvent(const char* label, int confidencePercent) {
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

void startPushToTalk() {
  Serial.println("Boton Presionado -> CMD_PTT_START");
  isTransmitting = true;
  setVisionPaused(true);
  setAudioEventsPaused(true);
  bleManager.sendCommand("CMD_PTT_START");
}

void stopPushToTalk() {
  Serial.println("Boton Soltado -> CMD_PTT_STOP");
  isTransmitting = false;
  setVisionPaused(false);
  setAudioEventsPaused(false);
  delay(kStopFlushDelayMs); // deja vaciar la cola BLE de audio antes del STOP
  bleManager.sendCommand("CMD_PTT_STOP");
}

void handleButton() {
  static bool stableState = HIGH;
  static bool lastReading = HIGH;
  static uint32_t lastChangeMs = 0;

  bool reading = digitalRead(BUTTON_PIN);
  if (reading != lastReading) {
    lastReading = reading;
    lastChangeMs = millis();
  }

  if (reading != stableState && millis() - lastChangeMs >= kDebounceMs) {
    stableState = reading;
    if (stableState == LOW) startPushToTalk();
    else stopPushToTalk();
  }
}
}

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  if (!initCamera()) Serial.println("Error al inicializar la camara");
  if (!initAudioPlayer()) Serial.println("Error al inicializar el reproductor de audio");
  if (!initMic()) Serial.println("Error al inicializar el microfono");

  if (!initVisionAI(onVisionEvent, onVisionContext)) Serial.println("Error al iniciar la vision local");
  if (!startAudioEvents(onAudioEvent, onAudioContext)) Serial.println("Error al iniciar la deteccion de audio");

  bleManager.init(onAudioReceived, onCommandReceived);

  if (!startPhotoTask()) Serial.println("Error al crear la tarea de fotos");
  if (!startVisionTask()) Serial.println("Error al crear la tarea de vision");

  Serial.println("Iris ESP32 listo. Esperando conexion BLE...");
}

void loop() {
  handleButton();

  if (beepRequested) {
    beepRequested = false;
    playThinkingBeep();
  }

  // Si el telefono se desconecta con el boton apretado, no quedarse "transmitiendo"
  if (isTransmitting && !bleManager.isConnected()) {
    isTransmitting = false;
    setVisionPaused(false);
    setAudioEventsPaused(false);
  }
  if (collectingAudio && !bleManager.isConnected()) collectingAudio = false;

  int16_t samples[kMicMaxSamples];
  size_t sampleCount = readMicSamples(samples, kMicMaxSamples);
  if (sampleCount == 0) return;

  const size_t byteCount = sampleCount * sizeof(int16_t);

  // 1. Procesamiento local (Edge AI audio)
  feedAudioEvents(samples, sampleCount);

  // 2. Transmision Bluetooth (push-to-talk o recoleccion de datos)
  if (isTransmitting || collectingAudio) {
    bleManager.sendAudioChunk((const uint8_t*)samples, byteCount);
  }
}

#endif
