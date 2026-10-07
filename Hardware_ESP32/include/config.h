#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// BLE Configuration
#define BLE_DEVICE_NAME "Iris_ESP32"
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_UUID_RX           "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 receives data
#define CHAR_UUID_TX           "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 sends audio
#define CHAR_UUID_CMD_TX       "6E400004-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 sends commands (button)
#define CHAR_UUID_PHOTO_TX     "6E400005-B5A3-F393-E0A9-E50E24DCCA9E" // ESP32 sends photo

#define AUDIO_SAMPLE_RATE 16000

#ifdef IRIS_XIAO
// ==========================================
// PINES XIAO ESP32S3 SENSE (PROTOTIPO 2)
// ==========================================
#define I2S_MIC_PORT  I2S_NUM_0
#define I2S_MIC_SCK   42 // PDM CLK
#define I2S_MIC_WS    -1 // PDM no usa WS
#define I2S_MIC_SD    41 // PDM DATA

#define I2S_AMP_PORT  I2S_NUM_1
#define I2S_AMP_LRC   1  // D1 (Asegurate de rutear esto en la placa)
#define I2S_AMP_BCLK  2  // D2
#define I2S_AMP_DIN   3  // D3

#define BUTTON_PIN    4  // D4

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
// ==========================================
#define I2S_MIC_PORT  I2S_NUM_0
#define I2S_MIC_SCK   2
#define I2S_MIC_WS    1
#define I2S_MIC_SD    21

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