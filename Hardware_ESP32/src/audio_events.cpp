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

namespace {
AudioFrontend frontend;
AudioEventCallback onEvent = nullptr;
AudioEventCallback onContext = nullptr;

tflite::MicroInterpreter* interpreter = nullptr;
TfLiteTensor* input = nullptr;
TfLiteTensor* output = nullptr;
float inputScale = 1.0f;
int inputZeroPoint = 0;

// Ultimo segundo de features ya cuantizadas a int8 (buffer circular de frames).
int8_t featureRing[kAfNumFrames][kAfNumMel];
int ringHead = 0;           // proximo frame a escribir (= el mas antiguo cuando esta lleno)
int framesStored = 0;
int framesSinceInference = 0;
bool paused = false;

TaskHandle_t inferenceTask = nullptr;
std::atomic<bool> inferenceBusy{false};  // true mientras la tarea usa el tensor de entrada

float previousScores[kAudioNumClasses] = {};
uint32_t lastEventMs[kAudioNumClasses] = {};
uint16_t contextCounts[kAudioNumClasses] = {};
uint32_t lastContextMs = 0;

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

// Corre la ventana de prueba que dejo export_model.py y compara con la salida calculada en el PC.
// Verifica la libreria TFLM (con o sin ESP-NN) en el chip real y mide cuanto tarda una inferencia.
void runSelfTest() {
    memcpy(input->data.int8, kAudioSelfTestInput, sizeof(kAudioSelfTestInput));
    const int64_t start = esp_timer_get_time();
    const bool invoked = interpreter->Invoke() == kTfLiteOk;
    const int64_t elapsedUs = esp_timer_get_time() - start;

    int maxDiff = 0, best = 0, expectedBest = 0;
    for (int i = 0; i < kAudioNumClasses; i++) {
        int diff = abs(output->data.int8[i] - kAudioSelfTestExpected[i]);
        if (diff > maxDiff) maxDiff = diff;
        if (output->data.int8[i] > output->data.int8[best]) best = i;
        if (kAudioSelfTestExpected[i] > kAudioSelfTestExpected[expectedBest]) expectedBest = i;
    }
    // Unos LSB de diferencia son normales (redondeos de TFLM vs TensorFlow); la clase debe ser la misma.
    const bool ok = invoked && best == expectedBest && maxDiff <= 8;
    Serial.printf("[Audio IA] Autotest %s: %.1f ms por inferencia, clase %s, max dif %d\n",
                  ok ? "OK" : "FALLO", elapsedUs / 1000.0, kAudioLabels[best], maxDiff);
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

void inferenceLoop(void*) {
    float scores[kAudioNumClasses];
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

        TfLiteStatus status = interpreter->Invoke();
        if (status == kTfLiteOk) {
            const float scale = output->params.scale;
            const int zeroPoint = output->params.zero_point;
            for (int i = 0; i < kAudioNumClasses; i++) {
                scores[i] = (output->data.int8[i] - zeroPoint) * scale;
            }
        }
        inferenceBusy = false;

        if (status == kTfLiteOk) handleScores(scores);
        else Serial.println("[Audio IA] Error en Invoke()");
    }
}

void onFrame(const float* mel, void*) {
    int8_t* row = featureRing[ringHead];
    for (int m = 0; m < kAfNumMel; m++) {
        long q = lroundf(mel[m] / inputScale) + inputZeroPoint;
        row[m] = (int8_t)(q < -128 ? -128 : q > 127 ? 127 : q);
    }
    ringHead = (ringHead + 1) % kAfNumFrames;
    if (framesStored < kAfNumFrames) framesStored++;
    framesSinceInference++;

    if (framesStored < kAfNumFrames || framesSinceInference < kAfInferenceStride) return;
    if (inferenceBusy) return;  // la red sigue con la ventana anterior: se reintenta en el proximo frame

    // Copiar la ventana en orden cronologico (del frame mas antiguo al mas nuevo).
    int8_t* dst = input->data.int8;
    for (int i = 0; i < kAfNumFrames; i++) {
        memcpy(dst + i * kAfNumMel, featureRing[(ringHead + i) % kAfNumFrames], kAfNumMel);
    }
    framesSinceInference = 0;
    inferenceBusy = true;
    xTaskNotifyGive(inferenceTask);
}
}  // namespace

bool startAudioEvents(AudioEventCallback callback, AudioEventCallback contextCallback) {
    onEvent = callback;
    onContext = contextCallback;

    const tflite::Model* model = tflite::GetModel(g_audio_model_data);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.println("[Audio IA] Version de schema del modelo incorrecta");
        return false;
    }

    // RAM interna (rapida); si no alcanza, PSRAM.
    uint8_t* arena = (uint8_t*)heap_caps_malloc(kAudioTensorArenaSize, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (arena == nullptr) arena = (uint8_t*)heap_caps_malloc(kAudioTensorArenaSize, MALLOC_CAP_SPIRAM);
    if (arena == nullptr) {
        Serial.println("[Audio IA] Sin memoria para el tensor arena");
        return false;
    }

    static tflite::MicroErrorReporter errorReporter;
    static tflite::AllOpsResolver resolver;
    static tflite::MicroInterpreter staticInterpreter(model, resolver, arena, kAudioTensorArenaSize, &errorReporter);
    interpreter = &staticInterpreter;

    if (interpreter->AllocateTensors() != kTfLiteOk) {
        Serial.printf("[Audio IA] AllocateTensors fallo: sube kAudioTensorArenaSize (%d)\n", kAudioTensorArenaSize);
        interpreter = nullptr;
        return false;
    }

    input = interpreter->input(0);
    output = interpreter->output(0);
    if (input->type != kTfLiteInt8 || input->bytes != (size_t)(kAfNumFrames * kAfNumMel) ||
        output->type != kTfLiteInt8 || output->dims->data[output->dims->size - 1] != kAudioNumClasses) {
        Serial.println("[Audio IA] El modelo no calza con el front-end: vuelve a correr export_model.py");
        interpreter = nullptr;
        return false;
    }
    inputScale = input->params.scale;
    inputZeroPoint = input->params.zero_point;
    runSelfTest();

    if (xTaskCreatePinnedToCore(inferenceLoop, "audio_ia", 6144, nullptr, 1, &inferenceTask, 1) != pdPASS) {
        Serial.println("[Audio IA] No se pudo crear la tarea de inferencia");
        interpreter = nullptr;
        return false;
    }

    Serial.printf("[Audio IA] Listo: %d clases, arena %u/%d bytes\n", kAudioNumClasses,
                  (unsigned)interpreter->arena_used_bytes(), kAudioTensorArenaSize);
    return true;
}

void feedAudioEvents(const int16_t* samples, size_t count) {
    if (interpreter == nullptr || paused) return;
    frontend.process(samples, count, onFrame, nullptr);
}

void setAudioEventsPaused(bool shouldPause) {
    if (shouldPause && !paused) {
        // Al volver se empieza una ventana limpia (sin mezclar audio de antes y despues de hablar).
        frontend.reset();
        framesStored = 0;
        framesSinceInference = 0;
    }
    paused = shouldPause;
}
