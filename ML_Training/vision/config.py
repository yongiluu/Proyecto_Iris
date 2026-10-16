"""Constantes compartidas por todo el pipeline de vision.

La entrada del modelo DEBE coincidir con la camara del firmware (camera_driver.cpp:
OV2640, FRAMESIZE_96X96, PIXFORMAT_GRAYSCALE). No edites los archivos generados a mano:
cambia este archivo y vuelve a correr export_model.py, que regenera
Hardware_ESP32/include/vision_model_data.h y src/vision_model_data.cpp.
"""
from pathlib import Path

# ─── Rutas ───
VISION_DIR = Path(__file__).resolve().parent
ML_DIR = VISION_DIR.parent
REPO_DIR = ML_DIR.parent
DATA_DIR = ML_DIR / "data"
RAW_DIR = DATA_DIR / "raw" / "openimages"     # CSV de anotaciones de Open Images
IMAGES_DIR = DATA_DIR / "vision_images"       # imagenes reducidas (grises, lado corto STORE_SHORT_SIDE)
BOARD_DIR = DATA_DIR / "vision_board"         # fotos reales de la placa (capture_photos.py), por clase
SELECTION_FILE = DATA_DIR / "vision_selection.csv"
DATASET_FILE = DATA_DIR / "vision_dataset.npz"
MODELS_DIR = ML_DIR / "models"
FIRMWARE_INCLUDE = REPO_DIR / "Hardware_ESP32" / "include"
FIRMWARE_SRC = REPO_DIR / "Hardware_ESP32" / "src"

# ─── Imagen ───
IMAGE_SIZE = 96          # entrada del modelo (= FRAMESIZE_96X96 de la camara)
CROP_SIZE = 120          # recortes guardados en el dataset; el train saca 96x96 de aqui con zoom/desplazamiento
STORE_SHORT_SIDE = 256   # las fotos descargadas se guardan reducidas para cuidar el disco

# ─── Clases ───
# El orden define el indice de salida del modelo. Si lo cambias, reentrena.
CLASSES = ["nada", "persona", "vehiculo", "escalera", "puerta"]
# Clases que la placa informa a la app (CMD_VISION_EVENT:<clase>:<porcentaje>).
ALERT_CLASSES = {"persona", "vehiculo", "escalera", "puerta"}
# Puntaje minimo (promedio de 2 frames seguidos, ~1 s cada uno) para avisar. Se copia al firmware.
# v1: con 0.7 habia ~14% de avisos falsos por frame sobre "nada" en el test; con 0.8, ~10%.
ALERT_THRESHOLD = 0.8

# Open Images (nombres de clase con caja) -> clase de Iris.
OPENIMAGES_MAP = {
    **{n: "persona" for n in ["Person", "Man", "Woman", "Boy", "Girl"]},
    **{n: "vehiculo" for n in ["Car", "Bus", "Truck", "Van", "Motorcycle", "Bicycle", "Taxi",
                               "Ambulance", "Limousine", "Land vehicle", "Golf cart", "Train"]},
    "Stairs": "escalera",
    "Door": "puerta",
}
# Clases que vuelven ambigua una imagen de "nada" (partes de personas/vehiculos, cosas parecidas
# a escaleras o puertas). Una imagen con alguna de estas no se usa como "nada".
OPENIMAGES_AMBIGUOUS = [
    "Human body", "Human face", "Human head", "Human hand", "Human arm", "Human leg", "Human foot",
    "Human hair", "Human eye", "Human ear", "Human nose", "Human mouth", "Wheel", "Tire",
    "Vehicle registration plate", "Vehicle", "Wheelchair", "Ladder", "Door handle", "Snowmobile",
]

# Cuanto de un recorte debe cubrir el objeto para que cuente como esa clase (fraccion del area).
MIN_COVERAGE = {"persona": 0.10, "vehiculo": 0.10, "escalera": 0.15, "puerta": 0.10}
# Si otra clase cubre al menos esta fraccion de lo que cubre la principal, el recorte es ambiguo y se descarta.
AMBIGUITY_RATIO = 0.5

# Cuantas imagenes descargar como maximo por clase. v1 usaba 4000/3000/3000/4000/4000 (~17 mil fotos,
# ~0,5 GB); v2 usa casi todo lo disponible de escaleras y puertas y mucho mas "nada" (~45 mil, ~1,4 GB).
MAX_IMAGES_PER_CLASS = {"nada": 20000, "persona": 9000, "vehiculo": 8000, "escalera": 4000, "puerta": 10000}
# Recortes por imagen (zoom distintos alrededor del objeto). Mas para las clases con pocas fotos.
CROPS_PER_IMAGE = {"nada": 1, "persona": 1, "vehiculo": 1, "escalera": 3, "puerta": 1}
# Recortes de "nada" sacados de zonas sin objetos de fotos con objetos (calles sin autos, pasillos...).
BACKGROUND_CROPS_PER_IMAGE = 1

# Negativos dificiles (prepare_dataset.py --hard-negatives modelo.tflite): fotos de "nada" del train
# en las que un modelo anterior avisaba algo con al menos este puntaje reciben recortes extra.
HARD_NEGATIVE_MIN_SCORE = 0.4
HARD_NEGATIVE_EXTRA_CROPS = 3

# ─── Entrenamiento ───
SEED = 1234
VAL_FRACTION = 0.1
TEST_FRACTION = 0.1
