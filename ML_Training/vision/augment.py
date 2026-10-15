"""Aumentacion que simula la camara OV2640 de la placa (96x96, grises).

La usan train.py (en cada epoca, al azar) y prepare_dataset.py (una version fija del test,
"test camara", para medir como rinde el modelo con imagenes feas como las de la placa).
"""
import io

import numpy as np
from PIL import Image
from scipy.ndimage import convolve, gaussian_filter

import config

SIZE = config.IMAGE_SIZE


def to_model_input(images_uint8: np.ndarray) -> np.ndarray:
    """Pixeles 0..255 -> float32 en [-1, 1] (lo mismo que hace el firmware al cuantizar)."""
    return images_uint8.astype(np.float32)[..., np.newaxis] / 127.5 - 1.0


def resize(image: np.ndarray, size: int = SIZE) -> np.ndarray:
    return np.asarray(Image.fromarray(image).resize((size, size), Image.BILINEAR))


def random_view(crop: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Encuadre al azar: zoom, desplazamiento, inclinacion leve (camara colgada) y espejo."""
    image = Image.fromarray(crop)
    full = crop.shape[0]
    angle = 0.0
    if rng.random() < 0.5:
        angle = rng.uniform(-8, 8)
        image = image.rotate(angle, resample=Image.BILINEAR)
    # Con rotacion, el recorte debe caber en el cuadrado inscrito para no mostrar esquinas negras.
    max_side = full / (abs(np.cos(np.radians(angle))) + abs(np.sin(np.radians(angle))))
    side = rng.uniform(0.72, 1.0) * max_side
    shift = (max_side - side) / 2
    cx = full / 2 + rng.uniform(-shift, shift)
    cy = full / 2 + rng.uniform(-shift, shift)
    box = (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
    image = image.resize((SIZE, SIZE), Image.BILINEAR, box=box)
    out = np.asarray(image)
    return out[:, ::-1] if rng.random() < 0.5 else out


def camera_degrade(image: np.ndarray, rng: np.random.Generator, strength: float = 1.0) -> np.ndarray:
    """Simula la OV2640 sobre una imagen 96x96 uint8: exposicion, poca luz, desenfoque,
    baja resolucion, ruido de sensor, vineteado y artefactos JPEG."""
    x = image.astype(np.float32) / 255.0
    noise_boost = 1.0

    # Exposicion / poca luz (la autoexposicion de la OV2640 tarda y en interiores queda oscura).
    if rng.random() < 0.2 * strength:
        x *= rng.uniform(0.25, 0.6)
        noise_boost = 2.0
    elif rng.random() < 0.5:
        x *= rng.uniform(0.7, 1.35)
    if rng.random() < 0.4:
        x = np.clip(x, 0, 1) ** rng.uniform(0.75, 1.35)
    if rng.random() < 0.4:
        mean = x.mean()
        x = (x - mean) * rng.uniform(0.65, 1.2) + mean

    # Vineteado (lente barata: esquinas mas oscuras).
    if rng.random() < 0.4 * strength:
        yy, xx = np.mgrid[-1:1:SIZE * 1j, -1:1:SIZE * 1j]
        x *= 1 - rng.uniform(0.1, 0.35) * (xx ** 2 + yy ** 2) / 2

    # Desenfoque (foco fijo, suciedad) o movimiento (la persona camina).
    if rng.random() < 0.5 * strength:
        x = gaussian_filter(x, rng.uniform(0.3, 1.6))
    if rng.random() < 0.2 * strength:
        length = int(rng.integers(3, 8))
        kernel = np.zeros((length, length), np.float32)
        kernel[length // 2, :] = 1 / length
        if rng.random() < 0.5:
            kernel = kernel.T
        x = convolve(x, kernel, mode="reflect")

    # Baja resolucion efectiva (el sensor escala por hardware a 96x96).
    if rng.random() < 0.3 * strength:
        small = int(rng.integers(32, 72))
        img = Image.fromarray((np.clip(x, 0, 1) * 255).astype(np.uint8))
        x = np.asarray(img.resize((small, small), Image.BILINEAR).resize((SIZE, SIZE), Image.BILINEAR),
                       np.float32) / 255.0

    # Ruido de sensor (mas fuerte con poca luz).
    sigma = rng.uniform(0.003, 0.025) * noise_boost * strength
    x = x + rng.normal(0, sigma, x.shape)
    out = (np.clip(x, 0, 1) * 255 + 0.5).astype(np.uint8)

    # Artefactos JPEG.
    if rng.random() < 0.3 * strength:
        buffer = io.BytesIO()
        Image.fromarray(out).save(buffer, format="JPEG", quality=int(rng.integers(10, 50)))
        out = np.asarray(Image.open(buffer).convert("L"))
    return out
