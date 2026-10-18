"""Cuantiza el modelo de cercania a int8 y genera los archivos del firmware.

    python vision/proximity_export.py
    python vision/proximity_export.py --tflite otro.tflite

Escribe models/proximity_int8.tflite, models/proximity_report_int8.txt y
Hardware_ESP32/include/proximity_model_data.h + src/proximity_model_data.cpp.
Usa las mismas verificaciones que el modelo de clases (ops del TFLM viejo, FC por tensor, arena).
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from augment import camera_degrade, to_model_input
from export_model import (HEADER_NOTE, _byte_array, _float_literal, _int_array, check_ops_and_estimate_arena,
                          convert, int8_predictor)
from proximity_train import KERAS_MODEL, report
from train import build_model

TFLITE_MODEL = config.MODELS_DIR / "proximity_int8.tflite"
CLASSES = config.PROXIMITY_CLASSES


def write_files(tflite_model: bytes, arena: int, metrics: str, lut, image, expected) -> None:
    note = HEADER_NOTE.replace("export_model.py", "proximity_export.py")
    labels = ", ".join(f'"{c}"' for c in CLASSES)
    metric_lines = "".join(f"// {line}\n" for line in metrics.strip().splitlines())
    header = f"""{note}{metric_lines}#ifndef PROXIMITY_MODEL_DATA_H
#define PROXIMITY_MODEL_DATA_H

#include <stdint.h>

// Cercania: "¿hay algo cerca al frente?" con la misma imagen 96x96 en grises que el modelo de clases.
// Clases: 0 = libre, 1 = cerca (< {config.PROXIMITY_NEAR_M} m), 2 = muy_cerca (< {config.PROXIMITY_VERY_NEAR_M} m).
constexpr int kProximityNumClasses = {len(CLASSES)};
constexpr int kProximityTensorArenaSize = {arena};
constexpr float kProximityAlertThreshold = {_float_literal(config.PROXIMITY_ALERT_THRESHOLD)};  // cerca + muy_cerca

extern const unsigned char g_proximity_model_data[];
extern const unsigned int g_proximity_model_data_len;
extern const char* const kProximityLabels[kProximityNumClasses];
extern const int8_t kProximityInputLut[256];
extern const uint8_t kProximitySelfTestImage[96 * 96];
extern const int8_t kProximitySelfTestExpected[kProximityNumClasses];

#endif
"""
    source = f"""{note}#include "proximity_model_data.h"

const char* const kProximityLabels[kProximityNumClasses] = {{{labels}}};

const int8_t kProximityInputLut[256] = {{
{_int_array(lut)}
}};

const uint8_t kProximitySelfTestImage[96 * 96] = {{
{_int_array(image.reshape(-1))}
}};

const int8_t kProximitySelfTestExpected[kProximityNumClasses] = {{{", ".join(str(int(v)) for v in expected)}}};

alignas(16) const unsigned char g_proximity_model_data[] = {{
{_byte_array(tflite_model)}
}};
const unsigned int g_proximity_model_data_len = {len(tflite_model)};
"""
    (config.FIRMWARE_INCLUDE / "proximity_model_data.h").write_text(header, encoding="utf-8")
    (config.FIRMWARE_SRC / "proximity_model_data.cpp").write_text(source, encoding="utf-8")
    print(f"Modelo ({len(tflite_model) / 1024:.1f} KB) escrito en {config.FIRMWARE_SRC / 'proximity_model_data.cpp'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tflite", help="usar un .tflite int8 ya exportado")
    args = parser.parse_args()
    data = dict(np.load(config.PROXIMITY_DATASET_FILE))

    if args.tflite:
        tflite_model = open(args.tflite, "rb").read()
    else:
        trained = tf.keras.models.load_model(KERAS_MODEL)
        alpha = trained.get_layer("conv1").filters / 32
        model = build_model(len(CLASSES), alpha, batch_size=1)
        model.set_weights(trained.get_weights())
        rng = np.random.default_rng(config.SEED)
        picks = rng.choice(len(data["x_val"]), min(600, len(data["x_val"])), replace=False)
        images = [data["x_val"][i] for i in picks] + [camera_degrade(data["x_val"][i], rng) for i in picks[:300]]
        tflite_model = convert(model, to_model_input(np.stack(images)))
    TFLITE_MODEL.write_bytes(tflite_model)
    print(f"Modelo int8: {len(tflite_model) / 1024:.1f} KB -> {TFLITE_MODEL}")

    predict, interpreter = int8_predictor(tflite_model)
    arena = check_ops_and_estimate_arena(interpreter)
    print(f"Tensor arena estimada: {arena / 1024:.0f} KB")
    text = report(predict(data["x_test"]), data["y_test"], "Test limpio (int8, lo que corre en la placa)") + \
        "\n\n" + report(predict(data["x_test_cam"]), data["y_test"], "Test con simulacion OV2640 (int8)")
    print("\n" + text)
    (config.MODELS_DIR / "proximity_report_int8.txt").write_text(text, encoding="utf-8")

    summary = "\n".join(line.strip() for line in text.splitlines()
                        if line.startswith(("==", "Exactitud")) or "avisado" in line or "avisos falsos" in line)
    selftest = data["x_test"][int(np.argmax(data["y_test"] == 2))]  # el primer "muy_cerca" del test
    expected = predict.raw(selftest)
    print(f"Autotest del firmware: salida esperada {expected.tolist()}")
    write_files(tflite_model, arena, summary, predict.lut, selftest, expected)


if __name__ == "__main__":
    main()
