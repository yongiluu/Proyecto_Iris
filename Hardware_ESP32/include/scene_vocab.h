// GENERADO por ML_Training/scene/firmware_codegen.py desde vocab.py. No editar a mano.
#ifndef SCENE_VOCAB_H
#define SCENE_VOCAB_H

constexpr int kSceneNumObjects = 43;
constexpr int kSceneNumColors = 11;
constexpr int kSceneNumPositions = 3;   // izquierda, centro, derecha
constexpr int kSceneNumDistances = 3;   // cerca, medio, lejos
constexpr int kSceneNumHazards = 9;
constexpr int kSceneNumPeople = 4;    // 0, 1, 2, 3+
constexpr int kSceneNumPlaces = 16;
constexpr int kSceneNumQuality = 4;       // buena, oscura, borrosa, tapada
constexpr int kScenePersonIndex = 0;

// Umbrales de describe.py (double: se compara igual que Python)
constexpr int kSceneMaxObjects = 5;
constexpr double kSceneObjectThreshold = 0.5;
constexpr double kSceneHazardSure = 0.6;
constexpr double kSceneHazardMaybe = 0.3;
constexpr double kSceneHazardNone = 0.15;
constexpr double kScenePlaceThreshold = 0.6;
constexpr double kSceneColorThreshold = 0.5;
constexpr double kSceneQualityBad = 0.5;

extern const char* const kSceneObjectSingular[kSceneNumObjects];
extern const bool kSceneObjectFeminine[kSceneNumObjects];
extern const bool kSceneObjectHasColor[kSceneNumObjects];
extern const char* const kSceneColorMasculine[kSceneNumColors];
extern const char* const kSceneColorFeminine[kSceneNumColors];
extern const char* const kScenePlaceName[kSceneNumPlaces];   // nullptr = no se menciona ("otro")
extern const char* const kSceneHazardSureText[kSceneNumHazards];
extern const char* const kSceneHazardMaybeText[kSceneNumHazards];

#endif
