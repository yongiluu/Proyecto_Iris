"""Cuantiza el modelo a int8 y genera los archivos del firmware.

    python audio/export_model.py

Escribe:
  - models/audio_events_int8.tflite        (para live_demo.py y para versionar)
  - models/audio_report_int8.txt           (metricas del modelo cuantizado)
  - Hardware_ESP32/include/audio_model_data.h, src/audio_model_data.cpp
  - Hardware_ESP32/include/audio_frontend_config.h, src/audio_frontend_tables.cpp
Despues: compilar y subir el firmware con PlatformIO.
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from firmware_codegen import write_frontend_files, write_model_files
from train import KERAS_MODEL, build_model, report

TFLITE_MODEL = config.MODELS_DIR / "audio_events_int8.tflite"


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

    def predict(x: np.ndarray) -> np.ndarray:
        results = []
        for sample in x:
            q = np.clip(np.round(sample / in_scale + in_zero), -128, 127).astype(np.int8)
            interpreter.set_tensor(inp["index"], q[np.newaxis])
            interpreter.invoke()
            results.append((interpreter.get_tensor(out["index"])[0].astype(np.float32) - out_zero) * out_scale)
        return np.stack(results)

    return predict, interpreter


SUPPORTED_OPS = {"CONV_2D", "DEPTHWISE_CONV_2D", "AVERAGE_POOL_2D", "RESHAPE", "FULLY_CONNECTED",
                 "SOFTMAX", "QUANTIZE", "DEQUANTIZE"}


def check_ops_and_estimate_arena(interpreter: tf.lite.Interpreter) -> int:
    """Revisa que las ops existan en el TFLM del firmware y estima la memoria (tensor arena)."""
    ops = interpreter._get_ops_details()
    names = {op["op_name"] for op in ops}
    unsupported = names - SUPPORTED_OPS
    if unsupported:
        raise SystemExit(f"El modelo usa ops que el TFLM del firmware puede no soportar: {unsupported}")
    print("Ops del modelo:", sorted(names))

    tensors = {t["index"]: t for t in interpreter.get_tensor_details()}

    def nbytes(index):
        t = tensors[index]
        return int(np.prod(t["shape"])) * np.dtype(t["dtype"]).itemsize

    # Activaciones = tensores que produce algun operador, o la entrada del modelo. El resto son pesos
    # (viven en flash). Se toma el peor operador (entradas + salidas vivas) mas margen para las
    # estructuras internas de TFLM. El firmware imprime el uso real al arrancar.
    activations = {i for op in ops for i in op["outputs"]}
    activations |= {d["index"] for d in interpreter.get_input_details()}
    worst = 0
    for op in ops:
        live = sum(nbytes(i) for i in list(op["inputs"]) + list(op["outputs"]) if i in activations)
        worst = max(worst, live)
    estimate = int(worst * 1.3) + 12 * 1024
    return (estimate + 1023) // 1024 * 1024


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tflite", help="usar un .tflite int8 ya exportado (ej. entrenado en Lambda) en vez de convertir")
    args = parser.parse_args()
    data = dict(np.load(config.DATASET_FILE))

    if args.tflite:
        tflite_model = open(args.tflite, "rb").read()
        if os.path.abspath(args.tflite) != os.path.abspath(TFLITE_MODEL):
            TFLITE_MODEL.write_bytes(tflite_model)
    else:
        tflite_model = convert_keras_model(data)
    print(f"Modelo int8: {len(tflite_model) / 1024:.1f} KB -> {TFLITE_MODEL}")
    export(tflite_model, data)


def convert_keras_model(data) -> bytes:
    trained = tf.keras.models.load_model(KERAS_MODEL)
    # Misma red con batch fijo en 1: con batch variable, Flatten se convierte en SHAPE/STRIDED_SLICE/PACK,
    # que no existen en el TFLM del firmware.
    width = trained.layers[1].filters / 32
    model = build_model(len(config.CLASSES), width, batch_size=1)
    model.set_weights(trained.get_weights())

    rng = np.random.default_rng(config.SEED)
    representative = data["x_train"][rng.choice(len(data["x_train"]), min(1000, len(data["x_train"])), replace=False)]
    tflite_model = convert(model, representative)
    TFLITE_MODEL.write_bytes(tflite_model)
    return tflite_model


def export(tflite_model: bytes, data) -> None:
    predict, interpreter = int8_predictor(tflite_model)
    arena = check_ops_and_estimate_arena(interpreter)
    print(f"Tensor arena estimada: {arena / 1024:.0f} KB")

    test_report = report(predict, data["x_test"], data["y_test"], "Test (int8, lo que corre en la placa)")
    print("\n" + test_report)
    (config.MODELS_DIR / "audio_report_int8.txt").write_text(test_report, encoding="utf-8")

    summary = "\n".join(test_report.splitlines()[:2] + [test_report.splitlines()[-1]])
    write_frontend_files()
    write_model_files(tflite_model, arena, summary)
    print("\nListo. Compila y sube el firmware: cd Hardware_ESP32 && pio run -t upload")


if __name__ == "__main__":
    main()
