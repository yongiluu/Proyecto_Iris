"""Fotos + etiquetas de escena -> tf.data para entrenar al alumno.

Lo que ve el alumno es lo que ve la placa: 160x120 a color con la perdida de color del RGB565.
En el entrenamiento ademas se simula la camara barata (balance de blancos, poca luz, ruido, vineteado,
desenfoque) y se generan ejemplos "oscura", "borrosa" y "tapada" para que el modelo aprenda a decir
cuando no ve bien.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
import tensorflow as tf

import config
from schema import TARGET_KEYS, to_targets
from vocab import QUALITY

H, W = config.INPUT_HEIGHT, config.INPUT_WIDTH


# ───────────────────────── Etiquetas ─────────────────────────

def load_rows(mode: str = "mix") -> list[dict]:
    """mode: "auto" (solo etiquetas automaticas), "teacher" (solo profesor) o "mix" (profesor si hay, si no auto)."""
    files = []
    if mode in ("auto", "mix") and config.AUTO_LABELS.exists():
        files.append(config.AUTO_LABELS)
    if mode in ("teacher", "mix"):
        files += sorted(config.DATA_DIR.glob(config.TEACHER_LABELS_GLOB))  # el profesor reemplaza a lo automatico
    rows = {}
    for path in files:
        with open(path, encoding="utf-8") as file:
            for line in file:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue  # ultima linea a medio escribir (el etiquetado sigue corriendo)
                if Path(image_file(row["image"])).exists():
                    rows[row["image"]] = row
    return list(rows.values())


def split_of(image: str) -> str:
    h = int(hashlib.md5(image.encode()).hexdigest(), 16) % 1000 / 1000
    if h < config.TEST_FRACTION:
        return "test"
    if h < config.TEST_FRACTION + config.VAL_FRACTION:
        return "val"
    return "train"


def image_file(image: str) -> str:
    if image.startswith("board/"):
        return str(config.BOARD_IMAGES_DIR / image.split("/", 1)[1])
    return str(config.IMAGES_DIR / image)


def targets_array(rows: list[dict]) -> dict:
    per_row = [to_targets(r["labels"]) for r in rows]
    return {k: np.stack([t[k] for t in per_row]) for k in TARGET_KEYS}


# ───────────────────────── Imagen ─────────────────────────

def load_image(path: tf.Tensor, train: bool) -> tf.Tensor:
    """Archivo -> (120, 160, 3) float 0-255. Recorta al 4:3 de la camara (al azar en train, centrado si no)."""
    image = tf.io.decode_image(tf.io.read_file(path), channels=3, expand_animations=False)
    image = tf.cast(image, tf.float32)
    height, width = tf.cast(tf.shape(image)[0], tf.float32), tf.cast(tf.shape(image)[1], tf.float32)
    crop_w = tf.minimum(width, height * W / H)
    crop_h = crop_w * H / W
    if train:
        zoom = tf.random.uniform([], 0.85, 1.0)  # la placa ve un poco "mas cerca" o "mas lejos"
        crop_w, crop_h = crop_w * zoom, crop_h * zoom
        x0 = tf.random.uniform([], 0.0, 1.0) * (width - crop_w)
        y0 = tf.random.uniform([], 0.0, 1.0) * (height - crop_h)
    else:
        x0, y0 = (width - crop_w) / 2, (height - crop_h) / 2
    box = tf.stack([y0 / height, x0 / width, (y0 + crop_h) / height, (x0 + crop_w) / width])
    return tf.image.crop_and_resize(image[tf.newaxis], box[tf.newaxis], [0], [H, W], method="bilinear")[0]


def rgb565(image: tf.Tensor) -> tf.Tensor:
    """Misma perdida de color que la camara: 5 bits rojo/azul, 6 bits verde, expandidos como el firmware."""
    x = tf.clip_by_value(tf.round(image), 0, 255)
    r, g, b = tf.floor(x[..., 0] / 8), tf.floor(x[..., 1] / 4), tf.floor(x[..., 2] / 8)
    # (v << 3) | (v >> 2) = v * 8 + floor(v / 4)  (y para el verde de 6 bits: v * 4 + floor(v / 16))
    return tf.stack([r * 8 + tf.floor(r / 4), g * 4 + tf.floor(g / 16), b * 8 + tf.floor(b / 4)], -1)


def gaussian_blur(image: tf.Tensor, sigma: tf.Tensor) -> tf.Tensor:
    radius = 7
    x = tf.range(-radius, radius + 1, dtype=tf.float32)
    k = tf.exp(-x ** 2 / (2 * sigma ** 2))
    k /= tf.reduce_sum(k)
    kx = tf.tile(tf.reshape(k, [1, -1, 1, 1]), [1, 1, 3, 1])
    ky = tf.tile(tf.reshape(k, [-1, 1, 1, 1]), [1, 1, 3, 1])
    out = tf.nn.depthwise_conv2d(image[tf.newaxis], kx, [1, 1, 1, 1], "SAME")
    return tf.nn.depthwise_conv2d(out, ky, [1, 1, 1, 1], "SAME")[0]


def camera_degrade(image: tf.Tensor) -> tf.Tensor:
    """Simula la OV2640 a color: balance de blancos, exposicion, contraste, ruido, vineteado, desenfoque."""
    x = image / 255.0
    x *= tf.random.uniform([1, 1, 3], 0.85, 1.15)                       # balance de blancos
    x *= tf.random.uniform([], 0.6, 1.3)                                # exposicion
    x = tf.clip_by_value(x, 0, 1) ** tf.random.uniform([], 0.8, 1.25)   # gamma
    mean = tf.reduce_mean(x)
    x = (x - mean) * tf.random.uniform([], 0.75, 1.15) + mean           # contraste
    gray = tf.reduce_mean(x, axis=-1, keepdims=True)
    x = gray + (x - gray) * tf.random.uniform([], 0.6, 1.2)             # saturacion
    yy, xx = tf.meshgrid(tf.linspace(-1.0, 1.0, H), tf.linspace(-1.0, 1.0, W), indexing="ij")
    x *= (1 - tf.random.uniform([], 0.0, 0.3) * (xx ** 2 + yy ** 2) / 2)[..., tf.newaxis]  # vineteado
    x = tf.cond(tf.random.uniform([]) < 0.3, lambda: gaussian_blur(x, tf.random.uniform([], 0.4, 1.0)), lambda: x)
    x += tf.random.normal(tf.shape(x), 0, tf.random.uniform([], 0.0, 0.03))  # ruido del sensor
    return tf.clip_by_value(x, 0, 1) * 255.0


def bad_quality(image: tf.Tensor, kind: tf.Tensor) -> tf.Tensor:
    """kind 1: oscura, 2: borrosa, 3: tapada."""
    dark = image * tf.random.uniform([], 0.03, 0.12) + tf.random.normal(tf.shape(image), 0, 3.0)
    blurry = gaussian_blur(image / 255.0, tf.random.uniform([], 3.0, 6.0)) * 255.0
    yy, xx = tf.meshgrid(tf.linspace(0.0, 1.0, H), tf.linspace(0.0, 1.0, W), indexing="ij")
    tint = tf.random.uniform([1, 1, 3], 20, 160)
    covered = tint * (0.4 + 0.6 * (xx * tf.random.uniform([]) + yy * tf.random.uniform([]))[..., tf.newaxis] / 2)
    return tf.switch_case(kind - 1, [lambda: dark, lambda: blurry, lambda: covered])


def make_dataset(rows: list[dict], train: bool, batch_size: int, bad_fraction: float = 0.12) -> tf.data.Dataset:
    targets = targets_array(rows)
    paths = np.array([image_file(r["image"]) for r in rows])
    ds = tf.data.Dataset.from_tensor_slices((paths, targets))
    if train:
        ds = ds.shuffle(len(rows), seed=config.SEED, reshuffle_each_iteration=True)

    def prepare(path, t):
        image = load_image(path, train)
        if train:
            flip = tf.random.uniform([]) < 0.5
            image = tf.where(flip, image[:, ::-1], image)
            # Al reflejar, izquierda y derecha se intercambian en las etiquetas.
            t = dict(t)
            t["position"] = tf.where(flip, t["position"][:, ::-1], t["position"])
            image = camera_degrade(image)

            # Algunos ejemplos se arruinan a proposito: la etiqueta pasa a "oscura/borrosa/tapada" y lo
            # demas queda desconocido (no se le pide al modelo que vea en una foto que no se ve).
            kind = tf.random.uniform([], 1, 4, dtype=tf.int32)
            ruin = tf.random.uniform([]) < bad_fraction
            image = tf.cond(ruin, lambda: bad_quality(image, kind), lambda: image)
            quality = tf.one_hot(kind, len(QUALITY))
            t["quality"] = tf.where(ruin, quality, t["quality"])
            for key in ("presence", "hazards", "interior"):
                t[key] = tf.where(ruin, -tf.ones_like(t[key]), t[key])
            for key in ("position", "distance", "color", "people", "place"):
                t[key] = tf.where(ruin, tf.zeros_like(t[key]), t[key])
        return rgb565(image), t

    ds = ds.map(prepare, num_parallel_calls=tf.data.AUTOTUNE)
    return ds.batch(batch_size).prefetch(tf.data.AUTOTUNE)


def load_eval_image(path: str) -> np.ndarray:
    """Para demo/evaluacion: igual que en el test (recorte centrado + RGB565)."""
    return rgb565(load_image(tf.constant(path), train=False)).numpy()
