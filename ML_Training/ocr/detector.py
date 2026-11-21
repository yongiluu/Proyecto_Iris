"""Detector de DONDE hay texto en la foto (el lector lee lineas ya recortadas; este las encuentra).

    python ocr/detector.py synth            # escenas sinteticas: fotos reales + texto pegado
    python ocr/detector.py synth --escenas 40000 --val 2000 --workers 12     # en Colab
    python ocr/detector.py train            # entrena (~1 h en CPU); se puede cortar y retomar
    python ocr/detector.py train --nuevo    # borra el respaldo y empieza de cero
    python ocr/detector.py preview          # <datos>/detector_preview.png con una escena y su mapa
    (la exportacion a int8 la hace ocr/export_model.py junto con el lector)

Entrada: foto en grises 320x240 (la placa la saca de un frame VGA en grises). Salida: mapa de 40x30
celdas (cada una de 8x8 px) con la probabilidad de que haya texto. En la placa, las celdas marcadas
se juntan en lineas (componentes conexas), se recortan del frame VGA y van al lector.
Solo convoluciones (sin decodificador con upsampling): pocas ops y poca memoria para TFLM.

Las escenas se arman en el frame VGA (640x480), se ensucian como la camara (ocr/camera.py) y se reducen
a 320x240 con la MISMA funcion de la placa (pipeline.downsample2x). El entrenamiento guarda un respaldo
por epoca en <IRIS_OCR_WORK_DIR>/ocr_detector_respaldo: si se corta, al volver a correrlo sigue.
"""
import argparse
import os
import random
import shutil

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
from PIL import Image, ImageDraw

import camera
import config
import pipeline
from synth import build_resumable, font_at, load_fonts, load_sentences, random_text

W, H = config.DET_WIDTH, config.DET_HEIGHT
VW, VH = pipeline.VGA_W, pipeline.VGA_H     # las escenas se arman en el frame de la camara
S = config.DET_STRIDE
MW, MH = W // S, H // S
DET_SCENES = 24_000
DET_VAL = 1_500
KERAS_MODEL = config.WORK_DIR / "ocr_detector.keras"
BACKUP_DIR = config.WORK_DIR / "ocr_detector_respaldo"
TFLITE_MODEL = config.MODELS_DIR / "ocr_detector_int8.tflite"


# ───────────────────────── Escenas sinteticas ─────────────────────────

def clean_photos() -> list:
    """Fotos sin texto real (ocr/backgrounds.py): si el fondo tuviera texto sin marcar, aprenderia a ignorarlo."""
    clean = config.DATA_DIR / "fondos_sin_texto.txt"
    if not clean.exists():
        raise SystemExit(f"Falta {clean}: corre python ocr/backgrounds.py (o usa el paquete de paquete_colab.py)")
    available = {p.stem for p in config.BACKGROUNDS_DIR.glob("*.jpg")} if config.BACKGROUNDS_DIR.exists() else set()
    photos = [config.BACKGROUNDS_DIR / f"{i}.jpg" for i in clean.read_text(encoding="utf-8").split() if i in available]
    if not photos:
        raise SystemExit(f"No hay fotos de fondo sin texto en {config.BACKGROUNDS_DIR} (IRIS_BACKGROUNDS_DIR)")
    return photos


