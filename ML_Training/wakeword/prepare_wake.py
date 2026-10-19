"""Arma el dataset del wake word "Oye Iris" con las grabaciones de la app (misiones "Iris Wake Word").

    python wakeword/prepare_wake.py

Positivos: cada "Oye Iris" se corta solo (por energia) de las tomas de 30 s. En train se usa
POSITIVE_AUGMENT veces: otra velocidad de habla (0,88-1,12x), otra posicion dentro de la ventana de 1 s,
ruido de fondo (calle, casa, ESC-50) y respuesta/ganancia del microfono.
Negativos ("otro"): frases parecidas ("oye", "Iris" sola, "oye Isis"...), los bordes de las tomas de
"Oye Iris" sin la frase completa, fondos y voz grabados con la app, voz chilena (OpenSLR 71) y el
dataset del modelo de audio (fondos, bocinas, sirenas, perros, voz).
Las tomas se separan en train/val/test ENTERAS: el test son grabaciones que el modelo nunca vio.

Guarda data/wakeword_dataset.npz y data/wakeword_test_streams.npz (audio continuo de test).
Siguiente paso: python wakeword/train_wake.py
"""
import argparse
from collections import Counter

import numpy as np
from scipy.signal import butter, resample, sosfilt
from tqdm import tqdm

import wake_config as wc
from wake_common import CLIP, SR, find_utterances, stream_windows, takes
from features import log_mel_batch  # audio/
from prepare_dataset import RAW_DIR, load_audio, rms, split_by_key, synthetic_background, windows  # audio/

OTRO, OYE = 0, 1


def augment(clip, rng, backgrounds, mix=True):
    """Microfono de la placa y ambiente (sin desplazar en el tiempo: el "Oye Iris" no debe cortarse)."""
    x = clip.astype(np.float64)
    if mix and rng.random() < 0.7:
        background = backgrounds[rng.integers(len(backgrounds))].astype(np.float64)
        snr_db = rng.uniform(3, 25)
        x = x + background * (rms(x) / (rms(background) * 10 ** (snr_db / 20) + 1e-9))
    x = sosfilt(butter(2, rng.uniform(60, 250), "highpass", fs=SR, output="sos"), x)
    if rng.random() < 0.5:
        x = sosfilt(butter(4, rng.uniform(4500, 7600), "lowpass", fs=SR, output="sos"), x)
    x *= 10 ** (rng.uniform(-25, 8) / 20)
    x += rng.normal(0, 10 ** rng.uniform(0, 1.6), len(x))
    if rng.random() < 0.05:
        limit = rng.uniform(4000, 20000)
        x = np.clip(x * rng.uniform(1.5, 3), -limit, limit)
    return np.clip(np.round(x), -32768, 32767).astype(np.int16)


def positive_clip(padded, pad, segment, rng, speed=1.0):
    """Ventana de 1 s con el tramo completo adentro, en una posicion al azar y a otra velocidad."""
    start, end = segment
    span = int(round(CLIP * speed))
    margin = int(0.03 * SR * speed)
    room = span - (end - start) - 2 * margin
    if room < 0:
        return None
    offset = margin + int(rng.integers(0, room + 1))
    chunk = padded[pad + start - offset: pad + start - offset + span]
    return resample(chunk, CLIP).astype(np.float32) if span != CLIP else chunk.astype(np.float32)


