#include "camera_driver.h"
#include "config.h"
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

namespace {
enum class CameraMode { Gray, Jpeg };

SemaphoreHandle_t cameraMutex = nullptr;
bool cameraReady = false;

constexpr TickType_t kGrayLockTimeoutTicks = pdMS_TO_TICKS(50);
constexpr TickType_t kJpegLockTimeoutTicks = pdMS_TO_TICKS(3000);

camera_config_t baseConfig() {
  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  // Siempre el frame mas reciente: evita descartar 2 frames a mano antes de cada captura.
  config.grab_mode = CAMERA_GRAB_LATEST;
  return config;
}

bool startCamera(CameraMode mode) {
  camera_config_t config = baseConfig();

  if (mode == CameraMode::Gray) {
    // Las redes neuronales ligeras usan imagenes pequenas en blanco y negro (1 byte por pixel).
    config.pixel_format = PIXFORMAT_GRAYSCALE;
    config.frame_size = FRAMESIZE_96X96;
    config.jpeg_quality = 12; // Irrelevante en grises
    config.fb_count = 2;
  } else {
    config.pixel_format = PIXFORMAT_JPEG;
    config.frame_size = PHOTO_FRAME_SIZE;
    config.jpeg_quality = PHOTO_JPEG_QUALITY;
    config.fb_count = 1;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[Camara] Error al inicializar (modo %s): 0x%x\n",
                  mode == CameraMode::Gray ? "grises" : "jpeg", err);
    return false;
  }

  // Si la camara queda "de cabeza" (180 grados), descomentar:
  // sensor_t* sensor = esp_camera_sensor_get();
  // if (sensor) { sensor->set_vflip(sensor, 1); sensor->set_hmirror(sensor, 1); }
  // Si esta girada 90 grados, es mejor rotar fisicamente el modulo (rotar por codigo gasta memoria y CPU).
  return true;
}

bool restartCamera(CameraMode mode) {
  esp_camera_deinit();
  return startCamera(mode);
}
}

bool initCamera() {
  if (cameraMutex == nullptr) cameraMutex = xSemaphoreCreateMutex();
  if (cameraMutex == nullptr) return false;

  cameraReady = startCamera(CameraMode::Gray);
  return cameraReady;
}

camera_fb_t* acquireGrayFrame() {
  if (!cameraReady) return nullptr;
  if (xSemaphoreTake(cameraMutex, kGrayLockTimeoutTicks) != pdTRUE) return nullptr;

  camera_fb_t* frame = esp_camera_fb_get();
  if (frame == nullptr) xSemaphoreGive(cameraMutex);
  return frame;
}

void releaseGrayFrame(camera_fb_t* frame) {
  if (frame == nullptr) return;
  esp_camera_fb_return(frame);
  xSemaphoreGive(cameraMutex);
}

camera_fb_t* acquireJpegFrame() {
  if (!cameraReady) return nullptr;
  if (xSemaphoreTake(cameraMutex, kJpegLockTimeoutTicks) != pdTRUE) return nullptr;

  if (!restartCamera(CameraMode::Jpeg)) {
    cameraReady = restartCamera(CameraMode::Gray);
    xSemaphoreGive(cameraMutex);
    return nullptr;
  }

  // Los primeros frames salen mal expuestos: se descartan.
  for (int i = 0; i < PHOTO_SETTLE_FRAMES; i++) {
    camera_fb_t* warmup = esp_camera_fb_get();
    if (warmup) esp_camera_fb_return(warmup);
  }

  camera_fb_t* frame = esp_camera_fb_get();
  if (frame == nullptr) {
    cameraReady = restartCamera(CameraMode::Gray);
    xSemaphoreGive(cameraMutex);
  }
  return frame;
}

void releaseJpegFrame(camera_fb_t* frame) {
  if (frame != nullptr) esp_camera_fb_return(frame);
  cameraReady = restartCamera(CameraMode::Gray);
  xSemaphoreGive(cameraMutex);
}
