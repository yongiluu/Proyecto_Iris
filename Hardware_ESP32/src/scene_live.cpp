#include "scene_live.h"

namespace {
int argmax(const float* values, int count) {
    int best = 0;
    for (int i = 1; i < count; i++) {
        if (values[i] > values[best]) best = i;
    }
    return best;
}

// Mezcla de bits (splitmix64) para que la firma no confunda escenas distintas.
uint64_t mix(uint64_t x) {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}
}  // namespace

uint64_t sceneLiveSignature(const SceneLiveState& s) {
    uint64_t h = mix(s.objects);
    h = mix(h ^ s.hazards);
    h = mix(h ^ ((uint64_t)s.people << 1) ^ (s.badImage ? 1u : 0u));
    return h;
}

bool sceneLiveUpdate(SceneLiveState* s, const ScenePrediction& p, uint32_t nowMs) {
    // 1. Objetos y peligros con histeresis
    for (int i = 0; i < kSceneNumObjects && i < 64; i++) {
        const uint64_t bit = 1ull << i;
        if (p.presence[i] >= kLiveEnter) s->objects |= bit;
        else if (p.presence[i] < kLiveExit) s->objects &= ~bit;
    }
    if (p.hazardsTrained) {
        for (int i = 0; i < kSceneNumHazards && i < 16; i++) {
            const uint16_t bit = (uint16_t)(1u << i);
            if (p.hazards[i] >= kLiveEnter) s->hazards |= bit;
            else if (p.hazards[i] < kLiveExit) s->hazards &= (uint16_t)~bit;
        }
    }
    s->people = (uint8_t)argmax(p.people, kSceneNumPeople);
    // Calidad: 0 = buena; cualquier otra clase con seguridad = imagen mala
    const int quality = argmax(p.quality, kSceneNumQuality);
    s->badImage = quality != 0 && p.quality[quality] >= kSceneQualityBad;

    // 2. Estabilidad: la misma firma en kLiveStableFrames cuadros seguidos
    const uint64_t signature = sceneLiveSignature(*s);
    if (signature == s->candidate) {
        if (s->candidateFrames < kLiveStableFrames) s->candidateFrames++;
    } else {
        s->candidate = signature;
        s->candidateFrames = 1;
    }
    if (s->candidateFrames < kLiveStableFrames) return false;
    if (s->announcedAny && signature == s->announced) return false;

    // 3. Escena vacia (nada, nadie, imagen buena): se recuerda pero no se dice
    const bool empty = s->objects == 0 && s->hazards == 0 && s->people == 0 && !s->badImage;
    if (empty) {
        s->announced = signature;
        s->announcedHazards = 0;
        s->announcedAny = true;
        return false;
    }

    // 4. Pausa minima, salvo que aparezca un peligro nuevo
    const bool newHazard = (s->hazards & (uint16_t)~s->announcedHazards) != 0;
    if (s->announcedAny && !newHazard && nowMs - s->lastAnnounceMs < kLiveMinGapMs) return false;

    s->announced = signature;
    s->announcedHazards = s->hazards;
    s->announcedAny = true;
    s->lastAnnounceMs = nowMs;
    return true;
}
