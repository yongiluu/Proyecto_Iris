#ifndef PROXIMITY_H
#define PROXIMITY_H

#include <Arduino.h>

// Cercania con vision (modelo de ML_Training/vision/proximity_*.py): con el mismo frame 96x96 en grises
// estima si hay algo al frente libre (0), cerca (1, < ~1,5 m) o muy cerca (2, < ~0,7 m).
// Es una estimacion con una camara: detecta paredes y obstaculos grandes al frente, no hoyos ni cosas
// delgadas. Un sensor de distancia (prototipo 3) lo hara mejor.

// Se llama desde la tarea de vision cuando cambia el nivel (0 libre, 1 cerca, 2 muy cerca).
typedef void (*ProximityCallback)(int level, int confidencePercent);

bool initProximityAI(ProximityCallback callback);

// Un frame 96x96 en grises. Llamar desde la tarea de vision, despues de runVisionInference.
void runProximityInference(const uint8_t* image_data, size_t len);

// Olvida el frame anterior (ej. tras una pausa).
void resetProximitySmoothing();

#endif
