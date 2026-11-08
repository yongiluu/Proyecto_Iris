"""Verifica que el procesamiento del lector de texto en la placa (ocr_pipeline.cpp) sea IDENTICO a
ocr/pipeline.py: reduccion del frame, lineas encontradas, recortes de 32x256 y texto decodificado.

    python tests/test_ocr_pipeline.py
"""
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

ML_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ML_DIR / "ocr"))
import config  # noqa: E402
import firmware_codegen  # noqa: E402
import pipeline  # noqa: E402

REPO_DIR = ML_DIR.parent
TESTS_DIR = Path(__file__).resolve().parent
BUILD_DIR = TESTS_DIR / "build"


def build() -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("ocr_pipeline_host.exe" if sys.platform == "win32" else "ocr_pipeline_host")
    src = REPO_DIR / "Hardware_ESP32" / "src"
    subprocess.run([sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17",
                    f"-I{REPO_DIR / 'Hardware_ESP32' / 'include'}", str(TESTS_DIR / "ocr_pipeline_host_main.cpp"),
                    str(src / "ocr_pipeline.cpp"), str(src / "ocr_config.cpp"), "-o", str(binary)], check=True)
    return binary


def random_case(rng):
    frame = rng.integers(0, 256, (pipeline.VGA_H, pipeline.VGA_W)).astype(np.uint8)
    text_map = np.zeros((pipeline.MAP_H, pipeline.MAP_W), np.uint8)
    for _ in range(rng.integers(0, 7)):  # bloques de "texto" de distintos tamaños
        h, w = rng.integers(1, 4), rng.integers(1, 30)
        y, x = rng.integers(0, pipeline.MAP_H - h + 1), rng.integers(0, pipeline.MAP_W - w + 1)
        text_map[y:y + h, x:x + w] = rng.integers(100, 256)
    text_map[rng.random(text_map.shape) < 0.03] = 200  # celdas sueltas (ruido)
    best = rng.integers(0, config.NUM_CLASSES, config.TIME_STEPS).astype(np.uint8)
    best[rng.random(config.TIME_STEPS) < 0.5] = 0     # muchos blancos, como en la realidad
    return frame, text_map, int(rng.integers(64, 200)), best


def main() -> int:
    firmware_codegen.main()
    binary = build()
    rng = np.random.default_rng(0)
    failures = 0
    cases = 300
    for case in range(cases):
        frame, text_map, threshold, best = random_case(rng)
        out = BUILD_DIR / "ocr_case"
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir()
        frame.tofile(out / "frame.raw")
        text_map.tofile(out / "map.raw")
        best.tofile(out / "best.raw")
        subprocess.run([str(binary), str(out / "frame.raw"), str(out / "map.raw"), str(threshold),
                        str(out / "best.raw"), str(out)], check=True)

        problems = []
        if not np.array_equal(np.fromfile(out / "det.raw", np.uint8).reshape(config.DET_HEIGHT, config.DET_WIDTH),
                              pipeline.downsample2x(frame)):
            problems.append("reduccion 2x")
        boxes = pipeline.find_lines(text_map, threshold)
        expected_lines, expected_rows = [], []
        for box in boxes:
            rect = pipeline.line_pixels(box)
            pieces = pipeline.crop_line(frame, rect)
            expected_rows.append(f"{box[0]} {box[1]} {box[2]} {box[3]} | {rect[0]} {rect[1]} {rect[2]} {rect[3]} | {len(pieces)}")
            expected_lines += pieces
        if (out / "boxes.txt").read_text().splitlines() != expected_rows:
            problems.append("lineas encontradas")
        firmware_lines = np.fromfile(out / "lines.raw", np.uint8)
        python_lines = np.concatenate([p.reshape(-1) for p in expected_lines]) if expected_lines else np.zeros(0, np.uint8)
        if not np.array_equal(firmware_lines, python_lines):
            problems.append("recortes 32x256")
        if (out / "text.txt").read_bytes().decode("utf-8") != pipeline.ctc_decode(best):
            problems.append("texto decodificado")
        if problems:
            failures += 1
            if failures <= 5:
                print(f"✗ caso {case}: {', '.join(problems)}")
    print(f"{cases - failures}/{cases} casos identicos (reduccion, lineas, recortes y texto)")
    print("TODO OK: la placa procesa igual que Python." if failures == 0 else f"{failures} distintos.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
