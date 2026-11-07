"""Constantes del modelo de descripcion de escenas (alumno chico para la placa, profesor grande en Lambda).

La entrada del alumno es EXACTAMENTE lo que ve la placa: la camara entrega color 160x120 RGB565
(camera_driver.cpp, CAMERA_COLOR_FRAME_SIZE) y el modelo recibe ese frame completo en RGB888.
"""
from pathlib import Path

# ─── Rutas ───
SCENE_DIR = Path(__file__).resolve().parent
ML_DIR = SCENE_DIR.parent
REPO_DIR = ML_DIR.parent
DATA_DIR = ML_DIR / "data" / "scene"
IMAGES_DIR = DATA_DIR / "images"                  # <fuente>/<id>.jpg a color, lado corto TEACHER_SHORT_SIDE
BOARD_IMAGES_DIR = ML_DIR / "data" / "scene_board"  # fotos reales 160x120 de la placa (vision/capture_photos.py)
OPENIMAGES_CSV_DIR = ML_DIR / "data" / "raw" / "openimages"  # CSV que ya bajo vision/download_datasets.py
AUTO_LABELS = DATA_DIR / "labels_auto.jsonl"      # etiquetas automaticas (cajas de Open Images + colores)
TEACHER_LABELS_GLOB = "labels_teacher_*.jsonl"    # etiquetas del modelo grande (label_teacher.py)
MODELS_DIR = ML_DIR / "models"
FIRMWARE_INCLUDE = REPO_DIR / "Hardware_ESP32" / "include"
FIRMWARE_SRC = REPO_DIR / "Hardware_ESP32" / "src"

# ─── Imagen ───
INPUT_WIDTH = 160            # = FRAMESIZE_QQVGA de la camara
INPUT_HEIGHT = 120
TEACHER_SHORT_SIDE = 384     # el profesor ve mas detalle que el alumno; el alumno recibe la version 160x120

# ─── Datos ───
SEED = 1234
VAL_FRACTION = 0.08
TEST_FRACTION = 0.08
# Cuantas fotos de Open Images bajar para el arranque local (Lambda: --count 60000 o mas).
DEFAULT_IMAGE_COUNT = 12000

# ─── Modelo alumno ───
BACKBONE_ALPHA = 0.35        # MobileNetV2 0,35: ~23 M multiplicaciones a 160x120 (cabe y corre en ~0,1-0,2 s con ESP-NN)
