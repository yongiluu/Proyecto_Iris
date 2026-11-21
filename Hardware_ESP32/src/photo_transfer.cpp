#include "photo_transfer.h"
#include "camera_driver.h"
#include <esp_heap_caps.h>
#include <string.h>
#include "ble_manager.h"
#include "config.h"
#include "image_convert.h"
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

  // El envio por BLE tarda segundos: se copia el JPEG a PSRAM y se libera la camara antes (si no, la
  // descripcion de escenas, el lector y el detector de luz se quedan sin camara todo ese rato). Si no
  // hay memoria para la copia, se envia desde el frame como antes (con la camara tomada).
  const size_t jpegLength = frame->len;
  uint8_t* copy = (uint8_t*)heap_caps_malloc(jpegLength, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  const uint8_t* jpeg = frame->buf;
  if (copy != nullptr) {
    memcpy(copy, frame->buf, jpegLength);
    releaseJpegFrame(frame);
    frame = nullptr;
    jpeg = copy;
  }

  char header[40];
  snprintf(header, sizeof(header), "CMD_PHOTO_START:%u", (unsigned)jpegLength);
  bool ok = bleManager.sendCommand(header);

  const size_t chunkSize = bleManager.payloadSize();
  for (size_t offset = 0; ok && offset < jpegLength; offset += chunkSize) {
    size_t length = jpegLength - offset;
    if (length > chunkSize) length = chunkSize;

    ok = bleManager.sendPhotoChunk(jpeg + offset, length);
    delay(PHOTO_CHUNK_DELAY_MS); // backpressure: evita saturar la cola de NimBLE y corromper el JPEG
  }

  Serial.printf("[Foto] %u bytes, %s\n", (unsigned)jpegLength, ok ? "enviada" : "fallo el envio");
  if (frame != nullptr) releaseJpegFrame(frame);
  if (copy != nullptr) heap_caps_free(copy);
  bleManager.sendCommand(ok ? "CMD_PHOTO_END" : "CMD_PHOTO_ERROR");
}

constexpr uint32_t kRequestJpeg = 1 << 0;
constexpr uint32_t kRequestFrame = 1 << 1;
// 160x120 RGB565 (37,5 KB, en PSRAM). Tamano fijo: se reserva una vez con el maximo y cada frame se
// valida contra eso (antes se reservaba con el tamano del primero y uno mayor despues se salia).
constexpr size_t kFrameCopyBytes = (size_t)160 * 120 * 2u;
uint8_t* frameCopy = nullptr;

// Frame a color 160x120 RGB565, exactamente lo que ve el modelo de escenas (Retina), para juntar fotos
// reales de la placa desde la app (pantalla Misiones). Se copia y se libera la camara antes de enviar.
void sendColorFrame() {
  camera_fb_t* frame = acquireColorFrame();
  bool ok = frame != nullptr && frame->format == PIXFORMAT_RGB565 &&
            frame->len >= (size_t)frame->width * frame->height * 2u;
  // La misma imagen que recibe Retina: derecha segun el montaje y en 160x120 (image_convert.h).
  const unsigned width = 160, height = 120;
  const size_t length = (size_t)width * height * 2u;
  static uint8_t* rgb = nullptr;  // 160x120x3 intermedio, en PSRAM
  if (ok) {
    if (frameCopy == nullptr) {
      frameCopy = (uint8_t*)heap_caps_malloc(kFrameCopyBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    if (rgb == nullptr) rgb = (uint8_t*)heap_caps_malloc((size_t)width * height * 3, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ok = frameCopy != nullptr && rgb != nullptr && length <= kFrameCopyBytes && frame->width >= width &&
         frame->height >= height;
    if (ok) {
      rgb565UprightToRgb888(frame->buf, frame->width, frame->height, CAMERA_MOUNT, rgb, width, height);
      rgb888ToRgb565(rgb, (size_t)width * height, frameCopy);
    }
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
