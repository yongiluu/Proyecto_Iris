// GENERADO por ML_Training/audio/firmware_codegen.py. No editar a mano.
#ifndef AUDIO_FRONTEND_CONFIG_H
#define AUDIO_FRONTEND_CONFIG_H

#include <stdint.h>

constexpr int kAfSampleRate = 16000;
constexpr int kAfWindowSamples = 480;
constexpr int kAfHopSamples = 320;
constexpr int kAfFftSize = 512;
constexpr int kAfNumMel = 40;
constexpr int kAfNumFrames = 49;          // frames por ventana del modelo (1 s)
constexpr int kAfInferenceStride = 25;  // frames entre inferencias
constexpr float kAfLogEps = 1e-06f;

extern const float kAfWindow[kAfWindowSamples];
extern const uint16_t kAfMelStart[kAfNumMel];
extern const uint16_t kAfMelCount[kAfNumMel];
extern const uint16_t kAfMelOffset[kAfNumMel];
extern const float kAfMelWeights[467];

#endif
