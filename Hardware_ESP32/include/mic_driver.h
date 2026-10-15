#ifndef MIC_DRIVER_H
#define MIC_DRIVER_H

#include <Arduino.h>

// Maximo de muestras int16 que devuelve readMicSamples() por llamada.
constexpr size_t kMicMaxSamples = 250;

bool initMic();

// Lee hasta maxSamples muestras PCM 16-bit mono. Devuelve 0 si expiro el timeout
// (asi el loop principal sigue atendiendo el boton aunque el microfono falle).
size_t readMicSamples(int16_t* out, size_t maxSamples);

#endif
