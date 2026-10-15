"""Convierte los datasets crudos en features log-mel listas para entrenar.

    python audio/prepare_dataset.py

Que hace:
  1. Lee ESC-50, la voz chilena (OpenSLR 71), UrbanSound8K si esta, y las grabaciones
     reales de la placa en data/board/<clase>/*.wav (capture_from_board.py).
  2. Corta ventanas de 1 s a 16 kHz.
  3. Separa train/val/test sin mezclar grabaciones (por fold o por hablante).
  4. Aumenta el train simulando el microfono de la placa: ganancia, ruido de fondo mezclado,
     filtro pasa-altos/pasa-bajos, piso de ruido y saturacion.
  5. Guarda data/audio_dataset.npz con las features (mismas que calcula el firmware).
"""
import argparse
import csv
import hashlib
from collections import Counter, defaultdict
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import butter, resample_poly, sosfilt
from tqdm import tqdm

import config
from features import log_mel_batch

RAW_DIR = config.DATA_DIR / "raw"
SPLITS = ("train", "val", "test")
CLIP = config.CLIP_SAMPLES
SR = config.SAMPLE_RATE


# ───────────────────────── Lectura ─────────────────────────

def load_audio(path: Path) -> np.ndarray:
    """Audio mono a 16 kHz, en escala int16 (float32)."""
    data, rate = sf.read(str(path), dtype="float32", always_2d=True)
    data = data.mean(axis=1)
    if rate != SR:
        g = gcd(SR, rate)
        data = resample_poly(data, SR // g, rate // g).astype(np.float32)
    return data * 32767.0


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64)) + 1e-12))


def windows(audio: np.ndarray, hop: int, min_relative_rms: float = 0.0, max_count: int = 1000):
    """Ventanas de 1 s. Con min_relative_rms > 0 se descartan las partes silenciosas
    (ESC-50 rellena con silencio muchos clips de alertas)."""
    if len(audio) < CLIP:
        audio = np.pad(audio, (0, CLIP - len(audio)))
    starts = list(range(0, len(audio) - CLIP + 1, hop))
    chunks = [audio[s:s + CLIP] for s in starts]
    if min_relative_rms > 0:
        levels = [rms(c) for c in chunks]
        peak = max(levels)
        chunks = [c for c, level in zip(chunks, levels) if level >= min_relative_rms * peak and level > 30]
    return chunks[:max_count]


def split_by_key(key: str, val_fraction=0.1, test_fraction=0.1) -> str:
    """Asignacion determinista: el mismo hablante/archivo siempre cae en el mismo split."""
    h = int(hashlib.md5(key.encode()).hexdigest(), 16) % 1000 / 1000
    if h < test_fraction:
        return "test"
    if h < test_fraction + val_fraction:
        return "val"
    return "train"


# ───────────────────────── Fuentes ─────────────────────────

def collect_esc50(pools):
    meta = next(RAW_DIR.glob("esc50/*/meta/esc50.csv"), None)
    if meta is None:
        print("⚠ ESC-50 no encontrado (corre download_datasets.py)")
        return
    audio_dir = meta.parent.parent / "audio"
    rows = list(csv.DictReader(open(meta, encoding="utf-8")))
    for row in tqdm(rows, desc="ESC-50"):
        label = config.ESC50_MAP.get(row["category"])
        if label is None:
            continue
        fold = int(row["fold"])
        split = "test" if fold == 5 else "val" if fold == 4 else "train"
        audio = load_audio(audio_dir / row["filename"])
        is_alert = label in config.ALERT_CLASSES
        chunks = windows(audio, hop=SR // 4 if is_alert else SR, min_relative_rms=0.3 if is_alert else 0.0,
                         max_count=6 if is_alert else 5)
        pools[split][label].extend(chunks)
        if split == "train" and row["category"] in config.HARD_NEGATIVE_CATEGORIES:
            pools[split]["_hard_fondo"].extend(chunks)


