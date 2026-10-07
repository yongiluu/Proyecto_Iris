#include "tflite_vision.h"
#include <TensorFlowLite_ESP32.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "person_detect_model_data.h"

namespace {
    const tflite::Model* vision_model = nullptr;
    tflite::MicroInterpreter* vision_interpreter = nullptr;
    tflite::ErrorReporter* vision_error_reporter = nullptr;
    TfLiteTensor* vision_input = nullptr;
    TfLiteTensor* vision_output = nullptr;

    constexpr int kVisionTensorArenaSize = 136 * 1024; // 136KB for MobileNet Vision
    uint8_t vision_tensor_arena[kVisionTensorArenaSize];
}

void initVisionAI() {
    Serial.println("[Edge AI Visión] Inicializando TensorFlow Lite para Imágenes...");
    
    static tflite::MicroErrorReporter micro_error_reporter;
    vision_error_reporter = &micro_error_reporter;

    vision_model = tflite::GetModel(g_person_detect_model_data);
    if (vision_model->version() != TFLITE_SCHEMA_VERSION) {
        Serial.println("[Edge AI Visión] Error: Schema version incorrecta.");
        return;
    }

    static tflite::AllOpsResolver vision_resolver;
    static tflite::MicroInterpreter static_interpreter(
        vision_model, vision_resolver, vision_tensor_arena, kVisionTensorArenaSize, vision_error_reporter);
    vision_interpreter = &static_interpreter;

    TfLiteStatus allocate_status = vision_interpreter->AllocateTensors();
    if (allocate_status != kTfLiteOk) {
        Serial.println("[Edge AI Visión] Error: AllocateTensors() falló.");
        return;
    }

    vision_input = vision_interpreter->input(0);
    vision_output = vision_interpreter->output(0);
    
    Serial.println("[Edge AI Visión] Modelo de Detección de Personas Cargado.");
}

void runVisionInference(uint8_t* image_data, size_t len) {
    if (!vision_interpreter) return;
    
    // El input del modelo person_detection es INT8, 96x96x1
    for (int i = 0; i < len && i < vision_input->bytes; i++) {
        // El modelo de TensorFlow espera los pixeles normalizados y convertidos a int8 (-128 a 127)
        vision_input->data.int8[i] = image_data[i] - 128;
    }

    if (vision_interpreter->Invoke() != kTfLiteOk) {
        Serial.println("[Edge AI Visión] Error en Invoke().");
        return;
    }

    // El output es un arreglo de 2 elementos [No Persona, Persona] en formato INT8
    int8_t person_score = vision_output->data.int8[1];
    int8_t no_person_score = vision_output->data.int8[0];
    
    // Convertir de INT8 (-128 a 127) a un porcentaje (0 a 100)
    int person_percent = (person_score + 128) * 100 / 255;
    
    Serial.printf("   -> IA Visión | Probabilidad de Persona: %d%%\n", person_percent);
    
    if (person_percent > 70) {
        Serial.println("👁️ [Edge AI PREDICCIÓN]: ¡PERSONA DETECTADA al frente!");
    }
}