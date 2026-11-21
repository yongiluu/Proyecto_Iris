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
#include "tflm_model_check.h"

namespace {
constexpr size_t kMaxTextBytes = 400;  // cabe en una notificacion BLE (MTU 512)

TaskHandle_t ocrTask = nullptr;
OcrResultCallback onResult = nullptr;

tflite::MicroInterpreter* detector = nullptr;
tflite::MicroInterpreter* reader = nullptr;

uint8_t* vgaFrame = nullptr;      // 640x480 en PSRAM (copia: la camara se libera enseguida)
uint8_t* detInput = nullptr;      // 320x240
uint8_t* pieces = nullptr;        // hasta kOcrMaxPieces lineas de 32x256

// inputBytes / outputBytes: lo que este firmware va a escribir y leer en los tensores. Los modelos llegan
// por WiFi y se entrenan aparte: si no calzan (otro tamano, salida en float), el lector queda apagado
// en vez de escribir fuera del arena.
uint8_t* detectorArena = nullptr;
uint8_t* readerArena = nullptr;

bool setupInterpreter(const char* storeName, tflite::MicroInterpreter** out, uint8_t** outArena,
                      const char* name, size_t inputBytes, size_t outputBytes) {
  const ModelEntry* entry = modelStoreGet(storeName);
  if (entry == nullptr) {
    Serial.printf("[Lector] %s: falta el modelo \"%s\" en la particion de modelos\n", name, storeName);
    return false;
  }
  const int declaredArena = (int)entry->arenaBytes;
  // Llega por WiFi: se revisa la estructura (y la version del schema) antes de usarlo.
  const tflite::Model* model = tflmCheckedModel(entry->data, entry->size);
  if (model == nullptr) {
    Serial.printf("[Lector] %s: el modelo esta danado o no es un .tflite valido\n", name);
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
  // Desde aqui lo reservado queda a cargo de freeOcrResources() si algo falla.
  *out = interpreter;
  *outArena = arena;
  if (interpreter->AllocateTensors() != kTfLiteOk) {
    Serial.printf("[Lector] %s: AllocateTensors fallo con %u bytes\n", name, (unsigned)arenaBytes);
    return false;
  }
  const TfLiteTensor* input = interpreter->input(0);
  const TfLiteTensor* output = interpreter->output(0);
  if (!tflmInt8TensorFits(input, inputBytes) || !tflmInt8TensorFits(output, outputBytes) ||
      !tflmScaleOk(input) || !tflmScaleOk(output)) {
    Serial.printf("[Lector] %s: el modelo no calza con este firmware (entrada %u, salida %u bytes; se esperaban "
                  "%u y %u int8 con escala valida): exportar de nuevo y subir firmware y modelos juntos\n",
                  name, (unsigned)input->bytes, (unsigned)output->bytes, (unsigned)inputBytes, (unsigned)outputBytes);
    return false;
  }
  Serial.printf("[Lector] %s listo, arena %u/%u bytes\n", name, (unsigned)interpreter->arena_used_bytes(),
                (unsigned)arenaBytes);
  return true;
}

// Si el arranque falla a mitad, se devuelve todo lo reservado (la PSRAM la usan la camara y el audio).
void freeOcrResources() {
  delete detector;
  detector = nullptr;
  delete reader;
  reader = nullptr;
  uint8_t** buffers[] = {&detectorArena, &readerArena, &vgaFrame, &detInput, &pieces};
  for (uint8_t** buffer : buffers) {
    if (*buffer != nullptr) heap_caps_free(*buffer);
    *buffer = nullptr;
  }
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
  out[0] = '\0';  // si Invoke falla, que no quede el texto del trozo anterior
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
  // Un trozo: hasta 64 columnas x 2 bytes (letras con tilde). Una linea: hasta kOcrMaxPieces trozos.
  // (Con 128 y 96 bytes, el final de una linea larga se perdia.) Estaticos: no gastan la pila de la tarea.
  static char pieceText[kOcrTimeSteps * 2 + 1];
  static char lineText[kOcrMaxPieces * kOcrTimeSteps * 2 + 1];
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
    // Los pesos estan en la flash (particion "modelos"): mientras corre, la subida de modelos espera.
    if (!modelStoreBeginUse()) {
      text[0] = '\0';  // se estan subiendo modelos nuevos: no tocar la particion
    } else {
      readText(text);
      modelStoreEndUse();
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
    freeOcrResources();
    return false;
  }
  if (!setupInterpreter(kOcrDetectorModelName, &detector, &detectorArena, "detector",
                        (size_t)kOcrDetWidth * kOcrDetHeight, (size_t)kOcrMapWidth * kOcrMapHeight) ||
      !setupInterpreter(kOcrReaderModelName, &reader, &readerArena, "lector",
                        (size_t)kOcrLineHeight * kOcrLineWidth, (size_t)kOcrTimeSteps * kOcrNumClasses)) {
    freeOcrResources();
    return false;
  }
  // Nucleo 0, prioridad baja: tarda ~1-3 s y no debe cortar el audio ni el Bluetooth.
  if (xTaskCreatePinnedToCore(ocrLoop, "ocr", 8192, nullptr, 1, &ocrTask, 0) != pdPASS) {
    ocrTask = nullptr;
    freeOcrResources();
    return false;
  }
  return true;
}

void requestReadText() {
  if (ocrTask != nullptr) xTaskNotifyGive(ocrTask);
}

#endif  // IRIS_OCR
