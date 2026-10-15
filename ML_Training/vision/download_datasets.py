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
}
TRAIN_BOXES_URL = CSV_BASE + "v6/oidv6-train-annotations-bbox.csv"
TRAIN_FILTERED = config.RAW_DIR / "train-annotations-bbox-filtered.csv"
IMAGE_URL = "https://open-images-dataset.s3.amazonaws.com/{folder}/{image_id}.jpg"

# Clases que se buscan en el CSV de train (en validation/test hay pocas).
TRAIN_SEARCH_CLASSES = {"escalera", "puerta"}
BOX_COLUMNS = ["ImageID", "LabelName", "XMin", "XMax", "YMin", "YMax", "IsGroupOf", "IsDepiction"]


def download_file(url: str, target) -> None:
    if target.exists():
        return
    partial = target.with_suffix(".part")
    with requests.get(url, stream=True, timeout=60) as response:
        response.raise_for_status()
        total = int(response.headers.get("content-length", 0))
        with open(partial, "wb") as file, tqdm(total=total or None, unit="B", unit_scale=True, desc=target.name) as bar:
            for chunk in response.iter_content(chunk_size=1 << 20):
                file.write(chunk)
                bar.update(len(chunk))
    partial.rename(target)


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
        if len(candidates) > limit:
            candidates = candidates.iloc[rng.choice(len(candidates), limit, replace=False)]
        print(f"  {cls:9s} {len(candidates):5d} fotos (de {big.ImageID.nunique()} candidatas)")
        rows.append(candidates.assign(cls=cls))

    # "nada": fotos de validation/test sin ninguna clase relevante, ni en cajas ni en etiquetas verificadas.
    ids = label_ids()
    relevant = {ids[n] for n in config.OPENIMAGES_MAP} | {ids[n] for n in config.OPENIMAGES_AMBIGUOUS}
    labels = pd.concat([all_images("validation"), all_images("test")], ignore_index=True)
    dirty = set(labels.ImageID[labels.LabelName.isin(relevant) & (labels.Confidence > 0)]) | set(boxes.ImageID)
    clean = labels[~labels.ImageID.isin(dirty)].drop_duplicates("ImageID")[["ImageID", "folder"]]
    limit = int(config.MAX_IMAGES_PER_CLASS["nada"] * scale)
    clean = clean.iloc[rng.choice(len(clean), min(limit, len(clean)), replace=False)]
    print(f"  {'nada':9s} {len(clean):5d} fotos")
    rows.append(clean.assign(cls="nada"))

    selection = pd.concat(rows, ignore_index=True)
    selection.to_csv(config.SELECTION_FILE, index=False)
    return selection


def fetch_image(image_id: str, folder: str) -> str:
    target = config.IMAGES_DIR / f"{image_id}.jpg"
    if target.exists():
        return "ok"
    try:
        response = requests.get(IMAGE_URL.format(folder=folder, image_id=image_id), timeout=60)
        if response.status_code != 200:
            return "missing"
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(response.content))).convert("L")
        scale = config.STORE_SHORT_SIDE / min(image.size)
        if scale < 1:
            image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        partial = target.with_suffix(".part")
        image.save(partial, format="JPEG", quality=92)
        partial.replace(target)
        return "ok"
    except Exception:  # noqa: BLE001 - una foto mala no debe cortar la descarga
        return "error"


def download_images(selection: pd.DataFrame, workers: int) -> None:
    config.IMAGES_DIR.mkdir(parents=True, exist_ok=True)
    unique = selection.drop_duplicates("ImageID")
    results = {"ok": 0, "missing": 0, "error": 0}
    with ThreadPoolExecutor(workers) as pool:
        futures = [pool.submit(fetch_image, r.ImageID, r.folder) for r in unique.itertuples()]
        for future in tqdm(as_completed(futures), total=len(futures), desc="fotos", unit="foto"):
            results[future.result()] += 1
    print(f"Fotos: {results}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-train-boxes", action="store_true", help="no filtrar el CSV de train (2,3 GB de descarga)")
    parser.add_argument("--scale", type=float, default=1.0, help="multiplica MAX_IMAGES_PER_CLASS (ej. 4 en Lambda)")
    parser.add_argument("--workers", type=int, default=32, help="descargas en paralelo")
    parser.add_argument("--csv-only", action="store_true", help="solo bajar/filtrar los CSV")
    args = parser.parse_args()

    config.RAW_DIR.mkdir(parents=True, exist_ok=True)
    for name, path in SMALL_CSVS.items():
        download_file(CSV_BASE + path, config.RAW_DIR / name)
    if not args.no_train_boxes:
        stream_train_boxes(TRAIN_SEARCH_CLASSES)
    if args.csv_only:
        return

    print("Eligiendo fotos:")
    selection = select_images(args.scale)
    download_images(selection, args.workers)

    free_gb = shutil.disk_usage(config.DATA_DIR).free / 1e9
    print(f"\nListo. Espacio libre en disco: {free_gb:.1f} GB")
    print("Siguiente paso: python vision/prepare_dataset.py")


if __name__ == "__main__":
    main()
