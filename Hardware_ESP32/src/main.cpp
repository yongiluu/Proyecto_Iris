#include <Arduino.h>
#include "config.h"
#include "camera_driver.h"
#include "audio_player.h"
#include "ble_manager.h"
#include "audio_processing.h"
#include "mic_driver.h"
#include "photo_transfer.h"
#include "tflite_inference.h"
#include "tflite_vision.h"
#include "vision_task.h"

namespace {
constexpr uint32_t kDebounceMs = 50;
constexpr uint32_t kStopFlushDelayMs = 20;

volatile bool beepRequested = false;
bool isTransmitting = false;

// Se ejecuta en el hilo BLE: solo encolar, nunca bloquear.
void onAudioReceived(const uint8_t* data, size_t length) {
  playAudioBuffer(data, length);
}

void onCommandReceived(const char* command) {
  if (strcmp(command, "CMD_TAKE_PHOTO") == 0) {
    requestPhotoCapture();
  } else if (strcmp(command, "CMD_BEEP_THINKING") == 0) {
    beepRequested = true;
  } else {
    Serial.printf("[BLE] Comando desconocido: %s\n", command);
  }
}

void startPushToTalk() {
  Serial.println("Boton Presionado -> CMD_PTT_START");
  isTransmitting = true;
  setVisionPaused(true);
  bleManager.sendCommand("CMD_PTT_START");
}

void stopPushToTalk() {
  Serial.println("Boton Soltado -> CMD_PTT_STOP");
  isTransmitting = false;
  setVisionPaused(false);
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

  initAudioProcessing(); // Motor FFT (Edge AI audio)
  initEdgeAI();          // TensorFlow Lite Micro (audio)
  initVisionAI();        // TensorFlow Lite Micro (imagenes)

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
  }

  int16_t samples[kMicMaxSamples];
  size_t sampleCount = readMicSamples(samples, kMicMaxSamples);
  if (sampleCount == 0) return;

  const size_t byteCount = sampleCount * sizeof(int16_t);

  // 1. Procesamiento local (Edge AI audio)
  processAudioFrame(samples, byteCount);

  // 2. Transmision Bluetooth
  if (isTransmitting) {
    bleManager.sendAudioChunk((const uint8_t*)samples, byteCount);
  }
}
