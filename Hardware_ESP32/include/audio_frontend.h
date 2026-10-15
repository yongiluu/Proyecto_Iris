#ifndef AUDIO_FRONTEND_H
#define AUDIO_FRONTEND_H

// Front-end log-mel para el modelo de eventos de audio.
// C++ puro (sin Arduino) para poder probarlo en el PC: ver ML_Training/tests/.
// Debe calzar con ML_Training/audio/features.py; las constantes y tablas se generan
// desde alli (audio_frontend_config.h / audio_frontend_tables.cpp).

#include <stddef.h>
#include <stdint.h>
#include "audio_frontend_config.h"

class AudioFrontend {
public:
    // Recibe un frame de kAfNumMel valores log-mel listo.
    typedef void (*FrameCallback)(const float* melFrame, void* context);

    AudioFrontend();

    // Descarta el audio acumulado (ej. al pausar).
    void reset();

    // Consume muestras PCM 16-bit; llama a callback por cada frame nuevo (cada kAfHopSamples).
    void process(const int16_t* samples, size_t count, FrameCallback callback, void* context);

private:
    void computeFrame(float* melOut);

    float window_[kAfWindowSamples];  // ultimas muestras (normalizadas a [-1, 1])
    size_t filled_;
    float fftRe_[kAfFftSize];
    float fftIm_[kAfFftSize];
    float mel_[kAfNumMel];
};

#endif
