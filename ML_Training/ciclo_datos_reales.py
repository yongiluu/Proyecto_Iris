"""Ciclo completo con los datos reales de la app (misiones): importar -> etiquetar -> reentrenar -> comparar.

    python ciclo_datos_reales.py iris_dataset_20261018_180000.zip
    python ciclo_datos_reales.py iris_dataset.zip --solo vision,cercania      # solo algunos modelos
    python ciclo_datos_reales.py --sin-importar                                # ya importado antes

Hace, uno a la vez (el PC tiene ~7 GB de RAM):
  1. Respalda los modelos actuales en models/antes_<fecha>/.
  2. Importa el zip (import_phone_data.py): audio -> data/board, fotos -> data/vision_board,
     mision de cercania -> data/proximity_board.
  3. Cercania: el profesor de profundidad etiqueta tus fotos (depth_labels.py) y se reentrena partiendo
     del modelo actual (fine-tuning).
  4. Audio y vision: prepare_dataset (suma tus datos) y fine-tuning desde el modelo actual.
  5. Exporta cada modelo (archivos del firmware) y lo compara con el anterior SOBRE EL MISMO TEST
     (compare_models.py). Si el nuevo es peor, el informe lo dice: para volver al anterior basta
     `python <audio|vision>/export_model.py --tflite models/antes_<fecha>/<modelo>.tflite`
     (cercania: vision/proximity_export.py --tflite ...).
  6. Verifica la libreria del firmware (tests/test_tflm_kernels.py) y compila la XIAO.

Todo queda en ciclo_<fecha>.log. Despues: revisar el informe, subir el firmware y probar.
"""
import argparse
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ML_DIR = Path(__file__).resolve().parent
MODELS = ML_DIR / "models"
PIO = Path.home() / ".platformio" / "penv" / "Scripts" / "pio.exe"
FILES = {
    "audio": ["audio_events.keras", "audio_events_int8.tflite"],
    "vision": ["vision_scenes.keras", "vision_scenes_int8.tflite"],
    "cercania": ["proximity.keras", "proximity_int8.tflite"],
}


class Logger:
    def __init__(self, path: Path):
        self.file = open(path, "a", encoding="utf-8")

    def step(self, text: str) -> None:
        line = f"\n=== {datetime.now():%H:%M:%S} {text} ==="
        print(line, flush=True)
        self.file.write(line + "\n")
        self.file.flush()

    def run(self, *command, cwd=ML_DIR) -> None:
        print("$", " ".join(str(c) for c in command), flush=True)
        self.file.write("$ " + " ".join(str(c) for c in command) + "\n")
        self.file.flush()
        result = subprocess.run([str(c) for c in command], cwd=cwd, stdout=self.file, stderr=subprocess.STDOUT,
                                env={**__import__("os").environ, "PYTHONIOENCODING": "utf-8"})
        if result.returncode != 0:
            raise SystemExit(f"Fallo: {' '.join(str(c) for c in command)} (ver el log)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("zip", nargs="?", help="zip exportado por la app (o carpeta iris_dataset)")
    parser.add_argument("--sin-importar", action="store_true", help="los datos ya estan importados")
    parser.add_argument("--solo", default="audio,vision,cercania", help="modelos a reentrenar, separados por coma")
    parser.add_argument("--epocas", type=int, default=10, help="epocas de fine-tuning")
    parser.add_argument("--sin-compilar", action="store_true")
    args = parser.parse_args()
    if not args.zip and not args.sin_importar:
        parser.error("indica el zip de la app o --sin-importar")
    targets = [t.strip() for t in args.solo.split(",") if t.strip()]
    python = sys.executable

    stamp = f"{datetime.now():%Y%m%d_%H%M}"
    log = Logger(ML_DIR / f"ciclo_{stamp}.log")
    backup = MODELS / f"antes_{stamp}"
    backup.mkdir(parents=True, exist_ok=True)
    for target in targets:
        for name in FILES[target]:
            if (MODELS / name).exists():
                shutil.copy2(MODELS / name, backup / name)
    log.step(f"Modelos actuales respaldados en {backup}")

    if not args.sin_importar:
        log.step("Importando los datos de la app")
        log.run(python, "import_phone_data.py", args.zip)

    if "cercania" in targets:
        board = ML_DIR / "data" / "proximity_board"
        if board.exists() and any(board.rglob("*.*")):
            log.step("Cercania: el profesor de profundidad etiqueta tus fotos")
            for old in (ML_DIR / "data" / "proximity_labels").glob("board_*.npz"):
                old.unlink()  # se re-etiqueta todo (son pocas fotos) para incluir las nuevas
            log.run(python, "vision/depth_labels.py", "--source", board, "--name", "board", "--n", "0")
        log.step("Cercania: fine-tuning")
        log.run(python, "vision/proximity_train.py", "--rebuild", "--finetune", "--epochs", args.epocas)
        log.run(python, "vision/proximity_export.py")
        log.run(python, "compare_models.py", "proximity", backup / "proximity_int8.tflite", MODELS / "proximity_int8.tflite")

    if "audio" in targets:
        log.step("Audio: dataset con tus grabaciones y fine-tuning")
        log.run(python, "audio/prepare_dataset.py")
        log.run(python, "audio/train.py", "--finetune", "--epochs", args.epocas)
        log.run(python, "audio/export_model.py")
        log.run(python, "compare_models.py", "audio", backup / "audio_events_int8.tflite", MODELS / "audio_events_int8.tflite")

    if "vision" in targets:
        log.step("Vision: dataset con tus fotos y fine-tuning")
        log.run(python, "vision/prepare_dataset.py", "--hard-negatives", backup / "vision_scenes_int8.tflite")
        log.run(python, "vision/train.py", "--finetune", "--epochs", args.epocas, "--workers", "4")
        log.run(python, "vision/export_model.py")
        log.run(python, "compare_models.py", "vision", backup / "vision_scenes_int8.tflite", MODELS / "vision_scenes_int8.tflite")

    log.step("Verificando la libreria del firmware con los modelos nuevos")
    log.run(python, "tests/test_tflm_kernels.py", "--n", "300")
    if not args.sin_compilar and PIO.exists():
        log.step("Compilando el firmware de la XIAO")
        log.run(PIO, "run", "-e", "seeed_xiao_esp32s3", "-j", "4", cwd=ML_DIR.parent / "Hardware_ESP32")

    log.step(f"Listo. Revisa las comparaciones en ciclo_{stamp}.log (antes vs. despues sobre el mismo test).")


if __name__ == "__main__":
    main()
