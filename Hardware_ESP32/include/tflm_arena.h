#ifndef TFLM_ARENA_H
#define TFLM_ARENA_H

#include <esp_heap_caps.h>
#include <stddef.h>
#include <stdint.h>

// Tensor arena de cada modelo en la placa. Los kernels ESP-NN optimizados para el S3 piden buffers de
// trabajo que en el PC (tests/test_tflm_kernels.py, ESP-NN en C) no aparecen: en la XIAO la vision pidio
// ~330 KB con 170 KB declarados. Por eso se reserva el doble + 192 KB, y en PSRAM (8 MB en la XIAO):
// la RAM interna queda para Bluetooth, la camara y el microfono. Al arrancar se imprime el uso real.
// En ceros: el autotest de cercania variaba entre arranques (max dif 5 a 30), senal de memoria sin iniciar.
inline size_t tflmArenaBytes(int declaredBytes) {
    return (size_t)declaredBytes * 2 + 192 * 1024;
}

inline uint8_t* allocTflmArena(size_t bytes) {
    uint8_t* arena = (uint8_t*)heap_caps_calloc(1, bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (arena == nullptr) arena = (uint8_t*)heap_caps_calloc(1, bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    return arena;
}

#endif
