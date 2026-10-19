"""Constantes del detector de la palabra de activacion "Oye Iris" (wake word).

Usa el MISMO front-end log-mel que el modelo de eventos de audio (audio/config.py y audio/features.py):
la placa calcula las features una sola vez y las pasa a los dos modelos.
"""
import sys
from pathlib import Path

WAKE_DIR = Path(__file__).resolve().parent
ML_DIR = WAKE_DIR.parent
sys.path.insert(0, str(ML_DIR / "audio"))

import config as audio_config  # noqa: E402  (front-end compartido)

DATA_DIR = ML_DIR / "data"
BOARD_DIR = DATA_DIR / "wakeword_board"          # oye_iris/ y no_wake/ (misiones de la app)
AUDIO_BOARD_DIR = DATA_DIR / "board"             # fondo/, voz/... de la app: tambien son negativos
# Copia fija del dataset del modelo de audio (fondo, voz chilena, bocinas...): todo eso es "otro".
NEGATIVES_FILE = DATA_DIR / "wakeword_negatives_audio.npz"
RAW_DIR = DATA_DIR / "raw"
DATASET_FILE = DATA_DIR / "wakeword_dataset.npz"
STREAMS_FILE = DATA_DIR / "wakeword_test_streams.npz"   # audio continuo de test (medir avisos falsos por hora)

MODELS_DIR = ML_DIR / "models"
KERAS_MODEL = MODELS_DIR / "wakeword.keras"
TFLITE_MODEL = MODELS_DIR / "wakeword_int8.tflite"
REPORT_FILE = MODELS_DIR / "wakeword_report_int8.txt"

CLASSES = ["otro", "oye_iris"]
SEED = 1234

# Corre cada 12 frames de 20 ms (0,24 s) sobre el ultimo segundo: "Oye Iris" dura ~0,6 s, asi que
# siempre queda entero en alguna ventana.
STRIDE_FRAMES = 12
# Puntaje minimo para despertar (se elige con el test de audio continuo en export_model.py).
THRESHOLD = 0.9
# Despues de despertar no vuelve a dispararse por este tiempo.
REFRACTORY_S = 2.0

# Cada "Oye Iris" de train se usa este numero de veces (velocidad, posicion, ruido y microfono distintos).
POSITIVE_AUGMENT = 40
# Tope de ventanas negativas que se toman del dataset del modelo de audio (cuida la RAM).
NEGATIVE_BANK_MAX = 30000
# Voz chilena extra (OpenSLR 71) solo para este modelo: la voz es lo que mas se parece a "Oye Iris".
EXTRA_SPEECH_FILES = 4000
