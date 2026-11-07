"""Alumno: MobileNetV2 (preentrenada en ImageNet) + cabezas del formulario de escena.

Solo usa operaciones que soporta el TFLite Micro de la placa (conv, depthwise, add, pad, avg pool,
reshape, fully connected, softmax, logistic). Mantiene el mapa espacial (4x5) en vez de promediarlo
todo, para que el modelo pueda saber si algo esta a la izquierda, al centro o a la derecha.
"""
import tensorflow as tf

import config
from vocab import COLOR_IDS, DISTANCES, HAZARD_IDS, OBJECT_IDS, PEOPLE_BINS, PLACES, POSITIONS, QUALITY

N_OBJ = len(OBJECT_IDS)
HEADS = {  # nombre: (forma de la salida, activacion)
    "presence": ((N_OBJ,), "sigmoid"),
    "position": ((N_OBJ, len(POSITIONS)), "softmax"),
    "distance": ((N_OBJ, len(DISTANCES)), "softmax"),
    "color": ((N_OBJ, len(COLOR_IDS)), "softmax"),
    "hazards": ((len(HAZARD_IDS),), "sigmoid"),
    "people": ((len(PEOPLE_BINS),), "softmax"),
    "place": ((len(PLACES),), "softmax"),
    "interior": ((1,), "sigmoid"),
    "quality": ((len(QUALITY),), "softmax"),
}


def build_model(alpha: float = config.BACKBONE_ALPHA, batch_size=None, pretrained: bool = True) -> tf.keras.Model:
    inputs = tf.keras.Input((config.INPUT_HEIGHT, config.INPUT_WIDTH, 3), batch_size=batch_size, name="rgb")
    x = tf.keras.layers.Rescaling(1 / 127.5, offset=-1.0)(inputs)  # MobileNetV2 espera [-1, 1]
    backbone = tf.keras.applications.MobileNetV2(
        input_shape=(config.INPUT_HEIGHT, config.INPUT_WIDTH, 3), alpha=alpha, include_top=False,
        weights="imagenet" if pretrained else None)
    features = backbone(x)                                           # (4, 5, 1280)
    x = tf.keras.layers.Conv2D(64, 1, activation="relu", name="reduce")(features)
    x = tf.keras.layers.Flatten()(x)                                 # conserva donde esta cada cosa
    x = tf.keras.layers.Dropout(0.3)(x)
    x = tf.keras.layers.Dense(192, activation="relu", name="shared")(x)

    outputs = {}
    for name, (shape, activation) in HEADS.items():
        units = 1
        for dim in shape:
            units *= dim
        y = tf.keras.layers.Dense(units, name=f"{name}_logits")(x)
        if len(shape) > 1:
            y = tf.keras.layers.Reshape(shape)(y)
        outputs[name] = tf.keras.layers.Activation(activation, name=name)(y)
    return tf.keras.Model(inputs, outputs, name="iris_scene")


# ───────────────────────── Perdidas que ignoran lo desconocido ─────────────────────────

def masked_bce(pos_weight: float = 2.0):
    """Binaria con etiquetas 1/0/-1 (desconocido). Los positivos pesan mas: los objetos son raros."""
    def loss(y_true, y_pred):
        mask = tf.cast(y_true >= 0, tf.float32)
        y = tf.clip_by_value(y_true, 0, 1)
        p = tf.clip_by_value(y_pred, 1e-6, 1 - 1e-6)
        bce = -(pos_weight * y * tf.math.log(p) + (1 - y) * tf.math.log(1 - p))
        axes = list(range(1, len(y_true.shape)))
        return tf.reduce_sum(bce * mask, axes) / tf.maximum(tf.reduce_sum(mask, axes), 1.0)
    return loss


def masked_cce(y_true, y_pred):
    """Categorica donde una fila de ceros = desconocido (no aporta)."""
    ce = -tf.reduce_sum(y_true * tf.math.log(tf.clip_by_value(y_pred, 1e-6, 1.0)), axis=-1)
    known = tf.cast(tf.reduce_sum(y_true, axis=-1) > 0, tf.float32)
    axes = list(range(1, len(ce.shape)))
    if not axes:
        return ce
    return tf.reduce_sum(ce, axes) / tf.maximum(tf.reduce_sum(known, axes), 1.0)


LOSS_WEIGHTS = {"presence": 1.0, "position": 0.5, "distance": 0.5, "color": 0.5, "hazards": 1.0,
                "people": 0.5, "place": 0.5, "interior": 0.3, "quality": 0.5}


def losses() -> dict:
    return {name: masked_bce() if activation == "sigmoid" else masked_cce
            for name, (_, activation) in HEADS.items()}
