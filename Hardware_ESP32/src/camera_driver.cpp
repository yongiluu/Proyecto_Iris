#include "camera_driver.h"
#include "config.h"
#include "image_convert.h"
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <esp_heap_caps.h>

namespace {
enum class CameraMode { Color, Jpeg, GrayVga };

SemaphoreHandle_t cameraMutex = nullptr;
volatile bool cameraReady = false;
volatile bool fixedExposure = false;  // detector de luz

void applyExposure() {
  sensor_t* sensor = esp_camera_sensor_get();
  if (sensor == nullptr) return;
  sensor->set_exposure_ctrl(sensor, fixedExposure ? 0 : 1);
  sensor->set_gain_ctrl(sensor, fixedExposure ? 0 : 1);
  if (fixedExposure) {
    sensor->set_aec_value(sensor, LIGHT_METER_EXPOSURE);
    sensor->set_agc_gain(sensor, 0);
  }
}

constexpr TickType_t kColorLockTimeoutTicks = pdMS_TO_TICKS(50);
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

  if (mode == CameraMode::Color) {
    // Lo que miran los modelos locales: color y el campo de vision completo de la camara (4:3).
    // Los modelos en grises reciben el cuadrado central reducido a 96x96 (captureGray96).
    config.pixel_format = PIXFORMAT_RGB565;
    config.frame_size = CAMERA_COLOR_FRAME_SIZE;
    config.jpeg_quality = 12; // Irrelevante en RGB565
    config.fb_count = 2;
  } else if (mode == CameraMode::GrayVga) {
    // Lector de texto: 640x480 en grises (1 byte por pixel, 300 KB en PSRAM). Las letras necesitan detalle.
    config.pixel_format = PIXFORMAT_GRAYSCALE;
    config.frame_size = FRAMESIZE_VGA;
    config.jpeg_quality = 12;
    config.fb_count = 1;
  } else {
    config.pixel_format = PIXFORMAT_JPEG;
    config.frame_size = PHOTO_FRAME_SIZE;
    config.jpeg_quality = PHOTO_JPEG_QUALITY;
    config.fb_count = 1;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[Camara] Error al inicializar (modo %s): 0x%x\n",
                  mode == CameraMode::Color ? "color" : mode == CameraMode::Jpeg ? "jpeg" : "grises VGA", err);
    return false;
  }

  if (mode == CameraMode::Color) applyExposure();

  // Si la camara queda "de cabeza" (180 grados), descomentar:
  // sensor_t* sensor = esp_camera_sensor_get();
  // if (sensor) { sensor->set_vflip(sensor, 1); sensor->set_hmirror(sensor, 1); }
  // Si esta girada 90 grados, es mejor rotar fisicamente el modulo (rotar por codigo gasta memoria y CPU).
  return true;
}

// Cada foto para la IA cambia la camara de color a JPEG y de vuelta. Si un cambio falla (ej. sin memoria
// interna para el DMA), antes la camara quedaba apagada hasta reiniciar la placa: ahora se reintenta.
bool restartCamera(CameraMode mode) {
  for (int attempt = 1; attempt <= 3; attempt++) {
    esp_camera_deinit();
    if (startCamera(mode)) return true;
    Serial.printf("[Camara] Reintento %d (RAM interna libre %u)\n", attempt,
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    delay(150);
  }
  return false;
}

// Si la camara quedo apagada por un error, se intenta encender de nuevo cada kRecoverEveryMs.
constexpr uint32_t kRecoverEveryMs = 3000;
uint32_t lastRecoverMs = 0;
volatile bool shutdownRequested = false;

void tryRecover() {
  if (cameraReady || shutdownRequested || millis() - lastRecoverMs < kRecoverEveryMs) return;
  lastRecoverMs = millis();
  if (xSemaphoreTake(cameraMutex, 0) != pdTRUE) return;
  cameraReady = restartCamera(CameraMode::Color);
  Serial.printf("[Camara] Recuperacion %s\n", cameraReady ? "OK" : "fallida, se reintenta");
  xSemaphoreGive(cameraMutex);
}

// Con el candado tomado: la camara pudo apagarse (shutdownCamera, antes de actualizar por WiFi) o
// fallar mientras esta tarea esperaba. Sin esto, una foto pedida justo entonces la volvia a encender.
bool lockedCameraUsable() {
  if (cameraReady && !shutdownRequested) return true;
  xSemaphoreGive(cameraMutex);
  return false;
}
}  // namespace

