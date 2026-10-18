"""Compara dos modelos int8 sobre el MISMO test (el dataset actual), con los kernels de referencia.

    python compare_models.py vision    models/antes/vision_scenes_int8.tflite models/vision_scenes_int8.tflite
    python compare_models.py audio     models/antes/audio_events_int8.tflite  models/audio_events_int8.tflite
    python compare_models.py proximity models/antes/proximity_int8.tflite     models/proximity_int8.tflite

Imprime el informe de cada uno (test limpio y, en vision/cercania, con simulacion de la OV2640). Sirve para
decidir si un reentrenamiento (ej. con fotos reales de la placa o del celular) mejoro de verdad.
Si el modelo anterior tiene menos clases (ej. vision v4 sin "cruce"), solo se comparan las que conoce.
"""
import argparse
import importlib
import os
import sys
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

import numpy as np

ML_DIR = Path(__file__).resolve().parent


def load(package: str, *modules: str) -> dict:
    """audio/ y vision/ tienen modulos con el mismo nombre (config, train...): se cargan por separado."""
    for name in ("config", "features", "train", "export_model", "augment", "proximity_train", "depth_labels"):
        sys.modules.pop(name, None)
    sys.path.insert(0, str(ML_DIR / package))
    try:
        return {m: importlib.import_module(m) for m in modules}
    finally:
        sys.path.pop(0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kind", choices=["vision", "audio", "proximity"])
    parser.add_argument("models", nargs="+", help="uno o mas .tflite int8")
    args = parser.parse_args()

    if args.kind == "audio":
        m = load("audio", "config", "export_model", "train")
        data = np.load(m["config"].DATASET_FILE)
        for path in args.models:
            predict, _ = m["export_model"].int8_predictor(Path(path).read_bytes())
            print(m["train"].report(predict, data["x_test"], data["y_test"], f"{path} (test)") + "\n")
        return

    m = load("vision", "config", "export_model", "train", "proximity_train")
    cfg = m["config"]
    data = np.load(cfg.PROXIMITY_DATASET_FILE if args.kind == "proximity" else cfg.DATASET_FILE)
    for path in args.models:
        predict, _ = m["export_model"].int8_predictor(Path(path).read_bytes())
        for split, title in (("x_test", "test limpio"), ("x_test_cam", "simulacion OV2640")):
            probs = predict(data[split])
            y = data["y_test"]
            if args.kind == "proximity":
                print(m["proximity_train"].report(probs, y, f"{path} ({title})") + "\n")
                continue
            if probs.shape[1] < len(cfg.CLASSES):  # modelo anterior con menos clases
                known = y < probs.shape[1]
                print(f"(modelo con {probs.shape[1]} clases: se omiten {np.sum(~known)} ejemplos de clases nuevas)")
                probs, y = probs[known], y[known]
                pad = np.zeros((len(probs), len(cfg.CLASSES) - probs.shape[1]), np.float32)
                probs = np.concatenate([probs, pad], axis=1)
            print(m["train"].report(lambda _: probs, data[split][:len(y)], y, f"{path} ({title})") + "\n")


if __name__ == "__main__":
    main()
