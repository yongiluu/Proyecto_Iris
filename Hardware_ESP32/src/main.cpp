#include <Arduino.h>
#include "config.h"
#include "camera_driver.h"
#include "audio_player.h"
#include "ble_manager.h"
#include <driver/i2s.h>

#define I2S_MIC_PORT I2S_NUM_0
#define I2S_MIC_SCK  42
#define I2S_MIC_WS   41
#define I2S_MIC_SD   40
#define BUTTON_PIN   14

// Definimos el callback global
void onAudioReceived(const uint8_t* data, size_t length) {
  playAudioBuffer((uint8_t*)data, length);
}

void initMic() {
  i2s_config_t i2s_mic_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = AUDIO_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t i2s_mic_pins = {
    .bck_io_num = I2S_MIC_SCK,
    .ws_io_num = I2S_MIC_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_MIC_SD
  };

  i2s_driver_install(I2S_MIC_PORT, &i2s_mic_config, 0, NULL);
  i2s_set_pin(I2S_MIC_PORT, &i2s_mic_pins);
}

bool lastButtonState = HIGH;
bool isTransmitting = false;
bool isCapturingPhoto = false;

void triggerCameraCapture() {
  isCapturingPhoto = true;
}

void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  if (!initCamera()) {
    Serial.println("Error al inicializar la camara");
  }

  initAudioPlayer();
  initMic();

  bleManager.init(onAudioReceived);
  
  Serial.println("Iris ESP32 listo. Esperando conexion BLE...");
}

void loop() {
  if (isCapturingPhoto) {
    isCapturingPhoto = false;
    camera_fb_t * fb = capturePhoto();
    if (fb != NULL) {
      Serial.printf("Foto capturada: %d bytes\n", fb->len);
      char startCmd[32];
      sprintf(startCmd, "CMD_PHOTO_START:%d", fb->len);
      bleManager.sendCommand(startCmd);
      delay(50);

      size_t bytesSent = 0;
      const size_t CHUNK_SIZE = 240; // Extremely safe MTU size
      while(bytesSent < fb->len) {
          size_t toSend = fb->len - bytesSent;
          if (toSend > CHUNK_SIZE) toSend = CHUNK_SIZE;
          bleManager.sendPhotoChunk(fb->buf + bytesSent, toSend);
          bytesSent += toSend;
          delay(20); // 12 KB/s - Guaranteed to never overflow the BLE queue
      }
      delay(50);
      bleManager.sendCommand("CMD_PHOTO_END");
      esp_camera_fb_return(fb);
    } else {
      bleManager.sendCommand("CMD_PHOTO_ERROR");
    }
  }

  bool reading = digitalRead(BUTTON_PIN);

  if (reading != lastButtonState) {
    if (reading == LOW) {
      Serial.println("Boton Presionado -> CMD_PTT_START");
      bleManager.sendCommand("CMD_PTT_START");
      isTransmitting = true;
    } else {
      Serial.println("Boton Soltado -> CMD_PTT_STOP");
      isTransmitting = false;
      delay(20); // Allow BLE queue to flush audio before sending stop command
      bleManager.sendCommand("CMD_PTT_STOP");
    }
    delay(50); // Debounce
  }
  lastButtonState = reading;

  if (isTransmitting && bleManager.isConnected()) {
    int32_t samples[125]; // 500 bytes i2s
    size_t bytes_read = 0;
    
    esp_err_t result = i2s_read(I2S_MIC_PORT, &samples, sizeof(samples), &bytes_read, portMAX_DELAY);
    
    if (result == ESP_OK && bytes_read > 0) {
      int num_samples = bytes_read / 4;
      int16_t out_buf[125]; 
      
      // INMP441 uses 24-bit left justified in 32-bit (shifted by 14)
      for(int i = 0; i < num_samples; i++) {
        out_buf[i] = samples[i] >> 14;
      }
      
      bleManager.sendAudioChunk((const uint8_t*)out_buf, num_samples * 2);
    }
  } else {
    // Evitamos saturar la CPU si no estamos transmitiendo
    delay(10);
  }
}
