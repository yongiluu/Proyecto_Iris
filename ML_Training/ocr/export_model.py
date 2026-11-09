"""Cuantiza el lector y el detector a int8, los evalua y genera los archivos del firmware.

    python ocr/export_model.py               # con los modelos entrenados
    python ocr/export_model.py --untrained   # modelos sin entrenar del mismo tamaño (para medir la flash)

Escribe models/ocr_reader_int8.tflite, models/ocr_detector_int8.tflite, models/ocr_report_int8.txt,
anota ambos en models/firmware_models.json (van a la particion "modelos" de la placa con
Hardware_ESP32/tools/subir_modelos.py) y regenera ocr_config.* (firmware_codegen).
"""
import argparse
import os
import sys

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
import detector
import firmware_codegen
from model import build_model
from train import KERAS_MODEL, evaluate

READER_TFLITE = config.MODELS_DIR / "ocr_reader_int8.tflite"
DETECTOR_TFLITE = config.MODELS_DIR / "ocr_detector_int8.tflite"
REPORT = config.MODELS_DIR / "ocr_report_int8.txt"
SUPPORTED_OPS = {"CONV_2D", "DEPTHWISE_CONV_2D", "MAX_POOL_2D", "ADD", "RESHAPE", "SOFTMAX", "MUL",
                 "LOGISTIC", "QUANTIZE", "DEQUANTIZE"}


def to_int8(model: tf.keras.Model, samples) -> bytes:
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = lambda: ([s[np.newaxis, ..., np.newaxis].astype(np.float32)] for s in samples)
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    return converter.convert()


def interpreter_for(tflite_model: bytes) -> tf.lite.Interpreter:
    interpreter = tf.lite.Interpreter(
        model_content=tflite_model,
        experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    interpreter.allocate_tensors()
    return interpreter


def check(interpreter, name: str) -> tuple[set, int]:
    ops = {op["op_name"] for op in interpreter._get_ops_details()}
    if ops - SUPPORTED_OPS:
        raise SystemExit(f"{name}: ops que el TFLM de la placa puede no tener: {sorted(ops - SUPPORTED_OPS)}")
    tensors = {t["index"]: t for t in interpreter.get_tensor_details()}
    produced = {i for op in interpreter._get_ops_details() for i in op["outputs"]}
    produced |= {d["index"] for d in interpreter.get_input_details()}
    worst = max(sum(int(np.prod(tensors[i]["shape"])) * np.dtype(tensors[i]["dtype"]).itemsize
                    for i in list(op["inputs"]) + list(op["outputs"]) if i in produced)
                for op in interpreter._get_ops_details())
    return ops, int(worst * 1.3) + 16 * 1024


def register_models(reader: bytes, reader_arena: int, det: bytes, det_arena: int) -> None:
    """Guarda los .tflite y los anota en models/firmware_models.json para la particion de la placa."""
    sys.path.insert(0, str(config.ML_DIR / "tools"))
    import pack_models
    READER_TFLITE.write_bytes(reader)
    DETECTOR_TFLITE.write_bytes(det)
    pack_models.register("ocr_lector", READER_TFLITE, reader_arena)
    pack_models.register("ocr_detector", DETECTOR_TFLITE, det_arena)
    firmware_codegen.main()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--untrained", action="store_true", help="modelos sin entrenar (solo para medir tamaño)")
    args = parser.parse_args()
    rng = np.random.default_rng(config.SEED)

    lines = np.load(config.DATA_DIR / "lines_train_images.npy", mmap_mode="r")
    line_samples = [lines[i] for i in rng.choice(len(lines), 300, replace=False)]
    reader = build_model(batch_size=1)   # batch fijo: sin ops dinamicas que TFLM no tiene
    if not args.untrained:
        reader.set_weights(tf.keras.models.load_model(KERAS_MODEL, compile=False).get_weights())
    reader_tflite = to_int8(reader, line_samples)

    scenes_path = config.DATA_DIR / "det_train_images.npy"
    scenes = np.load(scenes_path, mmap_mode="r") if scenes_path.exists() else None
    scene_samples = ([scenes[i] for i in rng.choice(len(scenes), 200, replace=False)] if scenes is not None
                     else [rng.integers(0, 256, (config.DET_HEIGHT, config.DET_WIDTH)).astype(np.uint8) for _ in range(20)])
    det = detector.build_model(batch_size=1)
    if not args.untrained:
        det.set_weights(tf.keras.models.load_model(detector.KERAS_MODEL, compile=False).get_weights())
    det_tflite = to_int8(det, scene_samples)

    reader_ops, reader_arena = check(interpreter_for(reader_tflite), "lector")
    det_ops, det_arena = check(interpreter_for(det_tflite), "detector")
    summary = (f"Lector int8: {len(reader_tflite) / 1024:.0f} KB, arena ~{reader_arena / 1024:.0f} KB | "
               f"detector int8: {len(det_tflite) / 1024:.0f} KB, arena ~{det_arena / 1024:.0f} KB"
               + (" (SIN ENTRENAR: solo para medir)" if args.untrained else ""))
    print(summary)
    print(f"Ops lector: {sorted(reader_ops)} | detector: {sorted(det_ops)}")

    if args.untrained:
        print("Sin entrenar: no se anotan para la placa (solo se mide el tamaño).")
        return
    register_models(reader_tflite, reader_arena, det_tflite, det_arena)
    interpreter = interpreter_for(reader_tflite)
    inp, out = interpreter.get_input_details()[0], interpreter.get_output_details()[0]

    def predict(batch):
        in_scale, in_zero = inp["quantization"]
        results = []
        for image in np.asarray(batch):
            q = np.clip(np.round(image[np.newaxis, ..., np.newaxis] / in_scale + in_zero), -128, 127).astype(np.int8)
            interpreter.set_tensor(inp["index"], q)
            interpreter.invoke()
            results.append(interpreter.get_tensor(out["index"])[0].astype(np.float32))  # argmax: basta int8
        return np.stack(results)

    val_images = np.load(config.DATA_DIR / "lines_val_images.npy", mmap_mode="r")
    val_texts = np.load(config.DATA_DIR / "lines_val_meta.npz")["texts"]
    report = summary + "\n\n" + evaluate(predict, val_images[:3000], val_texts[:3000], "Lector int8 (validacion)")
    print(report)
    REPORT.write_text(report, encoding="utf-8")
    print("Listo: modelos anotados en models/firmware_models.json. Subirlos a la placa con "
          "Hardware_ESP32/tools/subir_modelos.py")


if __name__ == "__main__":
    main()
