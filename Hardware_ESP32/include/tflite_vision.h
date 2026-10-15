#ifndef TFLITE_VISION_H
#define TFLITE_VISION_H

#include <Arduino.h>

// Vision local (Edge AI): clasifica cada frame 96x96 en grises de la camara con el modelo
// entrenado en ML_Training/vision (nada, persona, vehiculo, escalera, puerta).

// Se llama desde la tarea de vision cuando hay un aviso (ej. "escalera", 84).
typedef void (*VisionEventCallback)(const char* label, int confidencePercent);

bool initVisionAI(VisionEventCallback callback);

// Un frame 96x96 en grises (1 byte por pixel). Llamar siempre desde la misma tarea.
void runVisionInference(const uint8_t* image_data, size_t len);

// Olvida el frame anterior (ej. tras una pausa, para no promediar escenas distintas).
void resetVisionSmoothing();

#endif
