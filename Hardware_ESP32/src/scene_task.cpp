#include "scene_task.h"

#include <Arduino.h>
#include <TensorFlowLite_ESP32.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <math.h>
#include <string.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"

#include "camera_driver.h"
#include "image_convert.h"
#include "model_store.h"
#include "scene_describe.h"
#include "scene_vocab.h"
#include "tflm_arena.h"

namespace {
constexpr const char* kModelName = "escena";
// Bandera del paquete de modelos (pack_models.register(..., flags)): el alumno aprendio peligros.
// Sin ella la frase no dice nada de peligros (ni "no detecto peligros").
constexpr uint32_t kSceneFlagHazardsTrained = 1;
constexpr int kInputWidth = 160, kInputHeight = 120;
constexpr size_t kMaxSentenceBytes = 400;  // cabe en una notificacion BLE (MTU 512)

TaskHandle_t sceneTask = nullptr;
SceneResultCallback onResult = nullptr;
tflite::MicroInterpreter* interpreter = nullptr;
bool hazardsTrained = false;
uint8_t* rgb = nullptr;  // 160x120x3 en PSRAM

// Cabezas del modelo. Se buscan por NOMBRE en la firma del .tflite (posicion y distancia tienen la
// misma forma 43x3: por orden se podrian confundir).
enum Head { kPresence, kPosition, kDistance, kColor, kHazards, kPeople, kPlace, kQuality, kNumHeads };
const char* const kHeadNames[kNumHeads] = {"presence", "position", "distance", "color",
                                           "hazards",  "people",   "place",    "quality"};
const int kHeadSizes[kNumHeads] = {kSceneNumObjects,
                                   kSceneNumObjects * kSceneNumPositions,
                                   kSceneNumObjects * kSceneNumDistances,
                                   kSceneNumObjects * kSceneNumColors,
                                   kSceneNumHazards,
                                   kSceneNumPeople,
                                   kSceneNumPlaces,
                                   kSceneNumQuality};
int headOutput[kNumHeads];  // indice de salida del interprete para cada cabeza
float* headValues[kNumHeads];

// Indice de salida (0..n-1) de cada cabeza segun la firma "serving_default" del modelo.
bool mapHeads(const tflite::Model* model) {
  const auto* signatures = model->signature_defs();
  if (signatures == nullptr || signatures->size() == 0) {
    Serial.println("[Escena] El modelo no trae firma con nombres de salida");
    return false;
  }
  const auto* outputs = signatures->Get(0)->outputs();
  const auto* subgraphOutputs = model->subgraphs()->Get(0)->outputs();
  for (int h = 0; h < kNumHeads; h++) {
    headOutput[h] = -1;
    for (size_t i = 0; outputs && i < outputs->size(); i++) {
      const auto* map = outputs->Get(i);
      if (map->name() == nullptr || strcmp(map->name()->c_str(), kHeadNames[h]) != 0) continue;
      for (size_t k = 0; k < subgraphOutputs->size(); k++) {
        if ((uint32_t)subgraphOutputs->Get(k) == map->tensor_index()) headOutput[h] = (int)k;
      }
    }
    if (headOutput[h] < 0) {
      Serial.printf("[Escena] Falta la salida \"%s\" en el modelo\n", kHeadNames[h]);
      return false;
    }
  }
  return true;
}

bool setupModel() {
  const ModelEntry* entry = modelStoreGet(kModelName);
  if (entry == nullptr) return false;
  const tflite::Model* model = tflite::GetModel(entry->data);
  if (model->version() != TFLITE_SCHEMA_VERSION || !mapHeads(model)) return false;
  hazardsTrained = (entry->flags & kSceneFlagHazardsTrained) != 0;

  const size_t arenaBytes = tflmArenaBytes((int)entry->arenaBytes);
  uint8_t* arena = allocTflmArena(arenaBytes);
  if (arena == nullptr) {
    Serial.printf("[Escena] Sin memoria para el arena (%u bytes)\n", (unsigned)arenaBytes);
    return false;
  }
  static tflite::MicroErrorReporter errorReporter;
  static tflite::AllOpsResolver resolver;
  interpreter = new tflite::MicroInterpreter(model, resolver, arena, arenaBytes, &errorReporter);
  if (interpreter->AllocateTensors() != kTfLiteOk) {
    Serial.printf("[Escena] AllocateTensors fallo con %u bytes\n", (unsigned)arenaBytes);
    return false;
  }
  const TfLiteTensor* input = interpreter->input(0);
  if (input->type != kTfLiteInt8 || input->bytes != (size_t)kInputWidth * kInputHeight * 3) {
    Serial.println("[Escena] La entrada del modelo no es 160x120x3 int8");
    return false;
  }
  for (int h = 0; h < kNumHeads; h++) {
    const TfLiteTensor* out = interpreter->output(headOutput[h]);
    if (out->type != kTfLiteInt8 || out->bytes != (size_t)kHeadSizes[h]) {
      Serial.printf("[Escena] La salida \"%s\" no tiene el tamano esperado\n", kHeadNames[h]);
      return false;
    }
    headValues[h] = (float*)heap_caps_malloc(kHeadSizes[h] * sizeof(float), MALLOC_CAP_SPIRAM);
    if (headValues[h] == nullptr) return false;
  }
  Serial.printf("[Escena] Lista, arena %u/%u bytes, peligros %s\n", (unsigned)interpreter->arena_used_bytes(),
                (unsigned)arenaBytes, hazardsTrained ? "entrenados" : "sin entrenar (no se mencionan)");
  return true;
}

void describe(char* sentence) {
  sentence[0] = '\0';
  const uint32_t started = millis();
  camera_fb_t* frame = acquireColorFrame();
  if (frame == nullptr) {
    Serial.println("[Escena] No se pudo sacar la foto");
    return;
  }
  const bool ok = frame->format == PIXFORMAT_RGB565 && frame->width == kInputWidth &&
                  frame->height == kInputHeight && frame->len >= (size_t)kInputWidth * kInputHeight * 2;
  if (ok) rgb565ToRgb888(frame->buf, (size_t)kInputWidth * kInputHeight, rgb);
  releaseColorFrame(frame);
  if (!ok) {
    Serial.println("[Escena] El frame no es 160x120 a color");
    return;
  }

  TfLiteTensor* input = interpreter->input(0);
  const float scale = input->params.scale;
  const int zero = input->params.zero_point;
  for (size_t i = 0; i < (size_t)kInputWidth * kInputHeight * 3; i++) {
    const long q = lroundf(rgb[i] / scale) + zero;
    input->data.int8[i] = (int8_t)(q < -128 ? -128 : q > 127 ? 127 : q);
  }
  if (interpreter->Invoke() != kTfLiteOk) {
    Serial.println("[Escena] Invoke fallo");
    return;
  }
  for (int h = 0; h < kNumHeads; h++) {
    const TfLiteTensor* out = interpreter->output(headOutput[h]);
    for (int i = 0; i < kHeadSizes[h]; i++) {
      headValues[h][i] = (out->data.int8[i] - out->params.zero_point) * out->params.scale;
    }
  }
  ScenePrediction prediction{headValues[kPresence], headValues[kPosition], headValues[kDistance],
                             headValues[kColor],    headValues[kHazards],  headValues[kPeople],
                             headValues[kPlace],    headValues[kQuality],  hazardsTrained};
  describeScene(prediction, sentence, kMaxSentenceBytes);
  Serial.printf("[Escena] %u ms: %s\n", (unsigned)(millis() - started), sentence);
}

void sceneLoop(void*) {
  static char sentence[kMaxSentenceBytes];
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    if (modelStoreWriting()) {
      sentence[0] = '\0';  // se estan subiendo modelos nuevos: no tocar la particion
    } else {
      describe(sentence);
    }
    if (onResult) onResult(sentence);
  }
}
}  // namespace

bool startSceneTask(SceneResultCallback callback) {
  onResult = callback;
  rgb = (uint8_t*)heap_caps_malloc((size_t)kInputWidth * kInputHeight * 3, MALLOC_CAP_SPIRAM);
  if (rgb == nullptr || !setupModel()) return false;
  // Nucleo 0, prioridad baja: tarda ~1 s y no debe cortar el audio ni el Bluetooth.
  return xTaskCreatePinnedToCore(sceneLoop, "escena", 8192, nullptr, 1, &sceneTask, 0) == pdPASS;
}

void requestDescribeScene() {
  if (sceneTask != nullptr) xTaskNotifyGive(sceneTask);
}
