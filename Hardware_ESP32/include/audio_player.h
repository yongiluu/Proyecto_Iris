#ifndef AUDIO_PLAYER_H
#define AUDIO_PLAYER_H

#include <Arduino.h>

void initAudioPlayer();
void playAudioBuffer(uint8_t *payload, size_t length);

#endif
