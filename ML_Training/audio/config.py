"""Constantes compartidas por todo el pipeline de audio.

Todo lo que afecta a las features DEBE coincidir con el firmware. No edites los
headers generados a mano: cambia este archivo y vuelve a correr export_model.py,
que regenera Hardware_ESP32/include/audio_frontend_config.h y las tablas.
"""
from pathlib import Path

# ─── Rutas ───
AUDIO_DIR = Path(__file__).resolve().parent
ML_DIR = AUDIO_DIR.parent
REPO_DIR = ML_DIR.parent
DATA_DIR = ML_DIR / "data"            # datasets crudos (gitignored)
CLIPS_DIR = DATA_DIR / "clips"        # clips de 1 s a 16 kHz, por clase
BOARD_DIR = DATA_DIR / "board"        # grabaciones reales de la placa (capture_from_board.py)
DATASET_FILE = DATA_DIR / "audio_dataset.npz"
MODELS_DIR = ML_DIR / "models"
FIRMWARE_INCLUDE = REPO_DIR / "Hardware_ESP32" / "include"
FIRMWARE_SRC = REPO_DIR / "Hardware_ESP32" / "src"

# ─── Front-end (log-mel) ───
SAMPLE_RATE = 16000
WINDOW_SAMPLES = 480      # 30 ms
HOP_SAMPLES = 320         # 20 ms
FFT_SIZE = 512
NUM_MEL = 40
MEL_LOW_HZ = 60.0
MEL_HIGH_HZ = 7600.0
LOG_EPS = 1e-6

CLIP_SAMPLES = SAMPLE_RATE  # el modelo mira ventanas de 1 s
NUM_FRAMES = 1 + (CLIP_SAMPLES - WINDOW_SAMPLES) // HOP_SAMPLES  # 49

# El firmware corre el modelo cada INFERENCE_STRIDE_FRAMES frames nuevos (25 x 20 ms = 0.5 s).
INFERENCE_STRIDE_FRAMES = 25

# ─── Clases ───
# El orden define el indice de salida del modelo. Si lo cambias, reentrena.
CLASSES = ["fondo", "voz", "bocina", "sirena", "perro"]
# Clases que la placa informa a la app como alerta (CMD_AUDIO_EVENT).
ALERT_CLASSES = {"bocina", "sirena", "perro"}
# Puntaje minimo (promedio de 2 inferencias seguidas) para avisar. Mas alto = menos falsas alarmas
# pero mas alertas perdidas. Se copia al firmware (audio_model_data.h) al exportar.
ALERT_THRESHOLD = 0.7

# Mapeo de ESC-50 (categoria -> clase). Lo que no aparece se ignora.
ESC50_MAP = {
    "car_horn": "bocina",
    "siren": "sirena",
    "dog": "perro",
    # Fondo: ruidos ambientales y domesticos que NO son alertas
    **{c: "fondo" for c in [
        "rain", "sea_waves", "crackling_fire", "crickets", "chirping_birds", "water_drops",
        "wind", "pouring_water", "toilet_flush", "thunderstorm", "footsteps", "door_wood_knock",
        "mouse_click", "keyboard_typing", "door_wood_creaks", "can_opening", "washing_machine",
        "vacuum_cleaner", "clock_tick", "engine", "train", "airplane", "helicopter",
        "hand_saw", "chainsaw", "clapping", "breathing", "brushing_teeth", "drinking_sipping",
        "glass_breaking", "church_bells", "fireworks", "cat", "rooster", "pig", "cow", "frog",
        "hen", "insects", "sheep", "crow",
    ]},
    # Se excluyen a proposito (ambiguos con voz o sirena): crying_baby, laughing, coughing,
    # sneezing, snoring, clock_alarm.
}

# Mapeo de UrbanSound8K (opcional, recomendado en Lambda: muchos mas ejemplos de alertas).
URBANSOUND_MAP = {
    "car_horn": "bocina",
    "siren": "sirena",
    "dog_bark": "perro",
    "air_conditioner": "fondo",
    "children_playing": None,   # tiene voces: ambiguo
    "drilling": "fondo",
    "engine_idling": "fondo",
    "gun_shot": "fondo",
    "jackhammer": "fondo",
    "street_music": None,       # puede tener voz cantada
}

# ─── Entrenamiento ───
SEED = 1234
# Cuantos ejemplos aumentados se generan por cada ventana original de una clase de alerta
# (hay pocas en ESC-50, asi que se multiplican con mezcla de ruido, ganancia, etc.).
ALERT_AUGMENT_FACTOR = 12
# Tope de ventanas aumentadas por clase de alerta en train. Con UrbanSound8K hay muchas mas alertas
# originales: se hacen menos copias de cada una (cuida la RAM; el PC tiene ~7 GB).
ALERT_MAX_TRAIN_WINDOWS = 9000
MAX_WINDOWS_PER_CLASS = {"fondo": 6000, "voz": 6000}

# Fondos "dificiles": sonidos sostenidos o tonales que el modelo v1 confundia con sirena/perro.
# Con HARD_NEGATIVE_FACTOR > 0 se agregan esas copias aumentadas extra al train: baja las falsas
# alarmas (6% -> 2% en test) pero tambien las detecciones (72% -> 53%). Con los pocos ejemplos de
# alertas de ESC-50 no convino; vale la pena reprobarlo con UrbanSound8K o datos de la placa.
HARD_NEGATIVE_CATEGORIES = {
    "church_bells", "vacuum_cleaner", "rooster", "wind", "hen", "frog", "clock_tick", "crow",
    "washing_machine", "crickets", "insects", "engine", "airplane", "helicopter", "chainsaw",
    "hand_saw", "train", "chirping_birds", "cat",
}
HARD_NEGATIVE_FACTOR = 0
