#include "mic_driver.h"
#include "config.h"
#include <driver/i2s.h>

namespace {
constexpr TickType_t kReadTimeoutTicks = pdMS_TO_TICKS(100);

#ifndef IRIS_XIAO
// INMP441: dato de 24 bits alineado a la izquierda en una palabra de 32.
// >>14 deja 18 bits utiles (ganancia x4 sobre el >>16 "puro"); se satura a 16 bits.
constexpr int kMicGainShift = 14;
constexpr size_t kDevkitFrameSamples = 125;
#endif
}

bool initMic() {
  i2s_config_t config = {
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

  // Usa los pines del MICROFONO (antes se usaban por error los del amplificador).
  i2s_pin_config_t pins = {
    .mck_io_num = I2S_PIN_NO_CHANGE, // sin MCLK (por defecto quedaria en GPIO0)
#ifdef IRIS_XIAO
    .bck_io_num = I2S_PIN_NO_CHANGE,
    .ws_io_num = I2S_MIC_SCK,   // PDM: el reloj de captura sale por WS
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_MIC_SD
#else
    .bck_io_num = I2S_MIC_SCK,
    .ws_io_num = I2S_MIC_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_MIC_SD
#endif
  };

  if (i2s_driver_install(I2S_MIC_PORT, &config, 0, NULL) != ESP_OK) {
    Serial.println("[Mic] Error: i2s_driver_install fallo");
    return false;
  }
  if (i2s_set_pin(I2S_MIC_PORT, &pins) != ESP_OK) {
    Serial.println("[Mic] Error: i2s_set_pin fallo");
    return false;
  }
  return true;
}

size_t readMicSamples(int16_t* out, size_t maxSamples) {
  size_t bytes_read = 0;

#ifdef IRIS_XIAO
  if (i2s_read(I2S_MIC_PORT, out, maxSamples * sizeof(int16_t), &bytes_read, kReadTimeoutTicks) != ESP_OK) {
    return 0;
  }
  return bytes_read / sizeof(int16_t);
#else
  static int32_t raw[kDevkitFrameSamples];
  size_t wanted = maxSamples < kDevkitFrameSamples ? maxSamples : kDevkitFrameSamples;

  if (i2s_read(I2S_MIC_PORT, raw, wanted * sizeof(int32_t), &bytes_read, kReadTimeoutTicks) != ESP_OK) {
    return 0;
  }

  size_t count = bytes_read / sizeof(int32_t);
  for (size_t i = 0; i < count; i++) {
    int32_t sample = raw[i] >> kMicGainShift;
    if (sample > INT16_MAX) sample = INT16_MAX;
    if (sample < INT16_MIN) sample = INT16_MIN;
    out[i] = (int16_t)sample;
  }
  return count;
#endif
}