def coverage(window_start, segments):
    """Fraccion maxima de algun tramo de voz que cae dentro de la ventana [start, start + 1 s)."""
    best = 0.0
    for s, e in segments:
        overlap = min(e, window_start + CLIP) - max(s, window_start)
        best = max(best, overlap / (e - s))
    return best


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--augment", type=int, default=wc.POSITIVE_AUGMENT)
    parser.add_argument("--speech-files", type=int, default=wc.EXTRA_SPEECH_FILES)
    args = parser.parse_args()
    rng = np.random.default_rng(wc.SEED)

    raw = {s: ([], []) for s in ("train", "val", "test")}  # audio crudo (clips, etiquetas)
    streams = {}

    def add(split, clip, label):
        raw[split][0].append(clip)
        raw[split][1].append(label)

    # ── Fondos para mezclar: grabados con la app + ESC-50 + ruido sintetico ──
    backgrounds = []
    for path in sorted((wc.AUDIO_BOARD_DIR / "fondo").glob("*.wav")):
        if split_by_key("board:" + path.name, val_fraction=0.15, test_fraction=0.15) == "train":
            backgrounds += windows(load_audio(path), hop=SR // 2)
    esc_dir = next(RAW_DIR.glob("esc50/*/audio"), None)
    if esc_dir is not None:
        esc_files = sorted(esc_dir.glob("[1-3]-*.wav"))  # folds 1-3 (los de train del modelo de audio)
        for path in rng.choice(esc_files, min(500, len(esc_files)), replace=False):
            backgrounds += windows(load_audio(path), hop=SR, max_count=2)
    backgrounds += synthetic_background(rng, 200)
    print(f"{len(backgrounds)} fondos para mezclar")

    # ── "Oye Iris" ──
    oye_takes = takes("oye_iris")
    if not oye_takes:
        raise SystemExit(f"No hay grabaciones en {wc.BOARD_DIR / 'oye_iris'}: corre import_phone_data.py")
    test_audio, test_utts, offset = [], [], 0
    counts = Counter()
    for split, path in tqdm(oye_takes, desc="Oye Iris"):
        audio = load_audio(path)
        good, segments = find_utterances(audio)
        pad = 2 * CLIP
        padded = np.pad(audio, pad, mode="reflect")
        for segment in good:
            if split == "train":
                for _ in range(args.augment):
                    clip = positive_clip(padded, pad, segment, rng, speed=rng.uniform(0.88, 1.12))
                    if clip is not None:
                        add(split, augment(clip, rng, backgrounds), OYE)
            else:
                clip = positive_clip(padded, pad, segment, rng)
                if clip is not None:
                    add(split, clip, OYE)
                    add(split, augment(clip, rng, backgrounds), OYE)
            counts[split] += 1
        # Negativos de la misma toma: ventanas que no contienen ni un 30% de ningun tramo de voz.
        for start in range(0, len(audio) - CLIP + 1, SR // 10):
            if coverage(start, segments) <= 0.3:
                clip = audio[start:start + CLIP]
                add(split, augment(clip, rng, backgrounds) if split == "train" else clip, OTRO)
        if split == "test":
            test_audio.append(audio)
            test_utts += [(s + offset, e + offset) for s, e in good]
            offset += len(audio)
    print(f"Tramos 'Oye Iris' por split: {dict(counts)}")
    test_audio = np.concatenate(test_audio)
    x, t = stream_windows(test_audio)
    streams["oye_iris"] = {"x": x.astype(np.float16), "t": t, "utterances": np.asarray(test_utts),
                           "seconds": len(test_audio) / SR}

    # ── Frases parecidas (no deben despertar) ──
    parecidas_test = []
    for split, path in tqdm(takes("no_wake"), desc="Frases parecidas"):
        audio = load_audio(path)
        for clip in windows(audio, hop=SR // 4 if split == "train" else SR // 2):
            if split == "train":
                for _ in range(3):
                    add(split, augment(clip, rng, backgrounds), OTRO)
            else:
                add(split, clip, OTRO)
        if split == "test":
            parecidas_test.append(audio)
    if parecidas_test:
        audio = np.concatenate(parecidas_test)
        x, t = stream_windows(audio)
        streams["frases_parecidas"] = {"x": x.astype(np.float16), "t": t, "seconds": len(audio) / SR}

    # ── Fondos, voz y alertas grabados con la app ──
    app_test = []
    for path in sorted(wc.AUDIO_BOARD_DIR.glob("*/*.wav")):
        split = split_by_key("board:" + path.name, val_fraction=0.15, test_fraction=0.15)
        audio = load_audio(path)
        for clip in windows(audio, hop=SR // 2):
            add(split, augment(clip, rng, backgrounds, mix=False) if split == "train" else clip, OTRO)
        if split == "test":
            app_test.append(audio)
    if app_test:
        audio = np.concatenate(app_test)
        x, t = stream_windows(audio)
        streams["fondos_app"] = {"x": x.astype(np.float16), "t": t, "seconds": len(audio) / SR}

    # ── Voz chilena (OpenSLR 71), por hablante ──
    files = sorted(RAW_DIR.glob("slr71_*/**/*.wav"))
    by_split = {"train": [], "val": [], "test": []}
    for path in files:
        speaker = path.stem.split("_")[1] if "_" in path.stem else path.stem
        by_split[split_by_key("speaker:" + speaker)].append(path)
    for path in tqdm(rng.permutation(by_split["train"])[:args.speech_files], desc="Voz chilena (train)"):
        for clip in windows(load_audio(path), hop=SR, min_relative_rms=0.2, max_count=3):
            add("train", augment(clip, rng, backgrounds), OTRO)
    for path in rng.permutation(by_split["val"])[:300]:
        for clip in windows(load_audio(path), hop=SR, min_relative_rms=0.2, max_count=2):
            add("val", clip, OTRO)
    speech = [load_audio(p) for p in tqdm(rng.permutation(by_split["test"])[:700], desc="Voz chilena (test)")]
    if speech:
        audio = np.concatenate(speech)
        x, t = stream_windows(audio)
        streams["voz_chilena"] = {"x": x.astype(np.float16), "t": t, "seconds": len(audio) / SR}

    # ── Features ──
    output = {}
    for split, (clips, labels) in raw.items():
        print(f"Calculando features de {split} ({len(clips)} ventanas)...")
        output[f"x_{split}"] = np.concatenate([
            log_mel_batch(np.stack(clips[i:i + 2000])).astype(np.float16) for i in range(0, len(clips), 2000)])
        output[f"y_{split}"] = np.asarray(labels, dtype=np.int64)
    del raw

    # ── Dataset del modelo de audio (ya en features): todo es "otro" ──
    if wc.NEGATIVES_FILE.exists():
        bank = np.load(wc.NEGATIVES_FILE)
        for split, cap in (("train", wc.NEGATIVE_BANK_MAX), ("val", 3000), ("test", 100000)):
            x = bank[f"x_{split}"]
            pick = np.sort(rng.choice(len(x), min(cap, len(x)), replace=False))
            output[f"x_{split}"] = np.concatenate([output[f"x_{split}"], x[pick].astype(np.float16)])
            output[f"y_{split}"] = np.concatenate([output[f"y_{split}"], np.zeros(len(pick), np.int64)])
            print(f"  + {len(pick)} ventanas del dataset de audio en {split}")
    else:
        print(f"⚠ No esta {wc.NEGATIVES_FILE}: copia data/audio_dataset.npz ahi (negativos de fondo y voz)")

    for split in ("train", "val", "test"):
        order = rng.permutation(len(output[f"y_{split}"]))
        output[f"x_{split}"] = output[f"x_{split}"][order]
        output[f"y_{split}"] = output[f"y_{split}"][order]
        c = Counter(output[f"y_{split}"].tolist())
        print(f"  {split}: otro={c[OTRO]}  oye_iris={c[OYE]}")

    np.savez(wc.DATASET_FILE, classes=np.array(wc.CLASSES), **output)
    np.savez(wc.STREAMS_FILE, streams=np.array(streams, dtype=object))
    print(f"\nGuardado {wc.DATASET_FILE} y {wc.STREAMS_FILE}")
    print("Audio continuo de test: " + ", ".join(f"{k} {v['seconds'] / 60:.1f} min" for k, v in streams.items()))
    print("Siguiente paso: python wakeword/train_wake.py")


if __name__ == "__main__":
    main()
