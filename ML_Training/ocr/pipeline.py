"""Referencia en Python de lo que hace la placa alrededor de los dos modelos del lector de texto.

    frame VGA en grises (640x480)
      -> reducir a 320x240 (promedio 2x2)                  -> detector -> mapa 40x30 de "hay texto"
      -> juntar celdas marcadas en lineas (componentes conexas, de arriba a abajo)
      -> recortar cada linea del frame VGA y llevarla a 32x256 (bilineal en punto fijo, relleno a la derecha)
      -> lector -> decodificar CTC -> texto

Hardware_ESP32/src/ocr_pipeline.cpp hace EXACTAMENTE lo mismo con la misma aritmetica entera;
tests/test_ocr_pipeline.py los compara.
"""
import numpy as np

import config

VGA_W, VGA_H = 640, 480
SCALE = VGA_W // config.DET_WIDTH          # 2: del frame VGA a la entrada del detector
CELL = config.DET_STRIDE * SCALE           # 16 px del frame VGA por celda del mapa
MAP_W, MAP_H = config.DET_WIDTH // config.DET_STRIDE, config.DET_HEIGHT // config.DET_STRIDE
MIN_CELLS = 2                              # componentes mas chicas se descartan (ruido)
MAX_LINES = 8
PAD_X = 8                                  # margen horizontal del recorte (px del frame VGA)
MAX_PIECES = 4                             # una linea muy larga se parte en hasta 4 trozos


def downsample2x(frame: np.ndarray) -> np.ndarray:
    f = frame.astype(np.uint16)
    return ((f[0::2, 0::2] + f[0::2, 1::2] + f[1::2, 0::2] + f[1::2, 1::2] + 2) >> 2).astype(np.uint8)


def find_lines(text_map: np.ndarray, threshold: int) -> list[tuple[int, int, int, int]]:
    """text_map: (30, 40) uint8 (probabilidad * 255). Devuelve cajas (x0, y0, x1, y1) en celdas, x1/y1
    exclusivos, ordenadas de arriba a abajo y de izquierda a derecha. Componentes 4-conexas."""
    marked = text_map >= threshold
    label = np.zeros(marked.shape, np.int32)
    boxes = []
    for y in range(MAP_H):
        for x in range(MAP_W):
            if not marked[y, x] or label[y, x]:
                continue
            stack = [(y, x)]
            label[y, x] = 1
            x0 = x1 = x
            y0 = y1 = y
            count = 0
            while stack:
                cy, cx = stack.pop()
                count += 1
                x0, x1, y0, y1 = min(x0, cx), max(x1, cx), min(y0, cy), max(y1, cy)
                for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
                    if 0 <= ny < MAP_H and 0 <= nx < MAP_W and marked[ny, nx] and not label[ny, nx]:
                        label[ny, nx] = 1
                        stack.append((ny, nx))
            if count >= MIN_CELLS:
                boxes.append((x0, y0, x1 + 1, y1 + 1))
    boxes.sort(key=lambda b: (b[1], b[0]))
    return boxes[:MAX_LINES]


def line_pixels(box) -> tuple[int, int, int, int]:
    """Caja en celdas -> recorte en el frame VGA (con un poco de margen, dentro de la imagen)."""
    x0, y0, x1, y1 = box
    pad_y = max(2, (y1 - y0) * CELL // 4)
    return (max(0, x0 * CELL - PAD_X), max(0, y0 * CELL - pad_y),
            min(VGA_W, x1 * CELL + PAD_X), min(VGA_H, y1 * CELL + pad_y))


def crop_line(frame: np.ndarray, rect) -> list[np.ndarray]:
    """Recorte -> una o mas lineas de 32x256 para el lector. Si la linea es muy larga se parte en
    trozos (cada uno se lee por separado y los textos se juntan)."""
    x0, y0, x1, y1 = rect
    width, height = x1 - x0, y1 - y0
    natural = width * config.LINE_HEIGHT // height       # ancho al llevar el alto a 32
    pieces = 1 if natural <= config.LINE_WIDTH * 5 // 4 else -(-natural // config.LINE_WIDTH)
    pieces = min(pieces, MAX_PIECES)
    out = []
    for p in range(pieces):
        px0 = x0 + width * p // pieces
        px1 = x0 + width * (p + 1) // pieces
        out.append(_resize_line(frame, px0, y0, px1, y1))
    return out


def _resize_line(frame, x0, y0, x1, y1) -> np.ndarray:
    width, height = x1 - x0, y1 - y0
    out_w = min(config.LINE_WIDTH, max(1, width * config.LINE_HEIGHT // height))
    scale_y = (height << 16) // config.LINE_HEIGHT
    scale_x = (width << 16) // out_w
    line = np.empty((config.LINE_HEIGHT, config.LINE_WIDTH), np.uint8)
    src = frame.astype(np.int32)

    def coords(n, scale, size):
        c = np.maximum(np.arange(n) * scale + scale // 2 - (1 << 15), 0)
        i = c >> 16
        f = (c >> 8) & 0xFF
        f = np.where(i >= size - 1, 0, f)
        i = np.minimum(i, size - 1)
        return i, np.minimum(i + 1, size - 1), f

    yi, yi1, fy = coords(config.LINE_HEIGHT, scale_y, height)
    xi, xi1, fx = coords(out_w, scale_x, width)
    patch = src[y0:y1, x0:x1]
    a, b = patch[yi][:, xi], patch[yi][:, xi1]
    c, d = patch[yi1][:, xi], patch[yi1][:, xi1]
    fx, fy = fx[np.newaxis, :], fy[:, np.newaxis]
    top = a * (256 - fx) + b * fx
    bottom = c * (256 - fx) + d * fx
    line[:, :out_w] = ((top * (256 - fy) + bottom * fy + (1 << 15)) >> 16).astype(np.uint8)
    # Relleno a la derecha con el promedio de las 2 ultimas columnas (como en el entrenamiento)
    if out_w < config.LINE_WIDTH:
        edge = int(line[:, max(0, out_w - 2):out_w].astype(np.int32).sum()) // (config.LINE_HEIGHT * min(2, out_w))
        line[:, out_w:] = edge
    return line


def ctc_decode(best: np.ndarray) -> str:
    """Indice mas probable por columna -> texto (sin repetidos seguidos ni blancos)."""
    chars, previous = [], config.BLANK
    for index in best:
        if index != previous and index != config.BLANK:
            chars.append(config.CHARSET[index - 1])
        previous = index
    return "".join(chars).strip()
