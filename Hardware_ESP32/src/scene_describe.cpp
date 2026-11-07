#include "scene_describe.h"

#include <string.h>

namespace {
struct Writer {
    char* out;
    size_t size;
    size_t len = 0;
    bool firstSentence = true;

    void add(const char* text) {
        if (text == nullptr) return;
        for (; *text && len + 1 < size; text++) out[len++] = *text;
        out[len] = '\0';
    }
    void sentence() {  // las oraciones van separadas por un espacio
        if (!firstSentence) add(" ");
        firstSentence = false;
    }
};

int argmax(const float* v, int n) {
    int best = 0;
    for (int i = 1; i < n; i++) {
        if (v[i] > v[best]) best = i;  // en empate gana el primero, como numpy
    }
    return best;
}

// "a", "a y b", "a, b y c"
void addJoined(Writer& w, const char* const* parts, int count) {
    for (int i = 0; i < count; i++) {
        if (i > 0) w.add(i == count - 1 ? " y " : ", ");
        w.add(parts[i]);
    }
}

struct SceneObject {
    int index;
    int position;
    int distance;
    int color;  // -1 = sin color
    float confidence;
};

enum Group { kAhead, kLeft, kRight, kFar, kNumGroups };
const char* const kGroupName[kNumGroups] = {"Adelante", "A tu izquierda", "A tu derecha", "Al fondo"};
constexpr int kPhraseSize = 64;
}  // namespace

size_t describeScene(const ScenePrediction& p, char* out, size_t outSize) {
    if (outSize == 0) return 0;
    Writer w{out, outSize};
    out[0] = '\0';

    // Calidad de la imagen
    const int quality = argmax(p.quality, kSceneNumQuality);
    const double qualityConf = p.quality[quality];
    const bool badImage = quality != 0 && qualityConf >= kSceneQualityBad;
    if (badImage) {
        static const char* const kReason[kSceneNumQuality] = {"", "está muy oscura", "está borrosa", "parece tapada"};
        w.sentence();
        w.add("La imagen ");
        w.add(kReason[quality]);
        w.add("; no puedo describir bien.");
    }

    // Peligros, del mas probable al menos (orden estable, como sorted() de Python)
    if (p.hazardsTrained) {
        int order[kSceneNumHazards];
        for (int i = 0; i < kSceneNumHazards; i++) order[i] = i;
        for (int i = 1; i < kSceneNumHazards; i++) {
            const int key = order[i];
            int j = i - 1;
            while (j >= 0 && p.hazards[order[j]] < p.hazards[key]) {
                order[j + 1] = order[j];
                j--;
            }
            order[j + 1] = key;
        }
        const char* sure[2];
        const char* maybe[2];
        int nSure = 0, nMaybe = 0;
        for (int k = 0; k < kSceneNumHazards; k++) {
            const double v = p.hazards[order[k]];
            if (v >= kSceneHazardSure) {
                if (nSure < 2) sure[nSure++] = kSceneHazardSureText[order[k]];
            } else if (v >= kSceneHazardMaybe) {
                if (nMaybe < 2) maybe[nMaybe++] = kSceneHazardMaybeText[order[k]];
            }
        }
        if (nSure) {
            w.sentence();
            w.add("Cuidado: ");
            addJoined(w, sure, nSure);
            w.add(".");
        }
        if (nMaybe) {
            w.sentence();
            w.add("Atención: ");
            addJoined(w, maybe, nMaybe);
            w.add(".");
        }
    }

    // Lugar
    const int place = argmax(p.place, kSceneNumPlaces);
    if (p.place[place] >= kScenePlaceThreshold && kScenePlaceName[place] != nullptr) {
        w.sentence();
        w.add("Parece que estás en ");
        w.add(kScenePlaceName[place]);
        w.add(".");
    }

    // Objetos presentes, del mas cercano al mas lejano y despues por confianza (orden estable)
    SceneObject objects[kSceneNumObjects];
    int nObjects = 0;
    for (int i = 0; i < kSceneNumObjects; i++) {
        if (p.presence[i] < kSceneObjectThreshold) continue;
        SceneObject o{i, argmax(p.position + i * kSceneNumPositions, kSceneNumPositions),
                      argmax(p.distance + i * kSceneNumDistances, kSceneNumDistances), -1, p.presence[i]};
        const float* colors = p.color + i * kSceneNumColors;
        const int c = argmax(colors, kSceneNumColors);
        if (kSceneObjectHasColor[i] && colors[c] >= kSceneColorThreshold) o.color = c;
        objects[nObjects++] = o;
    }
    for (int i = 1; i < nObjects; i++) {
        const SceneObject key = objects[i];
        int j = i - 1;
        while (j >= 0 && (objects[j].distance > key.distance ||
                          (objects[j].distance == key.distance && objects[j].confidence < key.confidence))) {
            objects[j + 1] = objects[j];
            j--;
        }
        objects[j + 1] = key;
    }

    // Agrupar por donde estan (lo lejano va "al fondo")
    const int people = argmax(p.people, kSceneNumPeople);
    int groupItems[kNumGroups][kSceneMaxObjects];
    int groupCount[kNumGroups] = {0, 0, 0, 0};
    const int shown = nObjects < kSceneMaxObjects ? nObjects : kSceneMaxObjects;
    for (int k = 0; k < shown; k++) {
        const SceneObject& o = objects[k];
        const int g = o.distance == 2 ? kFar : o.position == 0 ? kLeft : o.position == 2 ? kRight : kAhead;
        groupItems[g][groupCount[g]++] = k;
    }
    for (int g = 0; g < kNumGroups; g++) {
        if (groupCount[g] == 0) continue;
        bool near = false;
        char phrases[kSceneMaxObjects][kPhraseSize];
        const char* parts[kSceneMaxObjects];
        for (int k = 0; k < groupCount[g]; k++) {
            const SceneObject& o = objects[groupItems[g][k]];
            if (g == kAhead && o.distance == 0) near = true;
            Writer pw{phrases[k], kPhraseSize};
            if (o.index == kScenePersonIndex && people >= 2) {
                pw.add(people == 2 ? "dos personas" : "varias personas");
            } else {
                const bool feminine = kSceneObjectFeminine[o.index];
                pw.add(feminine ? "una " : "un ");
                pw.add(kSceneObjectSingular[o.index]);
                if (o.color >= 0) {
                    pw.add(" ");
                    pw.add(feminine ? kSceneColorFeminine[o.color] : kSceneColorMasculine[o.color]);
                }
            }
            parts[k] = phrases[k];
        }
        w.sentence();
        w.add(kGroupName[g]);
        w.add(near ? ", muy cerca, hay " : " hay ");
        addJoined(w, parts, groupCount[g]);
        w.add(".");
    }

    if (nObjects == 0 && !badImage) {
        w.sentence();
        w.add("No reconozco objetos claros adelante.");
    }

    if (p.hazardsTrained && !badImage) {
        double highest = 0;
        for (int i = 0; i < kSceneNumHazards; i++) {
            if (p.hazards[i] > highest) highest = p.hazards[i];
        }
        if (highest < kSceneHazardNone) {
            w.sentence();
            w.add("No detecto peligros.");
        }
    }
    return w.len;
}
