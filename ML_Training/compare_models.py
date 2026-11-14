"""Compara modelos de audio int8 sobre el MISMO test (el dataset actual), con los kernels de referencia.

    python compare_models.py models/antes/audio_events_int8.tflite models/audio_events_int8.tflite

Imprime el informe de cada uno. Sirve para decidir si un reentrenamiento (ej. con grabaciones reales de la
placa o del celular) mejoro de verdad. (La wake word se compara con wakeword/export_wake.py --solo-medir;
Retina, el modelo de escenas a color, deja su informe en models/scene_report*.txt.)
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
    """Carga modulos de una carpeta (audio/, ...) que tienen nombres genericos (config, train...)."""
    for name in ("config", "features", "train", "export_model"):
        sys.modules.pop(name, None)
    sys.path.insert(0, str(ML_DIR / package))
    try:
        return {m: importlib.import_module(m) for m in modules}
    finally:
        sys.path.pop(0)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("models", nargs="+", help="uno o mas .tflite int8 del modelo de audio")
    args = parser.parse_args()

    m = load("audio", "config", "export_model", "train")
    data = np.load(m["config"].DATASET_FILE)
    for path in args.models:
        predict, _ = m["export_model"].int8_predictor(Path(path).read_bytes())
        print(m["train"].report(predict, data["x_test"], data["y_test"], f"{path} (test)") + "\n")


if __name__ == "__main__":
    main()
