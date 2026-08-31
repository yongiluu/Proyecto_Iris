#include <Arduino.h>
#include "esp_camera.h"
#include <WiFi.h>
#include "esp_http_server.h"
#include <driver/i2s.h>
#include <WebSocketsServer.h>

// =======================================================
// [INSERTA AQUÍ] TU LIBRERÍA DE EDGE IMPULSE
// #include <nombre_de_tu_modelo_inferencing.h>
// =======================================================

// =======================================================
// CONFIGURACIÓN DE AUDIO I2S
// =======================================================
#define I2S_MIC_PORT I2S_NUM_0
#define I2S_MIC_SCK  42
#define I2S_MIC_WS   41
#define I2S_MIC_SD   40

#define I2S_AMP_PORT I2S_NUM_1
#define I2S_AMP_LRC  1
#define I2S_AMP_BCLK 2
#define I2S_AMP_DIN  21

#define BUTTON_PIN   14

#define SAMPLE_RATE 16000

// Reemplaza con tus credenciales de WiFi
const char* ssid = "Diego";
const char* password = "Pepinillos";

// =======================================================
// CONFIGURACIÓN DE PINES PARA TU ESP32-S3 EXACTA
// =======================================================
#define PWDN_GPIO_NUM     -1 
#define RESET_GPIO_NUM    -1 
#define XCLK_GPIO_NUM     15
#define SIOD_GPIO_NUM     4  // SDA
#define SIOC_GPIO_NUM     5  // SCL

#define Y9_GPIO_NUM       16
#define Y8_GPIO_NUM       17
#define Y7_GPIO_NUM       18
#define Y6_GPIO_NUM       12
#define Y5_GPIO_NUM       10
#define Y4_GPIO_NUM       8
#define Y3_GPIO_NUM       9
#define Y2_GPIO_NUM       11
#define VSYNC_GPIO_NUM    6
#define HREF_GPIO_NUM     7
#define PCLK_GPIO_NUM     13
// =======================================================

WebSocketsServer webSocket = WebSocketsServer(81);
bool isAppConnected = false;
uint8_t connectedClientId = 0;

// Variables de Estado para el Flujo de Audio
volatile bool isStreamingAudio = false;
unsigned long streamingStartTime = 0;
const unsigned long STREAMING_TIMEOUT_MS = 12000; // Timeout de 12 segundos

// Buffer circular simulado para Edge Impulse (1 segundo aprox)
#define EI_BUFFER_SIZE 16000 
int16_t ei_audio_buffer[EI_BUFFER_SIZE];
volatile int ei_buffer_write_idx = 0;

void startCameraServer();
void playTone(int frequency, int duration_ms);
void playBeepConnecting();
void playBeepConnected();
void playBeepDisconnected();

void webSocketEvent(uint8_t num, WStype_t type, uint8_t * payload, size_t length) {
  switch(type) {
    case WStype_DISCONNECTED:
      Serial.printf("[%u] Desconectado!\n", num);
      if (num == connectedClientId) {
        isAppConnected = false;
        isStreamingAudio = false; // Detener streaming si se desconecta
      }
      break;
    case WStype_CONNECTED: {
      IPAddress ip = webSocket.remoteIP(num);
      Serial.printf("[%u] Conectado desde %d.%d.%d.%d url: %s\n", num, ip[0], ip[1], ip[2], ip[3], payload);
      isAppConnected = true;
      connectedClientId = num;
      break;
    }
    case WStype_TEXT: {
      String text = (char*)payload;
      // Escuchamos el comando de Flutter para detener el audio
      if (text == "CMD_PTT_STOP") {
        Serial.println("Comando CMD_PTT_STOP recibido. Deteniendo micrófono.");
        isStreamingAudio = false;
        playBeepDisconnected(); // Feedback de que dejó de escuchar
      }
      else if (text == "CMD_BEEP_START") {
        playBeepConnected();
      }
      else if (text == "CMD_BEEP_THINKING") {
        playBeepConnecting();
      }
      break;
    }
    case WStype_BIN: {
      // Audio entrante desde Flutter (para el altavoz)
      int16_t* incoming_samples = (int16_t*)payload;
      int num_samples = length / 2;
      
      int32_t* out_buffer = (int32_t*)malloc(num_samples * 2 * sizeof(int32_t));
      if(out_buffer) {
        // Reducimos la ganancia a 1 o 2, ya que Azure TTS viene con el volumen muy alto por defecto.
        // Si usamos 16, convertimos las ondas en "ondas cuadradas" (distorsión brutal).
        const int GANANCIA_SALIDA = 2; 
        for (int i = 0; i < num_samples; i++) {
          int32_t amplified = (int32_t)incoming_samples[i] * GANANCIA_SALIDA;
          if (amplified > 32767) amplified = 32767;
          if (amplified < -32768) amplified = -32768;
          
          // Expandir a 32 bits para el I2S
          int32_t sample_final = amplified << 16;
          
          out_buffer[i*2] = sample_final;
          out_buffer[i*2 + 1] = sample_final;
        }
        size_t bytes_written = 0;
        i2s_write(I2S_AMP_PORT, out_buffer, num_samples * 2 * sizeof(int32_t), &bytes_written, portMAX_DELAY);
        free(out_buffer);
      }
      break;
    }
    default:
      break;
  }
}

