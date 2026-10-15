"""Cuantiza el modelo de vision a int8 y genera los archivos del firmware.

    python vision/export_model.py
    python vision/export_model.py --tflite otro.tflite   # un .tflite int8 ya exportado (ej. de Lambda)

Escribe:
  - models/vision_scenes_int8.tflite        (para live_demo.py y para versionar)
  - models/vision_report_int8.txt           (metricas del modelo cuantizado)
  - Hardware_ESP32/include/vision_model_data.h, src/vision_model_data.cpp
Despues: compilar y subir el firmware con PlatformIO.
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from augment import to_model_input
from train import KERAS_MODEL, build_model, report

TFLITE_MODEL = config.MODELS_DIR / "vision_scenes_int8.tflite"
HEADER_NOTE = "// GENERADO por ML_Training/vision/export_model.py. No editar a mano.\n"

# Ops seguras en el TFLM de tanakamasayuki/TensorFlowLite_ESP32 1.0.0 (las mismas que el modelo de audio).
SUPPORTED_OPS = {"CONV_2D", "DEPTHWISE_CONV_2D", "AVERAGE_POOL_2D", "RESHAPE", "FULLY_CONNECTED",
                 "SOFTMAX", "QUANTIZE", "DEQUANTIZE"}


def convert(model: tf.keras.Model, representative: np.ndarray) -> bytes:
    def representative_dataset():
        for sample in representative:
            yield [sample[np.newaxis].astype(np.float32)]

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative_dataset
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    return converter.convert()


def int8_predictor(tflite_model: bytes):
    # Sin XNNPACK: asi se ven las ops reales del modelo (las mismas que ejecuta TFLM en la placa).
    interpreter = tf.lite.Interpreter(
        model_content=tflite_model,
        experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    out = interpreter.get_output_details()[0]
    in_scale, in_zero = inp["quantization"]
    out_scale, out_zero = out["quantization"]

    def predict(images_uint8: np.ndarray) -> np.ndarray:
        """Recibe pixeles 0..255 (como la camara) y cuantiza igual que el firmware."""
        x = to_model_input(images_uint8)
        results = []
        for sample in x:
            q = np.clip(np.round(sample / in_scale + in_zero), -128, 127).astype(np.int8)
            interpreter.set_tensor(inp["index"], q[np.newaxis])
            interpreter.invoke()
            results.append((interpreter.get_tensor(out["index"])[0].astype(np.float32) - out_zero) * out_scale)
        return np.stack(results)

    return predict, interpreter


def check_ops_and_estimate_arena(interpreter: tf.lite.Interpreter) -> int:
    """Revisa que las ops existan en el TFLM del firmware y estima la memoria (tensor arena)."""
    ops = interpreter._get_ops_details()
    names = {op["op_name"] for op in ops}
    unsupported = names - SUPPORTED_OPS
    if unsupported:
        raise SystemExit(f"El modelo usa ops que el TFLM del firmware puede no soportar: {unsupported}")
    print("Ops del modelo:", sorted(names))
    shape = interpreter.get_input_details()[0]["shape"]
    if shape[0] != 1:
        raise SystemExit(f"La entrada debe tener batch fijo en 1 (tiene {shape})")

    tensors = {t["index"]: t for t in interpreter.get_tensor_details()}

    def nbytes(index):
        t = tensors[index]
        return int(np.prod(t["shape"])) * np.dtype(t["dtype"]).itemsize

    # Peor operador (activaciones de entrada + salida vivas) mas margen para las estructuras de TFLM.
    activations = {i for op in ops for i in op["outputs"]}
    activations |= {d["index"] for d in interpreter.get_input_details()}
    worst = 0
    for op in ops:
        live = sum(nbytes(i) for i in list(op["inputs"]) + list(op["outputs"]) if i in activations)
        worst = max(worst, live)
    estimate = int(worst * 1.3) + 16 * 1024
    return (estimate + 1023) // 1024 * 1024


def _float_literal(value) -> str:
    text = f"{float(value):.9g}"
    if not any(c in text for c in ".en"):
        text += ".0"
    return text + "f"


def _byte_array(data: bytes, per_line=16) -> str:
    lines = [", ".join(f"0x{b:02x}" for b in data[i:i + per_line]) for i in range(0, len(data), per_line)]
    return "    " + ",\n    ".join(lines)


def write_model_files(tflite_model: bytes, arena_bytes: int, metrics: str) -> None:
    labels = ", ".join(f'"{c}"' for c in config.CLASSES)
    alerts = ", ".join("true" if c in config.ALERT_CLASSES else "false" for c in config.CLASSES)
    metric_lines = "".join(f"// {line}\n" for line in metrics.strip().splitlines())

    header = f"""{HEADER_NOTE}{metric_lines}#ifndef VISION_MODEL_DATA_H
