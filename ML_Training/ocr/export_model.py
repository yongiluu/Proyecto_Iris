"""Cuantiza el lector a int8 (lo que corre en la placa), revisa las ops y lo evalua.

    python ocr/export_model.py

Escribe models/ocr_reader_int8.tflite y models/ocr_report_int8.txt.
"""
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from model import build_model
from train import KERAS_MODEL, evaluate

TFLITE_MODEL = config.MODELS_DIR / "ocr_reader_int8.tflite"
REPORT = config.MODELS_DIR / "ocr_report_int8.txt"
SUPPORTED_OPS = {"CONV_2D", "DEPTHWISE_CONV_2D", "MAX_POOL_2D", "ADD", "RESHAPE", "SOFTMAX", "MUL",
                 "QUANTIZE", "DEQUANTIZE"}


def main() -> None:
    images = np.load(config.DATA_DIR / "lines_train_images.npy", mmap_mode="r")
    val_images = np.load(config.DATA_DIR / "lines_val_images.npy", mmap_mode="r")
    val_texts = np.load(config.DATA_DIR / "lines_val_meta.npz")["texts"]

    trained = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    width = trained.get_layer(index=2).filters / 32  # primera convolucion
    model = build_model(width, batch_size=1)          # batch fijo: sin ops dinamicas que TFLM no tiene
    model.set_weights(trained.get_weights())

    rng = np.random.default_rng(config.SEED)
    sample = rng.choice(len(images), 500, replace=False)

    def representative():
        for i in sample:
            yield [images[i][np.newaxis, ..., np.newaxis].astype(np.float32)]

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    tflite_model = converter.convert()
    TFLITE_MODEL.write_bytes(tflite_model)

    interpreter = tf.lite.Interpreter(
        model_content=tflite_model,
        experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    interpreter.allocate_tensors()
    inp, out = interpreter.get_input_details()[0], interpreter.get_output_details()[0]
    ops = {op["op_name"] for op in interpreter._get_ops_details()}
    unsupported = ops - SUPPORTED_OPS

    def predict(batch):
        in_scale, in_zero = inp["quantization"]
        out_scale, out_zero = out["quantization"]
        results = []
        for image in np.asarray(batch):
            q = np.clip(np.round(image[np.newaxis, ..., np.newaxis] / in_scale + in_zero), -128, 127).astype(np.int8)
            interpreter.set_tensor(inp["index"], q)
            interpreter.invoke()
            results.append((interpreter.get_tensor(out["index"])[0].astype(np.float32) - out_zero) * out_scale)
        return np.stack(results)

    summary = (f"Modelo int8: {len(tflite_model) / 1024:.0f} KB | ops: {sorted(ops)}"
               + (f"\n⚠ Ops que el TFLM de la placa puede no tener: {sorted(unsupported)}" if unsupported else ""))
    report = summary + "\n\n" + evaluate(predict, val_images[:3000], val_texts[:3000], "Validacion (int8, lo que corre en la placa)")
    print(report)
    REPORT.write_text(report, encoding="utf-8")
    print(f"\n✔ {TFLITE_MODEL}")


if __name__ == "__main__":
    main()
