"""Lector de texto (OCR) para la placa: constantes compartidas.

El lector recibe UNA linea de texto ya recortada (32 px de alto, 256 de ancho, grises) y devuelve, para
cada una de 64 columnas, la probabilidad de cada caracter; un decodificador CTC (en Python y en el
firmware) junta eso en el texto. Encontrar las lineas dentro de la foto es trabajo del detector.

Carpetas (se pueden mover con variables de entorno, p. ej. a Google Drive en Colab):
    IRIS_OCR_DATA_DIR     datos sinteticos (.npy), frases, fuentes descargadas  (def. data/ocr)
    IRIS_OCR_WORK_DIR     .keras entrenados, respaldos para retomar y reportes   (def. models/)
    IRIS_BACKGROUNDS_DIR  fotos de fondo en grises       (def. <DATA_DIR>/fondos si existe, si no data/vision_images)
    IRIS_FONTS_DIR        fuentes extra (.ttf/.otf) ademas de las del sistema
    IRIS_OCR_SENTENCES    archivo de frases (una por linea) en vez de OpenSLR 71
    IRIS_OCR_CAMERA       fuerza de las degradaciones de camara (1.0 = la medida en fotos reales)
Los .tflite finales y models/firmware_models.json quedan SIEMPRE en ML_Training/models (pack_models los
anota con rutas relativas a ML_Training).
"""
import json
import os
import sys
from pathlib import Path

OCR_DIR = Path(__file__).resolve().parent
ML_DIR = OCR_DIR.parent
REPO_DIR = ML_DIR.parent


def _env_dir(name: str, default: Path) -> Path:
    value = os.environ.get(name, "").strip()
    return Path(value).expanduser().resolve() if value else default


DATA_DIR = _env_dir("IRIS_OCR_DATA_DIR", ML_DIR / "data" / "ocr")
MODELS_DIR = ML_DIR / "models"                       # .tflite para la placa (no se mueve: ver arriba)
WORK_DIR = _env_dir("IRIS_OCR_WORK_DIR", MODELS_DIR)  # checkpoints, respaldos y reportes
FIRMWARE_INCLUDE = REPO_DIR / "Hardware_ESP32" / "include"
FIRMWARE_SRC = REPO_DIR / "Hardware_ESP32" / "src"
SPEECH_TRANSCRIPTS = [ML_DIR / "data" / "raw" / f"slr71_{g}" / "line_index.tsv" for g in ("female", "male")]
SENTENCES_FILE = DATA_DIR / "frases.txt"             # copia liviana de las frases (la arma paquete_colab.py)
FONTS_CACHE = DATA_DIR / "fuentes"                   # fuentes libres descargadas si el sistema tiene pocas
if os.environ.get("IRIS_BACKGROUNDS_DIR", "").strip():
    BACKGROUNDS_DIR = _env_dir("IRIS_BACKGROUNDS_DIR", DATA_DIR / "fondos")
elif (DATA_DIR / "fondos").is_dir():
    BACKGROUNDS_DIR = DATA_DIR / "fondos"            # fotos del paquete para Colab
else:
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
SYNTH_VERSION = 2   # subir si cambia la forma de generar: los datos viejos se regeneran solos

# ─── Detector de donde hay texto (ocr/detector.py) ───
DET_WIDTH = 320          # la placa reduce su frame VGA en grises a esto
DET_HEIGHT = 240
DETECT_THRESHOLD = 128   # celda con texto si probabilidad*255 >= esto (0,5)
DET_STRIDE = 8           # una celda del mapa de salida = 8x8 px -> mapa de 40x30

# ─── Realismo de la camara de los lentes (OV2640, foco fijo, ocr/camera.py) ───
# Lo que se vio en fotos reales: letras chicas (~12 px de alto en el frame VGA), gris claro sobre blanco,
# algo desenfocadas, con ruido del sensor, luz despareja y compresion JPEG. Las probabilidades se
# multiplican por CAMERA_STRENGTH (0 = casi limpio como antes, 1 = lo medido, 1.5 = mas duro); las
# magnitudes (desenfoque, ruido, sombra) tambien escalan con ella.
CAMERA_STRENGTH = float(os.environ.get("IRIS_OCR_CAMERA", "1.0"))
CAMERA = {
    "clean_fraction": 0.15,              # muestras sin desenfoque/ruido/JPEG (que no empeore con texto nitido)
    # Tinta: contraste |tinta - fondo| en niveles de gris (0-255)
    "low_contrast_prob": 0.40,           # gris claro sobre blanco (antes 8%)
    "low_contrast": (25, 80),
    "contrast": (80, 230),
    "bright_paper_prob": 0.30,           # fondo liso claro (cajas de remedios, etiquetas)
    # Alto del texto en el frame VGA de la camara (px): lineas del lector
    "small_text_prob": 0.50,
    "small_text_px": (8, 13),
    "text_px": (13, 34),
    "clean_text_px": (14, 40),
    # Alto de las lineas en el frame VGA (px): escenas del detector (la placa lo reduce 2x)
    "det_small_text_prob": 0.45,
    "det_small_text_px": (9, 18),
    "det_text_px": (18, 80),
    # Geometria
    "rotation_deg": 6.0,                 # giro maximo (+-)
    "rotation_prob": 0.6,
    "perspective_prob": 0.35,
    "perspective": 0.07,                 # cuanto se mueven las esquinas (fraccion del tamaño)
    # Optica y sensor (px del frame VGA)
    "defocus_prob": 0.65,
    "defocus_sigma": (0.4, 1.5),
    "motion_prob": 0.25,
    "motion_px": (1.5, 4.5),
    "illumination_prob": 0.6,
    "illumination_gradient": (0.10, 0.45),  # caida de luz de un lado a otro
    "vignette": (0.0, 0.35),                # esquinas mas oscuras
    "shadow_prob": 0.25,
    "shadow_depth": (0.2, 0.55),
    "noise_prob": 0.85,
    "noise_sigma": (1.5, 9.0),               # ruido de lectura
    "shot_noise": (0.0, 0.7),                # ruido que crece con la luz (x sqrt(nivel))
    "row_noise_prob": 0.2,                   # bandas horizontales del sensor
    "sharpen_prob": 0.3,                     # la OV2640 enfoca por software (halos)
    "jpeg_prob": 0.6,
    "jpeg_quality": (25, 80),
}


def camera_signature() -> str:
    """Huella de los ajustes de camara: si cambian, los datos sinteticos se regeneran."""
    return json.dumps({"version": SYNTH_VERSION, "strength": CAMERA_STRENGTH, "camera": CAMERA}, sort_keys=True)


def default_workers() -> int:
    """Procesos para generar datos: en Windows se dejan nucleos libres para usar el PC; en Linux (Colab) todos."""
    cpus = os.cpu_count() or 2
    if sys.platform == "win32":
        return max(1, min(4, cpus - 2))
    return max(1, min(32, cpus))


def save_report(name: str, text: str, to_models: bool = False) -> Path:
    """Escribe el reporte en WORK_DIR (def. models/). to_models=True lo copia ademas a models/ (lo usa
    export_model.py al anotar los modelos para la placa). Asi una prueba con IRIS_OCR_WORK_DIR temporal
    nunca toca models/."""
    folders = [WORK_DIR] + ([MODELS_DIR] if to_models and MODELS_DIR != WORK_DIR else [])
    for folder in folders:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(text, encoding="utf-8")
    return folders[-1] / name