def collect_urbansound(pools):
    meta = next(RAW_DIR.glob("urbansound/*/metadata/UrbanSound8K.csv"), None)
    if meta is None:
        return
    audio_dir = meta.parent.parent / "audio"
    rows = list(csv.DictReader(open(meta, encoding="utf-8")))
    for row in tqdm(rows, desc="UrbanSound8K"):
        label = config.URBANSOUND_MAP.get(row["class"])
        if label is None:
            continue
        fold = int(row["fold"])
        split = "test" if fold == 10 else "val" if fold == 9 else "train"
        try:
            audio = load_audio(audio_dir / f"fold{fold}" / row["slice_file_name"])
        except Exception as e:  # algunos archivos de US8K vienen en formatos raros
            print(f"  omitido {row['slice_file_name']}: {e}")
            continue
        is_alert = label in config.ALERT_CLASSES
        pools[split][label].extend(windows(audio, hop=SR // 2 if is_alert else SR,
                                           min_relative_rms=0.3 if is_alert else 0.0, max_count=4))


def collect_speech(pools, max_files: int):
    files = sorted(RAW_DIR.glob("slr71_*/**/*.wav"))
    if not files:
        print("⚠ Voz chilena (OpenSLR 71) no encontrada")
        return
    rng = np.random.default_rng(config.SEED)
    if len(files) > max_files:
        files = list(rng.choice(files, max_files, replace=False))
    for path in tqdm(files, desc="Voz (OpenSLR 71)"):
        speaker = path.stem.split("_")[1] if "_" in path.stem else path.stem  # clf_09334_xxx -> 09334
        split = split_by_key("speaker:" + speaker)
        audio = load_audio(path)
        pools[split]["voz"].extend(windows(audio, hop=SR, min_relative_rms=0.2, max_count=4))


