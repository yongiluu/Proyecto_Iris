#include "light_task.h"
#include "camera_driver.h"
#include "config.h"
#include "image_convert.h"
#include "light_meter.h"
#include "ble_manager.h"
#include <stdio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
constexpr uint32_t kIdlePeriodMs = 300;  // apagado: solo revisa si lo pidieron
volatile bool lightPaused = false;
uint8_t gray96[kGrayModelSize * kGrayModelSize];  // brillo del centro de la imagen (no es un modelo)

void lightTask(void*) {
  bool lightWasOn = false;
  int lightSteps = 0;
  for (;;) {
    const bool lightOn = lightMeterUpdate();
    vTaskDelay(pdMS_TO_TICKS(lightOn ? LIGHT_METER_PERIOD_MS : kIdlePeriodMs));

    if (lightOn != lightWasOn) {
      bleManager.sendCommand(lightOn ? "CMD_LIGHT:ON" : "CMD_LIGHT:OFF");  // la app sabe si sigue encendido
      lightWasOn = lightOn;
    }
    if (!lightOn || lightPaused) continue;

    if (captureGray96(gray96)) {
      const int level = lightMeterStep(gray96, sizeof(gray96));
      if (level >= 0 && ++lightSteps % 6 == 0) {  // ~1 vez por segundo a la app
        char command[24];
        snprintf(command, sizeof(command), "CMD_LIGHT:%d", level);
        bleManager.sendCommand(command);
      }
    }
  }
}
}

bool startLightTask() {
  return xTaskCreatePinnedToCore(lightTask, "luz", 6144, nullptr, 1, nullptr, 0) == pdPASS;
}

void setLightPaused(bool paused) {
  lightPaused = paused;
}
