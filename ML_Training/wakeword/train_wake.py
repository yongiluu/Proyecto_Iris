"""Entrena el detector de "Oye Iris" (misma red DS-CNN del modelo de audio, mas angosta, 2 salidas).

    python wakeword/train_wake.py
    python wakeword/train_wake.py --finetune     # partir del modelo anterior (ej. con tomas nuevas)

Guarda models/wakeword.keras. Imprime la medicion en audio continuo de test (lo que importa: cuantos
"Oye Iris" despiertan a Iris y cuantas activaciones falsas por hora hay con voz y ruido).
Siguiente paso: python wakeword/export_wake.py
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import wake_config as wc
from wake_common import load_streams, score_streams, stream_report
from train import build_model, spec_augment  # audio/train.py


def window_report(probs, y, title):
    """Por ventana de 1 s: positivos detectados y negativos que pasarian el umbral."""
    lines = [f"== {title} ({len(y)} ventanas) =="]
    for th in (0.5, 0.8, 0.9, 0.95):
        detected = np.mean(probs[y == 1] >= th) * 100
        false = np.mean(probs[y == 0] >= th) * 100
        lines.append(f"  umbral {th:4.2f}: Oye Iris {detected:5.1f}%  |  otro sobre el umbral {false:6.3f}%")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--width", type=float, default=0.5, help="multiplica los canales de la red de audio")
    parser.add_argument("--finetune", action="store_true")
    args = parser.parse_args()

    tf.keras.utils.set_random_seed(wc.SEED)
    data = np.load(wc.DATASET_FILE)
    x_train, y_train = data["x_train"], data["y_train"]
    x_val, y_val = data["x_val"].astype(np.float32), data["y_val"]
    print(f"train: {len(y_train)} ventanas ({int(y_train.sum())} Oye Iris), val: {len(y_val)}")

    if args.finetune and wc.KERAS_MODEL.exists():
        model = tf.keras.models.load_model(wc.KERAS_MODEL)
        lr = args.lr / 10
    else:
        model = build_model(len(wc.CLASSES), args.width)
        lr = args.lr
    model.summary()

    train = (tf.data.Dataset.from_tensor_slices((x_train, y_train))
             .shuffle(len(y_train), seed=wc.SEED, reshuffle_each_iteration=True)
             .map(lambda x, y: spec_augment(tf.cast(x, tf.float32), y), num_parallel_calls=tf.data.AUTOTUNE)
             .batch(args.batch_size).prefetch(tf.data.AUTOTUNE))
    steps = int(np.ceil(len(y_train) / args.batch_size)) * args.epochs
    model.compile(optimizer=tf.keras.optimizers.Adam(tf.keras.optimizers.schedules.CosineDecay(lr, steps, alpha=0.02)),
                  loss="sparse_categorical_crossentropy", metrics=["accuracy"])
    # Los positivos son ~10%: se pesan con la raiz del desbalance (pesarlos completo sube las activaciones falsas).
    ratio = (len(y_train) - y_train.sum()) / max(1, y_train.sum())
    class_weight = {0: 1.0, 1: float(np.sqrt(ratio))}
    print("Pesos por clase:", class_weight)
    model.fit(train, validation_data=(x_val, y_val), epochs=args.epochs, class_weight=class_weight, verbose=2)
    model.save(wc.KERAS_MODEL)

    def score(x):
        return model.predict(np.asarray(x, np.float32), batch_size=512, verbose=0)[:, 1]

    print("\n" + window_report(score(x_val), y_val, "Validacion (float32)"))
    print(window_report(score(data["x_test"]), data["y_test"], "Test (float32)"))
    print("\nAudio continuo de test (float32), una ventana cada "
          f"{wc.STRIDE_FRAMES * 20} ms, {wc.REFRACTORY_S:.0f} s sin re-activarse:")
    print(stream_report(score_streams(score, load_streams())))
    print(f"\nModelo guardado en {wc.KERAS_MODEL}\nSiguiente paso: python wakeword/export_wake.py")


if __name__ == "__main__":
    main()
