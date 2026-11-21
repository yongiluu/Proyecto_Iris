"""Verifica que la conversion de imagen del firmware (color RGB565 -> grises 96x96 y -> RGB888) de
EXACTAMENTE lo mismo que la referencia de Python (camara/board_image.py).

    python tests/test_image_convert.py

Compila Hardware_ESP32/src/image_convert.cpp para el PC con el compilador de `ziglang`.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np

ML_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ML_DIR / "camara"))
from board_image import (MOUNT_TRANSVERSE, MOUNT_UPRIGHT, pack_rgb565, rgb565_to_gray96,  # noqa: E402
                         unpack_rgb565, upright)

REPO_DIR = ML_DIR.parent
INCLUDE = REPO_DIR / "Hardware_ESP32" / "include"
SRC = REPO_DIR / "Hardware_ESP32" / "src"
TESTS_DIR = Path(__file__).resolve().parent
BUILD_DIR = TESTS_DIR / "build"


def build_host_binary() -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("image_convert_host.exe" if sys.platform == "win32" else "image_convert_host")
    command = [sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17", f"-I{INCLUDE}",
               str(TESTS_DIR / "image_convert_host_main.cpp"), str(SRC / "image_convert.cpp"), "-o", str(binary)]
    subprocess.run(command, check=True)
    return binary


def test_images(rng: np.random.Generator) -> dict:
    yy, xx = np.mgrid[0:120, 0:160]
    gradient = np.stack([xx * 255 // 159, yy * 255 // 119, (xx + yy) * 255 // 278], axis=-1)
    return {
        "aleatoria_160x120": rng.integers(0, 256, (120, 160, 3)),
        "degradado_160x120": gradient,
        "negra_160x120": np.zeros((120, 160, 3)),
        "blanca_160x120": np.full((120, 160, 3), 255),
        "aleatoria_96x96": rng.integers(0, 256, (96, 96, 3)),      # sin recorte ni escala
        "vertical_120x160": rng.integers(0, 256, (160, 120, 3)),   # mas alta que ancha
        "aleatoria_320x240": rng.integers(0, 256, (240, 320, 3)),  # QVGA, por si se cambia el tamaño
    }


def main() -> int:
    binary = build_host_binary()
    rng = np.random.default_rng(0)
    failures = 0
    for name, image in test_images(rng).items():
        image = image.astype(np.uint8)
        height, width = image.shape[:2]
        data = pack_rgb565(image)
        raw = BUILD_DIR / f"{name}.rgb565"
        out_gray, out_rgb = BUILD_DIR / f"{name}.gray", BUILD_DIR / f"{name}.rgb"
        raw.write_bytes(data)
        subprocess.run([str(binary), str(raw), str(width), str(height), str(out_gray), str(out_rgb)], check=True)

        firmware_gray = np.fromfile(out_gray, np.uint8).reshape(96, 96)
        firmware_rgb = np.fromfile(out_rgb, np.uint8).reshape(height, width, 3)
        gray_diff = int(np.abs(firmware_gray.astype(int) - rgb565_to_gray96(data, width, height)).max())
        rgb_diff = int(np.abs(firmware_rgb.astype(int) - unpack_rgb565(data, width, height)).max())
        ok = gray_diff == 0 and rgb_diff == 0
        failures += not ok
        print(f"{'✔' if ok else '✗'} {name:20s} max|dif| grises={gray_diff} rgb={rgb_diff}")

    # Imagen derecha (camara de lado en los lentes): grises para el lector y RGB565 -> RGB888 para Retina.
    cases = [("vga_lector", 640, 480, "gray", MOUNT_TRANSVERSE, 640, 480),
             ("xga_lector", 1024, 768, "gray", MOUNT_TRANSVERSE, 640, 480),
             ("qvga_retina", 320, 240, "rgb565", MOUNT_TRANSVERSE, 160, 120),
             ("qqvga_derecha", 160, 120, "rgb565", MOUNT_UPRIGHT, 160, 120),
             ("qvga_derecha", 320, 240, "gray", MOUNT_UPRIGHT, 160, 120),
             ("uxga_lector_zoom", 1600, 1200, "gray", MOUNT_TRANSVERSE, 640, 480, 640)]
    for name, sw, sh, kind, mount, dw, dh, *zoom in cases:
        zoom = zoom[0] if zoom else 0
        if kind == "gray":
            image = rng.integers(0, 256, (sh, sw), dtype=np.uint8)
            data, expected = image.tobytes(), upright(image, mount, dw, dh, zoom)
        else:
            rgb = rng.integers(0, 256, (sh, sw, 3), dtype=np.uint8)
            data = pack_rgb565(rgb)
            expected = upright(unpack_rgb565(data, sw, sh), mount, dw, dh)
        raw, out = BUILD_DIR / f"{name}.in", BUILD_DIR / f"{name}.out"
        raw.write_bytes(data)
        subprocess.run([str(binary), "upright", str(raw), str(sw), str(sh), kind, str(mount), str(dw), str(dh),
                        str(out), str(zoom)], check=True)
        got = np.fromfile(out, np.uint8).reshape(expected.shape)
        diff = int(np.abs(got.astype(int) - expected.astype(int)).max())
        failures += diff != 0
        print(f"{'✔' if diff == 0 else '✗'} {name:20s} derecha {sw}x{sh} -> {dw}x{dh} max|dif|={diff}")

    print("\nTODO OK: la placa convierte la imagen igual que el entrenamiento." if failures == 0
          else f"\n{failures} prueba(s) fallaron.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