void initI2S() {
  i2s_config_t i2s_mic_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = false,
    .fixed_mclk = 0
  };

  i2s_pin_config_t i2s_mic_pins = {
    .bck_io_num = I2S_MIC_SCK,
    .ws_io_num = I2S_MIC_WS,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = I2S_MIC_SD
  };

  i2s_driver_install(I2S_MIC_PORT, &i2s_mic_config, 0, NULL);
  i2s_set_pin(I2S_MIC_PORT, &i2s_mic_pins);

  i2s_config_t i2s_amp_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 256,
    .use_apll = false,
    .tx_desc_auto_clear = true,
    .fixed_mclk = 0
  };

  i2s_pin_config_t i2s_amp_pins = {
    .bck_io_num = I2S_AMP_BCLK,
    .ws_io_num = I2S_AMP_LRC,
    .data_out_num = I2S_AMP_DIN,
    .data_in_num = I2S_PIN_NO_CHANGE
  };

  i2s_driver_install(I2S_AMP_PORT, &i2s_amp_config, 0, NULL);
  i2s_set_pin(I2S_AMP_PORT, &i2s_amp_pins);
}

// =======================================================
// TAREA DE INFERENCIA - EDGE IMPULSE (Core 0)
// =======================================================
void inference_task(void *pvParameters) {
  Serial.println("Tarea de inferencia de Edge Impulse iniciada en Core 0");
  
  while (true) {
    if (!isStreamingAudio && isAppConnected) {
      // -----------------------------------------------------
      // [INTEGRACIÓN DE EDGE IMPULSE AQUÍ]
      // Llama a run_classifier_continuous() leyendo del ei_audio_buffer
      // Si el modelo detecta "Hey Iris" con buena probabilidad:
      // 
      // if (result.classification[1].value > 0.8) {
      //     wakeup_detected = true;
      // }
      // -----------------------------------------------------

      bool wakeup_detected = false; // <- Reemplazar por resultado de IA
      
      // Simulador de detección para pruebas (botón virtual o dummy)
      // wakeup_detected = false; 

      if (wakeup_detected) {
        Serial.println("¡Wake Word Detectado! Iniciando streaming de audio...");
        isStreamingAudio = true;
        streamingStartTime = millis();
        
        // Avisar a Flutter para que prepare el STT
        webSocket.broadcastTXT("CMD_PTT_START");
        playBeepConnected();
        
        // Limpiar buffer para evitar enviar basura vieja
        ei_buffer_write_idx = 0; 
      }
    }
    
    // Evitar bloquear el Watchdog
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// =======================================================
// GENERADOR DE TONOS
// =======================================================
void playTone(int frequency, int duration_ms) {
    int num_samples = (16000 * duration_ms) / 1000;
    int32_t* buffer = (int32_t*)malloc(num_samples * 2 * sizeof(int32_t));
    if(!buffer) return;
    for(int i=0; i<num_samples; i++) {
        float t = (float)i / 16000.0;
        int16_t val = (int16_t)(6000.0 * sin(2.0 * PI * frequency * t));
        buffer[i*2] = val << 16;    
        buffer[i*2 + 1] = val << 16; 
    }
    size_t bytes_written;
    i2s_write(I2S_AMP_PORT, buffer, num_samples * 2 * sizeof(int32_t), &bytes_written, portMAX_DELAY);
    free(buffer);
}

void playBeepConnecting() { playTone(600, 100); }
void playBeepConnected() { playTone(523, 100); playTone(659, 100); playTone(784, 150); }
void playBeepDisconnected() { playTone(400, 200); playTone(300, 300); }

void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  // Configuración de cámara para Captura Pasiva Alta Resolución
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
  config.xclk_freq_hz = 10000000; // <-- Reducido a 10MHz para evitar EV-VSYNC-OVF
  
  // MODO PASIVO ALTA RESOLUCIÓN
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_SVGA; // <-- Bajado a 800x600 para dar respiro a la PSRAM
  config.jpeg_quality = 12; 
  config.fb_count = 1;

  if(psramFound()){
    config.frame_size = FRAMESIZE_SVGA; 
    config.jpeg_quality = 10; 
    config.fb_count = 2; 
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Error cámara: 0x%x\n", err);
    Serial.println("Revisa el flex de la cámara, los pines SDA/SCL y la alimentación de 3.3V.");
    // En lugar de hacer return y crashear el loop, continuamos para probar el audio
  } else {
    sensor_t * s = esp_camera_sensor_get();
    s->set_vflip(s, 1);
    s->set_hmirror(s, 1);
  }

  initI2S();

  WiFi.begin(ssid, password);
  unsigned long lastBeepTime = 0;
  while (WiFi.status() != WL_CONNECTED) {
    if (millis() - lastBeepTime > 5000) {
      playBeepConnecting();
      lastBeepTime = millis();
    }
    delay(10);
    Serial.print(".");
  }
  Serial.println("\nWiFi conectado");
  Serial.print("IP del ESP32: ");
  Serial.println(WiFi.localIP());
  playBeepConnected();

  startCameraServer();
  webSocket.begin();
  webSocket.onEvent(webSocketEvent);

  // Crear la tarea de Inferencia en el Core 0 (El loop de Arduino corre en el Core 1 por defecto)
  /* 
  xTaskCreatePinnedToCore(
    inference_task,     // Función de la tarea
    "InferenceTask",    // Nombre
    8192,               // Tamaño de Pila (Ajustar si EI lo requiere)
    NULL,               // Parámetros
    1,                  // Prioridad (1)
    NULL,               // Handle
    0                   // Core 0
  );
  */

  Serial.println("¡Hardware de prueba listo! Esperando que presiones el botón físico...");
}

int16_t audio_accum_buffer[1600]; // Para enviar frames a WebSocket
int audio_accum_idx = 0;

bool buttonState = HIGH; 
bool lastButtonState = HIGH; 
unsigned long lastDebounceTime = 0;
const unsigned long debounceDelay = 50;

void loop() {
  webSocket.loop();

  // === Lectura del botón físico para Pruebas ===
  bool reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonState) {
    lastDebounceTime = millis();
  }
  
  if ((millis() - lastDebounceTime) > debounceDelay) {
    if (reading != buttonState) {
      buttonState = reading;
      
      if (buttonState == LOW) { // Presionado
        Serial.println("Botón Presionado -> CMD_PTT_START");
        Serial.print("IP Actual del ESP32: ");
        Serial.println(WiFi.localIP());
        isStreamingAudio = true;
        streamingStartTime = millis();
        if (isAppConnected) webSocket.broadcastTXT("CMD_PTT_START");
        playBeepConnected();
      } else { // Soltado
        Serial.println("Botón Soltado -> CMD_PTT_STOP");
        isStreamingAudio = false;
        if (isAppConnected) {
          if (audio_accum_idx > 0) {
            webSocket.sendBIN(connectedClientId, (uint8_t*)audio_accum_buffer, audio_accum_idx * sizeof(int16_t));
            audio_accum_idx = 0;
          }
          webSocket.broadcastTXT("CMD_PTT_STOP");
        }
        playBeepDisconnected();
      }
    }
  }
  lastButtonState = reading;

  // Gestión de Timeout de Seguridad
  if (isStreamingAudio) {
    if (millis() - streamingStartTime > STREAMING_TIMEOUT_MS) {
      Serial.println("Timeout de 12s alcanzado. Forzando fin de streaming.");
      isStreamingAudio = false;
      webSocket.broadcastTXT("CMD_PTT_STOP");
      playBeepDisconnected();
    }
  }

  // === Lectura y proceso del micrófono ===
  size_t bytes_read = 0;
  int32_t samples[128]; // 128 muestras estéreo

  esp_err_t result = i2s_read(I2S_MIC_PORT, &samples, sizeof(samples), &bytes_read, 10 / portTICK_PERIOD_MS);
  
  if (result == ESP_OK && bytes_read > 0) {
    int samples_read = bytes_read / sizeof(int32_t);
    static float dc_x = 0;
    static float dc_y = 0;
    
    for (int i = 0; i < samples_read; i += 2) { 
      int32_t raw_sample = samples[i]; 
      // Extraer los 16 bits más significativos
      int16_t sample16 = (int16_t)(raw_sample >> 16); 
      
      // Filtro Paso Alto (DC Blocker) Matemático de Precisión
      float x = (float)sample16;
      float y = x - dc_x + 0.995f * dc_y; // Alpha 0.995 para mantener frecuencias de voz
      dc_x = x;
      dc_y = y;
      
      // Ganancia suave con recorte (clipping) controlado
      int32_t amplified = (int32_t)(y * 12.0f); // Ganancia de 12x (ajustable)
      if (amplified > 32767) amplified = 32767;
      if (amplified < -32768) amplified = -32768;
      
      int16_t final_sample = (int16_t)amplified;

      if (isStreamingAudio) {
        // MODO TRANSMISIÓN: Acumular para WebSocket
        if (audio_accum_idx < 1600) {
          audio_accum_buffer[audio_accum_idx++] = final_sample;
        }
      } else {
        // MODO ESCUCHA (Wake Word): Alimentar buffer de Edge Impulse
        ei_audio_buffer[ei_buffer_write_idx] = final_sample;
        ei_buffer_write_idx = (ei_buffer_write_idx + 1) % EI_BUFFER_SIZE;
      }
    }
    
    // Si estamos transmitiendo, enviar fragmentos por WebSocket
    if (isStreamingAudio && isAppConnected && audio_accum_idx >= 512) {
      webSocket.sendBIN(connectedClientId, (uint8_t*)audio_accum_buffer, audio_accum_idx * sizeof(int16_t));
      audio_accum_idx = 0;
    }
  }
}

