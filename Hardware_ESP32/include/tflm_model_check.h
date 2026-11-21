#ifndef TFLM_MODEL_CHECK_H
#define TFLM_MODEL_CHECK_H

#include <cmath>
#include <stddef.h>
#include <stdint.h>
#include "tensorflow/lite/c/common.h"
#include "tensorflow/lite/schema/schema_generated.h"

// En esta version de la libreria la constante vive en micro_interpreter.h: sin esto el encabezado solo
// compilaba si alguien lo incluia antes (fragil). Es la version 3 del schema de TFLite.
#ifndef TFLITE_SCHEMA_VERSION
#define TFLITE_SCHEMA_VERSION (3)
#endif

// Revisiones de un modelo .tflite ANTES de usarlo. Los de la particion "modelos" llegan por WiFi y se
// entrenan aparte: un paquete equivocado o a medio escribir no debe hacer que la placa lea fuera del
// modelo o divida por cero; la funcion queda apagada y la app usa la nube.

// La estructura del flatbuffer (tablas, vectores y offsets dentro de los size bytes), la version del
// schema y al menos un subgrafo. Devuelve el modelo o nullptr.
inline const tflite::Model* tflmCheckedModel(const uint8_t* data, size_t size) {
    if (data == nullptr || size == 0) return nullptr;
    // Sin revisar alineacion: los paquetes alinean a 16 y un falso negativo apagaria un modelo que sirve.
    flatbuffers::Verifier verifier(data, size, /*max_depth=*/64, /*max_tables=*/1000000,
                                   /*check_alignment=*/false);
    if (!tflite::VerifyModelBuffer(verifier)) return nullptr;
    const tflite::Model* model = tflite::GetModel(data);
    if (model->version() != TFLITE_SCHEMA_VERSION) return nullptr;
    if (model->subgraphs() == nullptr || model->subgraphs()->size() < 1) return nullptr;
    return model;
}

// Tensor int8 con dimensiones validas que suman exactamente elements valores (y bytes).
inline bool tflmInt8TensorFits(const TfLiteTensor* tensor, size_t elements) {
    if (tensor == nullptr || tensor->type != kTfLiteInt8 || tensor->bytes != elements) return false;
    if (tensor->dims == nullptr || tensor->dims->size < 1) return false;
    size_t product = 1;
    for (int i = 0; i < tensor->dims->size; i++) {
        if (tensor->dims->data[i] <= 0) return false;
        product *= (size_t)tensor->dims->data[i];
    }
    return product == elements && tensor->data.int8 != nullptr;
}

// Escala de cuantizacion usable (la entrada se divide por ella).
inline bool tflmScaleOk(const TfLiteTensor* tensor) {
    return tensor != nullptr && tensor->params.scale > 0.0f && std::isfinite(tensor->params.scale);
}

#endif
