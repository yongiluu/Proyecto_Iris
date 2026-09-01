#include "audio_player.h"
#include "config.h"
#include <driver/i2s.h>

void initAudioPlayer() {
  i2s_config_t i2s_amp_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
    .sample_rate = AUDIO_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = true,
    .fixed_mclk = 0
  };

  i2s_pin_config_t i2s_amp_pins = {
    .bck_io_num = I2S_AMP_BCLK,
    .ws_io_num = I2S_AMP_LRC,
    .data_out_num = I2S_AMP_DIN,
    .data_in_num = I2S_PIN_NO_CHANGE
  };

  i2s_driver_install(I2S_AMP_PORT, &i2s_amp_config, 0, NULL);
  i2s_set_pin(I2S_AMP_PORT, &i2s_amp_pins);
}

void playAudioBuffer(uint8_t *payload, size_t length) {
  int16_t* incoming_samples = (int16_t*)payload;
  int num_samples = length / 2;
  
  int32_t* out_buffer = (int32_t*)malloc(num_samples * 2 * sizeof(int32_t));
  if(out_buffer) {
    const int GANANCIA_SALIDA = 2; 
    for (int i = 0; i < num_samples; i++) {
      int32_t amplified = (int32_t)incoming_samples[i] * GANANCIA_SALIDA;
      if (amplified > 32767) amplified = 32767;
      if (amplified < -32768) amplified = -32768;
      
      int32_t sample_final = amplified << 16;
      out_buffer[i*2] = sample_final;
      out_buffer[i*2 + 1] = sample_final;
    }
    size_t bytes_written = 0;
    i2s_write(I2S_AMP_PORT, out_buffer, num_samples * 2 * sizeof(int32_t), &bytes_written, portMAX_DELAY);
    free(out_buffer);
  }
}
