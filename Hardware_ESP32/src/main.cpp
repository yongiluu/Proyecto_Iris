#include <Arduino.h>
#include "config.h"
#include "camera_driver.h"
#include "audio_player.h"
#include "ble_manager.h"
#include "audio_processing.h"
#include "tflite_inference.h"
#include "tflite_vision.h"
#include <driver/i2s.h>



// Definimos el callback global
void onAudioReceived(const uint8_t* data, size_t length) {
  playAudioBuffer((uint8_t*)data, length);
}

void initMic() {
  i2s_config_t i2s_mic_config = {
#ifdef IRIS_XIAO
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
    .sample_rate = AUDIO_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,
#else
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = AUDIO_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
#endif
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t i2s_mic_pins = {
    .bck_io_num = I2S_AMP_BCLK,
    .ws_io_num = I2S_AMP_LRC,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_AMP_DIN
  };

  i2s_driver_install(I2S_MIC_PORT, &i2s_mic_config, 0, NULL);
  i2s_set_pin(I2S_MIC_PORT, &i2s_mic_pins);
}

void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  if (!initCamera()) {
    Serial.println("Error al inicializar la camara");
  }

  initAudioPlayer();
  initMic();
  initAudioProcessing(); // Inicializar motor FFT Edge AI
  initEdgeAI(); // Inicializar TensorFlow Lite Micro (Audio)
  initVisionAI(); // Inicializar TensorFlow Lite Micro (ImÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡genes)

  bleManager.init(onAudioReceived);
  
  Serial.println("Iris ESP32 listo. Esperando conexion BLE...");
}

void loop() {
  static bool isCapturingPhoto = false;
  static bool isTransmitting = false;
  static bool lastButtonState = HIGH;

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

  // Lectura continua del microfono para Edge AI
#ifdef IRIS_XIAO
  int16_t samples[250]; // 500 bytes (PDM 16-bit)
#else
  int32_t samples[125]; // 500 bytes (I2S 32-bit)
#endif
  size_t bytes_read = 0;
  
  esp_err_t result = i2s_read(I2S_MIC_PORT, &samples, sizeof(samples), &bytes_read, portMAX_DELAY);
  
  if (result == ESP_OK && bytes_read > 0) {
#ifdef IRIS_XIAO
    int num_samples = bytes_read / 2;
    int16_t* out_buf = samples;
#else
    int num_samples = bytes_read / 4;
    int16_t out_buf[125]; 
    for(int i = 0; i < num_samples; i++) {
      out_buf[i] = samples[i] >> 14;
    }
#endif
    
    // 1. Procesamiento Local (Edge AI Audio)
    processAudioFrame(out_buf, num_samples * 2);
    
    // 2. Transmision Bluetooth
    if (isTransmitting && bleManager.isConnected()) {
      bleManager.sendAudioChunk((const uint8_t*)out_buf, num_samples * 2);
    }
  }

  // 3. Procesamiento Local (Edge AI Vision) - 1 vez por segundo
  static unsigned long lastVisionTime = 0;
  if (millis() - lastVisionTime > 1000) {
    lastVisionTime = millis();
    
    camera_fb_t* fb = capturePhoto();
    if (fb) {
      runVisionInference(fb->buf, fb->len);
      esp_camera_fb_return(fb);
    }
  }
}
