"""Prueba el modo en vivo de la placa (Hardware_ESP32/src/scene_live.cpp): que avise solo cuando la
escena cambia de verdad (histeresis, estabilidad, pausa minima, peligros al tiro).

    python tests/test_scene_live.py
"""
import subprocess
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_DIR = TESTS_DIR.parents[1]
BUILD_DIR = TESTS_DIR / "build"


def main() -> None:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("scene_live_host.exe" if sys.platform == "win32" else "scene_live_host")
    src = REPO_DIR / "Hardware_ESP32" / "src"
    subprocess.run([sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17",
                    f"-I{REPO_DIR / 'Hardware_ESP32' / 'include'}", str(TESTS_DIR / "scene_live_host_main.cpp"),
                    str(src / "scene_live.cpp"), str(src / "scene_vocab.cpp"), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    print(result.stdout.strip())
    if result.returncode != 0:
        raise SystemExit("El modo en vivo no se comporta como se espera")
    print("Modo en vivo: avisa solo cuando la escena cambia")


if __name__ == "__main__":
    main()
