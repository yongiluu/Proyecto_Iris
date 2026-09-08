#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// Credenciales Wi-Fi
extern const char* WIFI_SSID;
extern const char* WIFI_PASS;

// Pines I2S - Amplificador MAX98357A
#define I2S_AMP_PORT  I2S_NUM_1
#define I2S_AMP_LRC   1
#define I2S_AMP_BCLK  2
#define I2S_AMP_DIN   21
#define AUDIO_SAMPLE_RATE 16000

// Pines Cámara (ESP32-S3 Standard Pinout)
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
