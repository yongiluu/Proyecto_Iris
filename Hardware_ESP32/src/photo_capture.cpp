// Firmware de CAPTURA DE FOTOS para entrenar: envia por USB los frames 96x96 en grises que ve el
// modelo de vision, para guardarlos con ML_Training/vision/capture_photos.py. No usa BLE ni audio.
// Se compila solo en el entorno seeed_xiao_esp32s3_photo_capture de platformio.ini.
#ifdef IRIS_PHOTO_CAPTURE

#include <Arduino.h>
#include "camera_driver.h"
#include "config.h"

// Paquete: 'I' 'R' 'I' 'M' | uint16 ancho | uint16 alto | pixeles (ancho*alto bytes) | uint16 suma de pixeles (LE)
static const uint8_t kPacketMagic[4] = {'I', 'R', 'I', 'M'};

void setup() {
  Serial.begin(VISION_CAPTURE_BAUD);
  delay(500);
  Serial.println("IRIS_PHOTO_CAPTURE listo (96x96 grises)");
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

  camera_fb_t* frame = acquireGrayFrame();
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
  releaseGrayFrame(frame);
}

#endif
