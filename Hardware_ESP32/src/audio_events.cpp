#include "audio_events.h"

#include <TensorFlowLite_ESP32.h>
#include <atomic>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_timer.h>
#include <math.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"

#include "audio_frontend.h"
#include "audio_model_data.h"
#include "config.h"
#include "tflm_arena.h"
#if WAKE_WORD_ENABLED
#include "wakeword_model_data.h"
#endif

namespace {
AudioFrontend frontend;
AudioEventCallback onEvent = nullptr;
AudioEventCallback onContext = nullptr;
WakeWordCallback onWake = nullptr;

// Un modelo TFLite (eventos de audio o wake word) que mira el ultimo segundo de log-mel.
struct Model {
    tflite::MicroInterpreter* interpreter = nullptr;
    TfLiteTensor* input = nullptr;
    TfLiteTensor* output = nullptr;
    float inputScale = 1.0f;
    int inputZeroPoint = 0;
    int stride = 0;                    // cada cuantos frames nuevos corre
    int framesSinceInference = 0;
    std::atomic<bool> busy{false};     // true mientras la tarea usa el tensor de entrada
};
Model audioModel;
Model wakeModel;

// Ultimo segundo de features log-mel (buffer circular de frames). Se guarda en float: cada modelo
// tiene su propia cuantizacion de entrada.
float featureRing[kAfNumFrames][kAfNumMel];
int ringHead = 0;           // proximo frame a escribir (= el mas antiguo cuando esta lleno)
int framesStored = 0;
bool paused = false;

TaskHandle_t inferenceTask = nullptr;
constexpr uint32_t kRunAudio = 1;
constexpr uint32_t kRunWake = 2;

float previousScores[kAudioNumClasses] = {};
uint32_t lastEventMs[kAudioNumClasses] = {};
uint16_t contextCounts[kAudioNumClasses] = {};
uint32_t lastContextMs = 0;
uint32_t lastWakeMs = 0;

// Resumen periodico: clase ganadora mas frecuente desde el ultimo resumen.
void updateContext(const float* scores) {
    int top = 0;
    for (int i = 1; i < kAudioNumClasses; i++) if (scores[i] > scores[top]) top = i;
    contextCounts[top]++;

    uint32_t now = millis();
    if (now - lastContextMs < AMBIENT_CONTEXT_PERIOD_MS) return;
    lastContextMs = now;
    int best = 0, total = 0;
    for (int i = 0; i < kAudioNumClasses; i++) {
        total += contextCounts[i];
        if (contextCounts[i] > contextCounts[best]) best = i;
    }
    if (total > 0 && onContext) onContext(kAudioLabels[best], contextCounts[best] * 100 / total);
    memset(contextCounts, 0, sizeof(contextCounts));
}

// Corre la ventana de prueba que dejo el export y compara con la salida calculada en el PC.
// Verifica la libreria TFLM (con o sin ESP-NN) en el chip real y mide cuanto tarda una inferencia.
void runSelfTest(Model& m, const char* tag, const int8_t* testInput, size_t inputBytes, const int8_t* expected,
                 int numOutputs) {
    memcpy(m.input->data.int8, testInput, inputBytes);
    const int64_t start = esp_timer_get_time();
    const bool invoked = m.interpreter->Invoke() == kTfLiteOk;
    const int64_t elapsedUs = esp_timer_get_time() - start;

    int maxDiff = 0, best = 0, expectedBest = 0;
    for (int i = 0; i < numOutputs; i++) {
        int diff = abs(m.output->data.int8[i] - expected[i]);
        if (diff > maxDiff) maxDiff = diff;
        if (m.output->data.int8[i] > m.output->data.int8[best]) best = i;
        if (expected[i] > expected[expectedBest]) expectedBest = i;
    }
    // Unos LSB de diferencia son normales (redondeos de TFLM vs TensorFlow); la clase debe ser la misma.
    const bool ok = invoked && best == expectedBest && maxDiff <= 8;
    Serial.printf("[%s] Autotest %s: %.1f ms por inferencia, salida %d, max dif %d\n", tag,
                  ok ? "OK" : "FALLO", elapsedUs / 1000.0, best, maxDiff);
}

void handleScores(const float* scores) {
    updateContext(scores);
    // Promedio con la inferencia anterior (~1 s de contexto) para evitar alertas por un golpe aislado.
    int best = -1;
    float bestScore = 0.0f;
    for (int i = 0; i < kAudioNumClasses; i++) {
        float smoothed = 0.5f * (scores[i] + previousScores[i]);
        previousScores[i] = scores[i];
        if (kAudioIsAlert[i] && smoothed > bestScore) {
            bestScore = smoothed;
            best = i;
        }
    }

#if AUDIO_EVENTS_DEBUG
    Serial.print("[Audio IA]");
    for (int i = 0; i < kAudioNumClasses; i++) Serial.printf(" %s=%.2f", kAudioLabels[i], scores[i]);
    Serial.println();
#endif

    if (best < 0 || bestScore < kAudioAlertThreshold) return;
    uint32_t now = millis();
    if (lastEventMs[best] != 0 && now - lastEventMs[best] < AUDIO_EVENT_COOLDOWN_MS) return;
    lastEventMs[best] = now;

    int percent = (int)lroundf(bestScore * 100.0f);
    Serial.printf("[Audio IA] Alerta: %s (%d%%)\n", kAudioLabels[best], percent);
    if (onEvent) onEvent(kAudioLabels[best], percent);
}

#if WAKE_WORD_ENABLED
void runWake() {
    TfLiteStatus status = wakeModel.interpreter->Invoke();
    float score = 0.0f;
    if (status == kTfLiteOk) {
        score = (wakeModel.output->data.int8[kWakeOutputIndex] - wakeModel.output->params.zero_point) *
                wakeModel.output->params.scale;
    }
    wakeModel.busy = false;
    if (status != kTfLiteOk) {
        Serial.println("[Wake word] Error en Invoke()");
        return;
    }
#if AUDIO_EVENTS_DEBUG
    if (score > 0.3f) Serial.printf("[Wake word] oye_iris=%.2f\n", score);
#endif
    uint32_t now = millis();
    if (score < kWakeThreshold || (lastWakeMs != 0 && now - lastWakeMs < kWakeRefractoryMs)) return;
    lastWakeMs = now;
    int percent = (int)lroundf(score * 100.0f);
    Serial.printf("[Wake word] Oye Iris (%d%%)\n", percent);
    if (onWake) onWake(percent);
}
#endif

void runAudio() {
    float scores[kAudioNumClasses];
    TfLiteStatus status = audioModel.interpreter->Invoke();
    if (status == kTfLiteOk) {
        const float scale = audioModel.output->params.scale;
        const int zeroPoint = audioModel.output->params.zero_point;
        for (int i = 0; i < kAudioNumClasses; i++) {
            scores[i] = (audioModel.output->data.int8[i] - zeroPoint) * scale;
        }
    }
    audioModel.busy = false;

    if (status == kTfLiteOk) handleScores(scores);
    else Serial.println("[Audio IA] Error en Invoke()");
}

void inferenceLoop(void*) {
    for (;;) {
        uint32_t bits = 0;
        xTaskNotifyWait(0, UINT32_MAX, &bits, portMAX_DELAY);
#if WAKE_WORD_ENABLED
        if (bits & kRunWake) runWake();   // primero el wake word: es el que el usuario espera
#endif
        if (bits & kRunAudio) runAudio();
    }
}

// Copia la ventana en orden cronologico (del frame mas antiguo al mas nuevo) cuantizada para el modelo.
void fillInput(Model& m) {
    int8_t* dst = m.input->data.int8;
    const float invScale = 1.0f / m.inputScale;
    for (int i = 0; i < kAfNumFrames; i++) {
        const float* row = featureRing[(ringHead + i) % kAfNumFrames];
        for (int k = 0; k < kAfNumMel; k++) {
            long q = lroundf(row[k] * invScale) + m.inputZeroPoint;
            *dst++ = (int8_t)(q < -128 ? -128 : q > 127 ? 127 : q);
        }
    }
}

// true si al modelo le toca correr con este frame y su entrada quedo lista.
bool schedule(Model& m) {
    if (m.interpreter == nullptr) return false;
    m.framesSinceInference++;
    if (framesStored < kAfNumFrames || m.framesSinceInference < m.stride) return false;
    if (m.busy) return false;  // la red sigue con la ventana anterior: se reintenta en el proximo frame
    fillInput(m);
    m.framesSinceInference = 0;
    m.busy = true;
    return true;
}

void onFrame(const float* mel, void*) {
    memcpy(featureRing[ringHead], mel, sizeof(featureRing[0]));
    ringHead = (ringHead + 1) % kAfNumFrames;
    if (framesStored < kAfNumFrames) framesStored++;

    uint32_t bits = 0;
    if (schedule(audioModel)) bits |= kRunAudio;
    if (schedule(wakeModel)) bits |= kRunWake;
    if (bits) xTaskNotify(inferenceTask, bits, eSetBits);
}

// Carga un modelo y revisa que calce con el front-end. arenaBytes viene del export.
bool loadModel(Model& m, const char* tag, const unsigned char* modelData, int arenaBytes, int numOutputs,
               tflite::MicroOpResolver& resolver, tflite::ErrorReporter* errorReporter) {
    const tflite::Model* model = tflite::GetModel(modelData);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.printf("[%s] Version de schema del modelo incorrecta\n", tag);
        return false;
    }
    const size_t arenaSize = tflmArenaBytes(arenaBytes);
    uint8_t* arena = allocTflmArena(arenaSize);
    if (arena == nullptr) {
        Serial.printf("[%s] Sin memoria para el tensor arena\n", tag);
        return false;
    }
    auto* interpreter = new tflite::MicroInterpreter(model, resolver, arena, arenaSize, errorReporter);
    if (interpreter->AllocateTensors() != kTfLiteOk) {
        Serial.printf("[%s] AllocateTensors fallo con %u bytes: sube tflmArenaBytes()\n", tag, (unsigned)arenaSize);
        return false;
    }
    TfLiteTensor* input = interpreter->input(0);
    TfLiteTensor* output = interpreter->output(0);
    if (input->type != kTfLiteInt8 || input->bytes != (size_t)(kAfNumFrames * kAfNumMel) ||
        output->type != kTfLiteInt8 || output->dims->data[output->dims->size - 1] != numOutputs) {
        Serial.printf("[%s] El modelo no calza con el front-end: vuelve a exportarlo\n", tag);
        return false;
    }
    m.input = input;
    m.output = output;
    m.inputScale = input->params.scale;
    m.inputZeroPoint = input->params.zero_point;
    m.interpreter = interpreter;
    Serial.printf("[%s] Listo: arena %u/%u bytes\n", tag, (unsigned)interpreter->arena_used_bytes(), (unsigned)arenaSize);
    return true;
}
}  // namespace

