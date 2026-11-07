// Firmware de CAPTURA DE FOTOS para entrenar: envia por USB los frames a color 160x120 (RGB565) que ve
// la placa, para guardarlos con ML_Training/vision/capture_photos.py. El script guarda la foto a color
// (descripcion de escenas) y su version 96x96 en grises (modelos de escenas y cercania).
// No usa BLE ni audio. Se compila solo en el entorno seeed_xiao_esp32s3_photo_capture de platformio.ini.
#ifdef IRIS_PHOTO_CAPTURE

#include <Arduino.h>
#include "camera_driver.h"
#include "config.h"

// Paquete: 'I' 'R' 'I' 'C' | uint16 ancho | uint16 alto | pixeles RGB565 (ancho*alto*2 bytes, byte alto
// primero) | uint16 suma de los bytes (LE). Todo en little-endian salvo los pixeles.
static const uint8_t kPacketMagic[4] = {'I', 'R', 'I', 'C'};

void setup() {
  Serial.begin(VISION_CAPTURE_BAUD);
  delay(500);
  Serial.println("IRIS_PHOTO_CAPTURE listo (160x120 color RGB565)");
  if (!initCamera()) {
    for (;;) {
      Serial.println("Error al inicializar la camara");
      delay(1000);
    }
  }
}

void loop() {
  static uint32_t lastSentMs = 0;
  if (millis() - lastSentMs < VISION_CAPTURE_INTERVAL_MS) return;
  lastSentMs = millis();

  camera_fb_t* frame = acquireColorFrame();
  if (frame == nullptr) return;

  uint16_t checksum = 0;
  for (size_t i = 0; i < frame->len; i++) checksum += frame->buf[i];

  uint8_t header[8];
  memcpy(header, kPacketMagic, 4);
  header[4] = (uint8_t)(frame->width & 0xFF);
  header[5] = (uint8_t)(frame->width >> 8);
  header[6] = (uint8_t)(frame->height & 0xFF);
  header[7] = (uint8_t)(frame->height >> 8);
  Serial.write(header, sizeof(header));
  Serial.write(frame->buf, frame->len);
  Serial.write((const uint8_t*)&checksum, sizeof(checksum));
  releaseColorFrame(frame);
}

#endif
