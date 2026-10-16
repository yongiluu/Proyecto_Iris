// GENERADO por ML_Training/vision/export_model.py. No editar a mano.
// == Test limpio (int8, lo que corre en la placa) ==
// Exactitud: 82.8%  (8199 ejemplos)
// avisos falsos sobre 'nada': 5.4%  |  aviso de clase equivocada: 1.7%
// == Test con simulacion OV2640 (int8) ==
// Exactitud: 80.1%  (8199 ejemplos)
// avisos falsos sobre 'nada': 5.5%  |  aviso de clase equivocada: 1.7%
#ifndef VISION_MODEL_DATA_H
#define VISION_MODEL_DATA_H

#include <stdint.h>

constexpr int kVisionImageSize = 96;       // entrada 96x96x1 en grises (FRAMESIZE_96X96)
constexpr int kVisionNumClasses = 5;
constexpr int kVisionTensorArenaSize = 89088;
constexpr float kVisionAlertThreshold = 0.75f;  // config.ALERT_THRESHOLD
// Pixel 0..255 -> entrada float del modelo: pixel * kVisionPixelScale + kVisionPixelOffset (augment.to_model_input)
constexpr float kVisionPixelScale = 0.00784313725f;
constexpr float kVisionPixelOffset = -1.0f;

extern const unsigned char g_vision_model_data[];
extern const unsigned int g_vision_model_data_len;
extern const char* const kVisionLabels[kVisionNumClasses];
extern const bool kVisionIsAlert[kVisionNumClasses];   // se informa a la app como CMD_VISION_EVENT

#endif
