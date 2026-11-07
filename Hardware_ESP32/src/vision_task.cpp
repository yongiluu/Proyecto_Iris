#include "vision_task.h"
#include "camera_driver.h"
#include "tflite_vision.h"
#include "proximity.h"
#include "config.h"
#include "image_convert.h"
#include "light_meter.h"
#include "ble_manager.h"
#include <stdio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
volatile bool visionPaused = false;
uint8_t gray96[kGrayModelSize * kGrayModelSize];

void visionTask(void*) {
  bool wasPaused = false;
  bool lightWasOn = false;
  int lightSteps = 0;
  for (;;) {
    const bool lightOn = lightMeterUpdate();
    vTaskDelay(pdMS_TO_TICKS(lightOn ? LIGHT_METER_PERIOD_MS : VISION_INTERVAL_MS));

    // Detector de luz: reemplaza a los modelos mientras esta encendido (con exposicion fija la imagen
    // no es la que conocen). Calla mientras la persona habla.
    if (lightOn != lightWasOn) {
      bleManager.sendCommand(lightOn ? "CMD_LIGHT:ON" : "CMD_LIGHT:OFF");  // la app sabe si sigue encendido
      lightWasOn = lightOn;
      wasPaused = true;  // al volver, no mezclar con lo de antes
    }
    if (lightOn) {
      if (!visionPaused && captureGray96(gray96)) {
        const int level = lightMeterStep(gray96, sizeof(gray96));
        if (level >= 0 && ++lightSteps % 6 == 0) {  // ~1 vez por segundo a la app
          char command[24];
          snprintf(command, sizeof(command), "CMD_LIGHT:%d", level);
          bleManager.sendCommand(command);
        }
      }
      continue;
    }

    if (visionPaused) {
      wasPaused = true;
      continue;
    }
    if (wasPaused) {
      // No promediar la escena de antes de la pausa con la de ahora.
      resetVisionSmoothing();
      resetProximitySmoothing();
      wasPaused = false;
    }

    // La camara entrega color; los modelos actuales reciben el cuadrado central en grises 96x96.
    // Se convierte y se libera el frame antes de inferir, asi la camara no queda tomada.
    if (!captureGray96(gray96)) continue;

    runVisionInference(gray96, sizeof(gray96));
    runProximityInference(gray96, sizeof(gray96));
  }
}
}

bool startVisionTask() {
  return xTaskCreatePinnedToCore(visionTask, "vision", 8192, nullptr, 1, nullptr, 0) == pdPASS;
}

void setVisionPaused(bool paused) {
  visionPaused = paused;
}
