#include "tflite_vision.h"

#include <TensorFlowLite_ESP32.h>
#include <esp_heap_caps.h>
#include <math.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"

#include "config.h"
#include "vision_model_data.h"

namespace {
tflite::MicroInterpreter* interpreter = nullptr;
TfLiteTensor* input = nullptr;
TfLiteTensor* output = nullptr;
VisionEventCallback onEvent = nullptr;
VisionEventCallback onContext = nullptr;

// Pixel 0..255 -> int8 de entrada, precalculado con la cuantizacion del modelo.
int8_t pixelToInput[256];

float previousScores[kVisionNumClasses] = {};
uint32_t lastEventMs[kVisionNumClasses] = {};
uint16_t contextCounts[kVisionNumClasses] = {};
uint32_t lastContextMs = 0;

// Resumen periodico: clase mas vista desde el ultimo resumen.
void updateContext(const float* scores) {
    int top = 0;
    for (int i = 1; i < kVisionNumClasses; i++) if (scores[i] > scores[top]) top = i;
    contextCounts[top]++;

    uint32_t now = millis();
    if (now - lastContextMs < AMBIENT_CONTEXT_PERIOD_MS) return;
    lastContextMs = now;
    int best = 0, total = 0;
    for (int i = 0; i < kVisionNumClasses; i++) {
        total += contextCounts[i];
        if (contextCounts[i] > contextCounts[best]) best = i;
    }
    if (total > 0 && onContext) onContext(kVisionLabels[best], contextCounts[best] * 100 / total);
    memset(contextCounts, 0, sizeof(contextCounts));
}

void handleScores(const float* scores) {
    updateContext(scores);
    // Promedio con el frame anterior (~1 s antes) para no avisar por un frame suelto.
    int best = -1;
    float bestScore = 0.0f;
    for (int i = 0; i < kVisionNumClasses; i++) {
        float smoothed = 0.5f * (scores[i] + previousScores[i]);
        previousScores[i] = scores[i];
        if (kVisionIsAlert[i] && smoothed > bestScore) {
            bestScore = smoothed;
            best = i;
        }
    }

#if VISION_EVENTS_DEBUG
    Serial.print("[Vision IA]");
    for (int i = 0; i < kVisionNumClasses; i++) Serial.printf(" %s=%.2f", kVisionLabels[i], scores[i]);
    Serial.println();
#endif

    if (best < 0 || bestScore < kVisionAlertThreshold) return;
    uint32_t now = millis();
    if (lastEventMs[best] != 0 && now - lastEventMs[best] < VISION_EVENT_COOLDOWN_MS) return;
    lastEventMs[best] = now;

    int percent = (int)lroundf(bestScore * 100.0f);
    Serial.printf("[Vision IA] Aviso: %s (%d%%)\n", kVisionLabels[best], percent);
    if (onEvent) onEvent(kVisionLabels[best], percent);
}
}  // namespace

bool initVisionAI(VisionEventCallback callback, VisionEventCallback contextCallback) {
    onEvent = callback;
    onContext = contextCallback;

    const tflite::Model* model = tflite::GetModel(g_vision_model_data);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.println("[Vision IA] Version de schema del modelo incorrecta");
        return false;
    }

    // RAM interna (rapida); si no alcanza, PSRAM.
    uint8_t* arena = (uint8_t*)heap_caps_malloc(kVisionTensorArenaSize, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (arena == nullptr) arena = (uint8_t*)heap_caps_malloc(kVisionTensorArenaSize, MALLOC_CAP_SPIRAM);
    if (arena == nullptr) {
        Serial.println("[Vision IA] Sin memoria para el tensor arena");
        return false;
    }

    static tflite::MicroErrorReporter errorReporter;
    static tflite::AllOpsResolver resolver;
    static tflite::MicroInterpreter staticInterpreter(model, resolver, arena, kVisionTensorArenaSize, &errorReporter);
    interpreter = &staticInterpreter;

    if (interpreter->AllocateTensors() != kTfLiteOk) {
        Serial.printf("[Vision IA] AllocateTensors fallo: sube kVisionTensorArenaSize (%d)\n", kVisionTensorArenaSize);
        interpreter = nullptr;
        return false;
    }

    input = interpreter->input(0);
    output = interpreter->output(0);
    if (input->type != kTfLiteInt8 || input->bytes != (size_t)(kVisionImageSize * kVisionImageSize) ||
        output->type != kTfLiteInt8 || output->dims->data[output->dims->size - 1] != kVisionNumClasses) {
        Serial.println("[Vision IA] El modelo no calza con la camara 96x96: vuelve a correr export_model.py");
        interpreter = nullptr;
        return false;
    }

    for (int p = 0; p < 256; p++) {
        float value = p * kVisionPixelScale + kVisionPixelOffset;
        long q = lroundf(value / input->params.scale) + input->params.zero_point;
        pixelToInput[p] = (int8_t)(q < -128 ? -128 : q > 127 ? 127 : q);
    }

    Serial.printf("[Vision IA] Listo: %d clases, arena %u/%d bytes\n", kVisionNumClasses,
                  (unsigned)interpreter->arena_used_bytes(), kVisionTensorArenaSize);
    return true;
}

void runVisionInference(const uint8_t* image_data, size_t len) {
    if (interpreter == nullptr) return;

    // El modelo espera exactamente 96x96x1 bytes; otro tamano indica una camara mal configurada.
    if (len != input->bytes) {
        Serial.printf("[Vision IA] Tamano de imagen inesperado: %u (se esperaban %u)\n", (unsigned)len,
                      (unsigned)input->bytes);
        return;
    }

    for (size_t i = 0; i < len; i++) input->data.int8[i] = pixelToInput[image_data[i]];

    if (interpreter->Invoke() != kTfLiteOk) {
        Serial.println("[Vision IA] Error en Invoke()");
        return;
    }

    float scores[kVisionNumClasses];
    const float scale = output->params.scale;
    const int zeroPoint = output->params.zero_point;
    for (int i = 0; i < kVisionNumClasses; i++) scores[i] = (output->data.int8[i] - zeroPoint) * scale;
    handleScores(scores);
}

void resetVisionSmoothing() {
    for (int i = 0; i < kVisionNumClasses; i++) previousScores[i] = 0.0f;
}
