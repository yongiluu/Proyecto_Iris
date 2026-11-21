"""Prueba rapida de los datos sinteticos del OCR (sin entrenar nada, ~20 s):
fuentes con ñ, camara, lineas de 32x256, escenas del detector y generacion que se retoma.

    python tests/test_ocr_synth.py

Usa una carpeta temporal (IRIS_OCR_DATA_DIR) para no tocar data/ocr.
"""
import os
import random
import sys
import tempfile
from pathlib import Path

import numpy as np

ML_DIR = Path(__file__).resolve().parents[1]
TMP = tempfile.mkdtemp(prefix="iris_ocr_test_")
os.environ["IRIS_OCR_DATA_DIR"] = TMP
os.environ["IRIS_OCR_WORK_DIR"] = TMP
sys.path.insert(0, str(ML_DIR / "ocr"))
import camera  # noqa: E402
import config  # noqa: E402
import synth  # noqa: E402


def main() -> int:
    problems = []
    fonts = synth.load_fonts()
    print(f"Fuentes usables: {len(fonts)}")
    if not fonts:
        problems.append("sin fuentes")

    rng, np_rng = random.Random(0), np.random.default_rng(0)
    frame = np.full((480, 640), 200, np.float32)
    frame[200:220, 100:400] = 150
    for clean in (False, True):
        out = camera.degrade(frame, rng, np_rng, clean=clean)
        if out.shape != frame.shape or out.dtype != np.uint8:
            problems.append(f"camara (clean={clean}) devuelve {out.shape} {out.dtype}")

    renderer = synth.Renderer(3)
    for _ in range(50):
        line, text = renderer.sample()
        if line.shape != (config.LINE_HEIGHT, config.LINE_WIDTH) or line.dtype != np.uint8:
            problems.append(f"linea {line.shape}")
            break
        if not text or len(text) > config.MAX_TEXT_LENGTH or any(c not in config.CHAR_TO_INDEX for c in text):
            problems.append(f"texto invalido {text!r}")
            break

    # Generacion por tandas: la segunda vez no rehace nada
    calls = []

    def worker(args):
        index, seed, count = args
        calls.append(index)
        return index, np.full((count, 4, 4), index, np.uint8), {"n": np.arange(count)}

    import multiprocessing.pool
    real_pool = synth.Pool
    synth.Pool = lambda workers: multiprocessing.pool.ThreadPool(workers)   # sin procesos: worker local
    try:
        finished = []
        synth.build_resumable("prueba", 25, 1, 10, (4, 4), worker, 2, lambda parts: finished.append(len(parts)))
        first = len(calls)
        synth.build_resumable("prueba", 25, 1, 10, (4, 4), worker, 2, lambda parts: finished.append(len(parts)))
        images = np.load(Path(TMP) / "prueba_images.npy")
        if first != 3 or len(calls) != 3 or finished != [3] or images[24, 0, 0] != 2:
            problems.append(f"retomar: tandas {calls}, final {finished}")
    finally:
        synth.Pool = real_pool

    if (config.DATA_DIR / "fondos_sin_texto.txt").exists() or (ML_DIR / "data" / "ocr" / "fondos_sin_texto.txt").exists():
        try:
            import detector
            if not (config.DATA_DIR / "fondos_sin_texto.txt").exists():
                # usar la lista del PC (solo lectura)
                (config.DATA_DIR / "fondos_sin_texto.txt").write_text(
                    (ML_DIR / "data" / "ocr" / "fondos_sin_texto.txt").read_text(encoding="utf-8"), encoding="utf-8")
            image, target = detector.SceneMaker(1).scene()
            if image.shape != (config.DET_HEIGHT, config.DET_WIDTH) or target.shape != (detector.MH, detector.MW):
                problems.append(f"escena {image.shape} {target.shape}")
        except SystemExit as error:
            print(f"(escena del detector no probada: {error})")

    print("TODO OK: datos sinteticos del OCR." if not problems else "PROBLEMAS: " + "; ".join(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
