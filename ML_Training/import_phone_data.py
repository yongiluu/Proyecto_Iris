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

from PIL import Image

ML_DIR = Path(__file__).resolve().parent
PROXIMITY_LABEL = "cercania"
WAKEWORD_LABELS = {"oye_iris", "no_wake"}
WAKEWORD_DIR = ML_DIR / "data" / "wakeword_board"
PROXIMITY_DIR = ML_DIR / "data" / "proximity_board"
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
    import_photos(source, load_config("vision"), counts, skipped)
    import_proximity(source, counts, skipped)


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
        print("\nSiguiente paso: prepare_dataset.py + train.py --finetune + export_model.py (ver README)")


if __name__ == "__main__":
    main()
