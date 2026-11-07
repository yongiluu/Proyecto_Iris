#include "vision_task.h"
#include "camera_driver.h"
#include "tflite_vision.h"
#include "proximity.h"
#include "config.h"
#include "image_convert.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
volatile bool visionPaused = false;
uint8_t gray96[kGrayModelSize * kGrayModelSize];

void visionTask(void*) {
  bool wasPaused = false;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(VISION_INTERVAL_MS));
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
