#include "photo_transfer.h"
#include "camera_driver.h"
#include "ble_manager.h"
#include "config.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// Protocolo hacia la app (ver esp32_speech_service.dart):
//   CMD_PHOTO_START:<bytes>  -> notificaciones de la caracteristica de foto -> CMD_PHOTO_END
//   CMD_PHOTO_ERROR si algo falla.

namespace {
TaskHandle_t photoTaskHandle = nullptr;

void sendPhoto() {
  camera_fb_t* frame = acquireJpegFrame();
  if (frame == nullptr) {
    Serial.println("[Foto] No se pudo capturar el JPEG");
    bleManager.sendCommand("CMD_PHOTO_ERROR");
    return;
  }

  char header[40];
  snprintf(header, sizeof(header), "CMD_PHOTO_START:%u", (unsigned)frame->len);
  bool ok = bleManager.sendCommand(header);

  const size_t chunkSize = bleManager.payloadSize();
  for (size_t offset = 0; ok && offset < frame->len; offset += chunkSize) {
    size_t length = frame->len - offset;
    if (length > chunkSize) length = chunkSize;

    ok = bleManager.sendPhotoChunk(frame->buf + offset, length);
    delay(PHOTO_CHUNK_DELAY_MS); // backpressure: evita saturar la cola de NimBLE y corromper el JPEG
  }

  Serial.printf("[Foto] %u bytes, %s\n", (unsigned)frame->len, ok ? "enviada" : "fallo el envio");
  releaseJpegFrame(frame);
  bleManager.sendCommand(ok ? "CMD_PHOTO_END" : "CMD_PHOTO_ERROR");
}

void photoTask(void*) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    sendPhoto();
  }
}
}

bool startPhotoTask() {
  // Pila amplia: snprintf + llamadas BLE. Nucleo 0 para no competir con el loop de audio (nucleo 1).
  return xTaskCreatePinnedToCore(photoTask, "photo_tx", 6144, nullptr, 2, &photoTaskHandle, 0) == pdPASS;
}

void requestPhotoCapture() {
  if (photoTaskHandle != nullptr) xTaskNotifyGive(photoTaskHandle);
}
