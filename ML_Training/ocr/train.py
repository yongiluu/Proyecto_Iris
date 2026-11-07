"""Entrena el lector de lineas con las lineas sinteticas de synth.py.

    python ocr/train.py                 # ~2 h en CPU
    python ocr/train.py --epochs 30     # en GPU / Lambda

Guarda models/ocr_reader.keras y models/ocr_report.txt (errores por caracter y lineas perfectas).
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from model import build_model, character_error_rate, ctc_loss, greedy_decode

KERAS_MODEL = config.MODELS_DIR / "ocr_reader.keras"
REPORT = config.MODELS_DIR / "ocr_report.txt"


class Lines(tf.keras.utils.PyDataset):
    """Lotes desde los arreglos uint8 en memoria (convertir todo a float32 no cabe en la RAM)."""

    def __init__(self, name, batch_size, shuffle, **kwargs):
        super().__init__(**kwargs)
        # Las imagenes se leen del disco a medida que se necesitan (memmap), no se cargan todas a la RAM.
        self.images = np.load(config.DATA_DIR / f"lines_{name}_images.npy", mmap_mode="r")
        meta = np.load(config.DATA_DIR / f"lines_{name}_meta.npz")
        self.labels, self.lengths, self.texts = meta["labels"], meta["lengths"], meta["texts"]
        self.batch_size, self.shuffle = batch_size, shuffle
        self.order = np.arange(len(self.images))
        self.rng = np.random.default_rng(config.SEED)
        self.on_epoch_end()

    def __len__(self):
        return int(np.ceil(len(self.order) / self.batch_size))

    def __getitem__(self, index):
        idx = np.sort(self.order[index * self.batch_size:(index + 1) * self.batch_size])  # lectura mas secuencial
        x = self.images[idx][..., np.newaxis].astype(np.float32)
        y = np.concatenate([self.labels[idx], self.lengths[idx, np.newaxis]], axis=1).astype(np.float32)
        return x, y

    def on_epoch_end(self):
        if self.shuffle:
            self.rng.shuffle(self.order)


def evaluate(predict, images, texts, title: str, examples: int = 15) -> str:
    probs = predict(images)
    predictions = [greedy_decode(p) for p in probs]
    cers = np.array([character_error_rate(p, str(t)) for p, t in zip(predictions, texts)])
    exact = np.mean([p == str(t) for p, t in zip(predictions, texts)])
    lines = [f"== {title} ({len(texts)} lineas) ==",
             f"Error por caracter (CER): {cers.mean():.1%} | lineas perfectas: {exact:.1%}",
             f"Lineas con CER <= 10%: {np.mean(cers <= 0.10):.1%}", "", "Ejemplos (leido | real):"]
    for p, t in list(zip(predictions, texts))[:examples]:
        lines.append(f"  {'✔' if p == str(t) else '✗'} {p!r:32s} | {str(t)!r}")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--width", type=float, default=1.0)
    args = parser.parse_args()

    tf.keras.utils.set_random_seed(config.SEED)
    train = Lines("train", args.batch_size, shuffle=True, workers=2, use_multiprocessing=False)
    val = Lines("val", 256, shuffle=False)
    print(f"Lineas: train={len(train.images)}, val={len(val.images)} | clases={config.NUM_CLASSES}")

    model = build_model(args.width)
    model.summary(line_length=100)
    steps = len(train) * args.epochs
    model.compile(optimizer=tf.keras.optimizers.Adam(tf.keras.optimizers.schedules.CosineDecay(args.lr, steps, alpha=0.02)),
                  loss=ctc_loss)
    config.MODELS_DIR.mkdir(parents=True, exist_ok=True)
    model.fit(train, validation_data=val, epochs=args.epochs, verbose=2,
              callbacks=[tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True)])

    model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    report = evaluate(lambda x: model.predict(np.asarray(x)[..., np.newaxis].astype(np.float32), batch_size=256, verbose=0),
                      val.images, val.texts, "Validacion (float32)")
    print("\n" + report)
    REPORT.write_text(report, encoding="utf-8")
    print(f"\n✔ {KERAS_MODEL}\nSiguiente: python ocr/export_model.py")


if __name__ == "__main__":
    main()
