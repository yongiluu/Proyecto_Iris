// Firmware de CAPTURA DE DATOS: envia el microfono crudo por el puerto serie/USB para grabar
// ejemplos reales con ML_Training/audio/capture_from_board.py. No usa BLE ni camara.
// Se compila solo en los entornos *_audio_capture de platformio.ini.
#ifdef IRIS_AUDIO_CAPTURE

#include <Arduino.h>
#include "config.h"
#include "mic_driver.h"

// Paquete: 'I' 'R' 'A' 'U' | uint16 cantidad de muestras (LE) | muestras int16 (LE)
static const uint8_t kPacketMagic[4] = {'I', 'R', 'A', 'U'};

void setup() {
#if !ARDUINO_USB_CDC_ON_BOOT
  Serial.setTxBufferSize(16384);  // UART del devkit: absorber rafagas sin perder audio
#endif
  Serial.begin(AUDIO_CAPTURE_BAUD);
  delay(500);
  Serial.println("IRIS_AUDIO_CAPTURE listo (16 kHz, PCM 16-bit)");
  if (!initMic()) {
    for (;;) {
      Serial.println("Error al inicializar el microfono");
      delay(1000);
    }
  }
}

void loop() {
  int16_t samples[kMicMaxSamples];
  size_t count = readMicSamples(samples, kMicMaxSamples);
  if (count == 0) return;

  uint8_t header[6];
  memcpy(header, kPacketMagic, 4);
  header[4] = (uint8_t)(count & 0xFF);
  header[5] = (uint8_t)(count >> 8);
  Serial.write(header, sizeof(header));
  Serial.write((const uint8_t*)samples, count * sizeof(int16_t));
}

#endif
