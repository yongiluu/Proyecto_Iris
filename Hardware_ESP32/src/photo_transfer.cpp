#include "photo_transfer.h"
#include "camera_driver.h"
#include <esp_heap_caps.h>
#include <string.h>
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
constexpr uint32_t kRequestFrame = 1 << 1;
uint8_t* frameCopy = nullptr;  // 160x120 RGB565 (37,5 KB, en PSRAM)

// Frame a color 160x120 RGB565, exactamente lo que ve el modelo de escenas (Retina), para juntar fotos
// reales de la placa desde la app (pantalla Misiones). Se copia y se libera la camara antes de enviar.
void sendColorFrame() {
  camera_fb_t* frame = acquireColorFrame();
  bool ok = frame != nullptr && frame->format == PIXFORMAT_RGB565 &&
            frame->len >= (size_t)frame->width * frame->height * 2u;
  unsigned width = 0, height = 0;
  size_t length = 0;
  if (ok) {
    width = frame->width;
    height = frame->height;
    length = (size_t)width * height * 2u;
    if (frameCopy == nullptr) {
      frameCopy = (uint8_t*)heap_caps_malloc(length, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    ok = frameCopy != nullptr && length <= (size_t)160 * 120 * 2u;
    if (ok) memcpy(frameCopy, frame->buf, length);
  }
  if (frame != nullptr) releaseColorFrame(frame);
  if (!ok) {
    bleManager.sendCommand("CMD_FRAME_ERROR");
    return;
  }

  char header[48];
  snprintf(header, sizeof(header), "CMD_FRAME_START:%u:%u:rgb565", width, height);
  ok = bleManager.sendCommand(header);
  const size_t chunkSize = bleManager.payloadSize();
  for (size_t offset = 0; ok && offset < length; offset += chunkSize) {
    size_t chunk = length - offset;
    if (chunk > chunkSize) chunk = chunkSize;
    ok = bleManager.sendPhotoChunk(frameCopy + offset, chunk);
    delay(PHOTO_CHUNK_DELAY_MS);
  }
  bleManager.sendCommand(ok ? "CMD_FRAME_END" : "CMD_FRAME_ERROR");
}

void photoTask(void*) {
  for (;;) {
    uint32_t requests = 0;
    xTaskNotifyWait(0, UINT32_MAX, &requests, portMAX_DELAY);
    if (requests & kRequestJpeg) sendPhoto();
    if (requests & kRequestFrame) sendColorFrame();
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

void requestColorFrameCapture() {
  if (photoTaskHandle != nullptr) xTaskNotify(photoTaskHandle, kRequestFrame, eSetBits);
}
