"""Lector de lineas (CRNN solo convolucional + CTC) que cabe en la placa.

Sin LSTM (el TFLite Micro de la placa no lo tiene): el "contexto" entre letras vecinas lo dan
convoluciones a lo ancho. Entrada (32, 256, 1) en grises; salida (64, NUM_CLASSES): probabilidades por
columna. Solo ops de TFLM: CONV_2D, DEPTHWISE_CONV_2D, MAX_POOL_2D, ADD, RESHAPE, SOFTMAX.
"""
import numpy as np
import tensorflow as tf

import config


def conv_bn(x, filters, kernel=3, strides=1, padding="same"):
    x = tf.keras.layers.Conv2D(filters, kernel, strides=strides, padding=padding, use_bias=False)(x)
    x = tf.keras.layers.BatchNormalization()(x)
    return tf.keras.layers.ReLU()(x)


def build_model(width: float = 1.0, batch_size=None) -> tf.keras.Model:
    def ch(n):
        return max(8, int(n * width))

    inputs = tf.keras.Input((config.LINE_HEIGHT, config.LINE_WIDTH, 1), batch_size=batch_size, name="line")
    x = tf.keras.layers.Rescaling(1 / 255.0)(inputs)
    x = conv_bn(x, ch(32))
    x = tf.keras.layers.MaxPooling2D(2)(x)                    # 16 x 128
    x = conv_bn(x, ch(64))
    x = conv_bn(x, ch(64))
    x = tf.keras.layers.MaxPooling2D(2)(x)                    # 8 x 64
    x = conv_bn(x, ch(96))
    x = conv_bn(x, ch(96))
    x = tf.keras.layers.MaxPooling2D((2, 1))(x)               # 4 x 64
    x = conv_bn(x, ch(128))
    x = tf.keras.layers.MaxPooling2D((2, 1))(x)               # 2 x 64
    x = conv_bn(x, ch(160), kernel=(2, 1), padding="valid")   # 1 x 64: una columna por paso de tiempo

    # Contexto a lo ancho (lo que haria un LSTM): separables con kernel 1x5, residuales.
    for _ in range(2):
        y = tf.keras.layers.DepthwiseConv2D((1, 5), padding="same", use_bias=False)(x)
        y = tf.keras.layers.BatchNormalization()(y)
        y = tf.keras.layers.ReLU()(y)
        y = conv_bn(y, ch(160), kernel=1)
        x = tf.keras.layers.Add()([x, y])

    x = tf.keras.layers.Dropout(0.2)(x)
    x = tf.keras.layers.Conv2D(config.NUM_CLASSES, 1, name="classes")(x)       # (1, 64, C)
    x = tf.keras.layers.Reshape((config.TIME_STEPS, config.NUM_CLASSES))(x)
    outputs = tf.keras.layers.Softmax(name="chars")(x)
    return tf.keras.Model(inputs, outputs, name="iris_ocr")


def ctc_loss(y_true, y_pred):
    """y_true: (B, MAX_TEXT_LENGTH + 1) = indices de caracteres (relleno 0) + largo al final."""
    labels = tf.cast(y_true[:, :-1], tf.int32)
    label_length = tf.cast(y_true[:, -1], tf.int32)
    logits = tf.math.log(tf.clip_by_value(y_pred, 1e-7, 1.0))
    batch = tf.shape(y_pred)[0]
    loss = tf.nn.ctc_loss(labels=labels, logits=logits, label_length=label_length,
                          logit_length=tf.fill([batch], config.TIME_STEPS), logits_time_major=False,
                          blank_index=config.BLANK)
    return loss


def greedy_decode(probs: np.ndarray) -> str:
    """(64, C) -> texto: el caracter mas probable por columna, sin repetidos seguidos ni blancos.
    Es lo mismo que hace el firmware (ocr_reader.cpp)."""
    best = probs.argmax(-1)
    chars, previous = [], config.BLANK
    for index in best:
        if index != previous and index != config.BLANK:
            chars.append(config.CHARSET[index - 1])
        previous = index
    return "".join(chars).strip()


def character_error_rate(predicted: str, truth: str) -> float:
    """Distancia de edicion / largo del texto real (0 = perfecto)."""
    previous = list(range(len(truth) + 1))
    for i, p in enumerate(predicted, 1):
        current = [i]
        for j, t in enumerate(truth, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (p != t)))
        previous = current
    return previous[-1] / max(1, len(truth))
