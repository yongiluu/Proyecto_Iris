"""Importa al PC lo grabado con la pantalla "Misiones de datos" de la app.

    python import_phone_data.py iris_dataset_20261020_153000.zip     # el zip exportado desde la app
    python import_phone_data.py "E:/Android/data/.../files/iris_dataset"   # o la carpeta copiada por USB
    python import_phone_data.py --supabase      # o lo que la app subio a Supabase (con consentimiento)

--supabase baja el bucket privado 'datos-entrenamiento' segun la tabla training_uploads. Necesita las
variables de entorno SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY (la clave de servicio: NUNCA en el repo
ni en la app). Lo bajado queda en data/supabase_cache/<user_id>/{audio,vision}/<clase>/ (misma forma
que el zip) y en cada corrida solo se descargan los archivos nuevos.

Copia:
  audio/<clase>/*.wav   -> data/board/<clase>/         (lo usa audio/prepare_dataset.py)
  audio/oye_iris|no_wake/*.wav -> data/wakeword_board/<clase>/  (wake word "Oye Iris", no es clase del
                           modelo de audio de 5 clases)
  vision/<mision>/*.png|*.bmp -> data/scene_board/      fotos a color 160x120 de la camara de la placa, como
                           PNG (la carpeta BOARD_IMAGES_DIR de Retina, scene/config.py). Las que no son a
                           color 160x120 (ej. los BMP 96x96 en grises de versiones antiguas de la app) se
                           saltan con un aviso.
Los archivos ya importados se saltan, asi que se puede correr varias veces con exports nuevos.
El ambiente (casa, calle, transporte...) queda en el nombre: <clase>__<ambiente>__<mision>__<fecha>.

Despues:
    python audio/prepare_dataset.py && python audio/train.py --finetune && python audio/export_model.py
    Fotos: las etiqueta el profesor de Retina (scene/label_teacher.py, fuente "board"; ver scene/README.md).
"""
import argparse
import importlib.util
import json
import os
import shutil
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import wave
import zipfile
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image

ML_DIR = Path(__file__).resolve().parent
WAKEWORD_LABELS = {"oye_iris", "no_wake"}
WAKEWORD_DIR = ML_DIR / "data" / "wakeword_board"
PHOTO_SIZE = (160, 120)  # ancho x alto del frame a color de la camara de la placa (lo que ve Retina)
PHOTO_SUFFIXES = (".png", ".bmp")
SUPABASE_CACHE = ML_DIR / "data" / "supabase_cache"
SUPABASE_BUCKET = "datos-entrenamiento"


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


def _color_photo(path: Path):
    """(foto RGB 160x120, "") o (None, motivo) si no sirve para Retina."""
    with Image.open(path) as image:
        if image.size != PHOTO_SIZE:
            return None, f"tamano {image.size[0]}x{image.size[1]}, se espera {PHOTO_SIZE[0]}x{PHOTO_SIZE[1]}"
        if image.mode not in ("RGB", "RGBA", "P"):
            return None, f"en grises (modo {image.mode})"
        rgb = image.convert("RGB")
    pixels = np.asarray(rgb)
    if np.array_equal(pixels[..., 0], pixels[..., 1]) and np.array_equal(pixels[..., 1], pixels[..., 2]):
        return None, "en grises (los 3 canales iguales)"
    return rgb, ""


def import_photos(source: Path, scene_config, counts: Counter, skipped: Counter) -> None:
    """Fotos de las misiones (vision/<mision>/): a color 160x120 -> data/scene_board/ para Retina."""
    board_dir = scene_config.BOARD_IMAGES_DIR
    for file in sorted(source.glob("vision/*/*")):
        label = file.parent.name
        if file.suffix.lower() not in PHOTO_SUFFIXES:
            skipped[f"vision/{label}/*{file.suffix.lower()} (formato no soportado)"] += 1
            continue
        name = file.stem if file.stem.startswith(label) else f"{label}__{file.stem}"
        target = board_dir / (name + ".png")
        if target.exists():
            skipped["ya importados"] += 1
            continue
        image, reason = _color_photo(file)
        if image is None:
            print(f"  - se salta {file.name}: {reason} (no es una foto a color 160x120)")
            skipped[f"vision/{label} (no es color 160x120)"] += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target)
        counts[f"fotos a color/{label}"] += 1


def _supabase_get(url: str, key: str) -> bytes:
    request = urllib.request.Request(url, headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def download_supabase() -> list[Path]:
    """Baja a data/supabase_cache/ lo registrado en training_uploads. Devuelve una carpeta por persona,
    con la misma estructura que el zip (audio/<clase>/ y vision/<clase>/)."""
    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not base or not key:
        raise SystemExit("Faltan SUPABASE_URL y/o SUPABASE_SERVICE_ROLE_KEY en las variables de entorno.")

    rows, page = [], 1000
    while True:
        query = urllib.parse.urlencode(
            {"select": "id,kind,label,storage_path", "order": "id.asc", "limit": page, "offset": len(rows)})
        batch = json.loads(_supabase_get(f"{base}/rest/v1/training_uploads?{query}", key))
        rows.extend(batch)
        if len(batch) < page:
            break

    users, new, missing = set(), 0, 0
    for row in rows:
        parts = row["storage_path"].split("/")  # <user_id>/<clase>/<archivo>
        if len(parts) != 3 or any(p in ("", ".", "..") or "\\" in p for p in parts):
            print(f"  - ruta rara, se salta: {row['storage_path']}")
            continue
        user_id, label, name = parts
        folder = "audio" if row["kind"] == "audio" else "vision"
        target = SUPABASE_CACHE / user_id / folder / label / name
        users.add(SUPABASE_CACHE / user_id)
        if target.exists():
            continue
        url = f"{base}/storage/v1/object/{SUPABASE_BUCKET}/{urllib.parse.quote(row['storage_path'])}"
        try:
            data = _supabase_get(url, key)
        except urllib.error.HTTPError as e:
            if e.code in (400, 404):  # registrado, pero ya no esta en el bucket
                missing += 1
                continue
            raise
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".part")
        partial.write_bytes(data)
        partial.replace(target)
        new += 1

    extra = f", {missing} ya no estaban en el bucket" if missing else ""
    print(f"Supabase: {len(rows)} registros, {new} archivos nuevos bajados{extra} -> {SUPABASE_CACHE}")
    return sorted(users)


def import_folder(source: Path, counts: Counter, skipped: Counter) -> None:
    import_audio(source, load_config("audio"), counts, skipped)
    import_photos(source, load_config("scene"), counts, skipped)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", nargs="?", help="zip exportado por la app o carpeta iris_dataset")
    parser.add_argument("--supabase", action="store_true",
                        help="bajar lo que la app subio a Supabase (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY)")
    args = parser.parse_args()
    if not args.source and not args.supabase:
        parser.error("indica un zip o carpeta, o usa --supabase")

    counts, skipped = Counter(), Counter()
    if args.supabase:
        for folder in download_supabase():
            import_folder(folder, counts, skipped)

    if args.source:
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
            import_folder(source, counts, skipped)

    for key, n in sorted(counts.items()):
        print(f"  ✔ {key}: {n}")
    for key, n in sorted(skipped.items()):
        print(f"  - saltados {key}: {n}")
    if not counts:
        print("No habia nada nuevo para importar.")
    else:
        print("\nSiguiente paso: audio -> prepare_dataset.py + train.py --finetune + export_model.py;"
              " fotos -> scene/label_teacher.py (ver scene/README.md)")


if __name__ == "__main__":
    main()
