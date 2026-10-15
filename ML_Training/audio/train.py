"""Entrena el clasificador de eventos de audio (DS-CNN pequeño para ESP32-S3).

    python audio/train.py                      # entrena desde cero
    python audio/train.py --epochs 60          # mas epocas (en GPU / Lambda)
    python audio/train.py --finetune           # parte del modelo anterior (ej. tras sumar datos de la placa)

Guarda models/audio_events.keras y models/audio_report_float.txt.
Siguiente paso: python audio/export_model.py
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config

KERAS_MODEL = config.MODELS_DIR / "audio_events.keras"
ALERT_THRESHOLD = config.ALERT_THRESHOLD


def build_model(num_classes: int, width: float = 1.0, batch_size=None) -> tf.keras.Model:
    """Solo usa operaciones que soporta TFLite Micro (Conv, DepthwiseConv, AvgPool, Reshape, FC, Softmax)."""
    def ch(n):
        return max(8, int(n * width))

    inputs = tf.keras.Input((config.NUM_FRAMES, config.NUM_MEL, 1), batch_size=batch_size, name="log_mel")
    x = tf.keras.layers.Conv2D(ch(32), (10, 4), strides=(2, 2), padding="same", use_bias=False)(inputs)
    x = tf.keras.layers.BatchNormalization()(x)
    x = tf.keras.layers.ReLU()(x)

    for filters, stride in ((ch(48), 1), (ch(64), 2), (ch(64), 1)):
        x = tf.keras.layers.DepthwiseConv2D(3, strides=stride, padding="same", use_bias=False)(x)
        x = tf.keras.layers.BatchNormalization()(x)
        x = tf.keras.layers.ReLU()(x)
        x = tf.keras.layers.Conv2D(filters, 1, use_bias=False)(x)
        x = tf.keras.layers.BatchNormalization()(x)
        x = tf.keras.layers.ReLU()(x)

    # AveragePooling del tamaño completo en vez de GlobalAveragePooling (MEAN no esta en el TFLM viejo)
    x = tf.keras.layers.AveragePooling2D(pool_size=(x.shape[1], x.shape[2]))(x)
    x = tf.keras.layers.Flatten()(x)
    x = tf.keras.layers.Dropout(0.2)(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax")(x)
    return tf.keras.Model(inputs, outputs, name="iris_audio_events")


def spec_augment(features, label):
    """Enmascara bandas de frecuencia y tramos de tiempo (SpecAugment), solo en train."""
    fill = tf.reduce_mean(features)
    for axis, max_width, size in ((1, 6, config.NUM_MEL), (0, 8, config.NUM_FRAMES)):
        width = tf.random.uniform([], 0, max_width + 1, dtype=tf.int32)
        start = tf.random.uniform([], 0, size - width + 1, dtype=tf.int32)
        idx = tf.range(size)
        mask = (idx >= start) & (idx < start + width)
        shape = [1, size, 1] if axis == 1 else [size, 1, 1]
        features = tf.where(tf.reshape(mask, shape), fill, features)
    return features, label


def make_datasets(data, batch_size):
    train = (tf.data.Dataset.from_tensor_slices((data["x_train"], data["y_train"]))
             .shuffle(len(data["y_train"]), seed=config.SEED, reshuffle_each_iteration=True)
             .map(spec_augment, num_parallel_calls=tf.data.AUTOTUNE)
             .batch(batch_size).prefetch(tf.data.AUTOTUNE))
    val = tf.data.Dataset.from_tensor_slices((data["x_val"], data["y_val"])).batch(256)
    return train, val


def report(model_or_fn, x, y, title: str) -> str:
    """Matriz de confusion, precision/recall por clase y tasa de falsas alarmas."""
    probs = model_or_fn(x)
    pred = probs.argmax(axis=1)
    n = len(config.CLASSES)
    confusion = np.zeros((n, n), dtype=int)
    for t, p in zip(y, pred):
        confusion[t, p] += 1

    lines = [f"== {title} ==", f"Exactitud: {np.mean(pred == y) * 100:.1f}%  ({len(y)} ejemplos)", "",
             "Real \\ Predicho  " + " ".join(f"{c[:7]:>7s}" for c in config.CLASSES)]
    for i, c in enumerate(config.CLASSES):
        lines.append(f"{c:16s} " + " ".join(f"{v:7d}" for v in confusion[i]))
    lines.append("")
    for i, c in enumerate(config.CLASSES):
        precision = confusion[i, i] / max(1, confusion[:, i].sum())
        recall = confusion[i, i] / max(1, confusion[i].sum())
        lines.append(f"{c:8s} precision={precision * 100:5.1f}%  recall={recall * 100:5.1f}%")

    # Lo que importa en la practica: alertas falsas cuando solo hay fondo o voz.
    alert_idx = [config.CLASSES.index(c) for c in config.CLASSES if c in config.ALERT_CLASSES]
    calm = np.isin(y, [config.CLASSES.index(c) for c in config.CLASSES if c not in config.ALERT_CLASSES])
    false_alarm = np.mean(probs[calm][:, alert_idx].max(axis=1) >= ALERT_THRESHOLD) if calm.any() else 0
    detected = np.mean(probs[~calm][:, alert_idx].max(axis=1) >= ALERT_THRESHOLD) if (~calm).any() else 0
    lines.append("")
    lines.append(f"Con umbral {ALERT_THRESHOLD}: alertas detectadas {detected * 100:.1f}%, "
                 f"falsas alarmas sobre fondo/voz {false_alarm * 100:.1f}%")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--width", type=float, default=1.0, help="multiplica los canales (0.5 = modelo mas chico)")
    parser.add_argument("--finetune", action="store_true", help="partir de models/audio_events.keras")
    parser.add_argument("--class-weight", choices=["full", "sqrt"], default="full")
    args = parser.parse_args()

    tf.keras.utils.set_random_seed(config.SEED)
    data = dict(np.load(config.DATASET_FILE))
    stored = [str(c) for c in data["classes"]]
    if stored != config.CLASSES:
        raise SystemExit(f"El dataset tiene clases {stored} pero config.py dice {config.CLASSES}. "
                         "Vuelve a correr prepare_dataset.py")

    if args.finetune and KERAS_MODEL.exists():
        print(f"Fine-tuning desde {KERAS_MODEL}")
        model = tf.keras.models.load_model(KERAS_MODEL)
        lr = args.lr / 10
    else:
        model = build_model(len(config.CLASSES), args.width)
        lr = args.lr
    model.summary()

    steps = int(np.ceil(len(data["y_train"]) / args.batch_size)) * args.epochs
    schedule = tf.keras.optimizers.schedules.CosineDecay(lr, steps, alpha=0.02)
    model.compile(optimizer=tf.keras.optimizers.Adam(schedule),
                  loss="sparse_categorical_crossentropy", metrics=["accuracy"])

    # Pesos por clase: las alertas tienen menos ejemplos originales. "sqrt" empuja menos hacia las
    # alertas (menos falsas alarmas, menos detecciones).
    counts = np.bincount(data["y_train"], minlength=len(config.CLASSES))
    balance = len(data["y_train"]) / (len(counts) * np.maximum(1, counts))
    if args.class_weight == "sqrt":
        balance = np.sqrt(balance)
    class_weight = {i: float(w) for i, w in enumerate(balance)}
    print("Pesos por clase:", {config.CLASSES[i]: round(w, 2) for i, w in class_weight.items()})

    train_ds, val_ds = make_datasets(data, args.batch_size)
    config.MODELS_DIR.mkdir(parents=True, exist_ok=True)
    model.fit(
        train_ds, validation_data=val_ds, epochs=args.epochs, class_weight=class_weight,
        callbacks=[
            tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True),
            tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=10, restore_best_weights=True),
        ],
        verbose=2,
    )
    model = tf.keras.models.load_model(KERAS_MODEL)

    predict = lambda x: model.predict(x, batch_size=256, verbose=0)  # noqa: E731
    text = report(predict, data["x_val"], data["y_val"], "Validacion (float32)") + "\n\n" + \
        report(predict, data["x_test"], data["y_test"], "Test (float32)")
    print("\n" + text)
    (config.MODELS_DIR / "audio_report_float.txt").write_text(text, encoding="utf-8")
    print(f"\nModelo guardado en {KERAS_MODEL}\nSiguiente paso: python audio/export_model.py")


if __name__ == "__main__":
    main()
