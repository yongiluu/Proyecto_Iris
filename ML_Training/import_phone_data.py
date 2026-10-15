"""Importa al PC lo grabado con la pantalla "Misiones de datos" de la app.

    python import_phone_data.py iris_dataset_20261020_153000.zip     # el zip exportado desde la app
    python import_phone_data.py "E:/Android/data/.../files/iris_dataset"   # o la carpeta copiada por USB

Copia:
  audio/<clase>/*.wav   -> data/board/<clase>/         (lo usa audio/prepare_dataset.py)
  vision/<clase>/*.bmp  -> data/vision_board/<clase>/  como PNG (lo usa vision/prepare_dataset.py)
Los archivos ya importados se saltan, asi que se puede correr varias veces con exports nuevos.
El ambiente (casa, calle, transporte...) queda en el nombre: <clase>__<ambiente>__<mision>__<fecha>.

Despues:
    python audio/prepare_dataset.py && python audio/train.py --finetune && python audio/export_model.py
    python vision/prepare_dataset.py && python vision/train.py --finetune && python vision/export_model.py
"""
import argparse
import importlib.util
import shutil
import tempfile
import wave
import zipfile
from collections import Counter
from pathlib import Path

from PIL import Image

ML_DIR = Path(__file__).resolve().parent


def load_config(name: str):
    spec = importlib.util.spec_from_file_location(f"{name}_config", ML_DIR / name / "config.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def import_audio(source: Path, config, counts: Counter, skipped: Counter) -> None:
    for wav in sorted(source.glob("audio/*/*.wav")):
        label = wav.parent.name
        if label not in config.CLASSES:
            skipped[f"audio/{label} (clase desconocida)"] += 1
            continue
        with wave.open(str(wav)) as w:
            if w.getframerate() != config.SAMPLE_RATE or w.getsampwidth() != 2 or w.getnchannels() != 1:
                skipped[f"{wav.name} (formato)"] += 1
                continue
        target = config.BOARD_DIR / label / wav.name
        if target.exists():
            skipped["ya importados"] += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(wav, target)
        counts[f"audio/{label}"] += 1


def import_photos(source: Path, config, counts: Counter, skipped: Counter) -> None:
    for bmp in sorted(source.glob("vision/*/*.bmp")):
        label = bmp.parent.name
        if label not in config.CLASSES:
            skipped[f"vision/{label} (clase desconocida)"] += 1
            continue
        target = config.BOARD_DIR / label / (bmp.stem + ".png")
        if target.exists():
            skipped["ya importados"] += 1
            continue
        image = Image.open(bmp).convert("L")
        if image.size != (config.IMAGE_SIZE, config.IMAGE_SIZE):
            skipped[f"{bmp.name} (tamano {image.size})"] += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target)
        counts[f"vision/{label}"] += 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", help="zip exportado por la app o carpeta iris_dataset")
    args = parser.parse_args()

    source = Path(args.source)
    with tempfile.TemporaryDirectory() as temp:
        if source.suffix.lower() == ".zip":
            with zipfile.ZipFile(source) as zf:
                zf.extractall(temp)
            source = Path(temp)
        if not (source / "audio").exists() and not (source / "vision").exists():
            nested = next(source.glob("*/audio"), None) or next(source.glob("*/vision"), None)
            if nested is None:
                raise SystemExit(f"No encontre carpetas audio/ ni vision/ en {args.source}")
            source = nested.parent

        counts, skipped = Counter(), Counter()
        import_audio(source, load_config("audio"), counts, skipped)
        import_photos(source, load_config("vision"), counts, skipped)

    for key, n in sorted(counts.items()):
        print(f"  ✔ {key}: {n}")
    for key, n in sorted(skipped.items()):
        print(f"  - saltados {key}: {n}")
    if not counts:
        print("No habia nada nuevo para importar.")
    else:
        print("\nSiguiente paso: prepare_dataset.py + train.py --finetune + export_model.py (ver README)")


if __name__ == "__main__":
    main()
