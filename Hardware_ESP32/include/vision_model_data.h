// GENERADO por ML_Training/vision/export_model.py. No editar a mano.
// == Test limpio (int8, lo que corre en la placa) ==
// Exactitud: 83.8%  (6376 ejemplos)
// avisos falsos sobre 'nada': 5.9%  |  aviso de clase equivocada: 2.0%
// == Test con simulacion OV2640 (int8) ==
// Exactitud: 81.6%  (6376 ejemplos)
// avisos falsos sobre 'nada': 5.7%  |  aviso de clase equivocada: 1.9%
#ifndef VISION_MODEL_DATA_H
#define VISION_MODEL_DATA_H

#include <stdint.h>

constexpr int kVisionImageSize = 96;       // entrada 96x96x1 en grises (FRAMESIZE_96X96)
constexpr int kVisionNumClasses = 5;
constexpr int kVisionTensorArenaSize = 89088;
constexpr float kVisionAlertThreshold = 0.7f;  // config.ALERT_THRESHOLD
// Pixel 0..255 -> entrada float del modelo: pixel * kVisionPixelScale + kVisionPixelOffset (augment.to_model_input)
constexpr float kVisionPixelScale = 0.00784313725f;
constexpr float kVisionPixelOffset = -1.0f;

extern const unsigned char g_vision_model_data[];
extern const unsigned int g_vision_model_data_len;
extern const char* const kVisionLabels[kVisionNumClasses];
extern const bool kVisionIsAlert[kVisionNumClasses];   // se informa a la app como CMD_VISION_EVENT

#endif
