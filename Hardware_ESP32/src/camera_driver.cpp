#include "camera_driver.h"
#include "config.h"

bool initCamera() {
  camera_config_t config;
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
  
  // === CONFIGURACIÓN PARA EDGE AI (VISIÓN) ===
  // Las redes neuronales ligeras necesitan imágenes pequeñas y en blanco y negro.
  config.pixel_format = PIXFORMAT_GRAYSCALE; // Escala de grises (1 byte por pixel)
  config.frame_size = FRAMESIZE_96X96;       // Resolución 96x96
  
  config.jpeg_quality = 12; // Irrelevante para Grayscale, pero lo dejamos
  config.fb_count = 1;

  if (psramFound()) {
    config.fb_count = 2; 
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    return false;
  }

  // === AJUSTES FÍSICOS DEL LENTE (ROTACIÓN Y ESPEJO) ===
  sensor_t * s = esp_camera_sensor_get();
  if (s) {
    // Si la cámara está "de cabeza" (180 grados), descomenta estas dos líneas:
    // s->set_vflip(s, 1);   // Voltear verticalmente
    // s->set_hmirror(s, 1); // Modo espejo horizontal
    
    // Ojo: Si la cámara está girada de lado (90 grados), es mejor rotar físicamente 
    // el cuadradito negro de la cámara con los dedos. Rotar 90 grados por código 
    // consume mucha memoria y procesador innecesariamente.
  }

  return true;
}

camera_fb_t* capturePhoto() {
  // Clear old frames from buffer to ensure we get a fresh picture with correct exposure
  camera_fb_t * fb = esp_camera_fb_get();
  if (fb) esp_camera_fb_return(fb);
  
  fb = esp_camera_fb_get();
  if (fb) esp_camera_fb_return(fb);

  // Return fresh frame
  return esp_camera_fb_get();
}
