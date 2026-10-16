// Corre un modelo .tflite int8 con la libreria TFLM del firmware (lib/TensorFlowLite_ESP32), en el PC.
// Uso: tflm_host modelo.tflite entradas.bin salidas.bin
// entradas.bin = N ejemplos int8 seguidos (tamano del tensor de entrada); salidas.bin = N salidas int8.
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_profiler.h"
#include "tensorflow/lite/schema/schema_generated.h"

// Con TFLM_TRACE=1 imprime cada operacion antes de ejecutarla (para ubicar un fallo).
class TraceProfiler : public tflite::MicroProfiler {
 public:
  uint32_t BeginEvent(const char* tag) override {
    std::fprintf(stderr, "  op %u: %s\n", count_, tag);
    std::fflush(stderr);
    return count_++;
  }
  void EndEvent(uint32_t) override {}

 private:
  uint32_t count_ = 0;
  TF_LITE_REMOVE_VIRTUAL_DELETE
};

static std::vector<unsigned char> readFile(const char* path) {
  FILE* f = std::fopen(path, "rb");
  if (!f) { std::fprintf(stderr, "No se pudo abrir %s\n", path); std::exit(1); }
  std::fseek(f, 0, SEEK_END);
  long size = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  std::vector<unsigned char> data(size);
  if (std::fread(data.data(), 1, size, f) != (size_t)size) std::exit(1);
  std::fclose(f);
  return data;
}

int main(int argc, char** argv) {
  if (argc != 4) return 2;
  std::vector<unsigned char> modelBytes = readFile(argv[1]);
  std::vector<unsigned char> inputs = readFile(argv[2]);

  std::fprintf(stderr, "[1] modelo %zu bytes\n", modelBytes.size());
  const tflite::Model* model = tflite::GetModel(modelBytes.data());
  static tflite::MicroErrorReporter reporter;
  static tflite::AllOpsResolver resolver;
  static std::vector<uint8_t> arena(512 * 1024);
  static TraceProfiler tracer;
  const bool trace = std::getenv("TFLM_TRACE") != nullptr;
  tflite::MicroInterpreter interpreter(model, resolver, arena.data(), arena.size(), &reporter, nullptr,
                                       trace ? &tracer : nullptr);
  std::fprintf(stderr, "[2] interprete creado\n");
  if (interpreter.AllocateTensors() != kTfLiteOk) { std::fprintf(stderr, "AllocateTensors fallo\n"); return 1; }

  TfLiteTensor* input = interpreter.input(0);
  TfLiteTensor* output = interpreter.output(0);
  std::fprintf(stderr, "[3] tensores listos, entrada %zu bytes\n", input->bytes);
  const size_t count = inputs.size() / input->bytes;
  FILE* out = std::fopen(argv[3], "wb");
  for (size_t i = 0; i < count; i++) {
    std::copy(inputs.begin() + i * input->bytes, inputs.begin() + (i + 1) * input->bytes, input->data.int8);
    if (interpreter.Invoke() != kTfLiteOk) { std::fprintf(stderr, "Invoke fallo\n"); return 1; }
    std::fwrite(output->data.int8, 1, output->bytes, out);
  }
  std::fclose(out);
  std::printf("%zu ejemplos, arena usada %zu bytes\n", count, interpreter.arena_used_bytes());
  return 0;
}
