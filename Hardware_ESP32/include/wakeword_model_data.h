// GENERADO por ML_Training/audio/../wakeword/export_wake.py. No editar a mano.
// == Wake word 'Oye Iris' (int8) ==
// Umbral 0.90: 44/50 = 88.0% detectados; activaciones falsas/hora: oye_iris 119.5, frases_parecidas 0.0, fondos_app 0.0, voz_chilena 0.0
// Ventanas de test sueltas: Oye Iris 95.8%, otro sobre el umbral 0.113%
#ifndef WAKEWORD_MODEL_DATA_H
#define WAKEWORD_MODEL_DATA_H

#include <stdint.h>

// Detector de "Oye Iris": entrada = el mismo segundo de log-mel que el modelo de eventos de audio.
constexpr int kWakeTensorArenaSize = 44032;
constexpr int kWakeOutputIndex = 1;
constexpr float kWakeThreshold = 0.9f;
constexpr int kWakeStrideFrames = 12;          // una inferencia cada 240 ms
constexpr uint32_t kWakeRefractoryMs = 2000;

extern const unsigned char g_wakeword_model_data[];
extern const unsigned int g_wakeword_model_data_len;
extern const int8_t kWakeSelfTestInput[1960];
extern const int8_t kWakeSelfTestExpected[2];

#endif
