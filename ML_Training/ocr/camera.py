"""Lo que la camara de los lentes (OV2640, foco fijo) le hace a la imagen, para ensuciar los datos sinteticos.

Lo usan synth.py (lineas para el lector) y detector.py (escenas). Todo trabaja en la resolucion del
frame VGA de la camara (640x480), que es donde pasan el desenfoque, el ruido y el JPEG; despues cada
script lleva la imagen a lo que ve su modelo con la MISMA aritmetica de la placa (ocr/pipeline.py).
Las probabilidades y magnitudes salen de config.CAMERA y se escalan con config.CAMERA_STRENGTH.
"""
import io
import math

import numpy as np
from PIL import Image

import config


def chance(rng, key: str) -> bool:
    return rng.random() < min(1.0, config.CAMERA[key] * config.CAMERA_STRENGTH)


def amount(rng, key: str) -> float:
    lo, hi = config.CAMERA[key]
    return rng.uniform(lo, hi) * config.CAMERA_STRENGTH


def ink_contrast(rng) -> float:
    """|tinta - fondo|: a menudo gris claro sobre blanco (lo que mas fallaba con fotos reales)."""
    if chance(rng, "low_contrast_prob"):
        return rng.uniform(*config.CAMERA["low_contrast"])
    return rng.uniform(*config.CAMERA["contrast"])


def ink_level(rng, background: float) -> float:
    contrast = ink_contrast(rng)
    ink = background - contrast if background > 127 else background + contrast
    return float(np.clip(ink, 0, 255))


# ───────────────────────── Geometria ─────────────────────────

def perspective_coeffs(width: int, height: int, rng, strength: float) -> tuple:
    """Coeficientes para Image.transform(PERSPECTIVE): mueve cada esquina hasta strength*tamaño."""
    dx, dy = width * strength, height * strength
    corners = [(0, 0), (width, 0), (width, height), (0, height)]
    moved = [(x + rng.uniform(-dx, dx), y + rng.uniform(-dy, dy)) for x, y in corners]
    # La transformada va de pixel de salida -> pixel de entrada: salida = esquinas, entrada = movidas
    rows, rhs = [], []
    for (x, y), (u, v) in zip(corners, moved):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        rhs += [u, v]
    return tuple(np.linalg.solve(np.array(rows, np.float64), np.array(rhs, np.float64)))


def random_geometry(width: int, height: int, rng, rotate_prob_key: str = "rotation_prob"):
    """Lista de transformaciones a aplicar igual a la imagen y a su mascara (None = nada)."""
    ops = []
    if chance(rng, rotate_prob_key):
        ops.append(("rotate", rng.uniform(-1, 1) * config.CAMERA["rotation_deg"]))
    if chance(rng, "perspective_prob"):
        ops.append(("perspective", perspective_coeffs(width, height, rng,
                                                      rng.uniform(0.3, 1.0) * config.CAMERA["perspective"])))
    return ops


def apply_geometry(image: Image.Image, ops, fill: int = 0, expand: bool = False) -> Image.Image:
    """expand=True agranda el lienzo al girar (una linea inclinada entera, como la caja del detector)."""
    for kind, value in ops:
        if kind == "rotate":
            image = image.rotate(value, resample=Image.BILINEAR, fillcolor=fill, expand=expand)
        elif kind == "affine":   # cizalle (letra inclinada / camara de lado)
            image = image.transform(image.size, Image.AFFINE, value, Image.BILINEAR, fillcolor=fill)
        else:
            image = image.transform(image.size, Image.PERSPECTIVE, value, Image.BILINEAR, fillcolor=fill)
    return image


# ───────────────────────── Optica y sensor ─────────────────────────

def _blur_1d(x: np.ndarray, kernel: np.ndarray, axis: int) -> np.ndarray:
    radius = len(kernel) // 2
    pad = [(0, 0), (0, 0)]
    pad[axis] = (radius, radius)
    padded = np.pad(x, pad, mode="edge")
    out = np.zeros_like(x)
    n = x.shape[axis]
    for i, k in enumerate(kernel):
        out += k * (padded[i:i + n] if axis == 0 else padded[:, i:i + n])
    return out


def gaussian_blur(x: np.ndarray, sigma: float) -> np.ndarray:
    if sigma < 0.15:
        return x
    radius = max(1, int(math.ceil(sigma * 2.5)))
    t = np.arange(-radius, radius + 1, dtype=np.float32)
    kernel = np.exp(-0.5 * (t / sigma) ** 2)
    kernel /= kernel.sum()
    return _blur_1d(_blur_1d(x, kernel, 0), kernel, 1)


