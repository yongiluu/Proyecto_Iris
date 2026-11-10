#include "light_meter.h"

#include <Arduino.h>
#include <math.h>

#include "audio_player.h"
#include "camera_driver.h"
#include "config.h"

namespace {
volatile int requested = -1;  // -1 nada pendiente, 0 apagar, 1 encender
bool enabled = false;
uint32_t enabledAtMs = 0;
float smoothed = -1.0f;
}  // namespace

float lightMeterFrequency(int level) {
  if (level < 0) level = 0;
  if (level > 100) level = 100;
  // Exponencial: el oido percibe la altura de forma logaritmica, asi cada paso de luz "suena" parejo.
  return LIGHT_METER_MIN_HZ * powf(LIGHT_METER_MAX_HZ / LIGHT_METER_MIN_HZ, level / 100.0f);
}

static void setEnabled(bool on) {
  if (on == enabled) return;
  enabled = on;
  smoothed = -1.0f;
  setCameraFixedExposure(on);
  if (on) {
    enabledAtMs = millis();
    playTone(440.0f, 80);  // aviso de encendido: un pitido...
  } else {
    playTone(330.0f, 80);  // ...y de apagado, mas grave
    playTone(220.0f, 120);
  }
  Serial.printf("[Luz] Detector %s\n", on ? "encendido" : "apagado");
}

void requestLightMeter(bool on) {
  requested = on ? 1 : 0;
}

bool lightMeterUpdate() {
  const int pending = requested;
  if (pending >= 0) {
    requested = -1;
    setEnabled(pending == 1);
  }
  if (enabled && millis() - enabledAtMs > LIGHT_METER_TIMEOUT_MS) setEnabled(false);
  return enabled;
}

int lightMeterStep(const uint8_t* gray, size_t length) {
  if (!enabled || gray == nullptr || length == 0) return -1;

  // Brillo medio del centro (la luz hacia donde apunta la persona, no los bordes con vineteado).
  const int side = 96, margin = 24;
  uint32_t sum = 0, count = 0;
  for (int y = margin; y < side - margin; y++) {
    for (int x = margin; x < side - margin; x++) {
      sum += gray[y * side + x];
      count++;
    }
  }
  const float mean = count ? (float)sum / count : 0.0f;
  smoothed = smoothed < 0 ? mean : smoothed * 0.6f + mean * 0.4f;  // sin saltos por ruido del sensor

  // Escala perceptual: la diferencia entre 5 y 20 importa mas que entre 200 y 215.
  const int level = (int)lroundf(100.0f * sqrtf(smoothed / 255.0f));
  // Mientras Iris habla no se pita: los tonos quedarian en cola detras de la voz y sonarian todos
  // juntos al terminar la respuesta (un pitido cada 0,16 s durante una respuesta de 10 s = 60 pitidos).
  if (pendingPlaybackMs() < 2 * LIGHT_METER_PERIOD_MS) playTone(lightMeterFrequency(level), LIGHT_METER_TONE_MS);
#if LIGHT_METER_DEBUG
  Serial.printf("[Luz] brillo %.1f -> nivel %d (%.0f Hz)\n", mean, level, lightMeterFrequency(level));
#endif
  return level;
}
