"""Entrena el lector de lineas con las lineas sinteticas de synth.py.

    python ocr/train.py                 # ~2 h en CPU
    python ocr/train.py --epochs 40 --batch-size 256 --lr 3e-3 --ram --workers 6    # GPU (Colab)
    python ocr/train.py --nuevo         # borra el respaldo y empieza de cero

Se puede cortar cuando quieras (cerrar, apagar el PC, Colab desconectado): al volver a correrlo sigue
desde la ultima epoca terminada (<IRIS_OCR_WORK_DIR>/ocr_reader_respaldo/). --desde-epoca N parte de
ocr_reader.keras como si ya se hubieran hecho N epocas (para retomar un entrenamiento hecho sin respaldo).

Guarda ocr_reader.keras y ocr_report.txt (errores por caracter y lineas perfectas) en IRIS_OCR_WORK_DIR
(def. models/). Con IRIS_OCR_WORK_DIR apuntando a otra carpeta no se toca nada de models/.
"""
import argparse
import os
import shutil

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from awake import keep_awake
from model import build_model, character_error_rate, ctc_loss, greedy_decode

KERAS_MODEL = config.WORK_DIR / "ocr_reader.keras"
BACKUP_DIR = config.WORK_DIR / "ocr_reader_respaldo"


class Lines(tf.keras.utils.PyDataset):
    """Lotes desde los arreglos uint8 en memoria (convertir todo a float32 no cabe en la RAM)."""

    def __init__(self, name, batch_size, shuffle, in_ram=False, **kwargs):
        super().__init__(**kwargs)
        # Las imagenes se leen del disco a medida que se necesitan (memmap); con RAM de sobra (Colab) se
        # cargan todas (uint8: 400 mil lineas = 3,3 GB) y los lotes salen mas rapido para la GPU.
        self.images = np.load(config.DATA_DIR / f"lines_{name}_images.npy", mmap_mode=None if in_ram else "r")
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
    parser.add_argument("--workers", type=int, default=2, help="hilos que arman lotes")
    parser.add_argument("--ram", action="store_true", help="cargar todas las lineas en RAM (Colab)")
    parser.add_argument("--nuevo", action="store_true", help="borrar el respaldo y entrenar de cero")
    parser.add_argument("--desde-epoca", type=int, default=0, dest="start_epoch",
                        help="seguir desde models/ocr_reader.keras como si ya se hubieran hecho N epocas")
    args = parser.parse_args()
    keep_awake()
    if args.nuevo:
        shutil.rmtree(BACKUP_DIR, ignore_errors=True)

    tf.keras.utils.set_random_seed(config.SEED)
    train = Lines("train", args.batch_size, shuffle=True, in_ram=args.ram, workers=args.workers, use_multiprocessing=False)
    val = Lines("val", 256, shuffle=False)
    print(f"Lineas: train={len(train.images)}, val={len(val.images)} | clases={config.NUM_CLASSES}")

    model = build_model(args.width)
    model.summary(line_length=100)
    steps = len(train) * args.epochs
    # Una epoca de calentamiento (lr/10 -> lr): con lotes grandes en GPU el CTC arranca mas estable.
    schedule = tf.keras.optimizers.schedules.CosineDecay(args.lr / 10, steps, alpha=0.02,
                                                         warmup_target=args.lr, warmup_steps=len(train))
    model.compile(optimizer=tf.keras.optimizers.Adam(schedule), loss=ctc_loss)
    config.WORK_DIR.mkdir(parents=True, exist_ok=True)
    if BACKUP_DIR.exists():
        print(f"Hay respaldo en {BACKUP_DIR}: sigue desde la ultima epoca terminada (--nuevo para empezar de cero)")
    callbacks = [tf.keras.callbacks.BackupAndRestore(str(BACKUP_DIR), delete_checkpoint=False),
                 tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True)]
    initial_epoch = 0
    if args.start_epoch and not BACKUP_DIR.exists():
        model.set_weights(tf.keras.models.load_model(KERAS_MODEL, compile=False).get_weights())
        model.optimizer.build(model.trainable_variables)
        model.optimizer.iterations.assign(args.start_epoch * len(train))  # la tasa de aprendizaje sigue donde iba
        initial_epoch = args.start_epoch
        print(f"Siguiendo desde {KERAS_MODEL.name} como epoca {initial_epoch}")
    model.fit(train, validation_data=val, epochs=args.epochs, initial_epoch=initial_epoch, verbose=2,
              callbacks=callbacks)

    model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    report = evaluate(lambda x: model.predict(np.asarray(x)[..., np.newaxis].astype(np.float32), batch_size=256, verbose=0),
                      val.images, val.texts, "Validacion (float32)")
    print("\n" + report)
    config.save_report("ocr_report.txt", report)
    print(f"\n✔ {KERAS_MODEL}\nSiguiente: python ocr/export_model.py")


if __name__ == "__main__":
    main()
