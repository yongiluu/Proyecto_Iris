#include "vision_task.h"
#include "camera_driver.h"
#include "tflite_vision.h"
#include "config.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
volatile bool visionPaused = false;

void visionTask(void*) {
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(VISION_INTERVAL_MS));
    if (visionPaused) continue;

    camera_fb_t* frame = acquireGrayFrame();
    if (frame == nullptr) continue;

    runVisionInference(frame->buf, frame->len);
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
