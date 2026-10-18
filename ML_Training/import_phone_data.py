"""Importa al PC lo grabado con la pantalla "Misiones de datos" de la app.

    python import_phone_data.py iris_dataset_20261020_153000.zip     # el zip exportado desde la app
    python import_phone_data.py "E:/Android/data/.../files/iris_dataset"   # o la carpeta copiada por USB

Copia:
  audio/<clase>/*.wav   -> data/board/<clase>/         (lo usa audio/prepare_dataset.py)
  vision/<clase>/*.bmp  -> data/vision_board/<clase>/  como PNG (lo usa vision/prepare_dataset.py)
  audio/oye_iris|no_wake/*.wav -> data/wakeword_board/<clase>/  (wake word "Oye Iris", no es clase del
                           modelo de audio de 5 clases)
  vision/cercania/*     -> data/proximity_board/         BMP y JPEG a color tal cual (no es una clase del
                           modelo de 5 clases; los JPEG se etiquetan con vision/depth_labels.py)
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
PROXIMITY_LABEL = "cercania"
WAKEWORD_LABELS = {"oye_iris", "no_wake"}
WAKEWORD_DIR = ML_DIR / "data" / "wakeword_board"
PROXIMITY_DIR = ML_DIR / "data" / "proximity_board"


def load_config(name: str):
    spec = importlib.util.spec_from_file_location(f"{name}_config", ML_DIR / name / "config.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def import_audio(source: Path, config, counts: Counter, skipped: Counter) -> None:
    for wav in sorted(source.glob("audio/*/*.wav")):
        label = wav.parent.name
        if label in WAKEWORD_LABELS:
            target = WAKEWORD_DIR / label / wav.name
            if target.exists():
                skipped["ya importados"] += 1
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(wav, target)
            counts[f"wake word/{label}"] += 1
            continue
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


def import_proximity(source: Path, counts: Counter, skipped: Counter) -> None:
    """Mision "Acercarse a obstaculos": se copian los BMP 96x96 y, si hay, los JPEG a color."""
    for file in sorted(source.glob(f"vision/{PROXIMITY_LABEL}/*")):
        if file.suffix.lower() not in (".bmp", ".jpg"):
            continue
        target = PROXIMITY_DIR / file.name
        if target.exists():
            skipped["ya importados"] += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
        counts[f"{PROXIMITY_LABEL} ({file.suffix.lower()[1:]})"] += 1


def import_photos(source: Path, config, counts: Counter, skipped: Counter) -> None:
    for bmp in sorted(source.glob("vision/*/*.bmp")):
        label = bmp.parent.name
        if label == PROXIMITY_LABEL:
            continue  # va a data/proximity_board/ (import_proximity)
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
        import_proximity(source, counts, skipped)

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
