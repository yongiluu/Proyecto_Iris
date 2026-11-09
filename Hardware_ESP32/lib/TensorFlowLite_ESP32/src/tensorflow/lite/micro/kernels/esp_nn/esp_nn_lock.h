// IRIS: ESP-NN guarda el buffer de trabajo de conv / depthwise / softmax en una variable GLOBAL
// (esp_nn_set_*_scratch_buf) y la lee durante toda la operacion. Con varios interpretes corriendo en
// tareas distintas (vision, audio, escenas, lector de texto) una tarea le cambiaba el buffer a la otra a
// mitad de una capa: resultados basura o escritura fuera del arena. Este candado deja pasar una sola
// operacion ESP-NN a la vez (dura milisegundos). En el PC (pruebas) no hace nada.
#ifndef IRIS_ESP_NN_LOCK_H_
#define IRIS_ESP_NN_LOCK_H_

#if defined(ESP_PLATFORM)
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

namespace tflite {
class EspNnScratchLock {
 public:
  EspNnScratchLock() { xSemaphoreTake(Mutex(), portMAX_DELAY); }
  ~EspNnScratchLock() { xSemaphoreGive(Mutex()); }

 private:
  // Se crea en la primera inferencia (los autotests de setup(), con una sola tarea).
  static SemaphoreHandle_t Mutex() {
    static SemaphoreHandle_t mutex = xSemaphoreCreateMutex();
    return mutex;
  }
};
}  // namespace tflite
#else
namespace tflite {
class EspNnScratchLock {
 public:
  EspNnScratchLock() {}
  ~EspNnScratchLock() {}
};
}  // namespace tflite
#endif

#endif  // IRIS_ESP_NN_LOCK_H_
