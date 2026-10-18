"""Entrena el modelo de CERCANIA: "¿hay algo cerca al frente?" (libre / cerca / muy_cerca).

    python vision/depth_labels.py --n 15000         # 1) etiquetas del profesor (Open Images)
    python vision/nyu_to_labels.py <nyu.mat>        # 2) opcional: NYU Depth V2 (profundidad real)
    python vision/proximity_train.py                # 3) este script
    python vision/proximity_export.py               # 4) int8 + archivos del firmware

Entrada igual que el modelo de clases (96x96 grises de la camara), red MobileNetV1 0,25 (rapida).
La etiqueta sale del mapa de profundidad: percentil PROXIMITY_PERCENTILE de la zona central
(config.PROXIMITY_ROWS/COLS) contra PROXIMITY_NEAR_M y PROXIMITY_VERY_NEAR_M.

Guarda models/proximity.keras, models/proximity_report_float.txt y data/proximity_dataset.npz.
"""
import argparse
import hashlib
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf
from PIL import Image

import config
from augment import camera_degrade, resize, to_model_input
from depth_labels import OUT_DIR
from train import build_model, load_imagenet_weights

KERAS_MODEL = config.MODELS_DIR / "proximity.keras"
CLASSES = config.PROXIMITY_CLASSES


def near_distance(depth_map: np.ndarray) -> float:
    r0, r1 = config.PROXIMITY_ROWS
    c0, c1 = config.PROXIMITY_COLS
    return float(np.percentile(depth_map[r0:r1, c0:c1].astype(np.float32), config.PROXIMITY_PERCENTILE))


def label_for(distance: float) -> int:
    if distance < config.PROXIMITY_VERY_NEAR_M:
        return 2
    if distance < config.PROXIMITY_NEAR_M:
        return 1
    return 0


def split_key(name: str) -> str:
    """Fotos casi iguales deben quedar juntas: NYU por escena, tandas de la app por tanda."""
    if name.startswith("nyu_"):
        return name.rsplit("_", 1)[0]
    stem = name.rsplit(".", 1)[0]
    return stem.rsplit("_", 1)[0] if "__" in stem else stem


def split_of(name: str) -> str:
    h = int(hashlib.md5(split_key(name).encode()).hexdigest(), 16) % 1000 / 1000
    return "test" if h < config.TEST_FRACTION else "val" if h < config.TEST_FRACTION + config.VAL_FRACTION else "train"


