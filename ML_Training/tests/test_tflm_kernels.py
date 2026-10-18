"""Verifica en el PC la libreria TFLM del firmware con los kernels ESP-NN (lib/TensorFlowLite_ESP32).

    python tests/test_tflm_kernels.py            # 300 ejemplos de test de cada modelo
    python tests/test_tflm_kernels.py --n 1000

Compila la libreria con el compilador de `ziglang` (como test_frontend.py), usando la version en C de
ESP-NN (la misma logica que el ensamblador del ESP32-S3, que solo corre en el chip) y los kernels
"pegamento" esp_nn/*.cpp de TFLM que usa la placa. Corre los modelos de vision y audio sobre datos
reales de test y compara la salida int8 con el interprete de TensorFlow (kernels de referencia).
Asi se detecto que la capa FULLY_CONNECTED cuantizada por canal salia mal en la placa (ver export_model).

El ensamblador del S3 se verifica en la placa: el autotest al arrancar compara contra una salida
esperada generada aqui (ver firmware_selftest en export_model.py).
"""
import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

import numpy as np
import tensorflow as tf

TESTS_DIR = Path(__file__).resolve().parent
ML_DIR = TESTS_DIR.parent
LIB_SRC = ML_DIR.parent / "Hardware_ESP32" / "lib" / "TensorFlowLite_ESP32" / "src"
# Kernels de referencia originales de tanakamasayuki/TensorFlowLite_ESP32 1.0.0 (los que reemplaza ESP-NN),
# para --reference (control: mismo binario sin ESP-NN).
REFERENCE_KERNELS = TESTS_DIR / "reference_kernels"
ESPNN_KERNELS = ("add", "conv", "depthwise_conv", "fully_connected", "mul", "pooling", "softmax")
BUILD_DIR = TESTS_DIR / "build" / "tflm"
BINARY = BUILD_DIR / ("tflm_host.exe" if os.name == "nt" else "tflm_host")

FLAGS = ["-O2", "-mno-sse4.1", "-mno-sse4.2", "-DESP_NN=1", "-DTF_LITE_STATIC_MEMORY", "-DTF_LITE_DISABLE_X86_NEON",
         f"-I{LIB_SRC}", f"-I{LIB_SRC / 'third_party' / 'flatbuffers' / 'include'}",
         f"-I{LIB_SRC / 'third_party' / 'gemmlowp'}", f"-I{LIB_SRC / 'third_party' / 'ruy'}",
         f"-I{LIB_SRC / 'esp_nn' / 'common'}", f"-I{TESTS_DIR / 'stubs'}", "-w"]


def sources(reference=False):
    cpp = sorted(p for p in (LIB_SRC / "tensorflow").rglob("*.cpp"))
    if reference:  # mismos archivos, pero con los kernels de referencia en vez de los ESP-NN
        cpp = [p for p in cpp if p.parent.name != "esp_nn"] + [REFERENCE_KERNELS / f"{k}.cpp" for k in ESPNN_KERNELS]
    # ESP-NN en C: ansi (lo que usa esp_nn.h sin CONFIG_NN_OPTIMIZED). Los *_esp32s3.c llaman al ensamblador.
    c = sorted(p for p in (LIB_SRC / "esp_nn").rglob("*.c") if not p.name.endswith("_esp32s3.c"))
    return cpp + [TESTS_DIR / "tflm_host_main.cpp"], c


def compile_one(src: Path, is_c: bool) -> Path:
    obj = BUILD_DIR / "obj" / (src.relative_to(src.anchor).as_posix().replace("/", "_") + ".o")
    if obj.exists() and obj.stat().st_mtime > src.stat().st_mtime:
        return obj
    obj.parent.mkdir(parents=True, exist_ok=True)
    # c++20 + std::span: el flatbuffers viejo de la libreria no compila con su span emulado en clang nuevo.
    lang = ["cc", "-std=c11"] if is_c else ["c++", "-std=c++20", "-DFLATBUFFERS_USE_STD_SPAN"]
    command = [sys.executable, "-m", "ziglang", *lang, "-c", *FLAGS, str(src), "-o", str(obj)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"Error compilando {src.name}:\n{result.stderr[-3000:]}")
    return obj


