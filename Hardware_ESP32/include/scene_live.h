#ifndef SCENE_LIVE_H
#define SCENE_LIVE_H

// Modo EN VIVO de la descripcion de escenas: la placa mira cada ~1,5 s pero solo habla cuando la escena
// cambia de verdad (aparece una persona, un auto, una escalera; la imagen se pone oscura...). Si hablara
// en cada cuadro seria insoportable, y si un objeto titubea en el borde del umbral diria lo mismo diez
// veces. Por eso:
//   - histeresis: un objeto "aparece" sobre kLiveEnter y "desaparece" bajo kLiveExit;
//   - estabilidad: el cambio debe verse en kLiveStableFrames cuadros seguidos;
//   - pausa minima entre avisos (kLiveMinGapMs), salvo un peligro nuevo, que se avisa al tiro;
//   - si la escena queda vacia no se dice nada (no es un aviso util).
// C++ puro (sin Arduino): ML_Training/tests/test_scene_live.py lo prueba en el PC.

#include <stdint.h>

#include "scene_describe.h"

constexpr double kLiveEnter = 0.6;
constexpr double kLiveExit = 0.4;
constexpr int kLiveStableFrames = 2;
constexpr uint32_t kLiveMinGapMs = 4000;

struct SceneLiveState {
    uint64_t objects = 0;      // objetos presentes (con histeresis), un bit por objeto
    uint16_t hazards = 0;      // peligros presentes (con histeresis), un bit por peligro
    uint8_t people = 0;        // 0, 1, 2, 3+ (la clase mas probable)
    bool badImage = false;     // oscura, borrosa o tapada
    uint64_t candidate = 0;    // firma vista en los ultimos cuadros
    int candidateFrames = 0;
    uint64_t announced = 0;    // firma del ultimo aviso
    uint16_t announcedHazards = 0;  // peligros que ya se avisaron
    bool announcedAny = false;
    uint32_t lastAnnounceMs = 0;
};

// Actualiza el estado con un cuadro nuevo. Devuelve true si hay que decir la frase de este cuadro.
bool sceneLiveUpdate(SceneLiveState* state, const ScenePrediction& p, uint32_t nowMs);

// Firma de lo que importa de la escena (para comparar cuadros). Expuesta para las pruebas.
uint64_t sceneLiveSignature(const SceneLiveState& state);

#endif
