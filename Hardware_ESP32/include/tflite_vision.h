#ifndef TFLITE_VISION_H
#define TFLITE_VISION_H

#include <Arduino.h>

void initVisionAI();
void runVisionInference(uint8_t* image_data, size_t len);

#endif