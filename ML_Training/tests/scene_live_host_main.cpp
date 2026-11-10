// Pruebas del modo en vivo (scene_live.cpp) con escenas simuladas cuadro a cuadro.
// Lo compila y corre tests/test_scene_live.py. Imprime "OK <n>" o la primera prueba que falla.
#include <stdio.h>
#include <string.h>

#include "scene_live.h"

namespace {
struct Frame {
    float presence[kSceneNumObjects];
    float position[kSceneNumObjects * kSceneNumPositions];
    float distance[kSceneNumObjects * kSceneNumDistances];
    float color[kSceneNumObjects * kSceneNumColors];
    float hazards[kSceneNumHazards];
    float people[kSceneNumPeople];
    float place[kSceneNumPlaces];
    float quality[kSceneNumQuality];

    Frame() {
        memset(this, 0, sizeof(*this));
        people[0] = 1.0f;   // nadie
        quality[0] = 1.0f;  // imagen buena
    }
    ScenePrediction prediction(bool hazardsTrained) const {
        return ScenePrediction{presence, position, distance, color, hazards, people, place, quality, hazardsTrained};
    }
};

int failures = 0, checks = 0;
void expect(bool condition, const char* what) {
    checks++;
    if (!condition) {
        failures++;
        printf("FALLA: %s\n", what);
    }
}

constexpr int kCar = 1, kTree = 2;
}  // namespace

int main() {
    // 1. Escena vacia: nunca habla
    {
        SceneLiveState s;
        Frame f;
        bool spoke = false;
        for (int t = 0; t < 10; t++) spoke |= sceneLiveUpdate(&s, f.prediction(false), t * 1500);
        expect(!spoke, "escena vacia no se anuncia");
    }
    // 2. Aparece una persona: se anuncia al segundo cuadro, una sola vez
    {
        SceneLiveState s;
        Frame f;
        sceneLiveUpdate(&s, f.prediction(false), 0);
        sceneLiveUpdate(&s, f.prediction(false), 1500);
        f.presence[kScenePersonIndex] = 0.9f;
        f.people[0] = 0.0f;
        f.people[1] = 1.0f;
        expect(!sceneLiveUpdate(&s, f.prediction(false), 3000), "un solo cuadro no basta (estabilidad)");
        expect(sceneLiveUpdate(&s, f.prediction(false), 4500), "persona estable se anuncia");
        bool again = false;
        for (int t = 4; t < 12; t++) again |= sceneLiveUpdate(&s, f.prediction(false), t * 1500);
        expect(!again, "la misma escena no se repite");

        // 3. Titubeo cerca del umbral: con histeresis sigue igual, sin avisos
        bool flicker = false;
        for (int t = 12; t < 20; t++) {
            f.presence[kScenePersonIndex] = (t % 2) ? 0.55f : 0.45f;
            flicker |= sceneLiveUpdate(&s, f.prediction(false), t * 1500);
        }
        expect(!flicker, "un objeto que titubea entre 0,45 y 0,55 no genera avisos");

        // 4. Llega un auto: se avisa, pero respetando la pausa minima
        f.presence[kScenePersonIndex] = 0.9f;
        f.presence[kCar] = 0.9f;
        SceneLiveState fast = s;
        fast.lastAnnounceMs = 29000;  // se acaba de avisar algo
        sceneLiveUpdate(&fast, f.prediction(false), 30000);
        expect(!sceneLiveUpdate(&fast, f.prediction(false), 31500), "un cambio antes de 4 s espera");
        expect(sceneLiveUpdate(&fast, f.prediction(false), 33500), "despues de la pausa se avisa el auto");
    }
    // 5. Peligro nuevo: se avisa al tiro aunque se acabe de hablar
    {
        SceneLiveState s;
        Frame f;
        f.presence[kTree] = 0.9f;
        sceneLiveUpdate(&s, f.prediction(true), 0);
        expect(sceneLiveUpdate(&s, f.prediction(true), 1500), "arbol se anuncia");
        f.hazards[0] = 0.9f;
        sceneLiveUpdate(&s, f.prediction(true), 2000);
        expect(sceneLiveUpdate(&s, f.prediction(true), 2500), "peligro nuevo salta la pausa minima");
    }
    // 6. Peligros de un modelo que no los aprendio: se ignoran
    {
        SceneLiveState s;
        Frame f;
        f.hazards[0] = 0.99f;
        bool spoke = false;
        for (int t = 0; t < 5; t++) spoke |= sceneLiveUpdate(&s, f.prediction(false), t * 1500);
        expect(!spoke, "peligros sin entrenar no cuentan");
    }
    // 7. La imagen se pone oscura: se avisa una vez
    {
        SceneLiveState s;
        Frame f;
        f.quality[0] = 0.1f;
        f.quality[1] = 0.9f;
        sceneLiveUpdate(&s, f.prediction(false), 0);
        expect(sceneLiveUpdate(&s, f.prediction(false), 1500), "imagen oscura se avisa");
        expect(!sceneLiveUpdate(&s, f.prediction(false), 9000), "imagen oscura no se repite");
    }
    if (failures == 0) printf("OK %d\n", checks);
    return failures == 0 ? 0 : 1;
}