def motion_blur(x: np.ndarray, length: float, angle: float) -> np.ndarray:
    """Promedio de copias corridas a lo largo de una recta (cabeza que se mueve al sacar la foto)."""
    steps = max(2, int(round(length)) + 1)
    pad = int(math.ceil(length)) + 1
    padded = np.pad(x, pad, mode="edge")
    h, w = x.shape
    out = np.zeros_like(x)
    for t in np.linspace(-length / 2, length / 2, steps):
        oy, ox = int(round(t * math.sin(angle))), int(round(t * math.cos(angle)))
        out += padded[pad + oy:pad + oy + h, pad + ox:pad + ox + w]
    return out / steps


def illumination(x: np.ndarray, rng) -> np.ndarray:
    """Luz despareja: degradado de un lado a otro, viñeta y a veces una sombra suave."""
    h, w = x.shape
    yy, xx = np.meshgrid(np.linspace(-1, 1, h, dtype=np.float32), np.linspace(-1, 1, w, dtype=np.float32),
                         indexing="ij")
    angle = rng.uniform(0, 2 * math.pi)
    along = xx * math.cos(angle) + yy * math.sin(angle)
    field = 1 + amount(rng, "illumination_gradient") * along / 2
    field *= 1 - amount(rng, "vignette") * (xx ** 2 + yy ** 2) / 2
    if chance(rng, "shadow_prob"):
        angle = rng.uniform(0, 2 * math.pi)
        edge = xx * math.cos(angle) + yy * math.sin(angle) - rng.uniform(-0.6, 0.6)
        softness = rng.uniform(0.05, 0.4)
        field *= 1 - amount(rng, "shadow_depth") / (1 + np.exp(-edge / softness))
    return x * np.clip(field, 0.2, 1.6)


def sensor_noise(x: np.ndarray, rng, np_rng) -> np.ndarray:
    sigma = amount(rng, "noise_sigma")
    shot = amount(rng, "shot_noise")
    noise = np_rng.standard_normal(x.shape).astype(np.float32)
    x = x + noise * (sigma + shot * np.sqrt(np.clip(x, 0, 255)))
    if chance(rng, "row_noise_prob"):
        x = x + np_rng.normal(0, rng.uniform(0.5, 2.5), (x.shape[0], 1)).astype(np.float32)
    return x


def sharpen(x: np.ndarray, rng) -> np.ndarray:
    """Realce de bordes del procesador de la camara (deja halos claros/oscuros alrededor de las letras)."""
    return x + rng.uniform(0.3, 1.0) * (x - gaussian_blur(x, rng.uniform(0.6, 1.2)))


def jpeg(image: np.ndarray, rng) -> np.ndarray:
    lo, hi = config.CAMERA["jpeg_quality"]
    quality = rng.uniform(lo, hi)
    quality = int(np.clip(100 - (100 - quality) * config.CAMERA_STRENGTH, 5, 95))
    buffer = io.BytesIO()
    Image.fromarray(image).save(buffer, format="JPEG", quality=quality)
    buffer.seek(0)
    return np.asarray(Image.open(buffer).convert("L"))


def degrade(x: np.ndarray, rng, np_rng, clean: bool = False) -> np.ndarray:
    """float32 (en px del frame VGA) -> uint8 como lo entregaria la camara."""
    x = np.asarray(x, np.float32)
    if clean:  # nitido: solo un poco de exposicion y ruido
        x = (x - x.mean()) * rng.uniform(0.85, 1.1) + x.mean() * rng.uniform(0.85, 1.1)
        x = x + np_rng.normal(0, rng.uniform(0, 2), x.shape).astype(np.float32)
        return np.clip(np.round(x), 0, 255).astype(np.uint8)
    if chance(rng, "defocus_prob"):
        x = gaussian_blur(x, amount(rng, "defocus_sigma"))
    if chance(rng, "motion_prob"):
        x = motion_blur(x, amount(rng, "motion_px"), rng.uniform(0, math.pi))
    if chance(rng, "illumination_prob"):
        x = illumination(x, rng)
    # Exposicion y contraste global (poca luz, sobreexpuesto)
    mean = float(x.mean())
    x = (x - mean) * rng.uniform(0.7, 1.15) + mean * rng.uniform(0.6, 1.25)
    if rng.random() < 0.3:  # gamma
        x = 255.0 * (np.clip(x, 0, 255) / 255.0) ** rng.uniform(0.75, 1.35)
    if chance(rng, "sharpen_prob"):
        x = sharpen(x, rng)
    if chance(rng, "noise_prob"):
        x = sensor_noise(x, rng, np_rng)
    out = np.clip(np.round(x), 0, 255).astype(np.uint8)
    if chance(rng, "jpeg_prob"):
        out = jpeg(out, rng)
    return out
