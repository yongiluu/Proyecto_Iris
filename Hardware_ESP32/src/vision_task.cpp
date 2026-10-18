#include "vision_task.h"
#include "camera_driver.h"
#include "tflite_vision.h"
#include "proximity.h"
#include "config.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
volatile bool visionPaused = false;

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

    camera_fb_t* frame = acquireGrayFrame();
    if (frame == nullptr) continue;

    runVisionInference(frame->buf, frame->len);
    runProximityInference(frame->buf, frame->len);
    releaseGrayFrame(frame);
  }
}
}

bool startVisionTask() {
  return xTaskCreatePinnedToCore(visionTask, "vision", 8192, nullptr, 1, nullptr, 0) == pdPASS;
}

void setVisionPaused(bool paused) {
  visionPaused = paused;
}