def build(reference=False) -> None:
    global BINARY
    if reference:
        BINARY = BINARY.with_name("tflm_host_ref" + BINARY.suffix)
    cpp, c = sources(reference)
    print(f"Compilando {len(cpp)} archivos C++ y {len(c)} de ESP-NN (C) con zig...")
    with ThreadPoolExecutor(max(1, (os.cpu_count() or 4) // 2)) as pool:
        objects = list(pool.map(lambda s: compile_one(s, False), cpp)) + \
                  list(pool.map(lambda s: compile_one(s, True), c))
    command = [sys.executable, "-m", "ziglang", "c++", *objects, "-o", str(BINARY)]
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"Error enlazando:\n{result.stderr[-3000:]}")


def reference(model: bytes, inputs_q: np.ndarray, resolver=None) -> np.ndarray:
    # BUILTIN_REF = kernels de referencia de TFLite (los que imita TFLM). Los BUILTIN optimizados usan
    # tablas/aproximaciones distintas (ej. softmax) y difieren en algunos LSB.
    interpreter = tf.lite.Interpreter(
        model_content=model,
        experimental_op_resolver_type=resolver or tf.lite.experimental.OpResolverType.BUILTIN_REF)
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    out = interpreter.get_output_details()[0]
    results = []
    for sample in inputs_q:
        interpreter.set_tensor(inp["index"], sample.reshape(inp["shape"]))
        interpreter.invoke()
        results.append(interpreter.get_tensor(out["index"]).reshape(-1).copy())
    return np.stack(results)


def quantize(model: bytes, x: np.ndarray) -> np.ndarray:
    interpreter = tf.lite.Interpreter(model_content=model)
    scale, zero = interpreter.get_input_details()[0]["quantization"]
    return np.clip(np.round(x / scale + zero), -128, 127).astype(np.int8)


def declared_arena(header: str, constant: str) -> int:
    """Tamano de arena que reserva el firmware (generado por export_model.py)."""
    text = (ML_DIR.parent / "Hardware_ESP32" / "include" / header).read_text(encoding="utf-8")
    return int(re.search(rf"{constant}\s*=\s*(\d+)", text).group(1))


def check(name: str, model_path: Path, x_float: np.ndarray, arena_bytes: int) -> bool:
    model = model_path.read_bytes()
    inputs_q = quantize(model, x_float)
    expected = reference(model, inputs_q)

    in_file, out_file = BUILD_DIR / f"{name}_in.bin", BUILD_DIR / f"{name}_out.bin"
    inputs_q.tofile(in_file)
    run = subprocess.run([str(BINARY), str(model_path), str(in_file), str(out_file)], capture_output=True, text=True)
    if run.returncode != 0:
        print(f"✘ {name}: el binario fallo: {run.stderr}")
        return False
    got = np.fromfile(out_file, dtype=np.int8).reshape(expected.shape)

    diff = np.abs(got.astype(int) - expected.astype(int))
    same_class = np.mean(got.argmax(1) == expected.argmax(1))
    exact = np.mean(diff.max(1) == 0)
    # TFLM (2022) y TFLite actual redondean distinto en casos aislados (unos LSB): se exige la misma clase
    # en todos los ejemplos y diferencias chicas.
    # Hasta ~16/256 en casos aislados (cascada de redondeos); la clase debe coincidir siempre.
    ok = same_class == 1 and diff.max() <= 16
    # La arena que usa TFLM aca (64 bits, punteros mas grandes) es una cota superior de la de la placa.
    used = int(re.search(r"arena usada (\d+)", run.stdout).group(1))
    if used > arena_bytes:
        print(f"✘ {name}: TFLM usa {used} bytes de arena y el firmware reserva {arena_bytes}: "
              "en la placa fallaria AllocateTensors. Sube el margen en export_model.py.")
        ok = False
    print(f"{'✔' if ok else '✘'} {name:7s} {len(got)} ejemplos: "
          f"identicos {exact * 100:.1f}%, max |dif| {diff.max()} (int8), misma clase {same_class * 100:.1f}%  "
          f"[{run.stdout.strip()}]")
    return ok


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--n", type=int, default=300)
    parser.add_argument("--reference", action="store_true", help="compilar con los kernels de referencia (control)")
    args = parser.parse_args()

    build(args.reference)
    rng = np.random.default_rng(0)
    ok = True

    vision = np.load(ML_DIR / "data" / "vision_dataset.npz")
    x = vision["x_test"]
    x = x[rng.choice(len(x), min(args.n, len(x)), replace=False)]
    ok &= check("vision", ML_DIR / "models" / "vision_scenes_int8.tflite",
                x.astype(np.float32)[..., None] / 127.5 - 1.0,
                declared_arena("vision_model_data.h", "kVisionTensorArenaSize"))

    audio = np.load(ML_DIR / "data" / "audio_dataset.npz")
    x = audio["x_test"]
    ok &= check("audio", ML_DIR / "models" / "audio_events_int8.tflite",
                x[rng.choice(len(x), min(args.n, len(x)), replace=False)],
                declared_arena("audio_model_data.h", "kAudioTensorArenaSize"))

    proximity_file = ML_DIR / "data" / "proximity_dataset.npz"
    if proximity_file.exists() and (ML_DIR / "models" / "proximity_int8.tflite").exists():
        x = np.load(proximity_file)["x_test"]
        x = x[rng.choice(len(x), min(args.n, len(x)), replace=False)]
        ok &= check("cercania", ML_DIR / "models" / "proximity_int8.tflite",
                    x.astype(np.float32)[..., None] / 127.5 - 1.0,
                    declared_arena("proximity_model_data.h", "kProximityTensorArenaSize"))

    print("\nTODO OK: los kernels ESP-NN del firmware dan lo mismo que TensorFlow." if ok
          else "\n✘ Hay diferencias: revisar los kernels ESP-NN antes de subir el firmware.")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
