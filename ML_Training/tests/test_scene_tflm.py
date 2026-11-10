"""El modelo de escenas ("escena", particion de modelos) calcula lo mismo en la libreria TFLM de la placa
que en TensorFlow.

    python tests/test_scene_tflm.py

Corre models/scene_student_int8.tflite con la libreria del firmware compilada en el PC (como
test_tflm_kernels.py) y compara TODAS las cabezas con el interprete de TensorFlow. Asi se detecto que las
capas FULLY_CONNECTED cuantizadas por canal salian mal en la placa (el TFLM de 2022 usa una sola escala):
las frases que decia la placa no eran las del modelo. Ver scene/export_model.py.
"""
import os
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

import numpy as np
import tensorflow as tf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_tflm_kernels as tflm

MODEL = tflm.ML_DIR / "models" / "scene_student_int8.tflite"
N = 12
MAX_DIFF = 16  # como test_tflm_kernels: TFLM (2022) y TFLite redondean distinto en casos aislados


def images(shape) -> np.ndarray:
    """Imagenes sinteticas con estructura (manchas suaves + ruido): sin datos de entrenamiento."""
    rng = np.random.default_rng(1234)
    _, h, w, c = shape
    out = []
    for _ in range(N):
        small = rng.integers(0, 256, (h // 8, w // 8, c)).astype(np.float32)
        big = np.kron(small, np.ones((8, 8, 1), np.float32)) + rng.normal(0, 12, (h, w, c))
        out.append(np.clip(big, 0, 255))
    return np.stack(out)


def main() -> int:
    model = MODEL.read_bytes()
    interpreter = tf.lite.Interpreter(model_content=model,
                                      experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF)
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    outs = interpreter.get_output_details()
    names = {d["index"]: name for name, d in interpreter.get_signature_runner().get_output_details().items()}
    scale, zero = inp["quantization"]
    inputs_q = np.clip(np.round(images(inp["shape"]) / scale + zero), -128, 127).astype(np.int8)

    expected = []
    for sample in inputs_q:
        interpreter.set_tensor(inp["index"], sample.reshape(inp["shape"]))
        interpreter.invoke()
        expected.append(np.concatenate([interpreter.get_tensor(d["index"]).reshape(-1) for d in outs]))
    expected = np.stack(expected)

    tflm.build()
    in_file, out_file = tflm.BUILD_DIR / "escena_in.bin", tflm.BUILD_DIR / "escena_out.bin"
    inputs_q.tofile(in_file)
    run = subprocess.run([str(tflm.BINARY), str(MODEL), str(in_file), str(out_file)], capture_output=True, text=True,
                         env={**os.environ, "TFLM_ARENA_KB": "4096"})
    if run.returncode != 0:
        print(f"✘ el binario fallo: {run.stderr[-2000:]}")
        return 1
    got = np.fromfile(out_file, dtype=np.int8).reshape(expected.shape)

    ok = True
    start = 0
    for d in outs:
        size = int(np.prod(d["shape"]))
        diff = np.abs(got[:, start:start + size].astype(int) - expected[:, start:start + size].astype(int))
        start += size
        good = diff.max() <= MAX_DIFF
        ok = ok and good
        print(f"{'✔' if good else '✘'} {names.get(d['index'], d['name']):9s} max |dif| {diff.max():3d} (int8), "
              f"identicos {np.mean(diff == 0) * 100:.1f}%")
    print(run.stdout.strip())
    if not ok:
        print("La placa calcularia distinto que el entrenamiento: revisar scene/export_model.py "
              "(capas densas cuantizadas por canal).")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
