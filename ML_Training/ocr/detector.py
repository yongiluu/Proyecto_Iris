"""Detector de DONDE hay texto en la foto (el lector lee lineas ya recortadas; este las encuentra).

    python ocr/detector.py synth            # escenas sinteticas: fotos reales + texto pegado (~10 min)
    python ocr/detector.py train            # entrena (~1 h en CPU)
    python ocr/detector.py export           # int8 + chequeo de ops + models/ocr_detector_int8.tflite
    python ocr/detector.py preview          # data/ocr/detector_preview.png con lo que detecta

Entrada: foto en grises 320x240 (la placa la saca de un frame VGA en grises). Salida: mapa de 40x30
celdas (cada una de 8x8 px) con la probabilidad de que haya texto. En la placa, las celdas marcadas
se juntan en lineas (componentes conexas), se recortan del frame VGA y van al lector.
Solo convoluciones (sin decodificador con upsampling): pocas ops y poca memoria para TFLM.
"""
import argparse
import os
import random
import sys
from multiprocessing import Pool

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import config
from synth import load_fonts, load_sentences, random_text

W, H = config.DET_WIDTH, config.DET_HEIGHT
S = config.DET_STRIDE
MW, MH = W // S, H // S
DET_SCENES = 24_000
DET_VAL = 1_500
KERAS_MODEL = config.MODELS_DIR / "ocr_detector.keras"
TFLITE_MODEL = config.MODELS_DIR / "ocr_detector_int8.tflite"


# ───────────────────────── Escenas sinteticas ─────────────────────────

class SceneMaker:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.np_rng = np.random.default_rng(seed)
        self.fonts = load_fonts()
        self.sentences = load_sentences()
        self.photos = sorted(config.BACKGROUNDS_DIR.glob("*.jpg"))

    def photo(self) -> Image.Image:
        image = Image.open(self.rng.choice(self.photos)).convert("L")
        scale = max(W / image.width, H / image.height) * self.rng.uniform(1.0, 1.6)
        image = image.resize((int(image.width * scale) + 1, int(image.height * scale) + 1), Image.BILINEAR)
        x, y = self.rng.randint(0, image.width - W), self.rng.randint(0, image.height - H)
        return image.crop((x, y, x + W, y + H))

    def scene(self):
        rng = self.rng
        image = self.photo()
        mask = Image.new("L", (W, H), 0)          # 1 = pixel dentro de la caja de una linea de texto
        draw_img, draw_mask = ImageDraw.Draw(image), ImageDraw.Draw(mask)
        if rng.random() < 0.15:                    # algunas escenas sin texto (aprender a no inventar)
            return self.degrade(image), np.zeros((MH, MW), np.float32)

        for _ in range(rng.randint(1, 4)):        # bloques de texto (letreros, etiquetas)
            lines = rng.randint(1, 3)
            size = rng.randint(9, 40)              # alto del texto en la foto de 320x240
            font = ImageFont.truetype(rng.choice(self.fonts), size)
            texts = [t for t in (random_text(rng, self.sentences) for _ in range(lines)) if t]
            if not texts:
                continue
            boxes = [font.getbbox(t) for t in texts]
            block_w = max(b[2] - b[0] for b in boxes)
            line_h = int(size * rng.uniform(1.15, 1.6))
            block_h = line_h * len(texts)
            if block_w >= W - 8 or block_h >= H - 8:
                continue
            x0, y0 = rng.randint(4, W - block_w - 4), rng.randint(4, H - block_h - 4)
            region = np.asarray(image.crop((x0, y0, x0 + block_w, y0 + block_h)), np.float32)
            if rng.random() < 0.6:                 # letrero: placa lisa detras del texto
                plate = rng.uniform(0, 255)
                pad = int(size * 0.4)
                draw_img.rectangle((x0 - pad, y0 - pad, x0 + block_w + pad, y0 + block_h + pad), fill=int(plate))
                background = plate
            else:
                background = float(region.mean())
            ink = int(np.clip(background - rng.uniform(90, 200) if background > 127 else background + rng.uniform(90, 200), 0, 255))
            for i, (text, box) in enumerate(zip(texts, boxes)):
                x, y = x0, y0 + i * line_h
                draw_img.text((x - box[0], y - box[1]), text, font=font, fill=ink)
                draw_mask.rectangle((x, y, x + box[2] - box[0], y + box[3] - box[1]), fill=255)

        if rng.random() < 0.5:                     # camara algo girada respecto del letrero
            angle = rng.uniform(-7, 7)
            image = image.rotate(angle, resample=Image.BILINEAR, fillcolor=int(np.asarray(image).mean()))
            mask = mask.rotate(angle, resample=Image.BILINEAR)
        target = np.asarray(mask.resize((MW, MH), Image.BOX), np.float32) / 255.0
        return self.degrade(image), (target >= 0.3).astype(np.float32)

    def degrade(self, image: Image.Image) -> np.ndarray:
        rng = self.rng
        if rng.random() < 0.5:
            image = image.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.2)))
        x = np.asarray(image, np.float32)
        x = (x - x.mean()) * rng.uniform(0.6, 1.2) + x.mean() * rng.uniform(0.5, 1.3)
        x += self.np_rng.normal(0, rng.uniform(0, 8), x.shape)
        return np.clip(np.round(x), 0, 255).astype(np.uint8)


