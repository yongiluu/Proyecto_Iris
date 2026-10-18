"""Convierte las fotos descargadas en recortes etiquetados listos para entrenar.

    python vision/prepare_dataset.py

Que hace:
  1. Por cada foto elegida (data/vision_selection.csv) saca recortes cuadrados alrededor del
     objeto, con distintos zoom, como lo veria una camara en el pecho al acercarse.
     Un recorte vale como clase X si el objeto cubre al menos MIN_COVERAGE de la imagen y
     ninguna otra clase compite (AMBIGUITY_RATIO). Si no, se descarta.
  2. Agrega recortes de "nada" desde zonas vacias de esas mismas fotos (calles sin autos,
     pasillos sin puertas...), que son los negativos mas utiles.
  3. Suma las fotos reales de la placa en data/vision_board/<clase>/*.png (capture_photos.py).
  4. Separa train/val/test por foto (los recortes de una misma foto quedan juntos).
  5. Con --hard-negatives modelo.tflite, las fotos de "nada" del train que ese modelo confunde
     (avisaria algo) reciben recortes extra: es lo que mas baja los avisos falsos.
  6. Guarda data/vision_dataset.npz: train/val en CROP_SIZE (el train hace el resto de la
     aumentacion en cada epoca), test limpio en 96x96 y "test camara" = test con la
     simulacion de la OV2640 (augment.camera_degrade, semilla fija).
"""
import argparse
import hashlib
from collections import Counter

import numpy as np
import pandas as pd
from PIL import Image
from tqdm import tqdm

import config
from augment import camera_degrade, resize
from download_datasets import load_boxes

CROP = config.CROP_SIZE
GRID = 48  # resolucion de la mascara para medir cuanto cubre cada clase


def split_by_key(key: str) -> str:
    h = int(hashlib.md5(key.encode()).hexdigest(), 16) % 1000 / 1000
    if h < config.TEST_FRACTION:
        return "test"
    if h < config.TEST_FRACTION + config.VAL_FRACTION:
        return "val"
    return "train"


def coverage(boxes: pd.DataFrame, crop) -> dict:
    """Fraccion del recorte (x0, y0, side en coords normalizadas de la foto) cubierta por cada clase."""
    x0, y0, side_x, side_y = crop
    result = {}
    for cls, group in boxes.groupby("cls"):
        mask = np.zeros((GRID, GRID), bool)
        for b in group.itertuples():
            gx0 = int(np.floor((b.XMin - x0) / side_x * GRID)); gx1 = int(np.ceil((b.XMax - x0) / side_x * GRID))
            gy0 = int(np.floor((b.YMin - y0) / side_y * GRID)); gy1 = int(np.ceil((b.YMax - y0) / side_y * GRID))
            mask[max(0, gy0):max(0, min(GRID, gy1)), max(0, gx0):max(0, min(GRID, gx1))] = True
        result[cls] = mask.mean()
    return result


def cut(image: Image.Image, crop) -> np.ndarray:
    x0, y0, sx, sy = crop
    w, h = image.size
    box = (x0 * w, y0 * h, (x0 + sx) * w, (y0 + sy) * h)
    return np.asarray(image.resize((CROP, CROP), Image.BILINEAR, box=box, reducing_gap=2.0))


def square(w, h, cx, cy, side_px):
    """Cuadrado de side_px centrado en (cx, cy) en pixeles, movido para quedar dentro de la foto.
    Devuelve (x0, y0, ancho, alto) normalizados."""
    side_px = min(side_px, w, h)
    x0 = np.clip(cx - side_px / 2, 0, w - side_px)
    y0 = np.clip(cy - side_px / 2, 0, h - side_px)
    return x0 / w, y0 / h, side_px / w, side_px / h


def object_crops(image, boxes, cls, rng):
    w, h = image.size
    own = boxes[boxes.cls == cls].sort_values("area", ascending=False)
    others = boxes[(boxes.cls != cls) & (boxes.cls != "ambigua")]
    crops = []
    for _ in range(config.CROPS_PER_IMAGE[cls]):
        b = own.iloc[0] if rng.random() < 0.7 or len(own) == 1 else own.iloc[int(rng.integers(len(own)))]
        bw, bh = (b.XMax - b.XMin) * w, (b.YMax - b.YMin) * h
        side = max(bw, bh) * rng.uniform(1.0, 2.2)
        side = max(side, 0.3 * min(w, h))
        cx = (b.XMin + b.XMax) / 2 * w + rng.uniform(-0.15, 0.15) * bw
        cy = (b.YMin + b.YMax) / 2 * h + rng.uniform(-0.15, 0.15) * bh
        crop = square(w, h, cx, cy, side)
        cov = coverage(pd.concat([own, others]), crop)
        main = cov.get(cls, 0)
        rival = max([v for k, v in cov.items() if k != cls], default=0)
        if main >= config.MIN_COVERAGE[cls] and rival < config.AMBIGUITY_RATIO * main:
            crops.append(cut(image, crop))
    return crops


def background_crops(image, boxes, rng, count):
    """Zonas de la foto sin ningun objeto relevante (ni partes de personas o vehiculos)."""
    w, h = image.size
    crops = []
    for _ in range(12):
        if len(crops) >= count:
            break
        side = rng.uniform(0.4, 0.8) * min(w, h)
        crop = square(w, h, rng.uniform(0, w), rng.uniform(0, h), side)
        if max(coverage(boxes, crop).values(), default=0) < 0.01:
            crops.append(cut(image, crop))
    return crops


def scene_crop(image, rng):
    w, h = image.size
    side = rng.uniform(0.6, 1.0) * min(w, h)
    return cut(image, square(w, h, rng.uniform(0, w), rng.uniform(0, h), side))


