"""Prueba el modelo de vision int8 en el PC, igual que lo correria la placa.

    python vision/live_demo.py                       # webcam del notebook
    python vision/live_demo.py --camera 1            # otra camara
    python vision/live_demo.py --simulate            # ademas degrada la imagen como la OV2640
    python vision/live_demo.py --images carpeta/     # fotos sueltas (jpg/png), una por una

La webcam se pasa a grises, se recorta al centro (cuadrado) y se reduce a 96x96, como
FRAMESIZE_96X96 de la placa. Usa el mismo suavizado (promedio de 2 frames) y el mismo umbral
que el firmware. En la ventana: Q o Esc para salir, S para cambiar --simulate.
"""
import argparse
import os
import time
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import cv2
import numpy as np

import config
from augment import camera_degrade
from export_model import TFLITE_MODEL, int8_predictor

THRESHOLD = config.ALERT_THRESHOLD


def to_board_frame(bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY) if bgr.ndim == 3 else bgr
    h, w = gray.shape
    side = min(h, w)
    y0, x0 = (h - side) // 2, (w - side) // 2
    return cv2.resize(gray[y0:y0 + side, x0:x0 + side], (config.IMAGE_SIZE, config.IMAGE_SIZE),
                      interpolation=cv2.INTER_AREA)


class Detector:
    def __init__(self, model_path):
        self.predict, _ = int8_predictor(Path(model_path).read_bytes())
        self.previous = np.zeros(len(config.CLASSES), dtype=np.float32)

    def __call__(self, frame96: np.ndarray):
        scores = self.predict(frame96[np.newaxis])[0]
        smoothed = 0.5 * (scores + self.previous)
        self.previous = scores
        alerts = [(smoothed[i], c) for i, c in enumerate(config.CLASSES) if c in config.ALERT_CLASSES]
        best, label = max(alerts)
        return scores, (label, best) if best >= THRESHOLD else None


def describe(scores, alert) -> str:
    bars = "  ".join(f"{c}:{'█' * int(s * 10):<10s}" for c, s in zip(config.CLASSES, scores))
    flag = f"  👁 AVISO: {alert[0]} ({alert[1] * 100:.0f}%)" if alert else ""
    return bars + flag


def draw(frame96, scores, alert, simulate) -> np.ndarray:
    view = cv2.resize(frame96, (384, 384), interpolation=cv2.INTER_NEAREST)
    view = cv2.cvtColor(view, cv2.COLOR_GRAY2BGR)
    panel = np.zeros((384, 260, 3), np.uint8)
    for i, (c, s) in enumerate(zip(config.CLASSES, scores)):
        y = 40 + i * 50
        cv2.putText(panel, f"{c} {s * 100:3.0f}%", (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (230, 230, 230), 1)
        cv2.rectangle(panel, (10, y + 8), (10 + int(s * 230), y + 20), (0, 200, 255) if c != "nada" else (120, 120, 120), -1)
    if alert:
        cv2.putText(panel, f"AVISO: {alert[0]}", (10, 330), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
    cv2.putText(panel, "simulando OV2640" if simulate else "imagen limpia", (10, 370),
                cv2.FONT_HERSHEY_SIMPLEX, 0.45, (160, 160, 160), 1)
    return np.hstack([view, panel])


def run_camera(detector, index, interval, simulate):
    capture = cv2.VideoCapture(index)
    if not capture.isOpened():
        raise SystemExit(f"No se pudo abrir la camara {index}")
    rng = np.random.default_rng()
    started = last = time.time()
    scores, alert = np.zeros(len(config.CLASSES)), None
    print("Mirando... (Q o Esc para salir, S para simular la OV2640)")
    while True:
        ok, bgr = capture.read()
        if not ok:
            break
        frame = to_board_frame(bgr)
        if simulate:
            frame = camera_degrade(frame, rng, strength=0.7)
        # La placa infiere cada VISION_INTERVAL_MS (1 s); aqui igual, para que el suavizado se comporte igual.
        if time.time() - last >= interval:
            last = time.time()
            scores, alert = detector(frame)
            print(f"{last - started:6.1f}s  {describe(scores, alert)}")
        cv2.imshow("Iris vision (96x96)", draw(frame, scores, alert, simulate))
        key = cv2.waitKey(1) & 0xFF
        if key in (ord("q"), 27):
            break
        if key == ord("s"):
            simulate = not simulate
    capture.release()
    cv2.destroyAllWindows()


def run_images(detector, folder, simulate):
    paths = sorted(p for p in Path(folder).rglob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"})
    rng = np.random.default_rng(config.SEED)
    for path in paths:
        frame = to_board_frame(cv2.imread(str(path)))
        if simulate:
            frame = camera_degrade(frame, rng, strength=0.7)
        detector.previous[:] = 0  # cada foto es independiente: sin suavizado
        scores = detector.predict(frame[np.newaxis])[0]
        best = int(np.argmax(scores))
        print(f"{path.name:40s} -> {config.CLASSES[best]:9s} {scores[best] * 100:3.0f}%   {describe(scores, None)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--images", help="carpeta con fotos en vez de la webcam")
    parser.add_argument("--simulate", action="store_true", help="degradar como la OV2640 (ruido, desenfoque...)")
    parser.add_argument("--interval", type=float, default=1.0, help="segundos entre inferencias (VISION_INTERVAL_MS)")
    parser.add_argument("--model", default=str(TFLITE_MODEL))
    args = parser.parse_args()

    detector = Detector(args.model)
    try:
        if args.images:
            run_images(detector, args.images, args.simulate)
        else:
            run_camera(detector, args.camera, args.interval, args.simulate)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
