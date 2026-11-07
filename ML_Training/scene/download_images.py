"""Baja fotos A COLOR de Open Images y crea etiquetas automaticas de escena (sin modelo grande).

    python scene/download_images.py                 # ~12 mil fotos (~0,5 GB), para probar todo en el PC
    python scene/download_images.py --count 60000   # en Lambda, antes de etiquetar con el profesor

Que hace:
  1. Usa los CSV de Open Images de validation y test (cajas y etiquetas de imagen verificadas por
     personas). Si no estan (ej. en Lambda), los baja (~250 MB).
  2. Elige fotos que tengan objetos del vocabulario (vocab.py), repartidas para que todos aparezcan.
  3. Baja cada foto a color, la reduce a lado corto TEACHER_SHORT_SIDE y la guarda en
     data/scene/images/openimages/<id>.jpg.
  4. Escribe data/scene/labels_auto.jsonl con lo que se puede sacar de las anotaciones:
       - objetos: el ejemplar mas grande de cada uno; posicion por el centro de la caja, distancia por su
         tamaño, color por los pixeles del centro de la caja (heuristica en HSV)
       - personas: cuantas cajas de persona (IsGroupOf = "3+")
       - lugar e interior: de las etiquetas de imagen (Kitchen, Street, Park...)
       - peligros: null (no se pueden sacar de las cajas; los pone el profesor)
     Son etiquetas ruidosas: sirven para probar el pipeline y como respaldo; las buenas vienen del
     profesor (label_teacher.py).
"""
import argparse
import io
import json
from concurrent.futures import ThreadPoolExecutor, as_completed

import numpy as np
import pandas as pd
import requests
from PIL import Image, ImageOps
from tqdm import tqdm

import config
from schema import clean
from vocab import COLOR_IDS, OBJECT_INFO, PEOPLE_BINS

IMAGE_URL = "https://open-images-dataset.s3.amazonaws.com/{folder}/{image_id}.jpg"
CSV_URLS = {
    "oidv7-class-descriptions.csv": "v7/oidv7-class-descriptions.csv",
    "validation-annotations-bbox.csv": "v5/validation-annotations-bbox.csv",
    "test-annotations-bbox.csv": "v5/test-annotations-bbox.csv",
    "oidv7-val-annotations-human-imagelabels.csv": "v7/oidv7-val-annotations-human-imagelabels.csv",
    "oidv7-test-annotations-human-imagelabels.csv": "v7/oidv7-test-annotations-human-imagelabels.csv",
    "validation-images-with-rotation.csv": "2018_04/validation/validation-images-with-rotation.csv",
    "test-images-with-rotation.csv": "2018_04/test/test-images-with-rotation.csv",
}
SPLITS = {"validation": "validation-annotations-bbox.csv", "test": "test-annotations-bbox.csv"}
IMAGE_LABELS = {"validation": "oidv7-val-annotations-human-imagelabels.csv",
                "test": "oidv7-test-annotations-human-imagelabels.csv"}
ROTATIONS = {"validation": "validation-images-with-rotation.csv", "test": "test-images-with-rotation.csv"}

# Etiquetas de imagen de Open Images -> (lugar, interior)
PLACE_LABELS = {
    "Kitchen": ("cocina", True), "Bathroom": ("bano", True), "Bedroom": ("habitacion", True),
    "Living room": ("living", True), "Office": ("oficina", True), "Classroom": ("sala_clases", True),
    "Supermarket": ("tienda", True), "Retail": ("tienda", True), "Stairs": ("escalera", None),
    "Zebra crossing": ("cruce", False), "Pedestrian crossing": ("cruce", False),
    "Sidewalk": ("vereda", False), "Street": ("calle", False), "Road": ("calle", False),
    "Alley": ("calle", False), "Parking lot": ("estacionamiento", False), "Park": ("parque", False),
    "Public transport": ("transporte", None),
}
INDOOR_HINTS = {"Room", "Interior design"}
OUTDOOR_HINTS = {"Metropolitan area", "Lane", "Building"}

# Tamaño de la caja (fraccion de la foto) -> distancia aproximada
NEAR_AREA, MID_AREA = 0.25, 0.04


