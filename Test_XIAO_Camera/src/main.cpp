#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>
#include <driver/i2s.h>

// Camara
#define PWDN_GPIO_NUM     -1
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM     10
#define SIOD_GPIO_NUM     40
#define SIOC_GPIO_NUM     39
#define Y9_GPIO_NUM       48
#define Y8_GPIO_NUM       11
#define Y7_GPIO_NUM       12
#define Y6_GPIO_NUM       14
#define Y5_GPIO_NUM       16
#define Y4_GPIO_NUM       18
#define Y3_GPIO_NUM       17
#define Y2_GPIO_NUM       15
#define VSYNC_GPIO_NUM    38
#define HREF_GPIO_NUM     47
#define PCLK_GPIO_NUM     13

// Microfono PDM
#define PDM_CLK_PIN 42
#define PDM_DATA_PIN 41

WebServer server(80);

void handleCapture() {
  camera_fb_t * fb = esp_camera_fb_get();
  if (fb) esp_camera_fb_return(fb);
  fb = esp_camera_fb_get();
  if (!fb) {
    server.send(500, "text/plain", "Error capturing photo");
    return;
  }
  server.send_P(200, "image/jpeg", (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
}

void handleRecord() {
  int duration_sec = 3;
  int sample_rate = 16000;
  int bytes_per_sec = sample_rate * 2; // 16-bit mono
  int total_bytes = bytes_per_sec * duration_sec;
  
  uint8_t* audio_buffer = (uint8_t*)ps_malloc(total_bytes + 44);
  if (!audio_buffer) {
    server.send(500, "text/plain", "Error allocate memory");
    return;
  }
  
  // Create WAV header
  uint32_t fileSize = total_bytes + 36;
  uint32_t byteRate = sample_rate * 2;
  
  const uint8_t wavHeader[44] = {
    'R','I','F','F',
    (uint8_t)(fileSize & 0xFF), (uint8_t)((fileSize >> 8) & 0xFF), (uint8_t)((fileSize >> 16) & 0xFF), (uint8_t)((fileSize >> 24) & 0xFF),
    'W','A','V','E',
    'f','m','t',' ',
    16, 0, 0, 0,
    1, 0, // PCM
    1, 0, // 1 channel
    (uint8_t)(sample_rate & 0xFF), (uint8_t)((sample_rate >> 8) & 0xFF), (uint8_t)((sample_rate >> 16) & 0xFF), (uint8_t)((sample_rate >> 24) & 0xFF),
    (uint8_t)(byteRate & 0xFF), (uint8_t)((byteRate >> 8) & 0xFF), (uint8_t)((byteRate >> 16) & 0xFF), (uint8_t)((byteRate >> 24) & 0xFF),
    2, 0, // Block align
    16, 0, // 16 bits
    'd','a','t','a',
    (uint8_t)(total_bytes & 0xFF), (uint8_t)((total_bytes >> 8) & 0xFF), (uint8_t)((total_bytes >> 16) & 0xFF), (uint8_t)((total_bytes >> 24) & 0xFF)
  };
  
  memcpy(audio_buffer, wavHeader, 44);
  
  size_t bytes_read = 0;
  i2s_read(I2S_NUM_0, audio_buffer + 44, total_bytes, &bytes_read, portMAX_DELAY);
  
  String header = "HTTP/1.1 200 OK\r\n";
  header += "Content-Type: audio/wav\r\n";
  header += "Content-Disposition: attachment; filename=\"audio.wav\"\r\n";
  header += "Content-Length: " + String(total_bytes + 44) + "\r\n";
  header += "Connection: close\r\n\r\n";
  
  server.client().write(header.c_str(), header.length());
  server.client().write(audio_buffer, total_bytes + 44);
  
  free(audio_buffer);
}

void setup() {
  Serial.begin(115200);
  
  // Iniciar Microfono PDM
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
    .sample_rate = 16000,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
  };

  i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_PIN_NO_CHANGE,
    .ws_io_num = PDM_CLK_PIN,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = PDM_DATA_PIN
  };

  i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_NUM_0, &pin_config);
  
  // Iniciar Camara
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
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_VGA;
  config.jpeg_quality = 10;
  config.fb_count = 2;

  esp_camera_init(&config);
  
  WiFi.softAP("XIAO_Camera_Test", "12345678");
  
  server.on("/", []() {
    server.send(200, "text/html", "<html><body><h1>XIAO Sense Test</h1><img src='/capture' width='640'><br><br><button onclick='location.reload()'>Tomar Otra Foto</button><br><br><a href='/record'><button style='padding: 20px; font-size: 20px; background: red; color: white;'>Grabar 3 Segundos de Audio</button></a></body></html>");
  });
  server.on("/capture", handleCapture);
  server.on("/record", handleRecord);
  server.begin();
}

void loop() {
  server.handleClient();
}