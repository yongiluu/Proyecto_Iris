#ifndef AUDIO_EVENTS_H
#define AUDIO_EVENTS_H

#include <Arduino.h>

// Deteccion local de eventos de audio (Edge AI): log-mel + modelo TFLite entrenado en
// ML_Training/audio. Las features se calculan en el loop (barato) y la red corre en su propia
// tarea para no cortar la lectura del microfono.

// Se llama desde la tarea de inferencia cuando se detecta una alerta (ej. "sirena", 87).
typedef void (*AudioEventCallback)(const char* label, int confidencePercent);

// onContext recibe cada AMBIENT_CONTEXT_PERIOD_MS la clase que mas aparecio (ej. "voz", 60 = 60% de
// las inferencias). Es contexto silencioso para la IA de la app, no una alerta. Puede ser nullptr.
// Wake word "Oye Iris" (modelo de ML_Training/wakeword, usa las mismas features): se llama desde la tarea
// de inferencia con el puntaje en % cuando alguien dice "Oye Iris". Requiere WAKE_WORD_ENABLED en config.h.
typedef void (*WakeWordCallback)(int confidencePercent);

bool startAudioEvents(AudioEventCallback callback, AudioEventCallback onContext = nullptr,
                      WakeWordCallback onWake = nullptr);

// Alimentar con las muestras del microfono (PCM 16-bit, 16 kHz). Llamar desde el loop.
void feedAudioEvents(const int16_t* samples, size_t count);

// Pausa mientras se transmite audio por push-to-talk. Llamar desde el loop.
void setAudioEventsPaused(bool paused);

#endif