def color_name(rgb: np.ndarray) -> str | None:
    """Color dominante de una region (pixeles x 3, uint8) con reglas simples en HSV. None si no hay mayoria."""
    hsv = np.asarray(Image.fromarray(rgb.reshape(-1, 1, 3)).convert("HSV")).reshape(-1, 3).astype(np.float32)
    h, s, v = hsv[:, 0] * 360 / 255, hsv[:, 1] / 255, hsv[:, 2] / 255
    names = np.full(len(h), "", dtype=object)
    names[:] = "gris"
    gray = s < 0.18
    names[gray & (v > 0.78)] = "blanco"
    names[v < 0.2] = "negro"
    colored = ~gray & (v >= 0.2)
    hue_names = [(15, "rojo"), (40, "naranjo"), (68, "amarillo"), (165, "verde"), (255, "azul"),
                 (295, "morado"), (340, "rosado"), (361, "rojo")]
    lower = 0
    for upper, name in hue_names:
        names[colored & (h >= lower) & (h < upper)] = name
        lower = upper
    brown = colored & (h >= 8) & (h < 50) & ((v < 0.62) | ((s < 0.55) & (v < 0.8)))
    names[brown] = "cafe"
    pink = colored & ((h >= 330) | (h < 12)) & (s < 0.5) & (v > 0.6)
    names[pink] = "rosado"

    values, counts = np.unique(names, return_counts=True)
    best = int(counts.argmax())
    return str(values[best]) if counts[best] / len(names) >= 0.4 and values[best] in COLOR_IDS else None


def ensure_csvs() -> None:
    config.OPENIMAGES_CSV_DIR.mkdir(parents=True, exist_ok=True)
    for name, path in CSV_URLS.items():
        target = config.OPENIMAGES_CSV_DIR / name
        if target.exists():
            continue
        print(f"Bajando {name}...")
        partial = target.with_suffix(".part")
        with requests.get("https://storage.googleapis.com/openimages/" + path, stream=True, timeout=60) as response:
            response.raise_for_status()
            with open(partial, "wb") as file:
                for chunk in response.iter_content(1 << 20):
                    file.write(chunk)
        partial.rename(target)


def load_annotations():
    names = pd.read_csv(config.OPENIMAGES_CSV_DIR / "oidv7-class-descriptions.csv")
    mid_to_name = dict(zip(names.iloc[:, 0], names.iloc[:, 1]))
    name_to_object = {oi: obj for obj, info in OBJECT_INFO.items() for oi in info["openimages"]}

    boxes, labels, rotations = [], [], {}
    for folder, filename in SPLITS.items():
        b = pd.read_csv(config.OPENIMAGES_CSV_DIR / filename,
                        usecols=["ImageID", "LabelName", "XMin", "XMax", "YMin", "YMax", "IsGroupOf", "IsDepiction"])
        b["objeto"] = b["LabelName"].map(mid_to_name).map(name_to_object)
        b = b[b["objeto"].notna() & (b["IsDepiction"] != 1)]
        b["folder"] = folder
        boxes.append(b)

        l = pd.read_csv(config.OPENIMAGES_CSV_DIR / IMAGE_LABELS[folder], usecols=["ImageID", "LabelName", "Confidence"])
        l["name"] = l["LabelName"].map(mid_to_name)
        l = l[(l["Confidence"] == 1) & l["name"].isin(set(PLACE_LABELS) | INDOOR_HINTS | OUTDOOR_HINTS)]
        labels.append(l[["ImageID", "name"]])

        rotation_file = config.OPENIMAGES_CSV_DIR / ROTATIONS[folder]
        if rotation_file.exists():
            r = pd.read_csv(rotation_file, usecols=["ImageID", "Rotation"]).dropna()
            rotations.update(zip(r["ImageID"], r["Rotation"].astype(int)))
    boxes = pd.concat(boxes)
    boxes["area"] = (boxes["XMax"] - boxes["XMin"]) * (boxes["YMax"] - boxes["YMin"])
    return boxes, pd.concat(labels), rotations