class SceneMaker:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.np_rng = np.random.default_rng(seed)
        self.fonts = load_fonts()
        self.sentences = load_sentences()
        self.photos = clean_photos()

    def photo(self) -> Image.Image:
        image = Image.open(self.rng.choice(self.photos)).convert("L")
        scale = max(VW / image.width, VH / image.height) * self.rng.uniform(1.0, 1.6)
        image = image.resize((int(image.width * scale) + 1, int(image.height * scale) + 1), Image.BILINEAR)
        x, y = self.rng.randint(0, image.width - VW), self.rng.randint(0, image.height - VH)
        return image.crop((x, y, x + VW, y + VH))

    def scene(self):
        """-> (foto 320x240 uint8 como la recibe el detector, mapa 30x40 de celdas con texto)."""
        rng, cam = self.rng, config.CAMERA
        image = self.photo()
        mask = Image.new("L", (VW, VH), 0)          # 255 = pixel dentro de la caja de una linea de texto
        draw_img, draw_mask = ImageDraw.Draw(image), ImageDraw.Draw(mask)
        clean = rng.random() < cam["clean_fraction"]
        if rng.random() < 0.15:                    # algunas escenas sin texto (aprender a no inventar)
            return self.finish(image, mask, clean, camera.random_geometry(VW, VH, rng))

        for _ in range(rng.randint(1, 5)):        # bloques de texto (letreros, etiquetas, cajas)
            small = not clean and camera.chance(rng, "det_small_text_prob")
            size = int(rng.uniform(*cam["det_small_text_px" if small else "det_text_px"]))  # alto en VGA
            lines = rng.randint(1, 6) if small else rng.randint(1, 3)
            font = font_at(rng.choice(self.fonts), size)
            texts = [t for t in (random_text(rng, self.sentences) for _ in range(lines)) if t]
            if not texts:
                continue
            boxes = [font.getbbox(t) for t in texts]
            block_w = max(b[2] - b[0] for b in boxes)
            line_h = int(size * rng.uniform(1.15, 1.6))
            block_h = line_h * len(texts)
            if block_w >= VW - 16 or block_h >= VH - 16:
                continue
            x0, y0 = rng.randint(8, VW - block_w - 8), rng.randint(8, VH - block_h - 8)
            region = np.asarray(image.crop((x0, y0, x0 + block_w, y0 + block_h)), np.float32)
            if rng.random() < 0.6:                 # letrero/etiqueta: placa lisa detras del texto
                plate = rng.uniform(190, 250) if camera.chance(rng, "bright_paper_prob") else rng.uniform(0, 255)
                pad = int(size * rng.uniform(0.3, 1.0))
                draw_img.rectangle((x0 - pad, y0 - pad, x0 + block_w + pad, y0 + block_h + pad), fill=int(plate))
                # La placa tapa el texto de bloques anteriores: ya no se ve, no se marca
                draw_mask.rectangle((x0 - pad, y0 - pad, x0 + block_w + pad, y0 + block_h + pad), fill=0)
                background = plate
            else:
                if np.asarray(mask.crop((x0, y0, x0 + block_w, y0 + block_h))).any():
                    continue   # texto sobre texto sin placa: ninguno se leeria
                background = float(region.mean())
            ink = int(round(camera.ink_level(rng, background)))
            for i, (text, box) in enumerate(zip(texts, boxes)):
                x, y = x0, y0 + i * line_h
                draw_img.text((x - box[0], y - box[1]), text, font=font, fill=ink)
                # Caja de al menos una celda de alto (16 px en VGA): una linea chica igual marca su fila
                top, bottom = y, y + box[3] - box[1]
                if bottom - top < 2 * S:
                    middle = (top + bottom) / 2
                    top, bottom = middle - S, middle + S
                draw_mask.rectangle((x, top, x + box[2] - box[0], bottom), fill=255)

        return self.finish(image, mask, clean, camera.random_geometry(VW, VH, rng))

    def finish(self, image, mask, clean, ops):
        """Misma geometria a foto y mascara, camara, y reduccion 2x como la placa."""
        if ops:
            image = camera.apply_geometry(image, ops, fill=int(np.asarray(image).mean()))
            mask = camera.apply_geometry(mask, ops, fill=0)
        frame = camera.degrade(np.asarray(image, np.float32), self.rng, self.np_rng, clean=clean)
        target = np.asarray(mask.resize((MW, MH), Image.BOX), np.float32) / 255.0
        return pipeline.downsample2x(frame), (target >= 0.3).astype(np.float32)


def _chunk(args):
    index, seed, count = args
    maker = SceneMaker(seed)
    images = np.empty((count, H, W), np.uint8)
    targets = np.empty((count, MH, MW), np.uint8)
    for i in range(count):
        image, target = maker.scene()
        images[i], targets[i] = image, target.astype(np.uint8)
    return index, images, {"targets": targets}


def synth(workers: int, scenes: int = DET_SCENES, val: int = DET_VAL) -> None:
    load_fonts()          # descarga las fuentes libres (si hace falta) antes de abrir los procesos
    print(f"Fotos de fondo sin texto: {len(clean_photos())} | camara x{config.CAMERA_STRENGTH} "
          f"| datos en {config.DATA_DIR}")
    for name, total, seed in (("val", val, 2), ("train", scenes, 1)):
        def finish(parts, name=name):
            np.save(config.DATA_DIR / f"det_{name}_targets.npy", np.concatenate([p["targets"] for p in parts]))
        build_resumable(f"det_{name}", total, seed, 250, (H, W), _chunk, workers, finish)
    print(f"✔ {config.DATA_DIR}")


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


