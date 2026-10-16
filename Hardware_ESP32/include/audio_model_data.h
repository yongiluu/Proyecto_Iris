// GENERADO por ML_Training/audio/export_model.py. No editar a mano.
// == Test (int8, lo que corre en la placa) ==
// Exactitud: 87.9%  (4431 ejemplos)
// Con umbral 0.7: alertas detectadas 71.4%, falsas alarmas sobre fondo/voz 3.3%
#ifndef AUDIO_MODEL_DATA_H
#define AUDIO_MODEL_DATA_H

#include <stdint.h>

constexpr int kAudioNumClasses = 5;
constexpr int kAudioTensorArenaSize = 64512;
constexpr float kAudioAlertThreshold = 0.7f;  // config.ALERT_THRESHOLD

extern const unsigned char g_audio_model_data[];
extern const unsigned int g_audio_model_data_len;
extern const char* const kAudioLabels[kAudioNumClasses];
extern const bool kAudioIsAlert[kAudioNumClasses];   // se informa a la app como CMD_AUDIO_EVENT

#endif
