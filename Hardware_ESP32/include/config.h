#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// ==========================================
// BLE
// ==========================================
#define BLE_DEVICE_NAME "Iris_ESP32"
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_UUID_RX           "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 recibe audio TTS (solo PCM)
#define CHAR_UUID_TX           "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 envia audio del microfono
#define CHAR_UUID_CMD_TX       "6E400004-B5A3-F393-E0A9-E50E24DCCA9E" // Comandos en ambos sentidos (boton, foto, beep)
#define CHAR_UUID_PHOTO_TX     "6E400005-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 envia la foto JPEG

#define BLE_DEFAULT_MTU        23   // MTU de ATT antes de negociar
#define BLE_ATT_HEADER_BYTES   3    // Payload real por notificacion = MTU - 3
#define BLE_REQUESTED_MTU      512

// ==========================================
// Audio
// ==========================================
#define AUDIO_SAMPLE_RATE 16000

// ==========================================
// Foto (JPEG hacia GPT) y vision local (Edge AI)
// ==========================================
#define PHOTO_FRAME_SIZE        FRAMESIZE_VGA // 640x480
#define PHOTO_JPEG_QUALITY      12            // 0-63, menor = mejor calidad
#define PHOTO_SETTLE_FRAMES     3             // Frames descartados para que la autoexposicion se estabilice
#define PHOTO_CHUNK_DELAY_MS    20            // Backpressure entre notificaciones de foto
#define VISION_INTERVAL_MS      500   // con ESP-NN una inferencia de vision toma ~50-100 ms (sin ESP-NN ~2,3 s)

// ==========================================
// Eventos de audio (Edge AI, modelo de ML_Training/audio)
// ==========================================
// El umbral de alerta viene del entrenamiento: kAudioAlertThreshold en audio_model_data.h
#define AUDIO_EVENT_COOLDOWN_MS 5000   // no repetir la misma alerta antes de esto
#define AUDIO_EVENTS_DEBUG      0      // 1 = imprime los puntajes de cada inferencia por serial
#define AUDIO_CAPTURE_BAUD      921600 // firmware de captura de datos (entornos *_audio_capture)

// Wake word "Oye Iris" (modelo de ML_Training/wakeword). Al detectarlo la placa hace lo mismo que el
// boton: manda tu pregunta a la app y corta sola cuando dejas de hablar.
#define WAKE_WORD_ENABLED        1
#define WAKE_PREROLL_MS          500    // audio de antes de la deteccion que tambien se manda
#define WAKE_WAIT_SPEECH_MS      4000   // si no hablas en este tiempo, se cancela
#define WAKE_END_SILENCE_MS      900    // silencio que marca el fin de la pregunta
#define WAKE_MAX_MS              10000  // tope de una pregunta por wake word

// ==========================================
// Vision local (Edge AI, modelo de ML_Training/vision)
// ==========================================
// El umbral de aviso viene del entrenamiento: kVisionAlertThreshold en vision_model_data.h
#define VISION_EVENT_COOLDOWN_MS   8000   // no repetir el mismo aviso antes de esto
#define VISION_EVENTS_DEBUG        0      // 1 = imprime los puntajes de cada frame por serial
#define VISION_CAPTURE_BAUD        921600 // firmware de captura de fotos (entorno *_photo_capture)
#define VISION_CAPTURE_INTERVAL_MS 200    // ~5 frames por segundo hacia el PC

// Contexto silencioso para la IA de la app: cada cuanto la placa resume lo que oye y ve
// (CMD_AUDIO_CONTEXT / CMD_VISION_CONTEXT). No genera avisos hablados.
#define AMBIENT_CONTEXT_PERIOD_MS  10000

// Cercania con vision: pitidos de la placa. Apagados por ahora: con fotos reales el modelo da muchos
// avisos falsos con el camino libre. El nivel igual se manda a la app (CMD_PROXIMITY, contexto silencioso).
#define PROXIMITY_BEEPS_ENABLED      0
// Intervalo entre pitidos segun el nivel (proximity.h)
#define PROXIMITY_BEEP_NEAR_MS       800   // "cerca" (< ~1,5 m)
#define PROXIMITY_BEEP_VERY_NEAR_MS  250   // "muy cerca" (< ~0,7 m)

#ifdef IRIS_XIAO
// ==========================================
// PINES XIAO ESP32S3 SENSE (PROTOTIPO 2)
// Mapa XIAO: D0=GPIO1, D1=GPIO2, D2=GPIO3, D3=GPIO4
// ==========================================
#define I2S_MIC_PORT  I2S_NUM_0
#define I2S_MIC_SCK   42 // PDM CLK (en PDM el reloj sale por el pin WS del driver)
#define I2S_MIC_WS    -1 // PDM no usa WS
#define I2S_MIC_SD    41 // PDM DATA

#define I2S_AMP_PORT  I2S_NUM_1
#define I2S_AMP_LRC   1  // D0 (rutear en la placa)
#define I2S_AMP_BCLK  2  // D1
#define I2S_AMP_DIN   3  // D2

#define BUTTON_PIN    4  // D3
#define BUTTON_PIN_BOOT 0 // boton BOOT de la XIAO: tambien sirve para hablarle a Iris (sin boton externo)

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

#else
// ==========================================
// PINES ESP32-S3 DEVKIT (PROTOTIPO GRANDE)
// Coinciden con el README: microfono INMP441 en 42/41/40 y
// amplificador MAX98357A en 1/2/21 (no pueden compartir pines).
// ==========================================
#define I2S_MIC_PORT  I2S_NUM_0
#define I2S_MIC_SCK   42
#define I2S_MIC_WS    41
#define I2S_MIC_SD    40

#define I2S_AMP_PORT  I2S_NUM_1
#define I2S_AMP_LRC   1
#define I2S_AMP_BCLK  2
#define I2S_AMP_DIN   21

#define BUTTON_PIN    14

#define PWDN_GPIO_NUM     -1
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM     15
#define SIOD_GPIO_NUM      4
#define SIOC_GPIO_NUM      5
#define Y9_GPIO_NUM       16
#define Y8_GPIO_NUM       17
#define Y7_GPIO_NUM       18
#define Y6_GPIO_NUM       12
#define Y5_GPIO_NUM       10
#define Y4_GPIO_NUM        8
#define Y3_GPIO_NUM        9
#define Y2_GPIO_NUM       11
#define VSYNC_GPIO_NUM     6
#define HREF_GPIO_NUM      7
#define PCLK_GPIO_NUM     13
#endif

#endif
