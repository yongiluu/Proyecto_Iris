"""Lector de texto (OCR) para la placa: constantes compartidas.

El lector recibe UNA linea de texto ya recortada (32 px de alto, 256 de ancho, grises) y devuelve, para
cada una de 64 columnas, la probabilidad de cada caracter; un decodificador CTC (en Python y en el
firmware) junta eso en el texto. Encontrar las lineas dentro de la foto es trabajo de otro modelo
(detector, mas adelante).
"""
from pathlib import Path

OCR_DIR = Path(__file__).resolve().parent
ML_DIR = OCR_DIR.parent
REPO_DIR = ML_DIR.parent
DATA_DIR = ML_DIR / "data" / "ocr"
MODELS_DIR = ML_DIR / "models"
FIRMWARE_INCLUDE = REPO_DIR / "Hardware_ESP32" / "include"
FIRMWARE_SRC = REPO_DIR / "Hardware_ESP32" / "src"
SPEECH_TRANSCRIPTS = [ML_DIR / "data" / "raw" / f"slr71_{g}" / "line_index.tsv" for g in ("female", "male")]
BACKGROUNDS_DIR = ML_DIR / "data" / "vision_images"   # fotos reales en grises (Open Images) para fondos

# ─── Imagen de una linea ───
LINE_HEIGHT = 32
LINE_WIDTH = 256
TIME_STEPS = LINE_WIDTH // 4        # columnas de salida del modelo (64)
MAX_TEXT_LENGTH = 24                # CTC necesita hasta 2 columnas por caracter repetido

# ─── Alfabeto ───
# El indice 0 es el "blanco" de CTC. El orden define las salidas del modelo: si cambia, reentrenar.
CHARSET = (
    " abcdefghijklmnopqrstuvwxyzáéíóúüñ"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZÁÉÍÓÚÜÑ"
    "0123456789"
    ".,:;-!?¡¿/$%()\"'+=#&*°"
)
BLANK = 0
NUM_CLASSES = len(CHARSET) + 1
CHAR_TO_INDEX = {c: i + 1 for i, c in enumerate(CHARSET)}

# ─── Datos sinteticos ───
SEED = 1234
TRAIN_LINES = 160_000
VAL_LINES = 6_000

# ─── Detector de donde hay texto (ocr/detector.py) ───
DET_WIDTH = 320          # la placa reduce su frame VGA en grises a esto
DET_HEIGHT = 240
DET_STRIDE = 8           # una celda del mapa de salida = 8x8 px -> mapa de 40x30