def select_images(boxes: pd.DataFrame, count: int, rng: np.random.Generator) -> list[str]:
    """Reparte la cuota entre objetos (los raros primero) para que todos aparezcan."""
    useful = boxes[boxes["area"] >= 0.01]
    by_object = useful.groupby("objeto")["ImageID"].unique()
    order = sorted(by_object.index, key=lambda o: len(by_object[o]))
    chosen, per_object = [], max(1, count // len(order))
    taken = set()
    for i, obj in enumerate(order):
        quota = (count - len(chosen)) // (len(order) - i)
        candidates = [x for x in rng.permutation(by_object[obj]) if x not in taken][:max(quota, per_object // 2)]
        chosen += candidates
        taken.update(candidates)
    return chosen[:count]


def fetch(image_id: str, folder: str, rotation: int) -> np.ndarray | None:
    target = config.IMAGES_DIR / "openimages" / f"{image_id}.jpg"
    if target.exists():
        return np.asarray(Image.open(target).convert("RGB"))
    try:
        response = requests.get(IMAGE_URL.format(folder=folder, image_id=image_id), timeout=60)
        response.raise_for_status()
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(response.content))).convert("RGB")
    except Exception:
        return None
    if rotation:
        image = image.rotate(-rotation, expand=True)  # Open Images: grados en sentido horario
    scale = config.TEACHER_SHORT_SIDE / min(image.size)
    if scale < 1:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    image.save(target, quality=90)
    return np.asarray(image)


def auto_labels(image: np.ndarray, image_boxes: pd.DataFrame, image_labels: set) -> dict:
    height, width = image.shape[:2]
    objects = []
    for obj, group in image_boxes.groupby("objeto"):
        box = group.sort_values("area").iloc[-1]
        center_x = (box["XMin"] + box["XMax"]) / 2
        position = "izquierda" if center_x < 0.36 else "derecha" if center_x > 0.64 else "centro"
        distance = "cerca" if box["area"] >= NEAR_AREA else "medio" if box["area"] >= MID_AREA else "lejos"
        color = None
        if OBJECT_INFO[obj]["has_color"] and box["area"] >= 0.02:
            # Centro de la caja (la mitad interior): menos fondo mezclado.
            x0, x1 = box["XMin"] + (box["XMax"] - box["XMin"]) / 4, box["XMax"] - (box["XMax"] - box["XMin"]) / 4
            y0, y1 = box["YMin"] + (box["YMax"] - box["YMin"]) / 4, box["YMax"] - (box["YMax"] - box["YMin"]) / 4
            region = image[int(y0 * height):max(int(y1 * height), int(y0 * height) + 1),
                           int(x0 * width):max(int(x1 * width), int(x0 * width) + 1)]
            color = color_name(region)
        objects.append({"objeto": obj, "posicion": position, "distancia": distance, "color": color})

    people = image_boxes[image_boxes["objeto"] == "persona"]
    if people.empty:
        n_people = "0"
    elif (people["IsGroupOf"] == 1).any():
        n_people = "3+"
    else:
        n_people = PEOPLE_BINS[min(len(people), 3)]

    place, interior = None, None
    for name in image_labels:
        if name in PLACE_LABELS:
            place, place_interior = PLACE_LABELS[name]
            interior = place_interior if place_interior is not None else interior
    if interior is None and image_labels & INDOOR_HINTS:
        interior = True
    elif interior is None and image_labels & OUTDOOR_HINTS:
        interior = False

    labels, _ = clean({"calidad": "buena", "interior": interior, "lugar": place, "personas": n_people,
                       "objetos": objects, "peligros": None})
    return labels


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=config.DEFAULT_IMAGE_COUNT)
    parser.add_argument("--workers", type=int, default=16)
    args = parser.parse_args()

    ensure_csvs()
    print("Leyendo anotaciones de Open Images...")
    boxes, image_labels, rotations = load_annotations()
    labels_by_image = image_labels.groupby("ImageID")["name"].apply(set).to_dict()
    rng = np.random.default_rng(config.SEED)
    chosen = select_images(boxes, args.count, rng)
    folder_of = boxes.drop_duplicates("ImageID").set_index("ImageID")["folder"].to_dict()
    boxes_by_image = boxes[boxes["ImageID"].isin(set(chosen))].groupby("ImageID")
    print(f"{len(chosen)} fotos elegidas con {boxes['objeto'].nunique()} objetos del vocabulario")

    (config.IMAGES_DIR / "openimages").mkdir(parents=True, exist_ok=True)
    done = set()
    if config.AUTO_LABELS.exists():
        with open(config.AUTO_LABELS, encoding="utf-8") as file:
            done = {json.loads(line)["image"] for line in file}

    def work(image_id):
        image = fetch(image_id, folder_of[image_id], rotations.get(image_id, 0))
        if image is None:
            return None
        labels = auto_labels(image, boxes_by_image.get_group(image_id), labels_by_image.get(image_id, set()))
        return {"image": f"openimages/{image_id}.jpg", "source": "auto_openimages", "labels": labels}

    pending = [i for i in chosen if f"openimages/{i}.jpg" not in done]
    failed = 0
    with open(config.AUTO_LABELS, "a", encoding="utf-8") as out, ThreadPoolExecutor(args.workers) as pool:
        futures = [pool.submit(work, i) for i in pending]
        for future in tqdm(as_completed(futures), total=len(futures), desc="Fotos a color"):
            row = future.result()
            if row is None:
                failed += 1
                continue
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"✔ Etiquetas automaticas en {config.AUTO_LABELS} ({failed} fotos no se pudieron bajar)")
    print("Siguiente: python scene/train.py  (o etiquetar con el profesor: ver scene/README.md)")


if __name__ == "__main__":
    main()
