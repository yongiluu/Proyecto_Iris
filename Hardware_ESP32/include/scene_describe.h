#ifndef SCENE_DESCRIBE_H
#define SCENE_DESCRIBE_H

// Arma la frase en español a partir de las salidas del modelo de escenas (ML_Training/scene).
// Es la misma logica que describe.py (C++ puro, sin Arduino): ML_Training/tests/test_scene_describe.py
// compila esto en el PC y verifica que den exactamente el mismo texto.
//
// Reglas de seguridad: primero los peligros (y "podria haber..." si el modelo duda), nunca dice
// "no hay peligros" (a lo mas "No detecto peligros", solo con buena imagen y todo bajo el umbral), y si
// la imagen esta oscura/borrosa/tapada lo dice.

#include <stddef.h>
#include "scene_vocab.h"

struct ScenePrediction {
    const float* presence;  // [kSceneNumObjects]            probabilidad de que el objeto este
    const float* position;  // [kSceneNumObjects * 3]        izquierda, centro, derecha
    const float* distance;  // [kSceneNumObjects * 3]        cerca, medio, lejos
    const float* color;     // [kSceneNumObjects * kSceneNumColors]
    const float* hazards;   // [kSceneNumHazards]
    const float* people;    // [kSceneNumPeople]
    const float* place;     // [kSceneNumPlaces]
    const float* quality;   // [kSceneNumQuality]
    bool hazardsTrained;    // false: el modelo no aprendio peligros, no se dice nada de ellos
};

// Escribe la frase (UTF-8, terminada en '\0') en out. Devuelve el largo; se corta si no cabe.
size_t describeScene(const ScenePrediction& p, char* out, size_t outSize);

#endif
