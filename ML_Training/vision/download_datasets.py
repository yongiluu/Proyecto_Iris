"""Descarga un subconjunto de Open Images V7 para el modelo de vision.

    python vision/download_datasets.py                  # ~150 MB de CSV + ~16k fotos reducidas (~400 MB en disco)
    python vision/download_datasets.py --no-train-boxes # sin el CSV de train (muy pocas escaleras/puertas)
    python vision/download_datasets.py --scale 4        # 4x mas fotos por clase (Lambda)

Que hace:
  1. Baja las cajas de validation y test de Open Images (~100 MB) y, en streaming, filtra el CSV
     de train (2,3 GB, no se guarda) quedandose solo con las fotos que tienen escaleras o puertas,
     que son raras en validation/test.
  2. Elige fotos por clase (config.MAX_IMAGES_PER_CLASS): objetos grandes, sin dibujos/juguetes.
     "nada" = fotos sin personas, vehiculos, escaleras ni puertas (ni partes de ellas).
  3. Descarga cada foto desde el bucket publico de Open Images, la pasa a grises, la reduce a
     lado corto 256 px y la guarda en data/vision_images/ (la original no se guarda).

Fuente: Open Images V7 (https://storage.googleapis.com/openimages/web/index.html).
Anotaciones CC BY 4.0; las fotos son de Flickr con licencia CC BY 2.0 (ver README).
"""
import argparse
import io
import shutil
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import numpy as np
import pandas as pd
import requests
from PIL import Image, ImageOps
from tqdm import tqdm

import config

CSV_BASE = "https://storage.googleapis.com/openimages/"
SMALL_CSVS = {
    "oidv7-class-descriptions-boxable.csv": "v7/oidv7-class-descriptions-boxable.csv",
    "validation-annotations-bbox.csv": "v5/validation-annotations-bbox.csv",
    "test-annotations-bbox.csv": "v5/test-annotations-bbox.csv",
    "validation-annotations-human-imagelabels-boxable.csv": "v5/validation-annotations-human-imagelabels-boxable.csv",
    "test-annotations-human-imagelabels-boxable.csv": "v5/test-annotations-human-imagelabels-boxable.csv",
    "validation-images-with-rotation.csv": "2018_04/validation/validation-images-with-rotation.csv",
    "test-images-with-rotation.csv": "2018_04/test/test-images-with-rotation.csv",
}
TRAIN_BOXES_URL = CSV_BASE + "v6/oidv6-train-annotations-bbox.csv"
TRAIN_FILTERED = config.RAW_DIR / "train-annotations-bbox-filtered.csv"
TRAIN_ROTATIONS_URL = CSV_BASE + "2018_04/train/train-images-boxable-with-rotation.csv"
TRAIN_ROTATIONS = config.RAW_DIR / "train-rotations-filtered.csv"
ROTATIONS_APPLIED = config.IMAGES_DIR / "rotaciones_aplicadas.txt"
IMAGE_URL = "https://open-images-dataset.s3.amazonaws.com/{folder}/{image_id}.jpg"

# Clases que se buscan en el CSV de train (en validation/test hay pocas).
TRAIN_SEARCH_CLASSES = {"escalera", "puerta"}
BOX_COLUMNS = ["ImageID", "LabelName", "XMin", "XMax", "YMin", "YMax", "IsGroupOf", "IsDepiction"]


def download_file(url: str, target, retries: int = 8) -> None:
    """Descarga reanudable: si se corta la conexion, reintenta desde donde quedo."""
    if target.exists():
        return
    partial = target.with_suffix(".part")
    for attempt in range(retries):
        done = partial.stat().st_size if partial.exists() else 0
        headers = {"Range": f"bytes={done}-"} if done else {}
        try:
            with requests.get(url, stream=True, timeout=60, headers=headers) as response:
                response.raise_for_status()
                if done and response.status_code != 206:
                    done = 0
                total = int(response.headers.get("content-length", 0)) + done
                with open(partial, "ab" if done else "wb") as file, \
                        tqdm(total=total or None, initial=done, unit="B", unit_scale=True, desc=target.name) as bar:
                    for chunk in response.iter_content(chunk_size=1 << 20):
                        file.write(chunk)
                        bar.update(len(chunk))
            partial.rename(target)
            return
        except (requests.ConnectionError, requests.exceptions.ChunkedEncodingError, requests.Timeout) as e:
            if attempt == retries - 1:
                raise
            print(f"\n⚠ Conexion cortada ({e.__class__.__name__}), reintentando en 10 s...")
            time.sleep(10)


