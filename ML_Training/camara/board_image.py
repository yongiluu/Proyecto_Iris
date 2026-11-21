"""Referencia en Python de las conversiones de imagen del firmware (Hardware_ESP32/src/image_convert.cpp).

La camara de la placa entrega color RGB565 160x120. Retina (scene/) recibe el frame completo en RGB888
(unpack_rgb565). El medidor de luz de la placa usa el cuadrado central reducido a 96x96 en grises
(rgb_to_gray96) con la MISMA aritmetica entera que aca; tests/test_image_convert.py lo verifica.
"""
import numpy as np

GRAY_SIZE = 96


def unpack_rgb565(data: bytes, width: int, height: int) -> np.ndarray:
    """Bytes RGB565 de la camara (byte alto primero) -> (alto, ancho, 3) uint8, como en el firmware."""
    v = np.frombuffer(data, dtype=">u2", count=width * height).reshape(height, width).astype(np.int32)
    r5, g6, b5 = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
    rgb = np.stack([(r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)], axis=-1)
    return rgb.astype(np.uint8)


def pack_rgb565(rgb: np.ndarray) -> bytes:
    """(alto, ancho, 3) uint8 -> bytes RGB565 byte alto primero (para simular la camara y para tests)."""
    rgb = rgb.astype(np.uint16)
    v = ((rgb[..., 0] >> 3) << 11) | ((rgb[..., 1] >> 2) << 5) | (rgb[..., 2] >> 3)
    return v.astype(">u2").tobytes()


def simulate_rgb565(rgb: np.ndarray) -> np.ndarray:
    """Pierde la misma precision de color que la camara (5-6-5 bits)."""
    h, w = rgb.shape[:2]
    return unpack_rgb565(pack_rgb565(rgb), w, h)


def luma(rgb: np.ndarray) -> np.ndarray:
    """Rec. 601 entera, igual que el firmware: (77 R + 150 G + 29 B + 128) >> 8."""
    rgb = rgb.astype(np.int32)
    return (77 * rgb[..., 0] + 150 * rgb[..., 1] + 29 * rgb[..., 2] + 128) >> 8


def rgb_to_gray96(rgb: np.ndarray) -> np.ndarray:
    """(alto, ancho, 3) uint8 -> 96x96 uint8: cuadrado central, bilineal en punto fijo 16.16."""
    height, width = rgb.shape[:2]
    side = min(width, height)
    x0, y0 = (width - side) // 2, (height - side) // 2
    gray = luma(rgb[y0:y0 + side, x0:x0 + side])

    scale = (side << 16) // GRAY_SIZE
    coords = np.arange(GRAY_SIZE) * scale + scale // 2 - (1 << 15)
    coords = np.maximum(coords, 0)
    index = coords >> 16
    frac = (coords >> 8) & 0xFF
    frac = np.where(index >= side - 1, 0, frac)
    index = np.minimum(index, side - 1)
    index1 = np.minimum(index + 1, side - 1)

    rows0, rows1 = gray[index], gray[index1]                       # (96, side)
    a, b = rows0[:, index], rows0[:, index1]
    c, d = rows1[:, index], rows1[:, index1]
    fx, fy = frac[np.newaxis, :], frac[:, np.newaxis]
    top = a * (256 - fx) + b * fx
    bottom = c * (256 - fx) + d * fx
    return ((top * (256 - fy) + bottom * fy + (1 << 15)) >> 16).astype(np.uint8)


def rgb565_to_gray96(data: bytes, width: int, height: int) -> np.ndarray:
    return rgb_to_gray96(unpack_rgb565(data, width, height))


# ─── Imagen derecha segun el montaje de la camara (image_convert.cpp: grayUpright / rgb565UprightToRgb888) ───
MOUNT_UPRIGHT = 0
MOUNT_TRANSVERSE = 1  # en los lentes: llega girada 90 grados y en espejo (PIL: Image.TRANSVERSE)


def _axis_taps(n_out: int, scale: int, offset: int, size: int):
    s = np.arange(n_out, dtype=np.int64) * scale + scale // 2 - (1 << 15)
    s = np.maximum(s, 0)
    i = s >> 16
    f = (s >> 8) & 0xFF
    f = np.where(i >= size - 1, 0, f)
    i = np.minimum(i, size - 1)
    i1 = np.minimum(i + 1, size - 1)
    return offset + i, offset + i1, f


def upright(image: np.ndarray, mount: int, dw: int, dh: int, max_crop_w: int = 0) -> np.ndarray:
    """(alto, ancho) o (alto, ancho, 3) uint8 -> (dh, dw[, 3]) derecha, recorte central, bilineal 16.16."""
    sh, sw = image.shape[:2]
    uw, uh = (sh, sw) if mount == MOUNT_TRANSVERSE else (sw, sh)
    if uw * dh > uh * dw:
        ch, cw = uh, uh * dw // dh
    else:
        cw, ch = uw, uw * dh // dw
    if max_crop_w and cw > max_crop_w:  # zoom digital (lector de texto): solo el centro, sin achicar
        cw, ch = max_crop_w, max_crop_w * dh // dw
    x0, y0 = (uw - cw) // 2, (uh - ch) // 2
    u0, u1, fu = _axis_taps(dw, (cw << 16) // dw, x0, cw)
    v0, v1, fv = _axis_taps(dh, (ch << 16) // dh, y0, ch)

    def fetch(u, v):
        if mount == MOUNT_TRANSVERSE:
            return image[(sh - 1 - u)[np.newaxis, :], (sw - 1 - v)[:, np.newaxis]].astype(np.int64)
        return image[v[:, np.newaxis], u[np.newaxis, :]].astype(np.int64)

    a, b, c, d = fetch(u0, v0), fetch(u1, v0), fetch(u0, v1), fetch(u1, v1)
    fx, fy = fu[np.newaxis, :], fv[:, np.newaxis]
    if image.ndim == 3:
        fx, fy = fx[..., np.newaxis], fy[..., np.newaxis]
    top = a * (256 - fx) + b * fx
    bottom = c * (256 - fx) + d * fx
    return ((top * (256 - fy) + bottom * fy + (1 << 15)) >> 16).astype(np.uint8)
