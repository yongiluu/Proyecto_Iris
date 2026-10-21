#include "audio_player.h"
#include "config.h"
#include <driver/i2s.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/stream_buffer.h>
#include <freertos/task.h>
#include <math.h>

namespace {
// Buffer grande en PSRAM (~32 s a 16 kHz/16 bit): la app puede mandar la respuesta entera de una vez y
// nada se descarta. Antes eran 16 KB (0,5 s) y el audio salia cortado con cualquier pausa del BLE.
constexpr size_t kStreamBufferBytes = 1024 * 1024;
constexpr size_t kFallbackBufferBytes = 16 * 1024;   // si no hay PSRAM
// Antes de empezar a sonar se juntan 0,4 s (o se espera a que deje de llegar audio: respuestas cortas
// y tonos). Si se vacia a la mitad (el BLE a veces llega mas lento que la reproduccion), se vuelve a
// juntar el DOBLE, hasta 4 s: una o dos pausas en vez de muchos trabones. Se reinicia en cada respuesta.
constexpr size_t kBytesPerSecond = AUDIO_SAMPLE_RATE * 2;
constexpr size_t kPrebufferBytes = kBytesPerSecond * 4 / 10;
constexpr size_t kMaxPrebufferBytes = kBytesPerSecond * 4;
constexpr TickType_t kEndOfStreamTicks = pdMS_TO_TICKS(250);
constexpr TickType_t kNewAnswerGapTicks = pdMS_TO_TICKS(1500);
constexpr size_t kChunkSamples = 256;
constexpr TickType_t kEnqueueTimeoutTicks = pdMS_TO_TICKS(50);
// Volumen: el parlante va en el oido. 2.0 y 1.5/0.7 sonaban rotos; 1.0/0.5 muy bajito. La salida nunca pasa
// de kMaxOutputLevel del maximo del amplificador (tope de seguridad auditiva).
constexpr float kOutputGain = 1.2f;
constexpr float kMaxOutputLevel = 0.6f;
// El parlante de ~1 cm no reproduce graves: solo distorsionan (suena a estatica). Pasa-altos a 300 Hz.
constexpr float kHighPassHz = 300.0f;

constexpr float kBeepFrequencyHz = 880.0f;
constexpr int kBeepDurationMs = 120;
constexpr int16_t kBeepAmplitude = 8000;

StreamBufferHandle_t playbackStream = nullptr;
StaticStreamBuffer_t playbackStreamStruct;
volatile TickType_t lastEnqueueTick = 0;
// Los tonos ("te escucho", "pensando") suenan al instante, sin esperar a juntar audio.
volatile bool playNowRequested = false;

// Biquad pasa-altos (RBJ, Q = 0,707).
struct HighPass {
    float b0, b1, b2, a1, a2;
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    void setup(float cutoffHz, float sampleRate) {
        const float w = 2.0f * (float)M_PI * cutoffHz / sampleRate;
        const float alpha = sinf(w) / (2.0f * 0.7071f);
        const float cosw = cosf(w);
        const float a0 = 1.0f + alpha;
        b0 = (1.0f + cosw) / 2.0f / a0;
        b1 = -(1.0f + cosw) / a0;
        b2 = b0;
        a1 = -2.0f * cosw / a0;
        a2 = (1.0f - alpha) / a0;
    }
    void reset() { x1 = x2 = y1 = y2 = 0; }
    float process(float x) {
        const float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        return y;
    }
};
HighPass highPass;

// El hilo BLE solo encola; la escritura I2S (bloqueante) ocurre en esta tarea.
void playbackTask(void*) {
  static int16_t input[kChunkSamples];
  static int32_t output[kChunkSamples * 2];
  bool playing = false;
  size_t prebuffer = kPrebufferBytes;

  for (;;) {
    if (!playing) {
      const size_t available = xStreamBufferBytesAvailable(playbackStream);
      const TickType_t sinceEnqueue = xTaskGetTickCount() - lastEnqueueTick;
      if (sinceEnqueue > kNewAnswerGapTicks) prebuffer = kPrebufferBytes;  // respuesta nueva
      const bool stillArriving = sinceEnqueue < kEndOfStreamTicks;
      if (available == 0 || (available < prebuffer && stillArriving && !playNowRequested)) {
        vTaskDelay(pdMS_TO_TICKS(10));
        continue;
      }
      playing = true;
      playNowRequested = false;
      highPass.reset();
    }

    size_t bytes = xStreamBufferReceive(playbackStream, input, sizeof(input), pdMS_TO_TICKS(20));
    if (bytes == 0) {
      playing = false;  // se vacio: vuelve a juntar antes de seguir
      if (xTaskGetTickCount() - lastEnqueueTick < kEndOfStreamTicks) {
        // Se quedo sin audio a la mitad de la respuesta: la proxima vez junta el doble.
        prebuffer = prebuffer * 2 > kMaxPrebufferBytes ? kMaxPrebufferBytes : prebuffer * 2;
      }
      continue;
    }
    size_t samples = bytes / sizeof(int16_t);

    for (size_t i = 0; i < samples; i++) {
      // Pasa-altos, ganancia y limitador suave (tanh): sin el recorte duro que agregaba estatica.
      float x = highPass.process((float)input[i]) * kOutputGain / 32768.0f;
      int32_t amplified = (int32_t)(tanhf(x) * 32767.0f * kMaxOutputLevel);

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

  highPass.setup(kHighPassHz, AUDIO_SAMPLE_RATE);

  uint8_t* storage = (uint8_t*)heap_caps_malloc(kStreamBufferBytes + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (storage != nullptr) {
    playbackStream = xStreamBufferCreateStatic(kStreamBufferBytes, 1, storage, &playbackStreamStruct);
  } else {
    playbackStream = xStreamBufferCreate(kFallbackBufferBytes, 1);
  }
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
  lastEnqueueTick = xTaskGetTickCount();
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
  playNowRequested = true;
}

void playThinkingBeep() {
  playTone(kBeepFrequencyHz, kBeepDurationMs);
}
