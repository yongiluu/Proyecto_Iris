"""Verifica que la frase que arma el firmware (scene_describe.cpp) sea IDENTICA a la de describe.py.

    python tests/test_scene_describe.py

Regenera las tablas del vocabulario (scene/firmware_codegen.py), compila el C++ para el PC con
`ziglang` y compara miles de predicciones al azar, incluidos valores justo en los umbrales.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

ML_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ML_DIR / "scene"))
import firmware_codegen  # noqa: E402
from describe import (COLOR_THRESHOLD, HAZARD_MAYBE, HAZARD_NONE, HAZARD_SURE, OBJECT_THRESHOLD,  # noqa: E402
                      PLACE_THRESHOLD, QUALITY_BAD, describe, scene_from_predictions)
from model import HEADS  # noqa: E402

REPO_DIR = ML_DIR.parent
TESTS_DIR = Path(__file__).resolve().parent
BUILD_DIR = TESTS_DIR / "build"
ORDER = ["presence", "position", "distance", "color", "hazards", "people", "place", "quality"]
THRESHOLDS = [OBJECT_THRESHOLD, COLOR_THRESHOLD, HAZARD_SURE, HAZARD_MAYBE, HAZARD_NONE, PLACE_THRESHOLD, QUALITY_BAD]


def build() -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("scene_describe_host.exe" if sys.platform == "win32" else "scene_describe_host")
    src = REPO_DIR / "Hardware_ESP32" / "src"
    subprocess.run([sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17",
                    f"-I{REPO_DIR / 'Hardware_ESP32' / 'include'}", str(TESTS_DIR / "scene_describe_host_main.cpp"),
                    str(src / "scene_describe.cpp"), str(src / "scene_vocab.cpp"), "-o", str(binary)], check=True)
    return binary


def random_case(rng: np.random.Generator) -> dict:
    case = {}
    for name in ORDER:
        shape, activation = HEADS[name]
        if activation == "softmax":
            sharp = rng.choice([0.3, 1.0, 5.0])
            values = rng.dirichlet(np.full(shape[-1], sharp), size=shape[:-1] or None)
        else:
            values = rng.random(shape) ** rng.choice([0.5, 1.0, 3.0])
        values = np.asarray(values, np.float32).reshape(shape)
        # A veces, valores exactamente en un umbral (lo mas facil de hacer distinto en C++ y Python).
        if rng.random() < 0.3:
            flat = values.reshape(-1)
            idx = rng.integers(0, flat.size, size=max(1, flat.size // 4))
            flat[idx] = np.float32(rng.choice(THRESHOLDS))
        case[name] = values
    if rng.random() < 0.2:
        case["presence"][:] = 0  # sin objetos
    if rng.random() < 0.2:
        case["hazards"][:] = rng.random(case["hazards"].shape).astype(np.float32) * 0.2  # casi sin peligros
    case["hazards_trained"] = bool(rng.random() < 0.8)
    return case


def main() -> int:
    firmware_codegen.main()
    binary = build()
    rng = np.random.default_rng(0)
    cases = [random_case(rng) for _ in range(3000)]

    data = np.concatenate([np.concatenate([c[n].reshape(-1) for n in ORDER] + [np.float32([c["hazards_trained"]])])
                           for c in cases]).astype(np.float32)
    raw, out = BUILD_DIR / "scene_cases.f32", BUILD_DIR / "scene_cases.txt"
    data.tofile(raw)
    subprocess.run([str(binary), str(raw), str(len(cases)), str(out)], check=True)
    firmware = out.read_bytes().decode("utf-8").split("\n")[:-1]

    failures = 0
    for i, case in enumerate(cases):
        expected = describe(scene_from_predictions(case, case["hazards_trained"]))
        if firmware[i] != expected:
            failures += 1
            if failures <= 5:
                print(f"✗ caso {i}\n  python:   {expected}\n  firmware: {firmware[i]}")
    print(f"\n{len(cases) - failures}/{len(cases)} frases identicas")
    print("Ejemplo:", firmware[1])
    print("TODO OK: la placa arma las mismas frases que Python." if failures == 0 else f"{failures} distintas.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