def zoomed_example(image: np.ndarray, depth: np.ndarray, rng: np.random.Generator):
    """Acercar la imagen (zoom 1/s) equivale aprox. a caminar hacia adelante: lo que estaba a d metros
    al centro queda a d*s. Asi se generan vistas cercanas de paredes, puertas y muebles (casi no hay
    fotos publicas tomadas a 50 cm de una pared). La distancia se recalcula en el mapa recortado."""
    s = rng.uniform(0.35, 0.75)
    full, grid = image.shape[0], depth.shape[0]
    side = s * full
    cx = full / 2 + rng.uniform(-0.1, 0.1) * (full - side)
    cy = full / 2 + rng.uniform(-0.1, 0.1) * (full - side)
    box = (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
    zoomed = np.asarray(Image.fromarray(image).resize((full, full), Image.BILINEAR, box=box))
    g = [int(round(v / full * grid)) for v in box]
    sub = depth[max(0, g[1]):min(grid, g[3]), max(0, g[0]):min(grid, g[2])].astype(np.float32)
    sub = np.asarray(Image.fromarray(sub).resize((grid, grid), Image.BILINEAR))
    return zoomed, near_distance(sub) * s


def build_dataset() -> dict:
    parts = sorted(OUT_DIR.glob("*.npz"))
    if not parts:
        raise SystemExit("No hay etiquetas: corre vision/depth_labels.py primero")
    pools = {s: ([], [], []) for s in ("train", "val", "test")}
    rng = np.random.default_rng(config.SEED + 7)
    zoomed_count = 0
    for part in parts:
        data = np.load(part)
        for name, depth, image in zip(data["names"], data["depth"], data["images"]):
            distance = near_distance(depth)
            split = split_of(str(name))
            x, y, d = pools[split]
            x.append(image)
            y.append(label_for(distance))
            d.append(distance)
            # Solo en train: el test queda con fotos sin trucar para medir honestamente.
            if split == "train" and distance > config.PROXIMITY_VERY_NEAR_M:
                zoomed, zoomed_distance = zoomed_example(image, depth, rng)
                x.append(zoomed)
                y.append(label_for(zoomed_distance))
                d.append(zoomed_distance)
                zoomed_count += 1
    print(f"Vistas acercadas con zoom (solo train): {zoomed_count}")
    out = {"classes": np.array(CLASSES)}
    for split, (x, y, d) in pools.items():
        y = np.array(y, np.int64)
        print(f"{split:5s} " + "  ".join(f"{c}={np.sum(y == i)}" for i, c in enumerate(CLASSES)))
        if split == "train":
            out["x_train"] = np.stack(x)
        else:
            small = np.stack([resize(img) for img in x])
            out[f"x_{split}"] = small
            if split == "test":
                rng = np.random.default_rng(config.SEED)
                out["x_test_cam"] = np.stack([camera_degrade(img, rng) for img in small])
        out[f"y_{split}"], out[f"d_{split}"] = y, np.array(d, np.float32)
    np.savez_compressed(config.PROXIMITY_DATASET_FILE, **out)
    return out


def gentle_view(crop: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Encuadre al azar SIN acercar mucho: un zoom fuerte haria ver las cosas mas cerca de lo que estan
    y contradiria la etiqueta de distancia. Inclinacion leve y espejo."""
    image = Image.fromarray(crop)
    full = crop.shape[0]
    if rng.random() < 0.5:
        image = image.rotate(rng.uniform(-5, 5), resample=Image.BILINEAR)
    side = rng.uniform(0.88, 0.95) * full   # 0,88+ para no ver las esquinas de la rotacion
    shift = (full - side) / 2
    cx, cy = full / 2 + rng.uniform(-shift, shift) * 0.5, full / 2 + rng.uniform(-shift, shift) * 0.5
    out = np.asarray(image.resize((config.IMAGE_SIZE, config.IMAGE_SIZE), Image.BILINEAR,
                                  box=(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)))
    return out[:, ::-1] if rng.random() < 0.5 else out


def random_softness(crop: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Las vistas acercadas con zoom quedan mas borrosas (se amplian pocos pixeles). Si solo ellas lo
    estuvieran, el modelo aprenderia "borroso = cerca" y pitaria con desenfoque o poca luz (paso en v1).
    Por eso se pierde resolucion al azar en CUALQUIER foto, con la misma intensidad que el zoom."""
    if rng.random() >= 0.5:
        return crop
    full = crop.shape[0]
    small = max(8, int(full * rng.uniform(0.35, 0.9)))
    image = Image.fromarray(crop).resize((small, small), Image.BILINEAR)
    return np.asarray(image.resize((full, full), Image.BILINEAR))


class AugmentedImages(tf.keras.utils.PyDataset):
    def __init__(self, x, y, batch_size, **kwargs):
        super().__init__(**kwargs)
        self.x, self.y, self.batch_size = x, y, batch_size
        self.rng = np.random.default_rng(config.SEED)
        self.order = self.rng.permutation(len(y))
        self.epoch = 0

    def __len__(self):
        return int(np.ceil(len(self.y) / self.batch_size))

    def __getitem__(self, index):
        ids = self.order[index * self.batch_size:(index + 1) * self.batch_size]
        rng = np.random.default_rng([self.epoch, index, config.SEED])
        batch = np.stack([camera_degrade(view, rng) if rng.random() < 0.8 else view
                          for view in (gentle_view(random_softness(self.x[i], rng), rng) for i in ids)])
        return to_model_input(batch), self.y[ids]

    def on_epoch_end(self):
        self.epoch += 1
        self.order = self.rng.permutation(len(self.y))


def report(probs: np.ndarray, y: np.ndarray, title: str, threshold: float = config.PROXIMITY_ALERT_THRESHOLD) -> str:
    pred = probs.argmax(1)
    n = len(CLASSES)
    confusion = np.zeros((n, n), int)
    for t, p in zip(y, pred):
        confusion[t, p] += 1
    lines = [f"== {title} ==", f"Exactitud: {np.mean(pred == y) * 100:.1f}%  ({len(y)} ejemplos)", "",
             "Real \\ Predicho  " + " ".join(f"{c[:9]:>9s}" for c in CLASSES)]
    for i, c in enumerate(CLASSES):
        lines.append(f"{c:16s} " + " ".join(f"{v:9d}" for v in confusion[i]))
    # Lo que importa: avisar cuando hay algo cerca, sin pitar en vano cuando el camino esta libre.
    near_score = probs[:, 1] + probs[:, 2]
    alarm = near_score >= threshold
    lines += ["",
              f"Con umbral {threshold} (cerca + muy_cerca):",
              f"  muy_cerca avisado: {np.mean(alarm[y == 2]) * 100:.1f}%   cerca avisado: {np.mean(alarm[y == 1]) * 100:.1f}%",
              f"  avisos falsos con el camino libre: {np.mean(alarm[y == 0]) * 100:.1f}%"]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--epochs", type=int, default=25)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--alpha", type=float, default=0.25)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--rebuild", action="store_true", help="rehacer data/proximity_dataset.npz")
    args = parser.parse_args()

    tf.keras.utils.set_random_seed(config.SEED)
    if args.rebuild or not config.PROXIMITY_DATASET_FILE.exists():
        build_dataset()
    data = dict(np.load(config.PROXIMITY_DATASET_FILE))

    model = build_model(len(CLASSES), args.alpha)
    load_imagenet_weights(model, args.alpha)
    steps = int(np.ceil(len(data["y_train"]) / args.batch_size)) * args.epochs
    model.compile(optimizer=tf.keras.optimizers.Adam(tf.keras.optimizers.schedules.CosineDecay(args.lr, steps, alpha=0.02)),
                  loss="sparse_categorical_crossentropy", metrics=["accuracy"])
    counts = np.bincount(data["y_train"], minlength=len(CLASSES))
    weights = np.sqrt(len(data["y_train"]) / (len(counts) * np.maximum(1, counts)))
    print("Ejemplos de train:", dict(zip(CLASSES, counts.tolist())), "pesos:", np.round(weights, 2).tolist())

    config.MODELS_DIR.mkdir(parents=True, exist_ok=True)
    model.fit(AugmentedImages(data["x_train"], data["y_train"], args.batch_size, workers=args.workers),
              validation_data=(to_model_input(data["x_val"]), data["y_val"]), epochs=args.epochs,
              class_weight={i: float(w) for i, w in enumerate(weights)},
              callbacks=[tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True),
                         tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=8, restore_best_weights=True)],
              verbose=2)
    model = tf.keras.models.load_model(KERAS_MODEL)
    predict = lambda x: model.predict(to_model_input(x), batch_size=256, verbose=0)  # noqa: E731
    text = "\n\n".join([report(predict(data["x_val"]), data["y_val"], "Validacion (float32)"),
                        report(predict(data["x_test"]), data["y_test"], "Test limpio (float32)"),
                        report(predict(data["x_test_cam"]), data["y_test"], "Test con simulacion OV2640 (float32)")])
    print("\n" + text)
    (config.MODELS_DIR / "proximity_report_float.txt").write_text(text, encoding="utf-8")
    print(f"\nModelo guardado en {KERAS_MODEL}\nSiguiente paso: python vision/proximity_export.py")


if __name__ == "__main__":
    main()
