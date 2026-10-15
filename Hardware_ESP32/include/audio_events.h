#ifndef AUDIO_EVENTS_H
#define AUDIO_EVENTS_H

#include <Arduino.h>

// Deteccion local de eventos de audio (Edge AI): log-mel + modelo TFLite entrenado en
// ML_Training/audio. Las features se calculan en el loop (barato) y la red corre en su propia
// tarea para no cortar la lectura del microfono.

// Se llama desde la tarea de inferencia cuando se detecta una alerta (ej. "sirena", 87).
typedef void (*AudioEventCallback)(const char* label, int confidencePercent);

bool startAudioEvents(AudioEventCallback callback);

// Alimentar con las muestras del microfono (PCM 16-bit, 16 kHz). Llamar desde el loop.
void feedAudioEvents(const int16_t* samples, size_t count);

// Pausa mientras se transmite audio por push-to-talk. Llamar desde el loop.
void setAudioEventsPaused(bool paused);

#endif
