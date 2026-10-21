#ifndef AUDIO_PLAYER_H
#define AUDIO_PLAYER_H

#include <Arduino.h>

bool initAudioPlayer();

// Encola PCM 16-bit mono 16 kHz. No bloquea la pila BLE: si el buffer esta lleno se descarta lo que no cabe.
void playAudioBuffer(const uint8_t* payload, size_t length);

// Tono corto de "pensando". Llamar desde el loop, no desde callbacks BLE.
void playThinkingBeep();

// true mientras Iris habla por el parlante (o acaba de llegar audio para reproducir). Mientras tanto la
// placa no manda avisos ni escucha el microfono: los avisos cortaban la respuesta y el microfono
// oia la voz de Iris (falsos "Oye Iris" y alertas).
bool isIrisSpeaking();

// Calla a Iris: descarta el audio que quedaba por reproducir (al apretar el boton para preguntar otra cosa).
void stopPlayback();

// Tono senoidal (ej. pitidos de cercania). Llamar desde el loop, no desde callbacks BLE.
void playTone(float frequencyHz, int durationMs);

#endif
