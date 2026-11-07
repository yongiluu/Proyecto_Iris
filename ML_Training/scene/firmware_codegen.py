"""Genera las tablas del vocabulario de escenas para el firmware (scene_vocab.h / scene_vocab.cpp).

    python scene/firmware_codegen.py

El firmware arma la frase con Hardware_ESP32/src/scene_describe.cpp, que es la misma logica que
describe.py; tests/test_scene_describe.py verifica que ambos den el mismo texto.
"""
import config
import describe
from vocab import (COLOR_FORMS, COLOR_IDS, DISTANCES, HAZARD_IDS, HAZARD_TEXT, OBJECT_IDS, OBJECT_INFO,
                   PEOPLE_BINS, PLACE_NAMES, PLACES, POSITIONS, QUALITY)

NOTE = "// GENERADO por ML_Training/scene/firmware_codegen.py desde vocab.py. No editar a mano.\n"


def c_string(text) -> str:
    if text is None:
        return "nullptr"
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def c_list(values, per_line=4) -> str:
    items = [c_string(v) if not isinstance(v, (bool, int)) else str(v).lower() for v in values]
    lines = [", ".join(items[i:i + per_line]) for i in range(0, len(items), per_line)]
    return "    " + ",\n    ".join(lines)


def main() -> None:
    assert POSITIONS == ["izquierda", "centro", "derecha"] and DISTANCES == ["cerca", "medio", "lejos"]
    assert QUALITY[0] == "buena" and PEOPLE_BINS == ["0", "1", "2", "3+"]

    header = f"""{NOTE}#ifndef SCENE_VOCAB_H
#define SCENE_VOCAB_H

constexpr int kSceneNumObjects = {len(OBJECT_IDS)};
constexpr int kSceneNumColors = {len(COLOR_IDS)};
constexpr int kSceneNumPositions = {len(POSITIONS)};   // izquierda, centro, derecha
constexpr int kSceneNumDistances = {len(DISTANCES)};   // cerca, medio, lejos
constexpr int kSceneNumHazards = {len(HAZARD_IDS)};
constexpr int kSceneNumPeople = {len(PEOPLE_BINS)};    // 0, 1, 2, 3+
constexpr int kSceneNumPlaces = {len(PLACES)};
constexpr int kSceneNumQuality = {len(QUALITY)};       // buena, oscura, borrosa, tapada
constexpr int kScenePersonIndex = {OBJECT_IDS.index("persona")};

// Umbrales de describe.py (double: se compara igual que Python)
constexpr int kSceneMaxObjects = {describe.MAX_OBJECTS};
constexpr double kSceneObjectThreshold = {describe.OBJECT_THRESHOLD};
constexpr double kSceneHazardSure = {describe.HAZARD_SURE};
constexpr double kSceneHazardMaybe = {describe.HAZARD_MAYBE};
constexpr double kSceneHazardNone = {describe.HAZARD_NONE};
constexpr double kScenePlaceThreshold = {describe.PLACE_THRESHOLD};
constexpr double kSceneColorThreshold = {describe.COLOR_THRESHOLD};
constexpr double kSceneQualityBad = {describe.QUALITY_BAD};

extern const char* const kSceneObjectSingular[kSceneNumObjects];
extern const bool kSceneObjectFeminine[kSceneNumObjects];
extern const bool kSceneObjectHasColor[kSceneNumObjects];
extern const char* const kSceneColorMasculine[kSceneNumColors];
extern const char* const kSceneColorFeminine[kSceneNumColors];
extern const char* const kScenePlaceName[kSceneNumPlaces];   // nullptr = no se menciona ("otro")
extern const char* const kSceneHazardSureText[kSceneNumHazards];
extern const char* const kSceneHazardMaybeText[kSceneNumHazards];

#endif
"""
    source = f"""{NOTE}#include "scene_vocab.h"

const char* const kSceneObjectSingular[kSceneNumObjects] = {{
{c_list([OBJECT_INFO[o]["singular"] for o in OBJECT_IDS])}
}};
const bool kSceneObjectFeminine[kSceneNumObjects] = {{
{c_list([OBJECT_INFO[o]["gender"] == "f" for o in OBJECT_IDS], 8)}
}};
const bool kSceneObjectHasColor[kSceneNumObjects] = {{
{c_list([OBJECT_INFO[o]["has_color"] for o in OBJECT_IDS], 8)}
}};
const char* const kSceneColorMasculine[kSceneNumColors] = {{
{c_list([COLOR_FORMS[c]["m"] for c in COLOR_IDS])}
}};
const char* const kSceneColorFeminine[kSceneNumColors] = {{
{c_list([COLOR_FORMS[c]["f"] for c in COLOR_IDS])}
}};
const char* const kScenePlaceName[kSceneNumPlaces] = {{
{c_list([PLACE_NAMES[p] for p in PLACES])}
}};
const char* const kSceneHazardSureText[kSceneNumHazards] = {{
{c_list([HAZARD_TEXT[h]["sure"] for h in HAZARD_IDS], 2)}
}};
const char* const kSceneHazardMaybeText[kSceneNumHazards] = {{
{c_list([HAZARD_TEXT[h]["maybe"] for h in HAZARD_IDS], 2)}
}};
"""
    (config.FIRMWARE_INCLUDE / "scene_vocab.h").write_text(header, encoding="utf-8")
    (config.FIRMWARE_SRC / "scene_vocab.cpp").write_text(source, encoding="utf-8")
    print(f"✔ {config.FIRMWARE_INCLUDE / 'scene_vocab.h'} y {config.FIRMWARE_SRC / 'scene_vocab.cpp'}")


if __name__ == "__main__":
    main()
