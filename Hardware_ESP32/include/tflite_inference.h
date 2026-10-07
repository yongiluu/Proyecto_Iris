#ifndef TFLITE_INFERENCE_H
#define TFLITE_INFERENCE_H

#include <Arduino.h>

void initEdgeAI();
void runInference(double* fft_features, size_t num_features);

#endif