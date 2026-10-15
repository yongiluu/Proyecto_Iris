"""Implementacion de referencia del front-end log-mel.

El firmware (Hardware_ESP32/src/audio_frontend.cpp) hace exactamente los mismos pasos
con las tablas que genera export_model.py a partir de este archivo:

    muestra int16 / 32768 -> ventana Hann (480) -> FFT de 512 (zero-padding)
    -> potencia |X|^2 de los bins 0..256 -> banco de 40 filtros mel -> ln(x + eps)

tests/test_frontend.py compara ambas implementaciones.
"""
import numpy as np

from config import (FFT_SIZE, HOP_SAMPLES, LOG_EPS, MEL_HIGH_HZ, MEL_LOW_HZ, NUM_MEL,
                    SAMPLE_RATE, WINDOW_SAMPLES)

NUM_FFT_BINS = FFT_SIZE // 2 + 1


def hann_window() -> np.ndarray:
    """Hann periodica: w[n] = 0.5 - 0.5 cos(2 pi n / N)."""
    n = np.arange(WINDOW_SAMPLES)
    return (0.5 - 0.5 * np.cos(2.0 * np.pi * n / WINDOW_SAMPLES)).astype(np.float32)


def _hz_to_mel(hz):
    return 2595.0 * np.log10(1.0 + np.asarray(hz) / 700.0)


def _mel_to_hz(mel):
    return 700.0 * (10.0 ** (np.asarray(mel) / 2595.0) - 1.0)


def mel_filterbank() -> np.ndarray:
    """Matriz (NUM_MEL, NUM_FFT_BINS) de filtros triangulares (escala mel HTK)."""
    mel_points = np.linspace(_hz_to_mel(MEL_LOW_HZ), _hz_to_mel(MEL_HIGH_HZ), NUM_MEL + 2)
    hz_points = _mel_to_hz(mel_points)
    bin_hz = np.arange(NUM_FFT_BINS) * SAMPLE_RATE / FFT_SIZE

    weights = np.zeros((NUM_MEL, NUM_FFT_BINS), dtype=np.float32)
    for m in range(NUM_MEL):
        left, center, right = hz_points[m], hz_points[m + 1], hz_points[m + 2]
        rising = (bin_hz - left) / (center - left)
        falling = (right - bin_hz) / (right - center)
        weights[m] = np.maximum(0.0, np.minimum(rising, falling))
    return weights


def sparse_filterbank(weights: np.ndarray):
    """Forma compacta para el firmware: por filtro, primer bin, cantidad y offset en el arreglo de pesos."""
    starts, counts, offsets, flat = [], [], [], []
    for row in weights:
        nonzero = np.nonzero(row)[0]
        start, end = int(nonzero[0]), int(nonzero[-1]) + 1
        starts.append(start)
        counts.append(end - start)
        offsets.append(len(flat))
        flat.extend(row[start:end].tolist())
    return starts, counts, offsets, np.asarray(flat, dtype=np.float32)


_WINDOW = hann_window()
_FILTERBANK = mel_filterbank()


def num_frames(num_samples: int) -> int:
    if num_samples < WINDOW_SAMPLES:
        return 0
    return 1 + (num_samples - WINDOW_SAMPLES) // HOP_SAMPLES


def log_mel(samples: np.ndarray) -> np.ndarray:
    """samples: int16 (o float en escala int16). Devuelve (frames, NUM_MEL) float32."""
    x = np.asarray(samples, dtype=np.float32) / 32768.0
    count = num_frames(len(x))
    if count == 0:
        return np.zeros((0, NUM_MEL), dtype=np.float32)

    frames = np.lib.stride_tricks.sliding_window_view(x, WINDOW_SAMPLES)[::HOP_SAMPLES][:count]
    spectrum = np.fft.rfft(frames * _WINDOW, n=FFT_SIZE, axis=1)
    power = (spectrum.real ** 2 + spectrum.imag ** 2).astype(np.float32)
    mel = power @ _FILTERBANK.T
    return np.log(mel + LOG_EPS).astype(np.float32)


def log_mel_batch(clips: np.ndarray) -> np.ndarray:
    """clips: (N, CLIP_SAMPLES) -> (N, NUM_FRAMES, NUM_MEL, 1)."""
    return np.stack([log_mel(clip) for clip in clips])[..., np.newaxis]
