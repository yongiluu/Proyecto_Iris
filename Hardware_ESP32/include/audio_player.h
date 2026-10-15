#ifndef AUDIO_PLAYER_H
#define AUDIO_PLAYER_H

#include <Arduino.h>

bool initAudioPlayer();

// Encola PCM 16-bit mono 16 kHz. No bloquea la pila BLE: si el buffer esta lleno se descarta lo que no cabe.
void playAudioBuffer(const uint8_t* payload, size_t length);

// Tono corto de "pensando". Llamar desde el loop, no desde callbacks BLE.
void playThinkingBeep();

#endif
