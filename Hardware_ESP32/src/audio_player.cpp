#include "audio_player.h"
#include "config.h"
#include <driver/i2s.h>
#include <freertos/FreeRTOS.h>
#include <freertos/stream_buffer.h>
#include <freertos/task.h>
#include <math.h>

namespace {
constexpr size_t kStreamBufferBytes = 16 * 1024;     // ~0.5 s de audio a 16 kHz/16 bit
constexpr size_t kChunkSamples = 256;
constexpr TickType_t kEnqueueTimeoutTicks = pdMS_TO_TICKS(50);
constexpr int kOutputGain = 2;

constexpr float kBeepFrequencyHz = 880.0f;
constexpr int kBeepDurationMs = 120;
constexpr int16_t kBeepAmplitude = 8000;

StreamBufferHandle_t playbackStream = nullptr;

// El hilo BLE solo encola; la escritura I2S (bloqueante) ocurre en esta tarea.
void playbackTask(void*) {
  static int16_t input[kChunkSamples];
  static int32_t output[kChunkSamples * 2];

  for (;;) {
    size_t bytes = xStreamBufferReceive(playbackStream, input, sizeof(input), portMAX_DELAY);
    size_t samples = bytes / sizeof(int16_t);

    for (size_t i = 0; i < samples; i++) {
      int32_t amplified = (int32_t)input[i] * kOutputGain;
      if (amplified > INT16_MAX) amplified = INT16_MAX;
      if (amplified < INT16_MIN) amplified = INT16_MIN;

      // MAX98357A espera 32 bits alineados a la izquierda; mismo valor en L y R.
      int32_t frame = amplified << 16;
      output[i * 2] = frame;
      output[i * 2 + 1] = frame;
    }

    size_t bytes_written = 0;
    i2s_write(I2S_AMP_PORT, output, samples * 2 * sizeof(int32_t), &bytes_written, portMAX_DELAY);
  }
}
}

bool initAudioPlayer() {
  i2s_config_t config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
    .sample_rate = AUDIO_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 10,
    .dma_buf_len = 300,
    .use_apll = false,
    .tx_desc_auto_clear = true,
    .fixed_mclk = 0
  };

  i2s_pin_config_t pins = {
    .mck_io_num = I2S_PIN_NO_CHANGE, // sin MCLK (por defecto quedaria en GPIO0)
    .bck_io_num = I2S_AMP_BCLK,
    .ws_io_num = I2S_AMP_LRC,
    .data_out_num = I2S_AMP_DIN,
    .data_in_num = I2S_PIN_NO_CHANGE
  };

  if (i2s_driver_install(I2S_AMP_PORT, &config, 0, NULL) != ESP_OK ||
      i2s_set_pin(I2S_AMP_PORT, &pins) != ESP_OK) {
    Serial.println("[Audio] Error al inicializar el amplificador I2S");
    return false;
  }

  playbackStream = xStreamBufferCreate(kStreamBufferBytes, 1);
  if (playbackStream == nullptr) {
    Serial.println("[Audio] Error: sin memoria para el buffer de reproduccion");
    return false;
  }

  xTaskCreatePinnedToCore(playbackTask, "audio_play", 4096, nullptr, 3, nullptr, 0);
  return true;
}

void playAudioBuffer(const uint8_t* payload, size_t length) {
  if (playbackStream == nullptr || payload == nullptr) return;

  length &= ~(size_t)1; // PCM de 16 bits: descartar un byte suelto
  if (length == 0) return;

  size_t sent = xStreamBufferSend(playbackStream, payload, length, kEnqueueTimeoutTicks);
  if (sent < length) {
    Serial.println("[Audio] Buffer de reproduccion lleno: audio descartado");
  }
}

void playTone(float frequencyHz, int durationMs) {
  if (playbackStream == nullptr) return;

  const int totalSamples = AUDIO_SAMPLE_RATE * durationMs / 1000;
  int16_t chunk[kChunkSamples];

  int produced = 0;
  while (produced < totalSamples) {
    int count = totalSamples - produced;
    if (count > (int)kChunkSamples) count = kChunkSamples;

    for (int i = 0; i < count; i++) {
      float phase = 2.0f * (float)M_PI * frequencyHz * (float)(produced + i) / AUDIO_SAMPLE_RATE;
      chunk[i] = (int16_t)(kBeepAmplitude * sinf(phase));
    }
    playAudioBuffer((const uint8_t*)chunk, count * sizeof(int16_t));
    produced += count;
  }
}

void playThinkingBeep() {
  playTone(kBeepFrequencyHz, kBeepDurationMs);
}
