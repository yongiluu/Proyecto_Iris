"""Cuantiza el alumno a int8 (lo que corre en la placa) y lo evalua.

    python scene/export_model.py

Escribe models/scene_student_int8.tflite y models/scene_report_int8.txt. Revisa que solo use operaciones
del TFLite Micro de la placa y estima tamaño y memoria. (La integracion en el firmware viene despues:
ver "Proximos pasos" en scene/README.md.)
"""
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from dataset import load_rows, make_dataset, split_of
from model import build_model
from train import KERAS_MODEL, evaluate, load_meta

TFLITE_MODEL = config.MODELS_DIR / "scene_student_int8.tflite"
REPORT = config.MODELS_DIR / "scene_report_int8.txt"
SUPPORTED_OPS = {"CONV_2D", "DEPTHWISE_CONV_2D", "ADD", "PAD", "AVERAGE_POOL_2D", "RESHAPE", "FULLY_CONNECTED",
                 "SOFTMAX", "LOGISTIC", "QUANTIZE", "DEQUANTIZE", "MUL", "RELU6", "RELU"}


def convert(rows: list[dict]) -> bytes:
    trained = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    meta = load_meta()
    # Misma red con batch fijo en 1 (con batch variable, Reshape/Flatten generan ops que TFLM no tiene).
    model = build_model(meta.get("alpha", config.BACKBONE_ALPHA), batch_size=1, pretrained=False)
    model.set_weights(trained.get_weights())

    sample = make_dataset(rows[:400], train=False, batch_size=1)

    def representative():
        for image, _ in sample:
            yield [image]

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    return converter.convert()


def int8_predictor(tflite_model: bytes):
    interpreter = tf.lite.Interpreter(
        model_content=tflite_model,
        experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    runner = interpreter.get_signature_runner()
    inp = runner.get_input_details()
    (in_name, in_detail), = inp.items()
    in_scale, in_zero = in_detail["quantization"]
    out_details = runner.get_output_details()

    def predict(rows):
        results = {name: [] for name in out_details}
        for image, _ in make_dataset(rows, train=False, batch_size=1):
            q = np.clip(np.round(image.numpy() / in_scale + in_zero), -128, 127).astype(np.int8)
            out = runner(**{in_name: q})
            for name, detail in out_details.items():
                scale, zero = detail["quantization"]
                results[name].append((out[name][0].astype(np.float32) - zero) * scale)
        return {name: np.stack(v) for name, v in results.items()}

    return predict, interpreter


def main() -> None:
    rows = load_rows("mix")
    train = [r for r in rows if split_of(r["image"]) == "train"]
    test = [r for r in rows if split_of(r["image"]) == "test"]

    tflite_model = convert(train)
    TFLITE_MODEL.write_bytes(tflite_model)
    predict, interpreter = int8_predictor(tflite_model)

    ops = {op["op_name"] for op in interpreter._get_ops_details()}
    unsupported = ops - SUPPORTED_OPS
    print(f"Ops: {sorted(ops)}")
    if unsupported:
        print(f"⚠ Ops que el TFLM de la placa puede no tener: {sorted(unsupported)}")

    tensors = {t["index"]: t for t in interpreter.get_tensor_details()}
    produced = {i for op in interpreter._get_ops_details() for i in op["outputs"]}
    produced |= {d["index"] for d in interpreter.get_input_details()}
    worst = max(sum(int(np.prod(tensors[i]["shape"])) * np.dtype(tensors[i]["dtype"]).itemsize
                    for i in list(op["inputs"]) + list(op["outputs"]) if i in produced)
                for op in interpreter._get_ops_details())
    summary = (f"Modelo int8: {len(tflite_model) / 1024:.0f} KB de flash; activaciones del peor paso ~{worst / 1024:.0f} KB "
               f"(arena estimada ~{(worst * 1.3 + 16384) / 1024:.0f} KB, va en PSRAM)")
    print(summary)

    report = summary + "\n\n" + evaluate(predict, test, "Test (int8, lo que correria en la placa)",
                                         hazards_trained=load_meta().get("hazards_trained", True))
    print("\n" + report)
    REPORT.write_text(report, encoding="utf-8")
    print(f"\n✔ {TFLITE_MODEL}")


if __name__ == "__main__":
    main()
