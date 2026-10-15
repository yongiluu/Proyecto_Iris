"""Verifica que el front-end C++ del firmware de el mismo resultado que features.py.

    python tests/test_frontend.py

Compila Hardware_ESP32/src/audio_frontend.cpp para el PC (con el compilador de `ziglang`,
pip install ziglang), le pasa señales de prueba y compara frame a frame.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "audio"))
import config  # noqa: E402
from features import log_mel  # noqa: E402

TESTS_DIR = Path(__file__).resolve().parent
BUILD_DIR = TESTS_DIR / "build"
TOLERANCE = 2e-3  # en unidades de ln(); float32 vs float64


def build_host_binary() -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("frontend_host.exe" if sys.platform == "win32" else "frontend_host")
    sources = [
        TESTS_DIR / "frontend_host_main.cpp",
        config.FIRMWARE_SRC / "audio_frontend.cpp",
        config.FIRMWARE_SRC / "audio_frontend_tables.cpp",
    ]
    command = [sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17",
               f"-I{config.FIRMWARE_INCLUDE}", *map(str, sources), "-o", str(binary)]
    subprocess.run(command, check=True)
    return binary


def test_signals(rng: np.random.Generator) -> dict:
    t = np.arange(config.SAMPLE_RATE * 2) / config.SAMPLE_RATE
    chirp = 12000 * np.sin(2 * np.pi * (100 + 1900 * t) * t)
    return {
        "silencio": np.zeros(config.SAMPLE_RATE),
        "ruido_suave": rng.normal(0, 30, config.SAMPLE_RATE),
        "chirp": chirp,
        "ruido_fuerte_saturado": np.clip(rng.normal(0, 20000, config.SAMPLE_RATE), -32768, 32767),
        "tono_1khz_con_ruido": 8000 * np.sin(2 * np.pi * 1000 * t[:12345]) + rng.normal(0, 500, 12345),
    }


def main() -> int:
    binary = build_host_binary()
    rng = np.random.default_rng(0)
    failures = 0

    for name, signal in test_signals(rng).items():
        pcm = np.round(signal).astype(np.int16)
        raw_path = BUILD_DIR / f"{name}.raw"
        out_path = BUILD_DIR / f"{name}.f32"
        pcm.tofile(raw_path)
        subprocess.run([str(binary), str(raw_path), str(out_path)], check=True)

        firmware = np.fromfile(out_path, dtype=np.float32).reshape(-1, config.NUM_MEL)
        reference = log_mel(pcm)
        if firmware.shape != reference.shape:
            print(f"✗ {name}: forma distinta firmware={firmware.shape} python={reference.shape}")
            failures += 1
            continue

        max_diff = float(np.max(np.abs(firmware - reference))) if len(reference) else 0.0
        ok = max_diff <= TOLERANCE
        failures += not ok
        print(f"{'✔' if ok else '✗'} {name:24s} frames={len(reference):3d}  max|dif|={max_diff:.2e}")

    print("\nTODO OK: el firmware calcula las mismas features que el entrenamiento." if failures == 0
          else f"\n{failures} prueba(s) fallaron.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
