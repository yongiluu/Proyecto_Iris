// Solo en las placas con el lector de texto (IRIS_OCR en platformio.ini). Los modelos estan en la
// particion "modelos" (model_store.h): sin ellos el lector no arranca y la app lee con el celular.
#ifdef IRIS_OCR

#include "ocr_task.h"

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
#include "model_store.h"
#include "ocr_config.h"
#include "ocr_pipeline.h"
#include "tflm_arena.h"

namespace {
constexpr size_t kMaxTextBytes = 400;  // cabe en una notificacion BLE (MTU 512)

TaskHandle_t ocrTask = nullptr;
OcrResultCallback onResult = nullptr;

tflite::MicroInterpreter* detector = nullptr;
tflite::MicroInterpreter* reader = nullptr;

uint8_t* vgaFrame = nullptr;      // 640x480 en PSRAM (copia: la camara se libera enseguida)
uint8_t* detInput = nullptr;      // 320x240
uint8_t* pieces = nullptr;        // hasta kOcrMaxPieces lineas de 32x256

bool setupInterpreter(const char* storeName, tflite::MicroInterpreter** out, const char* name) {
  const ModelEntry* entry = modelStoreGet(storeName);
  if (entry == nullptr) {
    Serial.printf("[Lector] %s: falta el modelo \"%s\" en la particion de modelos\n", name, storeName);
    return false;
  }
  const int declaredArena = (int)entry->arenaBytes;
  const tflite::Model* model = tflite::GetModel(entry->data);
  if (model->version() != TFLITE_SCHEMA_VERSION) {
    Serial.printf("[Lector] %s: version de schema incorrecta\n", name);
    return false;
  }
  const size_t arenaBytes = tflmArenaBytes(declaredArena);
  uint8_t* arena = allocTflmArena(arenaBytes);
  if (arena == nullptr) {
    Serial.printf("[Lector] %s: sin memoria para el arena (%u bytes)\n", name, (unsigned)arenaBytes);
    return false;
  }
  static tflite::MicroErrorReporter errorReporter;
  static tflite::AllOpsResolver resolver;
  // new (y no static): son dos interpretes con el mismo tipo; viven toda la ejecucion.
  auto* interpreter = new tflite::MicroInterpreter(model, resolver, arena, arenaBytes, &errorReporter);
  if (interpreter->AllocateTensors() != kTfLiteOk) {
    Serial.printf("[Lector] %s: AllocateTensors fallo con %u bytes\n", name, (unsigned)arenaBytes);
    return false;
  }
  Serial.printf("[Lector] %s listo, arena %u/%u bytes\n", name, (unsigned)interpreter->arena_used_bytes(),
                (unsigned)arenaBytes);
  *out = interpreter;
  return true;
}

// Pixel 0-255 -> int8 con la cuantizacion de la entrada del modelo.
void quantize(const uint8_t* pixels, size_t count, TfLiteTensor* input) {
  const float scale = input->params.scale;
  const int zero = input->params.zero_point;
  for (size_t i = 0; i < count; i++) {
    long q = lroundf(pixels[i] / scale) + zero;
    input->data.int8[i] = (int8_t)(q < -128 ? -128 : q > 127 ? 127 : q);
  }
}

// Lee una linea de 32x256: indice mas probable por columna -> texto.
size_t readLine(const uint8_t* line, char* out, size_t outSize) {
  TfLiteTensor* input = reader->input(0);
  quantize(line, kOcrLineHeight * kOcrLineWidth, input);
  if (reader->Invoke() != kTfLiteOk) return 0;
  const TfLiteTensor* output = reader->output(0);
  uint8_t best[kOcrTimeSteps];
  for (int t = 0; t < kOcrTimeSteps; t++) {
    const int8_t* row = output->data.int8 + t * kOcrNumClasses;
    int index = 0;
    for (int c = 1; c < kOcrNumClasses; c++) {
      if (row[c] > row[index]) index = c;  // la escala es la misma en toda la fila: basta comparar int8
    }
    best[t] = (uint8_t)index;
  }
  return ocrCtcDecode(best, out, outSize);
}

void appendText(char* text, size_t* length, const char* piece, const char* separator) {
  const size_t pieceLength = strlen(piece);
  if (pieceLength == 0) return;
  const size_t sepLength = *length ? strlen(separator) : 0;
  if (*length + sepLength + pieceLength + 1 > kMaxTextBytes) return;
  if (sepLength) memcpy(text + *length, separator, sepLength);
  memcpy(text + *length + sepLength, piece, pieceLength);
  *length += sepLength + pieceLength;
  text[*length] = '\0';
}

void readText(char* text) {
  text[0] = '\0';
  size_t length = 0;
  const uint32_t started = millis();

  camera_fb_t* frame = acquireGrayVgaFrame();
  if (frame == nullptr || frame->len < (size_t)(kOcrVgaWidth * kOcrVgaHeight)) {
    if (frame) releaseGrayVgaFrame(frame);
    Serial.println("[Lector] No se pudo sacar la foto");
    return;
  }
  memcpy(vgaFrame, frame->buf, kOcrVgaWidth * kOcrVgaHeight);
  releaseGrayVgaFrame(frame);  // la camara vuelve a color para los demas modelos

  // 1. Donde hay texto
  ocrDownsample2x(vgaFrame, detInput);
  quantize(detInput, kOcrDetWidth * kOcrDetHeight, detector->input(0));
  if (detector->Invoke() != kTfLiteOk) return;
  const TfLiteTensor* map = detector->output(0);
  uint8_t textMap[kOcrMapWidth * kOcrMapHeight];
  for (int i = 0; i < kOcrMapWidth * kOcrMapHeight; i++) {
    const float probability = (map->data.int8[i] - map->params.zero_point) * map->params.scale;
    textMap[i] = (uint8_t)(probability <= 0 ? 0 : probability >= 1 ? 255 : lroundf(probability * 255));
  }
  OcrBox boxes[kOcrMaxLines];
  const int lines = ocrFindLines(textMap, kOcrDetectThreshold, boxes, kOcrMaxLines);

  // 2. Leer cada linea (de arriba a abajo)
  char lineText[128], pieceText[96];
  for (int i = 0; i < lines; i++) {
    const int count = ocrCropLine(vgaFrame, ocrLinePixels(boxes[i]), pieces);
    lineText[0] = '\0';
    size_t lineLength = 0;
    for (int p = 0; p < count; p++) {
      readLine(pieces + p * kOcrLineHeight * kOcrLineWidth, pieceText, sizeof(pieceText));
      const size_t n = strlen(pieceText);
      if (lineLength + n + 1 < sizeof(lineText)) {
        memcpy(lineText + lineLength, pieceText, n + 1);
        lineLength += n;
      }
    }
    appendText(text, &length, lineText, ". ");
  }
  Serial.printf("[Lector] %d lineas en %u ms: \"%s\"\n", lines, (unsigned)(millis() - started), text);
}

void ocrLoop(void*) {
  static char text[kMaxTextBytes];
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    if (modelStoreWriting()) {
      text[0] = '\0';  // se estan subiendo modelos nuevos: no tocar la particion
    } else {
      readText(text);
    }
    if (onResult) onResult(text);
  }
}
}  // namespace

