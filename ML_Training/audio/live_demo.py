"""Prueba el modelo int8 en el PC, igual que lo correria la placa.

    python audio/live_demo.py                    # microfono del notebook
    python audio/live_demo.py --wav sirena.wav   # un archivo
    python audio/live_demo.py --gain 10          # si tu microfono suena bajo (dB)

Usa models/audio_events_int8.tflite, las mismas features y el mismo suavizado/umbral
que el firmware. Sirve para probar antes de tener el prototipo.
"""
import argparse
import os
import time
from collections import deque
from math import gcd

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from features import log_mel

THRESHOLD = config.ALERT_THRESHOLD
STEP_SAMPLES = config.INFERENCE_STRIDE_FRAMES * config.HOP_SAMPLES  # 0.5 s


class Detector:
    def __init__(self, model_path):
        self.interpreter = tf.lite.Interpreter(model_path=str(model_path))
        self.interpreter.allocate_tensors()
        self.inp = self.interpreter.get_input_details()[0]
        self.out = self.interpreter.get_output_details()[0]
        self.previous = np.zeros(len(config.CLASSES), dtype=np.float32)

    def __call__(self, clip: np.ndarray):
        features = log_mel(clip)[np.newaxis, ..., np.newaxis]
        scale, zero = self.inp["quantization"]
        q = np.clip(np.round(features / scale + zero), -128, 127).astype(np.int8)
        self.interpreter.set_tensor(self.inp["index"], q)
        self.interpreter.invoke()
        out_scale, out_zero = self.out["quantization"]
        scores = (self.interpreter.get_tensor(self.out["index"])[0].astype(np.float32) - out_zero) * out_scale
        smoothed = 0.5 * (scores + self.previous)
        self.previous = scores
        return scores, smoothed


def show(t: float, scores, smoothed):
    bars = "  ".join(f"{c}:{'█' * int(s * 10):<10s}" for c, s in zip(config.CLASSES, scores))
    alerts = [(smoothed[i], c) for i, c in enumerate(config.CLASSES) if c in config.ALERT_CLASSES]
    best, label = max(alerts)
    flag = f"  🔔 ALERTA: {label} ({best * 100:.0f}%)" if best >= THRESHOLD else ""
    print(f"{t:6.1f}s  {bars}{flag}")


def run_wav(path, detector, gain):
    import soundfile as sf
    from scipy.signal import resample_poly
    audio, rate = sf.read(path, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if rate != config.SAMPLE_RATE:
        g = gcd(config.SAMPLE_RATE, rate)
        audio = resample_poly(audio, config.SAMPLE_RATE // g, rate // g)
    audio = np.clip(audio * 32767 * 10 ** (gain / 20), -32768, 32767)
    audio = np.pad(audio, (config.CLIP_SAMPLES, 0))
    for end in range(config.CLIP_SAMPLES, len(audio) + 1, STEP_SAMPLES):
        show((end - config.CLIP_SAMPLES) / config.SAMPLE_RATE, *detector(audio[end - config.CLIP_SAMPLES:end]))


def run_microphone(detector, gain):
    import sounddevice as sd
    ring = deque(maxlen=config.CLIP_SAMPLES)
    ring.extend(np.zeros(config.CLIP_SAMPLES))
    print("Escuchando... (Ctrl+C para salir)")
    started = time.time()
    with sd.InputStream(samplerate=config.SAMPLE_RATE, channels=1, dtype="int16", blocksize=STEP_SAMPLES) as stream:
        while True:
            block, _ = stream.read(STEP_SAMPLES)
            ring.extend(np.clip(block[:, 0].astype(np.float32) * 10 ** (gain / 20), -32768, 32767))
            show(time.time() - started, *detector(np.asarray(ring)))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wav")
    parser.add_argument("--gain", type=float, default=0.0)
    parser.add_argument("--model", default=str(config.MODELS_DIR / "audio_events_int8.tflite"))
    args = parser.parse_args()

    detector = Detector(args.model)
    try:
        run_wav(args.wav, detector, args.gain) if args.wav else run_microphone(detector, args.gain)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
