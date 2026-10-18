#include "proximity.h"

#include <TensorFlowLite_ESP32.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <math.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"

#include "config.h"
#include "proximity_model_data.h"

namespace {
tflite::MicroInterpreter* interpreter = nullptr;
TfLiteTensor* input = nullptr;
TfLiteTensor* output = nullptr;
ProximityCallback onChange = nullptr;

float previousScores[kProximityNumClasses] = {};
int currentLevel = 0;

void runSelfTest() {
    for (int i = 0; i < 96 * 96; i++) input->data.int8[i] = kProximityInputLut[kProximitySelfTestImage[i]];
    const int64_t start = esp_timer_get_time();
    const bool invoked = interpreter->Invoke() == kTfLiteOk;
    const int64_t elapsedUs = esp_timer_get_time() - start;

    int maxDiff = 0, best = 0, expectedBest = 0;
    for (int i = 0; i < kProximityNumClasses; i++) {
        int diff = abs(output->data.int8[i] - kProximitySelfTestExpected[i]);
        if (diff > maxDiff) maxDiff = diff;
        if (output->data.int8[i] > output->data.int8[best]) best = i;
        if (kProximitySelfTestExpected[i] > kProximitySelfTestExpected[expectedBest]) expectedBest = i;
    }
    const bool ok = invoked && best == expectedBest && maxDiff <= 8;
    Serial.printf("[Cercania IA] Autotest %s: %.0f ms por imagen, clase %s, max dif %d\n",
                  ok ? "OK" : "FALLO", elapsedUs / 1000.0, kProximityLabels[best], maxDiff);
}
}  // namespace

bool initProximityAI(ProximityCallback callback) {
    onChange = callback;
    const tflite::Model* model = tflite::GetModel(g_proximity_model_data);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.println("[Cercania IA] Version de schema del modelo incorrecta");
        return false;
    }
    uint8_t* arena = (uint8_t*)heap_caps_malloc(kProximityTensorArenaSize, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (arena == nullptr) arena = (uint8_t*)heap_caps_malloc(kProximityTensorArenaSize, MALLOC_CAP_SPIRAM);
    if (arena == nullptr) {
        Serial.println("[Cercania IA] Sin memoria para el tensor arena");
        return false;
    }

    static tflite::MicroErrorReporter errorReporter;
    static tflite::AllOpsResolver resolver;
    static tflite::MicroInterpreter staticInterpreter(model, resolver, arena, kProximityTensorArenaSize, &errorReporter);
    interpreter = &staticInterpreter;
    if (interpreter->AllocateTensors() != kTfLiteOk) {
        Serial.printf("[Cercania IA] AllocateTensors fallo: sube kProximityTensorArenaSize (%d)\n",
                      kProximityTensorArenaSize);
        interpreter = nullptr;
        return false;
    }
    input = interpreter->input(0);
    output = interpreter->output(0);
    if (input->type != kTfLiteInt8 || input->bytes != 96 * 96 || output->type != kTfLiteInt8 ||
        output->dims->data[output->dims->size - 1] != kProximityNumClasses) {
        Serial.println("[Cercania IA] El modelo no calza con la camara 96x96: vuelve a correr proximity_export.py");
        interpreter = nullptr;
        return false;
    }
    runSelfTest();
    Serial.printf("[Cercania IA] Listo, arena %u/%d bytes\n", (unsigned)interpreter->arena_used_bytes(),
                  kProximityTensorArenaSize);
    return true;
}

void runProximityInference(const uint8_t* image_data, size_t len) {
    if (interpreter == nullptr || len != input->bytes) return;
    for (size_t i = 0; i < len; i++) input->data.int8[i] = kProximityInputLut[image_data[i]];
    if (interpreter->Invoke() != kTfLiteOk) return;

    // Promedio con el frame anterior: un frame suelto no dispara ni apaga los pitidos.
    float smoothed[kProximityNumClasses];
    const float scale = output->params.scale;
    const int zeroPoint = output->params.zero_point;
    for (int i = 0; i < kProximityNumClasses; i++) {
        float score = (output->data.int8[i] - zeroPoint) * scale;
        smoothed[i] = 0.5f * (score + previousScores[i]);
        previousScores[i] = score;
    }

    const float nearScore = smoothed[1] + smoothed[2];
    int level = 0;
    if (nearScore >= kProximityAlertThreshold) level = smoothed[2] > smoothed[1] ? 2 : 1;

#if VISION_EVENTS_DEBUG
    Serial.printf("[Cercania IA] libre=%.2f cerca=%.2f muy_cerca=%.2f -> %d\n", smoothed[0], smoothed[1], smoothed[2], level);
#endif
    if (level != currentLevel) {
        currentLevel = level;
        if (onChange) onChange(level, (int)lroundf(nearScore * 100.0f));
    }
}

void resetProximitySmoothing() {
    for (int i = 0; i < kProximityNumClasses; i++) previousScores[i] = 0.0f;
}
