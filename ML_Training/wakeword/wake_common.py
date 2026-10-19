"""Utilidades compartidas: cortar los "Oye Iris" de las grabaciones, splits por toma y la medicion
en audio continuo (como corre en la placa: una ventana de 1 s cada STRIDE_FRAMES frames)."""
from pathlib import Path

import numpy as np

import wake_config as wc
from features import log_mel  # audio/features.py (front-end de la placa)
from prepare_dataset import load_audio  # audio/prepare_dataset.py

SR = wc.audio_config.SAMPLE_RATE
HOP = wc.audio_config.HOP_SAMPLES
NUM_FRAMES = wc.audio_config.NUM_FRAMES
CLIP = wc.audio_config.CLIP_SAMPLES


def find_utterances(audio: np.ndarray):
    """Tramos con voz por energia (las misiones piden pausas de 2-3 s entre cada "Oye Iris").
    Devuelve (buenos, todos): buenos = tramos de 0,3 a 1,3 s, en muestras."""
    hop = SR // 100  # 10 ms
    x = audio / 32768.0
    energy = np.sqrt(np.convolve(x ** 2, np.ones(hop * 3) / (hop * 3), "same")[::hop])
    db = 20 * np.log10(energy + 1e-7)
    floor, peak = np.percentile(db, 20), np.percentile(db, 99)
    active = db > floor + max(10.0, 0.35 * (peak - floor))
    segments, i = [], 0
    while i < len(active):
        if not active[i]:
            i += 1
            continue
        j = i
        while j < len(active) and (active[j] or active[j:j + 25].any()):  # une huecos < 250 ms
            j += 1
        if j - i >= 15:
            segments.append((max(0, (i - 5) * hop), min(len(audio), (j + 5) * hop)))  # +-50 ms
        i = j
    good = [(s, e) for s, e in segments if 0.3 * SR <= e - s <= 1.3 * SR]
    return good, segments


def take_split(index: int) -> str:
    """Split por toma (grabacion de 30 s): las tomas de test no se ven nunca al entrenar."""
    if index % 5 == 4:
        return "test"
    if index % 10 == 2:
        return "val"
    return "train"


def takes(label: str):
    """[(split, path)] de las grabaciones de una clase del wake word, en orden fijo."""
    paths = sorted((wc.BOARD_DIR / label).glob("*.wav"))
    return [(take_split(i), p) for i, p in enumerate(paths)]


def stream_windows(audio: np.ndarray, stride: int = wc.STRIDE_FRAMES):
    """Features de todas las ventanas de 1 s que veria la placa y el instante (s) en que termina cada una."""
    mel = log_mel(audio)
    starts = np.arange(0, len(mel) - NUM_FRAMES + 1, stride)
    x = np.stack([mel[s:s + NUM_FRAMES] for s in starts])[..., np.newaxis]
    end_times = ((starts + NUM_FRAMES - 1) * HOP + wc.audio_config.WINDOW_SAMPLES) / SR
    return x, end_times


def triggers(scores: np.ndarray, times: np.ndarray, threshold: float, refractory: float = wc.REFRACTORY_S):
    """Instantes en que la placa despertaria (con el tiempo muerto despues de cada activacion)."""
    fired, last = [], -1e9
    for score, t in zip(scores, times):
        if score >= threshold and t - last >= refractory:
            fired.append(t)
            last = t
    return fired


def score_streams(score_fn, streams: dict) -> dict:
    return {name: (score_fn(item["x"]), item["t"], item.get("utterances"), item["seconds"])
            for name, item in streams.items()}


def stream_metrics(cache: dict, threshold: float):
    """Con un umbral: (Oye Iris detectados, total, activaciones falsas por hora en cada audio de test).
    Un "Oye Iris" cuenta como detectado si hay activacion entre 0,25 s despues del comienzo del tramo y 1,2 s despues del fin; en las
    tomas de "Oye Iris", una activacion lejos de todo tramo cuenta como falsa."""
    hits = total = 0
    false_per_hour = {}
    for name, (scores, times, utterances, seconds) in cache.items():
        fired = triggers(scores, times, threshold)
        if utterances is None:
            false_per_hour[name] = len(fired) / seconds * 3600
            continue
        starts = np.asarray(utterances)[:, 0] / SR
        ends = np.asarray(utterances)[:, 1] / SR
        matched, false = set(), 0
        for t in fired:
            # El modelo suele despertar apenas oye "Oye Iri...": vale desde 0,25 s despues del comienzo.
            near = np.nonzero((t >= starts + 0.25) & (t <= ends + 1.2))[0]
            if len(near):
                matched.add(int(near[0]))
            else:
                false += 1
        hits += len(matched)
        total += len(ends)
        false_per_hour[name] = false / seconds * 3600
    return hits, total, false_per_hour


def negative_hours(cache: dict) -> float:
    return sum(v[3] for v in cache.values() if v[2] is None) / 3600


def stream_report(cache: dict, thresholds=(0.5, 0.7, 0.8, 0.9, 0.95, 0.98)) -> str:
    """Tabla por umbral con la medicion en audio continuo de test (cache = score_streams(...))."""
    names = list(cache)
    lines = ["Umbral | Oye Iris detectados | activaciones falsas por hora: " + " / ".join(names)]
    for th in thresholds:
        hits, total, fa = stream_metrics(cache, th)
        lines.append(f"  {th:4.2f} | {hits:3d}/{total:3d} = {hits / max(1, total) * 100:5.1f}% | "
                     + " / ".join(f"{fa[n]:5.1f}" for n in names))
    minutes = {n: round(v[3] / 60, 1) for n, v in cache.items()}
    lines.append(f"(minutos de audio de test: {minutes})")
    return "\n".join(lines)


def load_streams(path: Path = wc.STREAMS_FILE) -> dict:
    data = np.load(path, allow_pickle=True)
    return data["streams"].item()
