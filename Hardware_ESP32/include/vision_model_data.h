// GENERADO por ML_Training/vision/export_model.py. No editar a mano.
// == Test limpio (int8, lo que corre en la placa) ==
// Exactitud: 84.6%  (8199 ejemplos)
// avisos falsos sobre 'nada': 4.8%  |  aviso de clase equivocada: 1.3%
// == Test con simulacion OV2640 (int8) ==
// Exactitud: 80.8%  (8199 ejemplos)
// avisos falsos sobre 'nada': 4.4%  |  aviso de clase equivocada: 1.3%
#ifndef VISION_MODEL_DATA_H
#define VISION_MODEL_DATA_H

#include <stdint.h>

constexpr int kVisionImageSize = 96;       // entrada 96x96x1 en grises (FRAMESIZE_96X96)
constexpr int kVisionNumClasses = 5;
constexpr int kVisionTensorArenaSize = 174080;
constexpr float kVisionAlertThreshold = 0.75f;  // config.ALERT_THRESHOLD

// Pixel 0..255 de la camara -> int8 de entrada del modelo (calculada en el PC con la cuantizacion del modelo).
extern const int8_t kVisionInputLut[256];
// Autotest al arrancar: una imagen de test y la salida int8 que da el modelo en el PC (kernels de referencia).
extern const uint8_t kVisionSelfTestImage[kVisionImageSize * kVisionImageSize];
extern const int8_t kVisionSelfTestExpected[kVisionNumClasses];

extern const unsigned char g_vision_model_data[];
extern const unsigned int g_vision_model_data_len;
extern const char* const kVisionLabels[kVisionNumClasses];
extern const bool kVisionIsAlert[kVisionNumClasses];   // se informa a la app como CMD_VISION_EVENT

#endif
