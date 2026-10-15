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

constexpr uint32_t kRequestJpeg = 1 << 0;
constexpr uint32_t kRequestGray = 1 << 1;
uint8_t grayCopy[96 * 96];

// Frame 96x96 en grises para recolectar datos de entrenamiento desde la app.
void sendGrayFrame() {
  camera_fb_t* frame = acquireGrayFrame();
  if (frame == nullptr || frame->len > sizeof(grayCopy)) {
    if (frame) releaseGrayFrame(frame);
    bleManager.sendCommand("CMD_FRAME_ERROR");
    return;
  }
  // Copiar y liberar enseguida: la vision local no debe quedarse sin camara durante el envio.
  const size_t length = frame->len;
  const unsigned width = frame->width, height = frame->height;
  memcpy(grayCopy, frame->buf, length);
  releaseGrayFrame(frame);

  char header[40];
  snprintf(header, sizeof(header), "CMD_FRAME_START:%u:%u", width, height);
  bool ok = bleManager.sendCommand(header);
  const size_t chunkSize = bleManager.payloadSize();
  for (size_t offset = 0; ok && offset < length; offset += chunkSize) {
    size_t chunk = length - offset;
    if (chunk > chunkSize) chunk = chunkSize;
    ok = bleManager.sendPhotoChunk(grayCopy + offset, chunk);
    delay(PHOTO_CHUNK_DELAY_MS);
  }
  bleManager.sendCommand(ok ? "CMD_FRAME_END" : "CMD_FRAME_ERROR");
}

void photoTask(void*) {
  for (;;) {
    uint32_t requests = 0;
    xTaskNotifyWait(0, UINT32_MAX, &requests, portMAX_DELAY);
    if (requests & kRequestJpeg) sendPhoto();
    if (requests & kRequestGray) sendGrayFrame();
  }
}
}

bool startPhotoTask() {
  // Pila amplia: snprintf + llamadas BLE. Nucleo 0 para no competir con el loop de audio (nucleo 1).
  return xTaskCreatePinnedToCore(photoTask, "photo_tx", 6144, nullptr, 2, &photoTaskHandle, 0) == pdPASS;
}

void requestPhotoCapture() {
  if (photoTaskHandle != nullptr) xTaskNotify(photoTaskHandle, kRequestJpeg, eSetBits);
}

void requestGrayFrameCapture() {
  if (photoTaskHandle != nullptr) xTaskNotify(photoTaskHandle, kRequestGray, eSetBits);
}