def label_ids() -> dict:
    """Nombre de clase de Open Images -> id (/m/...)."""
    names = pd.read_csv(config.RAW_DIR / "oidv7-class-descriptions-boxable.csv", header=None, names=["id", "name"])
    return dict(zip(names.name, names.id))


def stream_train_boxes(search_classes: set) -> None:
    """Lee el CSV de train (2,3 GB) por partes, sin guardarlo, y conserva las fotos que tienen
    alguna clase buscada (con todas sus cajas relevantes, para detectar ambiguedades)."""
    if TRAIN_FILTERED.exists():
        print(f"✔ Ya existe {TRAIN_FILTERED.name}")
        return
    ids = label_ids()
    wanted = {ids[n] for n, c in config.OPENIMAGES_MAP.items() if c in search_classes}
    relevant = {ids[n] for n in config.OPENIMAGES_MAP} | {ids[n] for n in config.OPENIMAGES_AMBIGUOUS}

    partial = TRAIN_FILTERED.with_suffix(".part")
    kept_images = 0
    print("Filtrando el CSV de train de Open Images en streaming (2,3 GB, ~25 min)...")
    with requests.get(TRAIN_BOXES_URL, stream=True, timeout=60) as response:
        response.raise_for_status()
        total = int(response.headers.get("content-length", 0))
        response.raw.decode_content = True
        bar = tqdm(total=total, unit="B", unit_scale=True, desc="train bbox")

        class Counting(io.RawIOBase):
            def readable(self):
                return True

            def readinto(self, buffer):
                data = response.raw.read(len(buffer))
                buffer[:len(data)] = data
                bar.update(len(data))
                return len(data)

        reader = pd.read_csv(io.BufferedReader(Counting(), 1 << 20), usecols=BOX_COLUMNS, chunksize=500_000)
        first = True
        carry = None  # cajas de la ultima foto de la parte anterior (el CSV esta ordenado por ImageID)
        for chunk in reader:
            if carry is not None:
                chunk = pd.concat([carry, chunk])
            last_id = chunk.ImageID.iloc[-1]
            carry = chunk[chunk.ImageID == last_id]
            chunk = chunk[chunk.ImageID != last_id]
            chunk = chunk[chunk.LabelName.isin(relevant)]
            keep_ids = chunk.ImageID[chunk.LabelName.isin(wanted)].unique()
            selected = chunk[chunk.ImageID.isin(keep_ids)]
            kept_images += len(keep_ids)
            selected.to_csv(partial, mode="w" if first else "a", header=first, index=False)
            first = False
            bar.set_postfix(fotos=kept_images)
        if carry is not None:
            carry = carry[carry.LabelName.isin(relevant)]
            if carry.LabelName.isin(wanted).any():
                carry.to_csv(partial, mode="a", header=first, index=False)
        bar.close()
    partial.rename(TRAIN_FILTERED)
    print(f"✔ {kept_images} fotos de train con {sorted(search_classes)}")


def stream_train_rotations() -> None:
    """Del CSV de rotaciones de train (640 MB, se borra al terminar) se queda con las fotos ya filtradas."""
    if TRAIN_ROTATIONS.exists() or not TRAIN_FILTERED.exists():
        return
    wanted = set(pd.read_csv(TRAIN_FILTERED, usecols=["ImageID"]).ImageID)
    full = config.RAW_DIR / "train-images-boxable-with-rotation.csv"
    download_file(TRAIN_ROTATIONS_URL, full)
    kept = [chunk[chunk.ImageID.isin(wanted) & chunk.Rotation.fillna(0).ne(0)]
            for chunk in pd.read_csv(full, usecols=["ImageID", "Rotation"], chunksize=500_000)]
    pd.concat(kept).to_csv(TRAIN_ROTATIONS, index=False)
    full.unlink()


