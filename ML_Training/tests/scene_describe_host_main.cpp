// Ejecuta describeScene() del firmware en el PC.
// Uso: scene_describe_host <entrada.f32> <cantidad> <salida.txt>
// La entrada tiene <cantidad> casos seguidos: las salidas del modelo en float32 (en el orden de
// ScenePrediction) y un float extra con 1 si el modelo aprendio peligros. Escribe una frase por linea.
#include <stdio.h>
#include <stdlib.h>
#include <vector>

#include "scene_describe.h"

int main(int argc, char** argv) {
    if (argc != 4) {
        fprintf(stderr, "uso: %s entrada.f32 cantidad salida.txt\n", argv[0]);
        return 2;
    }
    const int sizes[] = {kSceneNumObjects, kSceneNumObjects * kSceneNumPositions, kSceneNumObjects * kSceneNumDistances,
                         kSceneNumObjects * kSceneNumColors, kSceneNumHazards, kSceneNumPeople, kSceneNumPlaces,
                         kSceneNumQuality, 1};
    int perCase = 0;
    for (int s : sizes) perCase += s;

    const int cases = atoi(argv[2]);
    std::vector<float> data((size_t)perCase * cases);
    FILE* in = fopen(argv[1], "rb");
    if (!in || fread(data.data(), sizeof(float), data.size(), in) != data.size()) return 1;
    fclose(in);
    FILE* out = fopen(argv[3], "wb");
    if (!out) return 1;

    char text[512];
    for (int c = 0; c < cases; c++) {
        const float* f = data.data() + (size_t)c * perCase;
        const float* part[9];
        for (int k = 0; k < 9; k++) {
            part[k] = f;
            f += sizes[k];
        }
        ScenePrediction p{part[0], part[1], part[2], part[3], part[4], part[5], part[6], part[7], part[8][0] > 0.5f};
        describeScene(p, text, sizeof(text));
        fprintf(out, "%s\n", text);
    }
    fclose(out);
    return 0;
}