def collect_board(pools):
    """Grabaciones reales de la placa: data/board/<clase>/*.wav. Pesan mas en el train."""
    if not config.BOARD_DIR.exists():
        return
    for class_dir in sorted(config.BOARD_DIR.iterdir()):
        if not class_dir.is_dir() or class_dir.name not in config.CLASSES:
            continue
        for path in sorted(class_dir.glob("*.wav")):
            split = split_by_key("board:" + path.name, val_fraction=0.15, test_fraction=0.15)
            audio = load_audio(path)
            is_alert = class_dir.name in config.ALERT_CLASSES
            chunks = windows(audio, hop=SR // 2, min_relative_rms=0.3 if is_alert else 0.0, max_count=10000)
            pools[split][class_dir.name].extend(chunks)
            pools[split]["_board_" + class_dir.name].extend(chunks)  # para reportar aparte
    counts = {k: len(v) for k, v in pools["train"].items() if k.startswith("_board_")}
    if counts:
        print(f"Grabaciones de la placa (train): {counts}")


def synthetic_background(rng, count: int):
    """Silencio digital, ruido blanco y rosa a bajo nivel: lo que 'oye' la placa en una pieza quieta."""
    chunks = []
    for i in range(count):
        kind = i % 3
        level = 10 ** rng.uniform(np.log10(2), np.log10(400))
        if kind == 0:
            chunk = rng.normal(0, 1, CLIP) * level * 0.05
        elif kind == 1:
            chunk = rng.normal(0, level, CLIP)
        else:
            spectrum = np.fft.rfft(rng.normal(0, 1, CLIP))
            spectrum /= np.sqrt(np.arange(1, len(spectrum) + 1))
            chunk = np.fft.irfft(spectrum, CLIP)
            chunk *= level / (rms(chunk) + 1e-9)
        chunks.append(chunk.astype(np.float32))
    return chunks


# ───────────────────────── Aumentacion (simula el microfono de la placa) ─────────────────────────

class MicSimulator:
    def __init__(self, rng, backgrounds):
        self.rng = rng
        self.backgrounds = backgrounds

    def __call__(self, clip: np.ndarray, mix_background: bool) -> np.ndarray:
        rng = self.rng
        x = clip.astype(np.float64)

        # Desplazamiento temporal circular (el evento no siempre esta centrado)
        x = np.roll(x, rng.integers(-CLIP // 4, CLIP // 4))

        # Ruido de fondo a un SNR aleatorio
        if mix_background and self.backgrounds and rng.random() < 0.8:
            background = self.backgrounds[rng.integers(len(self.backgrounds))].astype(np.float64)
            snr_db = rng.uniform(0, 20)
            scale = rms(x) / (rms(background) * 10 ** (snr_db / 20) + 1e-9)
            x = x + background * scale

        # Respuesta del microfono: pasa-altos siempre, pasa-bajos a veces
        cutoff = rng.uniform(60, 250)
        x = sosfilt(butter(2, cutoff, "highpass", fs=SR, output="sos"), x)
        if rng.random() < 0.5:
            x = sosfilt(butter(4, rng.uniform(4500, 7600), "lowpass", fs=SR, output="sos"), x)

        # Distancia / ganancia: de -30 dB a +10 dB
        x *= 10 ** (rng.uniform(-30, 10) / 20)

        # Piso de ruido electrico del microfono
        x += rng.normal(0, 10 ** rng.uniform(0, 1.6), CLIP)

        # Saturacion ocasional (alguien grita al lado del microfono)
        if rng.random() < 0.08:
            limit = rng.uniform(4000, 20000)
            x = np.clip(x * rng.uniform(1.5, 4), -limit, limit)

        return np.clip(np.round(x), -32768, 32767).astype(np.int16)


# ───────────────────────── Main ─────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max-speech-files", type=int, default=3000)
    parser.add_argument("--alert-augment", type=int, default=config.ALERT_AUGMENT_FACTOR)
    args = parser.parse_args()

    rng = np.random.default_rng(config.SEED)
    pools = {s: defaultdict(list) for s in SPLITS}

    collect_esc50(pools)
    collect_urbansound(pools)
    collect_speech(pools, args.max_speech_files)
    collect_board(pools)

    for split, count in (("train", 600), ("val", 80), ("test", 80)):
        pools[split]["fondo"].extend(synthetic_background(rng, count))

    simulator = MicSimulator(rng, pools["train"]["fondo"])
    output = {}
    for split in SPLITS:
        clips, labels = [], []
        for label in config.CLASSES:
            source = pools[split][label]
            if split == "train":
                cap = config.MAX_WINDOWS_PER_CLASS.get(label)
                if cap and len(source) > cap:
                    source = [source[i] for i in rng.choice(len(source), cap, replace=False)]
                is_alert = label in config.ALERT_CLASSES
                copies = args.alert_augment if is_alert else 1
                for clip in tqdm(source, desc=f"Aumentando {label}", leave=False):
                    for _ in range(copies):
                        clips.append(simulator(clip, mix_background=label != "fondo"))
                        labels.append(config.CLASSES.index(label))
            else:
                clips.extend(np.clip(np.round(c), -32768, 32767).astype(np.int16) for c in source)
                labels.extend([config.CLASSES.index(label)] * len(source))

        if split == "train":
            hard = pools[split]["_hard_fondo"]
            for clip in tqdm(hard, desc="Aumentando fondos dificiles", leave=False):
                for _ in range(config.HARD_NEGATIVE_FACTOR):
                    clips.append(simulator(clip, mix_background=False))
                    labels.append(config.CLASSES.index("fondo"))

        if not clips:
            raise SystemExit(f"No hay datos para el split '{split}'. ¿Corriste download_datasets.py?")
        order = rng.permutation(len(clips))
        clips = np.stack(clips)[order]
        output[f"y_{split}"] = np.asarray(labels, dtype=np.int64)[order]
        print(f"Calculando features de {split} ({len(clips)} ejemplos)...")
        output[f"x_{split}"] = log_mel_batch(clips)
        counts = Counter(output[f"y_{split}"].tolist())
        print(f"  {split}: " + ", ".join(f"{config.CLASSES[i]}={counts[i]}" for i in range(len(config.CLASSES))))

    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(config.DATASET_FILE, classes=np.array(config.CLASSES), **output)
    print(f"\nDataset guardado en {config.DATASET_FILE}")
    print("Siguiente paso: python audio/train.py")


if __name__ == "__main__":
    main()