def _chunk(args):
    seed, count = args
    maker = SceneMaker(seed)
    images = np.empty((count, H, W), np.uint8)
    targets = np.empty((count, MH, MW), np.uint8)
    for i in range(count):
        image, target = maker.scene()
        images[i], targets[i] = image, target.astype(np.uint8)
    return images, targets


def synth(workers: int) -> None:
    for name, total, seed in (("val", DET_VAL, 2), ("train", DET_SCENES, 1)):
        chunk = 500
        jobs = [(seed * 100_000 + i, min(chunk, total - i * chunk)) for i in range((total + chunk - 1) // chunk)]
        images = np.lib.format.open_memmap(config.DATA_DIR / f"det_{name}_images.npy", mode="w+", dtype=np.uint8, shape=(total, H, W))
        targets = np.empty((total, MH, MW), np.uint8)
        position = 0
        with Pool(workers) as pool:
            for part_images, part_targets in pool.imap(_chunk, jobs):
                n = len(part_images)
                images[position:position + n], targets[position:position + n] = part_images, part_targets
                position += n
                print(f"\r  {name}: {position}/{total}", end="", flush=True)
        print()
        images.flush()
        np.save(config.DATA_DIR / f"det_{name}_targets.npy", targets)


# ───────────────────────── Modelo ─────────────────────────

def build_model(batch_size=None):
    import tensorflow as tf

    def conv(x, filters, kernel=3, strides=1):
        x = tf.keras.layers.Conv2D(filters, kernel, strides=strides, padding="same", use_bias=False)(x)
        x = tf.keras.layers.BatchNormalization()(x)
        return tf.keras.layers.ReLU()(x)

    def separable(x, filters, strides=1):
        x = tf.keras.layers.DepthwiseConv2D(3, strides=strides, padding="same", use_bias=False)(x)
        x = tf.keras.layers.BatchNormalization()(x)
        x = tf.keras.layers.ReLU()(x)
        return conv(x, filters, kernel=1)

    inputs = tf.keras.Input((H, W, 1), batch_size=batch_size, name="frame")
    x = tf.keras.layers.Rescaling(1 / 255.0)(inputs)
    x = conv(x, 16, strides=2)            # 120 x 160
    x = separable(x, 32, strides=2)       # 60 x 80
    x = separable(x, 48)
    x = separable(x, 64, strides=2)       # 30 x 40 (una celda = 8x8 px)
    for _ in range(3):                    # contexto: una linea es larga a lo ancho
        y = separable(x, 64)
        x = tf.keras.layers.Add()([x, y])
    x = tf.keras.layers.DepthwiseConv2D((1, 7), padding="same", use_bias=False)(x)  # a lo ancho
    x = conv(x, 64, kernel=1)
    outputs = tf.keras.layers.Conv2D(1, 1, activation="sigmoid", name="text")(x)
    return tf.keras.Model(inputs, outputs, name="iris_text_detector")


def bce_dice(y_true, y_pred):
    import tensorflow as tf
    y_true = tf.cast(y_true, tf.float32)
    bce = tf.reduce_mean(tf.keras.losses.binary_crossentropy(y_true, y_pred))
    inter = tf.reduce_sum(y_true * y_pred, axis=[1, 2, 3])
    dice = 1 - (2 * inter + 1) / (tf.reduce_sum(y_true, axis=[1, 2, 3]) + tf.reduce_sum(y_pred, axis=[1, 2, 3]) + 1)
    return bce + tf.reduce_mean(dice)


def train(epochs: int, batch_size: int) -> None:
    import tensorflow as tf
    images = np.load(config.DATA_DIR / "det_train_images.npy", mmap_mode="r")
    targets = np.load(config.DATA_DIR / "det_train_targets.npy")
    val_images = np.load(config.DATA_DIR / "det_val_images.npy")
    val_targets = np.load(config.DATA_DIR / "det_val_targets.npy")

    class Batches(tf.keras.utils.PyDataset):
        def __init__(self):
            super().__init__(workers=2)
            self.order = np.arange(len(images))

        def __len__(self):
            return len(images) // batch_size

        def __getitem__(self, i):
            idx = np.sort(self.order[i * batch_size:(i + 1) * batch_size])
            x = images[idx][..., np.newaxis].astype(np.float32)
            y = targets[idx][..., np.newaxis].astype(np.float32)
            if random.random() < 0.5:  # espejo horizontal
                x, y = x[:, :, ::-1], y[:, :, ::-1]
            return x, y

        def on_epoch_end(self):
            np.random.shuffle(self.order)

    model = build_model()
    model.summary(line_length=100)
    steps = len(images) // batch_size * epochs
    model.compile(optimizer=tf.keras.optimizers.Adam(tf.keras.optimizers.schedules.CosineDecay(2e-3, steps, alpha=0.02)),
                  loss=bce_dice)
    model.fit(Batches(), validation_data=(val_images[..., np.newaxis].astype(np.float32), val_targets[..., np.newaxis].astype(np.float32)),
              epochs=epochs, verbose=2,
              callbacks=[tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True)])
    model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    pred = model.predict(val_images[..., np.newaxis].astype(np.float32), batch_size=64, verbose=0)[..., 0] >= 0.5
    truth = val_targets.astype(bool)
    tp, fp, fn = (pred & truth).sum(), (pred & ~truth).sum(), (~pred & truth).sum()
    empty = ~truth.reshape(len(truth), -1).any(1)
    false_scene = pred.reshape(len(pred), -1).any(1)[empty].mean() if empty.any() else 0
    report = (f"Detector (validacion, {len(val_images)} escenas): celdas con texto encontradas {tp / max(1, tp + fn):.1%}, "
              f"celdas marcadas que si eran texto {tp / max(1, tp + fp):.1%}, escenas sin texto con alguna marca {false_scene:.1%}")
    print(report)
    (config.MODELS_DIR / "ocr_detector_report.txt").write_text(report, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", choices=["synth", "train", "export", "preview"])
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    if args.step == "synth":
        synth(args.workers)
    elif args.step == "train":
        train(args.epochs, args.batch_size)
    elif args.step == "preview":
        image, target = SceneMaker(5).scene()
        preview = Image.fromarray(image).convert("RGB")
        overlay = Image.fromarray((target * 255).astype(np.uint8)).resize((W, H), Image.NEAREST)
        preview.paste((255, 0, 0), mask=overlay.point(lambda v: 90 if v else 0))
        preview.resize((W * 2, H * 2), Image.NEAREST).save(config.DATA_DIR / "detector_preview.png")
        print(config.DATA_DIR / "detector_preview.png")
    else:
        sys.exit("export: pendiente (se escribe junto con la integracion en el firmware)")


if __name__ == "__main__":
    main()