def train(epochs: int, batch_size: int, lr: float = 2e-3, in_ram: bool = False, workers: int = 2) -> None:
    import tensorflow as tf
    images = np.load(config.DATA_DIR / "det_train_images.npy", mmap_mode=None if in_ram else "r")
    targets = np.load(config.DATA_DIR / "det_train_targets.npy")
    val_images = np.load(config.DATA_DIR / "det_val_images.npy")
    val_targets = np.load(config.DATA_DIR / "det_val_targets.npy")
    print(f"Escenas: train={len(images)}, val={len(val_images)} | {'en RAM' if in_ram else 'desde disco'}")

    class Batches(tf.keras.utils.PyDataset):
        def __init__(self):
            super().__init__(workers=workers)
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
    steps_per_epoch = len(images) // batch_size
    schedule = tf.keras.optimizers.schedules.CosineDecay(lr / 10, steps_per_epoch * epochs, alpha=0.02,
                                                         warmup_target=lr, warmup_steps=steps_per_epoch)
    model.compile(optimizer=tf.keras.optimizers.Adam(schedule), loss=bce_dice)
    config.WORK_DIR.mkdir(parents=True, exist_ok=True)
    if BACKUP_DIR.exists():
        print(f"Hay respaldo en {BACKUP_DIR}: sigue desde la ultima epoca terminada (--nuevo para empezar de cero)")
    model.fit(Batches(), validation_data=(val_images[..., np.newaxis].astype(np.float32), val_targets[..., np.newaxis].astype(np.float32)),
              epochs=epochs, verbose=2,
              callbacks=[tf.keras.callbacks.BackupAndRestore(str(BACKUP_DIR), delete_checkpoint=False),  # se puede cortar y seguir
                         tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True)])
    model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    pred = model.predict(val_images[..., np.newaxis].astype(np.float32), batch_size=64, verbose=0)[..., 0] >= 0.5
    truth = val_targets.astype(bool)
    tp, fp, fn = (pred & truth).sum(), (pred & ~truth).sum(), (~pred & truth).sum()
    empty = ~truth.reshape(len(truth), -1).any(1)
    false_scene = pred.reshape(len(pred), -1).any(1)[empty].mean() if empty.any() else 0
    report = (f"Detector (validacion, {len(val_images)} escenas): celdas con texto encontradas {tp / max(1, tp + fn):.1%}, "
              f"celdas marcadas que si eran texto {tp / max(1, tp + fp):.1%}, escenas sin texto con alguna marca {false_scene:.1%}")
    print(report)
    config.save_report("ocr_detector_report.txt", report)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", choices=["synth", "train", "export", "preview"])
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--workers", type=int, default=None, help="procesos (synth) o hilos de lotes (train)")
    parser.add_argument("--escenas", type=int, default=DET_SCENES, dest="scenes")
    parser.add_argument("--val", type=int, default=DET_VAL)
    parser.add_argument("--ram", action="store_true", help="cargar todas las escenas en RAM (Colab)")
    parser.add_argument("--nuevo", action="store_true", help="borrar el respaldo y entrenar de cero")
    args = parser.parse_args()
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    if args.step == "synth":
        synth(args.workers or config.default_workers(), args.scenes, args.val)
    elif args.step == "train":
        from awake import keep_awake
        keep_awake()
        if args.nuevo:
            shutil.rmtree(BACKUP_DIR, ignore_errors=True)
        train(args.epochs, args.batch_size, args.lr, args.ram, args.workers or 2)
    elif args.step == "preview":
        image, target = SceneMaker(11).scene()
        preview = Image.fromarray(image).convert("RGB")
        overlay = Image.fromarray((target * 255).astype(np.uint8)).resize((W, H), Image.NEAREST)
        preview.paste((255, 0, 0), mask=overlay.point(lambda v: 90 if v else 0))
        preview.resize((W * 2, H * 2), Image.NEAREST).save(config.DATA_DIR / "detector_preview.png")
        print(config.DATA_DIR / "detector_preview.png")
    else:
        raise SystemExit("export: usa python ocr/export_model.py (exporta el lector y el detector juntos)")


if __name__ == "__main__":
    main()