def collect_openimages(pools, hard_model=None):
    selection = pd.read_csv(config.SELECTION_FILE)
    boxes = load_boxes()
    boxes = boxes[boxes.ImageID.isin(set(selection.ImageID))]
    by_image = dict(tuple(boxes.groupby("ImageID")))
    rng = np.random.default_rng(config.SEED)
    missing = 0
    nada_train = []  # (ImageID, recorte) para buscar negativos dificiles
    for row in tqdm(selection.itertuples(), total=len(selection), desc="recortes"):
        path = config.IMAGES_DIR / f"{row.ImageID}.jpg"
        if not path.exists():
            missing += 1
            continue
        image = Image.open(path).convert("L")
        image_boxes = by_image.get(row.ImageID, boxes.iloc[:0])
        split = split_by_key(row.ImageID)
        if row.cls == "cruce":
            # Sin cajas: recortes de la escena completa (el cruce suele ocupar la parte de abajo).
            for _ in range(config.CROPS_PER_IMAGE["cruce"]):
                pools[split]["cruce"].append(scene_crop(image, rng))
            continue
        if row.cls == "nada":
            crop = scene_crop(image, rng)
            pools[split]["nada"].append(crop)
            if split == "train":
                nada_train.append((row.ImageID, crop))
            continue
        pools[split][row.cls].extend(object_crops(image, image_boxes, row.cls, rng))
        pools[split]["nada"].extend(background_crops(image, image_boxes, rng, config.BACKGROUND_CROPS_PER_IMAGE))
    if missing:
        print(f"⚠ {missing} fotos elegidas no estan descargadas (se omiten)")
    if hard_model and nada_train:
        add_hard_negatives(pools, nada_train, hard_model, rng)


def add_hard_negatives(pools, nada_train, model_path, rng):
    """Solo en train (el test queda comparable): recortes extra de las fotos de "nada" que el
    modelo anterior confunde con alguna clase de aviso."""
    from export_model import int8_predictor  # importa TensorFlow: solo si se pide

    predict, _ = int8_predictor(open(model_path, "rb").read())
    images = np.stack([resize(crop) for _, crop in nada_train])
    scores = predict(images)
    # El modelo anterior puede tener menos clases (v4 no tenia "cruce"): solo se miran las que conoce.
    alert_idx = [config.CLASSES.index(c) for c in config.CLASSES
                 if c in config.ALERT_CLASSES and config.CLASSES.index(c) < scores.shape[1]]
    worst = scores[:, alert_idx].max(axis=1)
    hard = [image_id for (image_id, _), s in zip(nada_train, worst) if s >= config.HARD_NEGATIVE_MIN_SCORE]
    for image_id in hard:
        image = Image.open(config.IMAGES_DIR / f"{image_id}.jpg").convert("L")
        for _ in range(config.HARD_NEGATIVE_EXTRA_CROPS):
            pools["train"]["nada"].append(scene_crop(image, rng))
    print(f"Negativos dificiles: {len(hard)} de {len(nada_train)} fotos de 'nada' del train "
          f"(puntaje de aviso >= {config.HARD_NEGATIVE_MIN_SCORE}), +{len(hard) * config.HARD_NEGATIVE_EXTRA_CROPS} recortes")


def collect_board(pools):
    """Fotos reales de la placa (96x96). Se separan por tanda: fotos seguidas son casi iguales y no
    deben quedar unas en train y otras en test. Tanda = nombre sin el numero final
    (app: <clase>__<ambiente>__<mision>__<fecha>_<n>; capture_photos.py: <clase>_<nota>_<fecha>_<n>)."""
    if not config.BOARD_DIR.exists():
        return
    found = Counter()
    for cls in config.CLASSES:
        for path in sorted((config.BOARD_DIR / cls).glob("*.png")):
            image = np.asarray(Image.open(path).convert("L"))
            take = path.stem.rsplit("_", 1)[0]
            pools[split_by_key("board:" + take)][cls].append(resize(image, CROP))
            found[cls] += 1
    if found:
        print(f"Fotos de la placa: {dict(found)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hard-negatives", metavar="MODELO.tflite",
                        help="modelo int8 anterior para buscar fotos de 'nada' que confunde")
    args = parser.parse_args()

    pools = {s: {c: [] for c in config.CLASSES} for s in ("train", "val", "test")}
    collect_openimages(pools, args.hard_negatives)
    collect_board(pools)

    out = {"classes": np.array(config.CLASSES)}
    rng = np.random.default_rng(config.SEED + 1)
    for split, by_class in pools.items():
        x, y = [], []
        for i, cls in enumerate(config.CLASSES):
            x += by_class[cls]
            y += [i] * len(by_class[cls])
        x = np.stack(x).astype(np.uint8)
        y = np.array(y, dtype=np.int64)
        print(f"{split:5s} " + "  ".join(f"{c}={np.sum(y == i)}" for i, c in enumerate(config.CLASSES)))
        if split == "train":
            out["x_train"], out["y_train"] = x, y
        else:
            small = np.stack([resize(img) for img in x])
            out[f"x_{split}"], out[f"y_{split}"] = small, y
            if split == "test":
                out["x_test_cam"] = np.stack([camera_degrade(img, rng) for img in small])

    np.savez_compressed(config.DATASET_FILE, **out)
    print(f"\nGuardado {config.DATASET_FILE} ({config.DATASET_FILE.stat().st_size / 1e6:.0f} MB)")
    print("Siguiente paso: python vision/train.py")


if __name__ == "__main__":
    main()