def load_rotations() -> dict:
    """ImageID -> grados a girar en sentido antihorario (PIL) para dejar la foto derecha.
    Las cajas de Open Images estan anotadas sobre la foto ya girada."""
    frames = [pd.read_csv(config.RAW_DIR / name, usecols=["ImageID", "Rotation"])
              for name in ("validation-images-with-rotation.csv", "test-images-with-rotation.csv",
                           TRAIN_ROTATIONS.name) if (config.RAW_DIR / name).exists()]
    if not frames:
        return {}
    rotations = pd.concat(frames)
    rotations = rotations[rotations.Rotation.fillna(0).ne(0)]
    return dict(zip(rotations.ImageID, rotations.Rotation.astype(int)))


def fix_existing_rotations(rotations: dict) -> None:
    """Gira las fotos que se bajaron antes de corregir la rotacion (una sola vez cada una)."""
    if not config.IMAGES_DIR.exists():
        return
    done = set(ROTATIONS_APPLIED.read_text().split()) if ROTATIONS_APPLIED.exists() else set()
    fixed = []
    for image_id, angle in rotations.items():
        path = config.IMAGES_DIR / f"{image_id}.jpg"
        if image_id in done or not path.exists():
            continue
        Image.open(path).rotate(angle, expand=True).save(path, format="JPEG", quality=92)
        fixed.append(image_id)
    if fixed:
        with open(ROTATIONS_APPLIED, "a") as file:
            file.write("\n".join(fixed) + "\n")
        print(f"✔ {len(fixed)} fotos ya descargadas giradas a su orientacion correcta")


def load_boxes() -> pd.DataFrame:
    """Todas las cajas relevantes con su clase de Iris (o 'ambigua'), su carpeta en el bucket y area."""
    ids = label_ids()
    to_class = {ids[n]: c for n, c in config.OPENIMAGES_MAP.items()}
    to_class.update({ids[n]: "ambigua" for n in config.OPENIMAGES_AMBIGUOUS})

    frames = []
    for folder, name in (("validation", "validation-annotations-bbox.csv"), ("test", "test-annotations-bbox.csv"),
                         ("train", TRAIN_FILTERED.name)):
        path = config.RAW_DIR / name
        if not path.exists():
            continue
        boxes = pd.read_csv(path, usecols=BOX_COLUMNS)
        boxes = boxes[boxes.LabelName.isin(to_class)]
        boxes["folder"] = folder
        frames.append(boxes)
    boxes = pd.concat(frames, ignore_index=True)
    boxes["cls"] = boxes.LabelName.map(to_class)
    boxes["area"] = (boxes.XMax - boxes.XMin) * (boxes.YMax - boxes.YMin)
    return boxes


def all_images(folder: str) -> pd.DataFrame:
    """Fotos de validation/test con sus etiquetas verificadas por personas (para elegir 'nada')."""
    labels = pd.read_csv(config.RAW_DIR / f"{folder}-annotations-human-imagelabels-boxable.csv")
    labels["folder"] = folder
    return labels


def select_images(scale: float) -> pd.DataFrame:
    rng = np.random.default_rng(config.SEED)
    boxes = load_boxes()
    # Dibujos, juguetes o carteles no sirven: se descarta la foto entera si el objeto es una representacion.
    depiction_ids = set(boxes.ImageID[(boxes.IsDepiction == 1) & (boxes.cls != "ambigua")])
    real = boxes[~boxes.ImageID.isin(depiction_ids)]

    rows = []
    for cls in config.CLASSES:
        if cls == "nada":
            continue
        big = real[(real.cls == cls) & (real.area >= config.MIN_COVERAGE[cls] * 0.5)]
        candidates = big.drop_duplicates("ImageID")[["ImageID", "folder"]]
        limit = int(config.MAX_IMAGES_PER_CLASS[cls] * scale)
        candidates = _sample(candidates, limit, rng)
        print(f"  {cls:9s} {len(candidates):5d} fotos (de {big.ImageID.nunique()} candidatas)")
        rows.append(candidates.assign(cls=cls))

    # "nada": fotos de validation/test sin ninguna clase relevante, ni en cajas ni en etiquetas verificadas.
    ids = label_ids()
    relevant = {ids[n] for n in config.OPENIMAGES_MAP} | {ids[n] for n in config.OPENIMAGES_AMBIGUOUS}
    labels = pd.concat([all_images("validation"), all_images("test")], ignore_index=True)
    dirty = set(labels.ImageID[labels.LabelName.isin(relevant) & (labels.Confidence > 0)]) | set(boxes.ImageID)
    clean = labels[~labels.ImageID.isin(dirty)].drop_duplicates("ImageID")[["ImageID", "folder"]]
    limit = int(config.MAX_IMAGES_PER_CLASS["nada"] * scale)
    clean = _sample(clean, limit, rng)
    print(f"  {'nada':9s} {len(clean):5d} fotos")
    rows.append(clean.assign(cls="nada"))

    selection = pd.concat(rows, ignore_index=True)
    selection.to_csv(config.SELECTION_FILE, index=False)
    return selection


