"""Demo en el PC de la IA que corre DENTRO de la placa: vision (webcam) + sonido (microfono).

    python demo_pc.py                 # webcam 0 + microfono por defecto
    python demo_pc.py --camera 1      # otra camara
    python demo_pc.py --simulate      # la imagen se degrada como la camara OV2640 (tecla S)
    python demo_pc.py --no-audio      # solo vision

Usa los mismos modelos int8 que el firmware (models/*_int8.tflite), las mismas entradas
(96x96 grises; log-mel de 1 s a 16 kHz), el mismo suavizado y los mismos umbrales. Sirve para
mostrar el sistema sin el prototipo. Q o Esc para salir.
"""
import argparse
import importlib
import os
import sys
import threading
import time
from collections import deque
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")

import cv2
import numpy as np

ML_DIR = Path(__file__).resolve().parent
SHARED = ("config", "features", "train", "export_model", "augment", "live_demo")


def load_package(name: str) -> dict:
    """audio/ y vision/ tienen modulos con el mismo nombre (config, train...): se cargan por separado."""
    for module in SHARED:
        sys.modules.pop(module, None)
    sys.path.insert(0, str(ML_DIR / name))
    try:
        return {m: importlib.import_module(m) for m in ("config", "live_demo")}
    finally:
        sys.path.pop(0)


AUDIO_NAMES = {"fondo": "ruido de fondo", "voz": "voces", "bocina": "BOCINA", "sirena": "SIRENA", "perro": "PERRO"}
VISION_NAMES = {"nada": "nada", "persona": "PERSONA", "vehiculo": "VEHICULO", "escalera": "ESCALERA",
                "puerta": "PUERTA"}


class AudioThread(threading.Thread):
    """Escucha el microfono y corre el modelo de audio cada 0,5 s, como la placa."""

    def __init__(self, audio):
        super().__init__(daemon=True)
        self.config = audio["config"]
        self.detector = audio["live_demo"].Detector(self.config.MODELS_DIR / "audio_events_int8.tflite")
        self.scores = np.zeros(len(self.config.CLASSES))
        self.alert = None
        self.alert_time = 0.0
        self.error = None

    def run(self):
        try:
            import sounddevice as sd
            step = self.config.INFERENCE_STRIDE_FRAMES * self.config.HOP_SAMPLES
            ring = deque(np.zeros(self.config.CLIP_SAMPLES), maxlen=self.config.CLIP_SAMPLES)
            with sd.InputStream(samplerate=self.config.SAMPLE_RATE, channels=1, dtype="int16", blocksize=step) as stream:
                while True:
                    block, _ = stream.read(step)
                    ring.extend(block[:, 0].astype(np.float32))
                    scores, smoothed = self.detector(np.asarray(ring))
                    self.scores = scores
                    alerts = [(smoothed[i], c) for i, c in enumerate(self.config.CLASSES)
                              if c in self.config.ALERT_CLASSES]
                    best, label = max(alerts)
                    if best >= self.config.ALERT_THRESHOLD:
                        self.alert, self.alert_time = (label, best), time.time()
        except Exception as e:  # noqa: BLE001 - sin microfono la demo sigue con vision
            self.error = str(e)


def bars(canvas, x, y, title, classes, scores, names, alert_classes):
    cv2.putText(canvas, title, (x, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1)
    for i, (c, s) in enumerate(zip(classes, scores)):
        yy = y + 22 + i * 26
        color = (0, 170, 255) if c in alert_classes else (150, 150, 150)
        cv2.putText(canvas, f"{names.get(c, c):<14s}", (x, yy + 12), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (220, 220, 220), 1)
        cv2.rectangle(canvas, (x + 120, yy), (x + 120 + int(s * 150), yy + 14), color, -1)
        cv2.putText(canvas, f"{s * 100:3.0f}%", (x + 275, yy + 12), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (220, 220, 220), 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument("--no-audio", action="store_true")
    args = parser.parse_args()

    audio_thread = None
    if not args.no_audio:
        audio_thread = AudioThread(load_package("audio"))
        audio_thread.start()
    vision = load_package("vision")
    vcfg, vdemo = vision["config"], vision["live_demo"]
    detector = vdemo.Detector(vcfg.MODELS_DIR / "vision_scenes_int8.tflite")
    from augment import camera_degrade  # el de vision (cargado por live_demo)

    capture = cv2.VideoCapture(args.camera)
    if not capture.isOpened():
        raise SystemExit(f"No se pudo abrir la camara {args.camera}")
    rng = np.random.default_rng()
    simulate = args.simulate
    vscores, valert, last, valert_time = np.zeros(len(vcfg.CLASSES)), None, 0.0, 0.0
    print("Demo Iris en marcha. Q o Esc para salir, S para simular la camara OV2640.")

    while True:
        ok, bgr = capture.read()
        if not ok:
            break
        frame = vdemo.to_board_frame(bgr)
        if simulate:
            frame = camera_degrade(frame, rng, strength=0.7)
        if time.time() - last >= 1.0:  # la placa infiere 1 vez por segundo
            last = time.time()
            vscores, alert = detector(frame)
            if alert:
                valert, valert_time = alert, time.time()

        canvas = np.zeros((480, 820, 3), np.uint8)
        canvas[48:432, 16:400] = cv2.cvtColor(cv2.resize(frame, (384, 384), interpolation=cv2.INTER_NEAREST),
                                              cv2.COLOR_GRAY2BGR)
        cv2.putText(canvas, "Lo que ve la placa (96x96)" + ("  [simulando OV2640]" if simulate else ""),
                    (16, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (200, 200, 200), 1)
        bars(canvas, 420, 40, "Vision (camara)", vcfg.CLASSES, vscores, VISION_NAMES, vcfg.ALERT_CLASSES)
        if valert and time.time() - valert_time < 4:
            cv2.putText(canvas, f"Iris: Adelante hay {VISION_NAMES[valert[0]].lower()}", (420, 200),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)
        if audio_thread is not None:
            acfg = audio_thread.config
            if audio_thread.error:
                cv2.putText(canvas, f"Sin microfono: {audio_thread.error[:40]}", (420, 250),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 255), 1)
            else:
                bars(canvas, 420, 250, "Sonido (microfono)", acfg.CLASSES, audio_thread.scores, AUDIO_NAMES,
                     acfg.ALERT_CLASSES)
                if audio_thread.alert and time.time() - audio_thread.alert_time < 4:
                    cv2.putText(canvas, f"Contexto: se escucha {AUDIO_NAMES[audio_thread.alert[0]].lower()}",
                                (420, 420), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 200, 255), 2)
        cv2.imshow("Iris - IA en la placa (demo en PC)", canvas)
        key = cv2.waitKey(1) & 0xFF
        if key in (ord("q"), 27):
            break
        if key == ord("s"):
            simulate = not simulate
    capture.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