#define VISION_MODEL_DATA_H

#include <stdint.h>

constexpr int kVisionImageSize = {config.IMAGE_SIZE};       // entrada 96x96x1 en grises (FRAMESIZE_96X96)
constexpr int kVisionNumClasses = {len(config.CLASSES)};
constexpr int kVisionTensorArenaSize = {arena_bytes};
constexpr float kVisionAlertThreshold = {_float_literal(config.ALERT_THRESHOLD)};  // config.ALERT_THRESHOLD
// Pixel 0..255 -> entrada float del modelo: pixel * kVisionPixelScale + kVisionPixelOffset (augment.to_model_input)
constexpr float kVisionPixelScale = {_float_literal(1 / 127.5)};
constexpr float kVisionPixelOffset = -1.0f;

extern const unsigned char g_vision_model_data[];
extern const unsigned int g_vision_model_data_len;
extern const char* const kVisionLabels[kVisionNumClasses];
extern const bool kVisionIsAlert[kVisionNumClasses];   // se informa a la app como CMD_VISION_EVENT

#endif
"""
    source = f"""{HEADER_NOTE}#include "vision_model_data.h"

const char* const kVisionLabels[kVisionNumClasses] = {{{labels}}};
const bool kVisionIsAlert[kVisionNumClasses] = {{{alerts}}};

alignas(16) const unsigned char g_vision_model_data[] = {{
{_byte_array(tflite_model)}
}};
const unsigned int g_vision_model_data_len = {len(tflite_model)};
"""
    (config.FIRMWARE_INCLUDE / "vision_model_data.h").write_text(header, encoding="utf-8")
    (config.FIRMWARE_SRC / "vision_model_data.cpp").write_text(source, encoding="utf-8")
    print(f"Modelo ({len(tflite_model) / 1024:.1f} KB) escrito en {config.FIRMWARE_SRC / 'vision_model_data.cpp'}")


def convert_keras_model(data) -> bytes:
    trained = tf.keras.models.load_model(KERAS_MODEL)
    # Misma red con batch fijo en 1: con batch variable, Flatten se convierte en SHAPE/STRIDED_SLICE/PACK,
    # que no existen en el TFLM del firmware.
    alpha = trained.get_layer("conv1").filters / 32
    model = build_model(len(config.CLASSES), alpha, batch_size=1)
    model.set_weights(trained.get_weights())

    rng = np.random.default_rng(config.SEED)
    # Representativo = imagenes de validacion limpias y con simulacion de la camara (cubre poca luz).
    from augment import camera_degrade
    picks = rng.choice(len(data["x_val"]), min(600, len(data["x_val"])), replace=False)
    images = [data["x_val"][i] for i in picks] + [camera_degrade(data["x_val"][i], rng) for i in picks[:300]]
    tflite_model = convert(model, to_model_input(np.stack(images)))
    TFLITE_MODEL.write_bytes(tflite_model)
    return tflite_model


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tflite", help="usar un .tflite int8 ya exportado en vez de convertir")
    args = parser.parse_args()
    data = dict(np.load(config.DATASET_FILE))

    if args.tflite:
        tflite_model = open(args.tflite, "rb").read()
        if os.path.abspath(args.tflite) != os.path.abspath(TFLITE_MODEL):
            TFLITE_MODEL.write_bytes(tflite_model)
    else:
        tflite_model = convert_keras_model(data)
    print(f"Modelo int8: {len(tflite_model) / 1024:.1f} KB -> {TFLITE_MODEL}")

    predict, interpreter = int8_predictor(tflite_model)
    arena = check_ops_and_estimate_arena(interpreter)
    print(f"Tensor arena estimada: {arena / 1024:.0f} KB")

    text = report(predict, data["x_test"], data["y_test"], "Test limpio (int8, lo que corre en la placa)") + \
        "\n\n" + report(predict, data["x_test_cam"], data["y_test"], "Test con simulacion OV2640 (int8)")
    print("\n" + text)
    (config.MODELS_DIR / "vision_report_int8.txt").write_text(text, encoding="utf-8")

    summary = "\n".join(line.strip() for line in text.splitlines()
                        if line.startswith(("==", "Exactitud")) or "avisos falsos" in line)
    write_model_files(tflite_model, arena, summary)
    print("\nListo. Compila y sube el firmware: cd Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload")


if __name__ == "__main__":
    main()