bool startOcrTask(OcrResultCallback callback) {
  onResult = callback;
  vgaFrame = (uint8_t*)heap_caps_malloc(kOcrVgaWidth * kOcrVgaHeight, MALLOC_CAP_SPIRAM);
  detInput = (uint8_t*)heap_caps_malloc(kOcrDetWidth * kOcrDetHeight, MALLOC_CAP_SPIRAM);
  pieces = (uint8_t*)heap_caps_malloc(kOcrMaxPieces * kOcrLineHeight * kOcrLineWidth, MALLOC_CAP_SPIRAM);
  if (!vgaFrame || !detInput || !pieces) {
    Serial.println("[Lector] Sin PSRAM para los buffers");
    return false;
  }
  if (!setupInterpreter(kOcrDetectorModelName, &detector, "detector") ||
      !setupInterpreter(kOcrReaderModelName, &reader, "lector")) {
    return false;
  }
  // Nucleo 0, prioridad baja: tarda ~1-3 s y no debe cortar el audio ni el Bluetooth.
  return xTaskCreatePinnedToCore(ocrLoop, "ocr", 8192, nullptr, 1, &ocrTask, 0) == pdPASS;
}

void requestReadText() {
  if (ocrTask != nullptr) xTaskNotifyGive(ocrTask);
}

#endif  // IRIS_OCR
