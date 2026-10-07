#ifndef AUDIO_PROCESSING_H
#define AUDIO_PROCESSING_H

#include <Arduino.h>

#define FFT_SAMPLES 256
#define SAMPLING_FREQUENCY 16000

void initAudioProcessing();
void processAudioFrame(const int16_t* audioData, size_t length);

#endif