// =======================================================
// MOTOR DEL SERVIDOR WEB (Captura y Vista en Vivo)
// =======================================================
httpd_handle_t camera_httpd = NULL;

static esp_err_t capture_handler(httpd_req_t *req){
    camera_fb_t * fb = NULL;
    
    // Descartar frame viejo
    fb = esp_camera_fb_get();
    if(fb) { esp_camera_fb_return(fb); }
    
    // Captura fresca en UXGA
    fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("Fallo al capturar la imagen");
      httpd_resp_send_500(req);
      return ESP_FAIL;
    }
  
  httpd_resp_set_type(req, "image/jpeg");
  esp_err_t res = httpd_resp_send(req, (const char *)fb->buf, fb->len);
  
  esp_camera_fb_return(fb);
  return res;
}

static esp_err_t index_handler(httpd_req_t *req) {
    const char* html = "<!DOCTYPE html><html><head><meta name='viewport' content='width=device-width, initial-scale=1.0'>"
                       "<title>Iris Camera Test</title></head><body style='background:#111; color:white; text-align:center; font-family:sans-serif;'>"
                       "<h2>Prueba de Visión - Iris</h2>"
                       "<img id='cam' src='/capture' style='width:100%; max-width:800px; border-radius:10px; border:2px solid #555;'>"
                       "<script>"
                       "setInterval(function() { "
                       "  document.getElementById('cam').src = '/capture?' + Math.random();"
                       "}, 200);"
                       "</script></body></html>";
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, html, HTTPD_RESP_USE_STRLEN);
}

void startCameraServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  
  httpd_uri_t index_uri = {
    .uri       = "/",
    .method    = HTTP_GET,
    .handler   = index_handler,
    .user_ctx  = NULL
  };
  
  httpd_uri_t capture_uri = {
    .uri       = "/capture",
    .method    = HTTP_GET,
    .handler   = capture_handler,
    .user_ctx  = NULL
  };
  
  if (httpd_start(&camera_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(camera_httpd, &index_uri);
    httpd_register_uri_handler(camera_httpd, &capture_uri);
  }
}