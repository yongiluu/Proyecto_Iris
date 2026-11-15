#include "power_manager.h"

#include <Arduino.h>
#include <driver/rtc_io.h>
#include <esp_sleep.h>

#include "config.h"

namespace {
volatile uint32_t lastActivityMs = 0;
bool wokeByButton = false;

// El pin del boton queda como "pin RTC" mientras la placa duerme (con su resistencia a 3,3 V): asi
// apretarlo (0 V) la despierta. Al arrancar se devuelve a pin normal.
void releaseWakePin(int pin) {
  rtc_gpio_hold_dis((gpio_num_t)pin);
  rtc_gpio_deinit((gpio_num_t)pin);
}

void armWakePin(int pin) {
  rtc_gpio_init((gpio_num_t)pin);
  rtc_gpio_set_direction((gpio_num_t)pin, RTC_GPIO_MODE_INPUT_ONLY);
  rtc_gpio_pulldown_dis((gpio_num_t)pin);
  rtc_gpio_pullup_en((gpio_num_t)pin);
}

// Con el cable USB conectado a un PC (monitor serial abierto alguna vez) no se duerme: dormir corta el
// puerto y no se podria ver el log ni grabar la placa sin apretar BOOT.
bool usbHostConnected() {
#if ARDUINO_USB_CDC_ON_BOOT
  return (bool)Serial;
#else
  return false;
#endif
}
}  // namespace

void powerBegin() {
  const esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  wokeByButton = cause == ESP_SLEEP_WAKEUP_EXT0 || cause == ESP_SLEEP_WAKEUP_EXT1;
  releaseWakePin(BUTTON_PIN);
#ifdef BUTTON_PIN_BOOT
  releaseWakePin(BUTTON_PIN_BOOT);
#endif
  lastActivityMs = millis();
}

bool powerWokeByButton() {
  return wokeByButton;
}

void powerActivity() {
  lastActivityMs = millis();
}

bool powerShouldSleep() {
  if (!POWER_SLEEP_ENABLED || usbHostConnected()) return false;
  return millis() - lastActivityMs >= POWER_IDLE_SLEEP_MS;
}

void powerDeepSleep() {
  Serial.println("[Energia] A dormir. El boton despierta la placa.");
  Serial.flush();

  // Las resistencias de los pines RTC necesitan su dominio encendido mientras duerme.
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
  armWakePin(BUTTON_PIN);
  esp_sleep_enable_ext0_wakeup((gpio_num_t)BUTTON_PIN, 0);  // 0 = apretado
#ifdef BUTTON_PIN_BOOT
  // El boton BOOT de la XIAO tambien despierta (ext1 con un solo pin: "todos en 0" = ese pin en 0).
  armWakePin(BUTTON_PIN_BOOT);
  esp_sleep_enable_ext1_wakeup(1ULL << BUTTON_PIN_BOOT, ESP_EXT1_WAKEUP_ALL_LOW);
#endif
  esp_deep_sleep_start();
  for (;;) {}  // no se llega: al despertar la placa arranca de cero
}

// ───────────────────────── Bateria ─────────────────────────

int batteryMillivolts() {
  if (!BATTERY_SENSE_ENABLED) return 0;
  // Divisor de dos resistencias iguales: el pin ve la mitad del voltaje de la pila.
  uint32_t sum = 0;
  constexpr int kSamples = 16;
  for (int i = 0; i < kSamples; i++) sum += analogReadMilliVolts(BATTERY_ADC_PIN);
  return (int)(sum / kSamples) * 2;
}

int batteryPercent(int millivolts) {
  // Curva tipica de una LiPo de una celda en reposo (voltaje -> carga). Entre puntos, linea recta.
  static const struct { int mv; int percent; } kCurve[] = {
      {4200, 100}, {4100, 90}, {4000, 80}, {3900, 65}, {3800, 50}, {3700, 30},
      {3600, 15},  {3500, 7},  {3400, 3},  {3300, 0},
  };
  constexpr int kPoints = sizeof(kCurve) / sizeof(kCurve[0]);
  if (millivolts >= kCurve[0].mv) return 100;
  for (int i = 1; i < kPoints; i++) {
    if (millivolts >= kCurve[i].mv) {
      const int span = kCurve[i - 1].mv - kCurve[i].mv;
      return kCurve[i].percent + (millivolts - kCurve[i].mv) * (kCurve[i - 1].percent - kCurve[i].percent) / span;
    }
  }
  return 0;
}

BatteryLevel batteryLevel(int millivolts) {
  if (millivolts <= 0) return BatteryLevel::Unknown;
  // Menos de 2,5 V no es una pila: el divisor no esta puesto o el pin esta al aire.
  if (millivolts < 2500) return BatteryLevel::Unknown;
  if (millivolts <= BATTERY_CRITICAL_MV) return BatteryLevel::Critical;
  if (millivolts <= BATTERY_LOW_MV) return BatteryLevel::Low;
  return BatteryLevel::Ok;
}