def _sample(candidates: pd.DataFrame, limit: int, rng) -> pd.DataFrame:
    """Muestra al azar, prefiriendo las fotos ya descargadas (no repetir descargas al subir el limite)."""
    shuffled = candidates.iloc[rng.permutation(len(candidates))]
    have = shuffled.ImageID.map(lambda i: (config.IMAGES_DIR / f"{i}.jpg").exists())
    return pd.concat([shuffled[have], shuffled[~have]]).iloc[:limit]


def fetch_image(image_id: str, folder: str, rotation: int = 0) -> str:
    target = config.IMAGES_DIR / f"{image_id}.jpg"
    if target.exists():
        return "ok"
    try:
        response = requests.get(IMAGE_URL.format(folder=folder, image_id=image_id), timeout=60)
        if response.status_code != 200:
            return "missing"
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(response.content))).convert("L")
        if rotation:
            image = image.rotate(rotation, expand=True)
        scale = config.STORE_SHORT_SIDE / min(image.size)
        if scale < 1:
            image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        partial = target.with_suffix(".part")
        image.save(partial, format="JPEG", quality=92)
        partial.replace(target)
        return "ok"
    except Exception:  # noqa: BLE001 - una foto mala no debe cortar la descarga
        return "error"


def download_images(selection: pd.DataFrame, workers: int, rotations: dict) -> None:
    config.IMAGES_DIR.mkdir(parents=True, exist_ok=True)
    unique = selection.drop_duplicates("ImageID")
    results = {"ok": 0, "missing": 0, "error": 0}
    new_rotated = [r.ImageID for r in unique.itertuples()
                   if r.ImageID in rotations and not (config.IMAGES_DIR / f"{r.ImageID}.jpg").exists()]
    with ThreadPoolExecutor(workers) as pool:
        futures = [pool.submit(fetch_image, r.ImageID, r.folder, rotations.get(r.ImageID, 0))
                   for r in unique.itertuples()]
        for future in tqdm(as_completed(futures), total=len(futures), desc="fotos", unit="foto"):
            results[future.result()] += 1
    print(f"Fotos: {results}")
    if new_rotated:  # ya quedaron derechas al bajarlas: no volver a girarlas
        with open(ROTATIONS_APPLIED, "a") as file:
            file.write("\n".join(new_rotated) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-train-boxes", action="store_true", help="no filtrar el CSV de train (2,3 GB de descarga)")
    parser.add_argument("--scale", type=float, default=1.0, help="multiplica MAX_IMAGES_PER_CLASS (ej. 4 en Lambda)")
    parser.add_argument("--workers", type=int, default=32, help="descargas en paralelo")
    parser.add_argument("--csv-only", action="store_true", help="solo bajar/filtrar los CSV")
    parser.add_argument("--skip-train-rotations", action="store_true",
                        help="no bajar el CSV de rotaciones de train (640 MB; corrige ~1%% de esas fotos)")
    args = parser.parse_args()

    config.RAW_DIR.mkdir(parents=True, exist_ok=True)
    for name, path in SMALL_CSVS.items():
        download_file(CSV_BASE + path, config.RAW_DIR / name)
    if not args.no_train_boxes:
        stream_train_boxes(TRAIN_SEARCH_CLASSES)
        if not args.skip_train_rotations:
            stream_train_rotations()
    rotations = load_rotations()
    fix_existing_rotations(rotations)
    if args.csv_only:
        return

    print("Eligiendo fotos:")
    selection = select_images(args.scale)
    download_images(selection, args.workers, rotations)

    free_gb = shutil.disk_usage(config.DATA_DIR).free / 1e9
    print(f"\nListo. Espacio libre en disco: {free_gb:.1f} GB")
    print("Siguiente paso: python vision/prepare_dataset.py")


if __name__ == "__main__":
    main()
