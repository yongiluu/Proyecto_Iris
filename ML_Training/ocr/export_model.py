"""Cuantiza el lector y el detector a int8, los evalua y genera los archivos del firmware.

    python ocr/export_model.py               # con los modelos entrenados
    python ocr/export_model.py --untrained   # modelos sin entrenar del mismo tamaño (para medir la flash)

Escribe models/ocr_reader_int8.tflite, models/ocr_detector_int8.tflite, models/ocr_report_int8.txt y
Hardware_ESP32/include/ocr_model_data.h + src/ocr_model_data.cpp (mas ocr_config.*, por firmware_codegen).
"""
import argparse
import os

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
DETECT_THRESHOLD = 128   # probabilidad 0,5 en la escala 0-255 del mapa
SUPPORTED_OPS = {"CONV_2D", "DEPTHWISE_CONV_2D", "MAX_POOL_2D", "ADD", "RESHAPE", "SOFTMAX", "MUL",
                 "LOGISTIC", "QUANTIZE", "DEQUANTIZE"}
NOTE = "// GENERADO por ML_Training/ocr/export_model.py. No editar a mano.\n"


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


def byte_array(data: bytes) -> str:
    lines = [", ".join(f"0x{b:02x}" for b in data[i:i + 16]) for i in range(0, len(data), 16)]
    return "    " + ",\n    ".join(lines)


def write_firmware(reader: bytes, reader_arena: int, det: bytes, det_arena: int, summary: str) -> None:
    firmware_codegen.main()
    comment = "".join(f"// {line}\n" for line in summary.splitlines())
    header = f"""{NOTE}{comment}#ifndef OCR_MODEL_DATA_H
#define OCR_MODEL_DATA_H

#include "ocr_config.h"

constexpr int kOcrReaderArena = {reader_arena};
constexpr int kOcrDetectorArena = {det_arena};
constexpr int kOcrDetectThreshold = {DETECT_THRESHOLD};  // celda con texto si probabilidad*255 >= esto

extern const unsigned char g_ocr_reader_model[];
extern const unsigned int g_ocr_reader_model_len;
extern const unsigned char g_ocr_detector_model[];
extern const unsigned int g_ocr_detector_model_len;

#endif
"""
    source = f"""{NOTE}#include "ocr_model_data.h"

alignas(16) const unsigned char g_ocr_reader_model[] = {{
{byte_array(reader)}
}};
const unsigned int g_ocr_reader_model_len = {len(reader)};

alignas(16) const unsigned char g_ocr_detector_model[] = {{
{byte_array(det)}
}};
const unsigned int g_ocr_detector_model_len = {len(det)};
"""
    (config.FIRMWARE_INCLUDE / "ocr_model_data.h").write_text(header, encoding="utf-8")
    (config.FIRMWARE_SRC / "ocr_model_data.cpp").write_text(source, encoding="utf-8")


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

    if not args.untrained:
        READER_TFLITE.write_bytes(reader_tflite)
        DETECTOR_TFLITE.write_bytes(det_tflite)
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
    write_firmware(reader_tflite, reader_arena, det_tflite, det_arena, summary)
    print("✔ Archivos del firmware escritos (ocr_model_data.*)")


if __name__ == "__main__":
    main()
