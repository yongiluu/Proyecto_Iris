// GENERADO por ML_Training/vision/proximity_export.py. No editar a mano.
// == Test limpio (int8, lo que corre en la placa) ==
// Exactitud: 71.4%  (497 ejemplos)
// muy_cerca avisado: 61.9%   cerca avisado: 33.6%
// avisos falsos con el camino libre: 6.4%
// == Test con simulacion OV2640 (int8) ==
// Exactitud: 63.4%  (497 ejemplos)
// muy_cerca avisado: 81.0%   cerca avisado: 40.9%
// avisos falsos con el camino libre: 12.8%
#ifndef PROXIMITY_MODEL_DATA_H
#define PROXIMITY_MODEL_DATA_H

#include <stdint.h>

// Cercania: "¿hay algo cerca al frente?" con la misma imagen 96x96 en grises que el modelo de clases.
// Clases: 0 = libre, 1 = cerca (< 1.5 m), 2 = muy_cerca (< 0.7 m).
constexpr int kProximityNumClasses = 3;
constexpr int kProximityTensorArenaSize = 99328;
constexpr float kProximityAlertThreshold = 0.8f;  // cerca + muy_cerca

extern const unsigned char g_proximity_model_data[];
extern const unsigned int g_proximity_model_data_len;
extern const char* const kProximityLabels[kProximityNumClasses];
extern const int8_t kProximityInputLut[256];
extern const uint8_t kProximitySelfTestImage[96 * 96];
extern const int8_t kProximitySelfTestExpected[kProximityNumClasses];

#endif