bool initCamera() {
  if (cameraMutex == nullptr) cameraMutex = xSemaphoreCreateMutex();
  if (cameraMutex == nullptr) return false;

  cameraReady = startCamera(CameraMode::Color);
  if (cameraReady) Serial.printf("[Camara] Sensor %s\n", cameraSensorName());
  return cameraReady;
}

const char* cameraSensorName() {
  sensor_t* sensor = esp_camera_sensor_get();
  if (sensor == nullptr) return "?";
  switch (sensor->id.PID) {
    case OV2640_PID: return "OV2640";
    case OV3660_PID: return "OV3660";
    case OV5640_PID: return "OV5640";
    default: return "otra";
  }
}

camera_fb_t* acquireColorFrame() {
  if (!cameraReady) {
    tryRecover();
    if (!cameraReady) return nullptr;
  }
  if (xSemaphoreTake(cameraMutex, kColorLockTimeoutTicks) != pdTRUE) return nullptr;
  if (!lockedCameraUsable()) return nullptr;

  camera_fb_t* frame = esp_camera_fb_get();
  if (frame == nullptr) xSemaphoreGive(cameraMutex);
  return frame;
}

void releaseColorFrame(camera_fb_t* frame) {
  if (frame == nullptr) return;
  esp_camera_fb_return(frame);
  xSemaphoreGive(cameraMutex);
}

bool captureGray96(uint8_t* out) {
  camera_fb_t* frame = acquireColorFrame();
  if (frame == nullptr) return false;
  bool ok = frame->format == PIXFORMAT_RGB565 && frame->len >= frame->width * frame->height * 2u;
  if (ok) rgb565ToGray96(frame->buf, frame->width, frame->height, out);
  releaseColorFrame(frame);
  return ok;
}

camera_fb_t* acquireJpegFrame() {
  if (!cameraReady) {
    tryRecover();
    if (!cameraReady) return nullptr;
  }
  if (xSemaphoreTake(cameraMutex, kJpegLockTimeoutTicks) != pdTRUE) return nullptr;
  if (!lockedCameraUsable()) return nullptr;

  if (!restartCamera(CameraMode::Jpeg)) {
    cameraReady = restartCamera(CameraMode::Color);
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
    cameraReady = restartCamera(CameraMode::Color);
    xSemaphoreGive(cameraMutex);
  }
  return frame;
}

camera_fb_t* acquireGrayVgaFrame() {
  if (!cameraReady) {
    tryRecover();
    if (!cameraReady) return nullptr;
  }
  if (xSemaphoreTake(cameraMutex, kJpegLockTimeoutTicks) != pdTRUE) return nullptr;
  if (!lockedCameraUsable()) return nullptr;

  if (!restartCamera(CameraMode::GrayVga)) {
    cameraReady = restartCamera(CameraMode::Color);
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
    cameraReady = restartCamera(CameraMode::Color);
    xSemaphoreGive(cameraMutex);
  }
  return frame;
}

void releaseJpegFrame(camera_fb_t* frame) {
  if (frame != nullptr) esp_camera_fb_return(frame);
  cameraReady = !shutdownRequested && restartCamera(CameraMode::Color);
  xSemaphoreGive(cameraMutex);
}

void shutdownCamera() {
  if (cameraMutex == nullptr || !cameraReady) return;
  // Espera a que nadie este usando un frame; despues la camara queda apagada (acquire* devuelve nullptr).
  xSemaphoreTake(cameraMutex, portMAX_DELAY);
  shutdownRequested = true;
  cameraReady = false;
  esp_camera_deinit();
  xSemaphoreGive(cameraMutex);
}

void setCameraFixedExposure(bool fixed) {
  if (cameraMutex == nullptr) return;
  xSemaphoreTake(cameraMutex, portMAX_DELAY);
  fixedExposure = fixed;
  if (cameraReady) applyExposure();
  xSemaphoreGive(cameraMutex);
}

void releaseGrayVgaFrame(camera_fb_t* frame) {
  releaseJpegFrame(frame);  // mismo camino: devolver el frame y volver a color 160x120
}
