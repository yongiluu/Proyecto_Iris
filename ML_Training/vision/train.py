"""Entrena el clasificador de escenas para la camara de la placa (MobileNetV1 0.25, 96x96 grises).

    python vision/train.py                  # parte de los pesos de ImageNet (recomendado)
    python vision/train.py --epochs 60      # mas epocas (GPU / Lambda)
    python vision/train.py --finetune       # parte del modelo anterior (ej. tras sumar fotos de la placa)
    python vision/train.py --no-pretrained  # desde cero

Guarda models/vision_scenes.keras y models/vision_report_float.txt.
Siguiente paso: python vision/export_model.py
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from augment import camera_degrade, random_view, to_model_input

KERAS_MODEL = config.MODELS_DIR / "vision_scenes.keras"
ALERT_THRESHOLD = config.ALERT_THRESHOLD

# (canales, stride) de los bloques depthwise de MobileNetV1, antes de multiplicar por alpha.
MOBILENET_BLOCKS = [(64, 1), (128, 2), (128, 1), (256, 2), (256, 1), (512, 2),
                    (512, 1), (512, 1), (512, 1), (512, 1), (512, 1), (1024, 2), (1024, 1)]


def build_model(num_classes: int, alpha: float = 0.25, batch_size=None) -> tf.keras.Model:
    """MobileNetV1 con padding 'same' (sin ops PAD) y AveragePooling de tamano fijo (sin MEAN).
    Solo usa Conv, DepthwiseConv, AvgPool, Reshape, FC y Softmax, que soporta el TFLM viejo."""
    inputs = tf.keras.Input((config.IMAGE_SIZE, config.IMAGE_SIZE, 1), batch_size=batch_size, name="image")
    x = tf.keras.layers.Conv2D(int(32 * alpha), 3, strides=2, padding="same", use_bias=False, name="conv1")(inputs)
    x = tf.keras.layers.BatchNormalization(name="conv1_bn")(x)
    x = tf.keras.layers.ReLU(6.0, name="conv1_relu")(x)
    for i, (filters, stride) in enumerate(MOBILENET_BLOCKS, start=1):
        x = tf.keras.layers.DepthwiseConv2D(3, strides=stride, padding="same", use_bias=False, name=f"conv_dw_{i}")(x)
        x = tf.keras.layers.BatchNormalization(name=f"conv_dw_{i}_bn")(x)
        x = tf.keras.layers.ReLU(6.0, name=f"conv_dw_{i}_relu")(x)
        x = tf.keras.layers.Conv2D(int(filters * alpha), 1, use_bias=False, name=f"conv_pw_{i}")(x)
        x = tf.keras.layers.BatchNormalization(name=f"conv_pw_{i}_bn")(x)
        x = tf.keras.layers.ReLU(6.0, name=f"conv_pw_{i}_relu")(x)
    x = tf.keras.layers.AveragePooling2D(pool_size=(x.shape[1], x.shape[2]), name="pool")(x)
    x = tf.keras.layers.Flatten(name="flatten")(x)
    x = tf.keras.layers.Dropout(0.3, name="dropout")(x)
    outputs = tf.keras.layers.Dense(num_classes, activation="softmax", name="scores")(x)
    return tf.keras.Model(inputs, outputs, name=f"iris_vision_mobilenet_{alpha}")


def load_imagenet_weights(model: tf.keras.Model, alpha: float) -> None:
    """Copia los pesos de keras.applications.MobileNet (RGB) a la red de 1 canal.
    En la primera capa se suman los 3 canales: una foto gris es R=G=B."""
    reference = tf.keras.applications.MobileNet(input_shape=(128, 128, 3), alpha=alpha, include_top=False,
                                                weights="imagenet")
    copied = 0
    for layer in model.layers:
        try:
            source = reference.get_layer(layer.name)
        except ValueError:
            continue
        weights = source.get_weights()
        if layer.name == "conv1":
            weights = [weights[0].sum(axis=2, keepdims=True)]
        layer.set_weights(weights)
        copied += 1
    print(f"Pesos de ImageNet copiados en {copied} capas")


class AugmentedImages(tf.keras.utils.PyDataset):
    """Cada epoca genera vistas nuevas: encuadre al azar + simulacion de la OV2640."""

    def __init__(self, x, y, batch_size, seed, **kwargs):
        super().__init__(**kwargs)
        self.x, self.y, self.batch_size = x, y, batch_size
        self.rng = np.random.default_rng(seed)
        self.order = self.rng.permutation(len(y))
        self.epoch = 0

    def __len__(self):
        return int(np.ceil(len(self.y) / self.batch_size))

    def __getitem__(self, index):
        ids = self.order[index * self.batch_size:(index + 1) * self.batch_size]
        rng = np.random.default_rng([self.epoch, index, config.SEED])
        # 1 de cada 5 sin degradar: el modelo tambien debe andar bien con buena luz.
        batch = np.stack([camera_degrade(view, rng) if rng.random() < 0.8 else view
                          for view in (random_view(self.x[i], rng) for i in ids)])
        return to_model_input(batch), self.y[ids]

    def on_epoch_end(self):
        self.epoch += 1
        self.order = self.rng.permutation(len(self.y))


def report(model_or_fn, x, y, title: str) -> str:
    """Matriz de confusion, precision/recall por clase y lo que importa en la practica:
    avisos correctos y avisos falsos con el umbral del firmware."""
    probs = model_or_fn(x)
    pred = probs.argmax(axis=1)
    n = len(config.CLASSES)
    confusion = np.zeros((n, n), dtype=int)
    for t, p in zip(y, pred):
        confusion[t, p] += 1

    lines = [f"== {title} ==", f"Exactitud: {np.mean(pred == y) * 100:.1f}%  ({len(y)} ejemplos)", "",
             "Real \\ Predicho  " + " ".join(f"{c[:8]:>8s}" for c in config.CLASSES)]
    for i, c in enumerate(config.CLASSES):
        lines.append(f"{c:16s} " + " ".join(f"{v:8d}" for v in confusion[i]))
    lines.append("")
    for i, c in enumerate(config.CLASSES):
        precision = confusion[i, i] / max(1, confusion[:, i].sum())
        recall = confusion[i, i] / max(1, confusion[i].sum())
        lines.append(f"{c:9s} precision={precision * 100:5.1f}%  recall={recall * 100:5.1f}%")

    # Con umbral: se avisa la clase de alerta de mayor puntaje si supera ALERT_THRESHOLD.
    alert_idx = np.array([config.CLASSES.index(c) for c in config.CLASSES if c in config.ALERT_CLASSES])
    best = alert_idx[probs[:, alert_idx].argmax(axis=1)]
    fired = probs[:, alert_idx].max(axis=1) >= ALERT_THRESHOLD
    is_alert = np.isin(y, alert_idx)
    lines.append("")
    lines.append(f"Con umbral {ALERT_THRESHOLD} (1 frame, sin promediar):")
    for i in alert_idx:
        mask = y == i
        lines.append(f"  {config.CLASSES[i]:9s} avisada bien {np.mean(fired[mask] & (best[mask] == i)) * 100:5.1f}%")
    calm = ~is_alert
    lines.append(f"  avisos falsos sobre 'nada': {np.mean(fired[calm]) * 100:.1f}%  |  "
                 f"aviso de clase equivocada: {np.mean(fired[is_alert] & (best[is_alert] != y[is_alert])) * 100:.1f}%")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--alpha", type=float, default=0.25, help="ancho de MobileNet (0.25 = como person_detection)")
    parser.add_argument("--finetune", action="store_true", help="partir de models/vision_scenes.keras")
    parser.add_argument("--no-pretrained", action="store_true", help="no usar pesos de ImageNet")
    parser.add_argument("--workers", type=int, default=8, help="hilos que generan la aumentacion")
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
        model = build_model(len(config.CLASSES), args.alpha)
        if not args.no_pretrained:
            load_imagenet_weights(model, args.alpha)
        lr = args.lr
    model.summary()

    steps = int(np.ceil(len(data["y_train"]) / args.batch_size)) * args.epochs
    schedule = tf.keras.optimizers.schedules.CosineDecay(lr, steps, alpha=0.02)
    model.compile(optimizer=tf.keras.optimizers.Adam(schedule),
                  loss=tf.keras.losses.SparseCategoricalCrossentropy(), metrics=["accuracy"])

    counts = np.bincount(data["y_train"], minlength=len(config.CLASSES))
    balance = np.sqrt(len(data["y_train"]) / (len(counts) * np.maximum(1, counts)))
    class_weight = {i: float(w) for i, w in enumerate(balance)}
    print("Ejemplos de train:", {c: int(n) for c, n in zip(config.CLASSES, counts)})
    print("Pesos por clase:", {config.CLASSES[i]: round(w, 2) for i, w in class_weight.items()})

    train = AugmentedImages(data["x_train"], data["y_train"], args.batch_size, config.SEED,
                            workers=args.workers, use_multiprocessing=False)
    x_val = to_model_input(data["x_val"])
    config.MODELS_DIR.mkdir(parents=True, exist_ok=True)
    model.fit(
        train, validation_data=(x_val, data["y_val"]), epochs=args.epochs, class_weight=class_weight,
        callbacks=[
            tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True),
            tf.keras.callbacks.EarlyStopping(monitor="val_loss", patience=8, restore_best_weights=True),
        ],
        verbose=2,
    )
    model = tf.keras.models.load_model(KERAS_MODEL)

    predict = lambda x: model.predict(to_model_input(x), batch_size=256, verbose=0)  # noqa: E731
    text = "\n\n".join([
        report(predict, data["x_val"], data["y_val"], "Validacion (float32)"),
        report(predict, data["x_test"], data["y_test"], "Test limpio (float32)"),
        report(predict, data["x_test_cam"], data["y_test"], "Test con simulacion OV2640 (float32)"),
    ])
    print("\n" + text)
    (config.MODELS_DIR / "vision_report_float.txt").write_text(text, encoding="utf-8")
    print(f"\nModelo guardado en {KERAS_MODEL}\nSiguiente paso: python vision/export_model.py")


if __name__ == "__main__":
    main()