bool startAudioEvents(AudioEventCallback callback, AudioEventCallback contextCallback, WakeWordCallback wakeCallback) {
    onEvent = callback;
    onContext = contextCallback;
    onWake = wakeCallback;

    static tflite::MicroErrorReporter errorReporter;
    static tflite::AllOpsResolver resolver;

    if (!loadModel(audioModel, "Audio IA", g_audio_model_data, kAudioTensorArenaSize, kAudioNumClasses, resolver,
                   &errorReporter)) {
        return false;
    }
    audioModel.stride = kAfInferenceStride;
    runSelfTest(audioModel, "Audio IA", kAudioSelfTestInput, sizeof(kAudioSelfTestInput), kAudioSelfTestExpected,
                kAudioNumClasses);

#if WAKE_WORD_ENABLED
    // Si el wake word no carga, los eventos de audio siguen funcionando (se habla con el boton).
    if (loadModel(wakeModel, "Wake word", g_wakeword_model_data, kWakeTensorArenaSize, 2, resolver, &errorReporter)) {
        wakeModel.stride = kWakeStrideFrames;
        runSelfTest(wakeModel, "Wake word", kWakeSelfTestInput, sizeof(kWakeSelfTestInput), kWakeSelfTestExpected, 2);
    } else {
        wakeModel.interpreter = nullptr;
    }
#endif

    if (xTaskCreatePinnedToCore(inferenceLoop, "audio_ia", 6144, nullptr, 1, &inferenceTask, 1) != pdPASS) {
        Serial.println("[Audio IA] No se pudo crear la tarea de inferencia");
        audioModel.interpreter = nullptr;
        wakeModel.interpreter = nullptr;
        return false;
    }
    Serial.printf("[Audio IA] Listo: %d clases%s\n", kAudioNumClasses,
                  wakeModel.interpreter ? " + wake word \"Oye Iris\"" : "");
    return true;
}

void feedAudioEvents(const int16_t* samples, size_t count) {
    if (audioModel.interpreter == nullptr || paused) return;
    frontend.process(samples, count, onFrame, nullptr);
}

void setAudioEventsPaused(bool shouldPause) {
    if (shouldPause && !paused) {
        // Al volver se empieza una ventana limpia (sin mezclar audio de antes y despues de hablar).
        frontend.reset();
        framesStored = 0;
        audioModel.framesSinceInference = 0;
        wakeModel.framesSinceInference = 0;
    }
    paused = shouldPause;
}
