#include "tflite_inference.h"
#include <TensorFlowLite_ESP32.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "model_data.h"

namespace {
    const tflite::Model* model = nullptr;
    tflite::MicroInterpreter* interpreter = nullptr;
    tflite::ErrorReporter* error_reporter = nullptr;
    TfLiteTensor* input = nullptr;
    TfLiteTensor* output = nullptr;

    constexpr int kTensorArenaSize = 15 * 1024;
    uint8_t tensor_arena[kTensorArenaSize];
}

void initEdgeAI() {
    Serial.println("[Edge AI] Inicializando TensorFlow Lite...");
    
    static tflite::MicroErrorReporter micro_error_reporter;
    error_reporter = &micro_error_reporter;

    model = tflite::GetModel(g_model_data);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.println("Error: Schema version de modelo incorrecta!");
        return;
    }

    static tflite::AllOpsResolver resolver;
    static tflite::MicroInterpreter static_interpreter(model, resolver, tensor_arena, kTensorArenaSize, error_reporter);
    interpreter = &static_interpreter;

    TfLiteStatus allocate_status = interpreter->AllocateTensors();
    if (allocate_status != kTfLiteOk) {
        Serial.println("Error: AllocateTensors() falló");
        return;
    }

    input = interpreter->input(0);
    output = interpreter->output(0);
    
    Serial.println("[Edge AI] TFLite listo para inferencia local.");
}

void runInference(double* fft_features, size_t num_features) {
    if (!interpreter) return;
    
    int input_dim = input->dims->data[1]; 
    
    for (int i = 0; i < input_dim && i < num_features; i++) {
        input->data.f[i] = (float)fft_features[i] / 500000.0f; 
    }

    if (interpreter->Invoke() != kTfLiteOk) {
        Serial.println("Error en Invoke()");
        return;
    }

    float score_silence = output->data.f[0];
    float score_voice = output->data.f[1];
    float score_loud = output->data.f[2];
    
    // Imprimir lo que realmente está pensando la IA (MUTEADO)
    // Serial.printf("   -> IA Scores | Silencio: %.2f | Voz: %.2f | Ruido Fuerte: %.2f\n", score_silence, score_voice, score_loud);

    if (score_loud > 0.5) {
        // Serial.println("🤖 [Edge AI PREDICCIÓN]: ¡Ruido Fuerte / Alarma!");
    } else if (score_voice > 0.5) {
        // Serial.println("🤖 [Edge AI PREDICCIÓN]: Voz / Conversación");
    } else {
        // Serial.println("🤖 [Edge AI PREDICCIÓN]: Silencio / Indeterminado");
    }
}