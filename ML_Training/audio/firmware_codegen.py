"""Genera los archivos C++ que el firmware necesita a partir de config.py / features.py.

    python audio/firmware_codegen.py     # solo regenera las tablas del front-end

export_model.py lo usa ademas para escribir el modelo (audio_model_data.*).
"""
from pathlib import Path

import numpy as np

import config
from features import hann_window, mel_filterbank, sparse_filterbank

HEADER_NOTE = "// GENERADO por ML_Training/audio/{script}. No editar a mano.\n"


def _float_literal(value) -> str:
    text = f"{float(value):.9g}"
    if not any(c in text for c in ".en"):
        text += ".0"  # "0f" o "1f" no son literales validos en C++
    return text + "f"


def _float_array(values, per_line=8) -> str:
    items = [_float_literal(v) for v in values]
    lines = [", ".join(items[i:i + per_line]) for i in range(0, len(items), per_line)]
    return "    " + ",\n    ".join(lines)


def _int_array(values, per_line=16) -> str:
    items = [str(int(v)) for v in values]
    lines = [", ".join(items[i:i + per_line]) for i in range(0, len(items), per_line)]
    return "    " + ",\n    ".join(lines)


def _byte_array(data: bytes, per_line=16) -> str:
    lines = []
    for i in range(0, len(data), per_line):
        lines.append(", ".join(f"0x{b:02x}" for b in data[i:i + per_line]))
    return "    " + ",\n    ".join(lines)


def write_frontend_files(include_dir: Path = config.FIRMWARE_INCLUDE, src_dir: Path = config.FIRMWARE_SRC) -> None:
    starts, counts, offsets, weights = sparse_filterbank(mel_filterbank())
    window = hann_window()
    note = HEADER_NOTE.format(script="firmware_codegen.py")

    header = f"""{note}#ifndef AUDIO_FRONTEND_CONFIG_H
#define AUDIO_FRONTEND_CONFIG_H

#include <stdint.h>

constexpr int kAfSampleRate = {config.SAMPLE_RATE};
constexpr int kAfWindowSamples = {config.WINDOW_SAMPLES};
constexpr int kAfHopSamples = {config.HOP_SAMPLES};
constexpr int kAfFftSize = {config.FFT_SIZE};
constexpr int kAfNumMel = {config.NUM_MEL};
constexpr int kAfNumFrames = {config.NUM_FRAMES};          // frames por ventana del modelo (1 s)
constexpr int kAfInferenceStride = {config.INFERENCE_STRIDE_FRAMES};  // frames entre inferencias
constexpr float kAfLogEps = {config.LOG_EPS:.9g}f;

extern const float kAfWindow[kAfWindowSamples];
extern const uint16_t kAfMelStart[kAfNumMel];
extern const uint16_t kAfMelCount[kAfNumMel];
extern const uint16_t kAfMelOffset[kAfNumMel];
extern const float kAfMelWeights[{len(weights)}];

#endif
"""
    source = f"""{note}#include "audio_frontend_config.h"

const float kAfWindow[kAfWindowSamples] = {{
{_float_array(window)}
}};

const uint16_t kAfMelStart[kAfNumMel] = {{
{_int_array(starts)}
}};

const uint16_t kAfMelCount[kAfNumMel] = {{
{_int_array(counts)}
}};

const uint16_t kAfMelOffset[kAfNumMel] = {{
{_int_array(offsets)}
}};

const float kAfMelWeights[{len(weights)}] = {{
{_float_array(weights)}
}};
"""
    (include_dir / "audio_frontend_config.h").write_text(header, encoding="utf-8")
    (src_dir / "audio_frontend_tables.cpp").write_text(source, encoding="utf-8")
    print(f"Front-end escrito en {include_dir / 'audio_frontend_config.h'} y {src_dir / 'audio_frontend_tables.cpp'}")


def write_model_files(tflite_model: bytes, arena_bytes: int, metrics: str,
                      include_dir: Path = config.FIRMWARE_INCLUDE, src_dir: Path = config.FIRMWARE_SRC) -> None:
    note = HEADER_NOTE.format(script="export_model.py")
    labels = ", ".join(f'"{c}"' for c in config.CLASSES)
    alerts = ", ".join("true" if c in config.ALERT_CLASSES else "false" for c in config.CLASSES)
    metric_lines = "".join(f"// {line}\n" for line in metrics.strip().splitlines())

    header = f"""{note}{metric_lines}#ifndef AUDIO_MODEL_DATA_H
#define AUDIO_MODEL_DATA_H

#include <stdint.h>

constexpr int kAudioNumClasses = {len(config.CLASSES)};
constexpr int kAudioTensorArenaSize = {arena_bytes};
constexpr float kAudioAlertThreshold = {_float_literal(config.ALERT_THRESHOLD)};  // config.ALERT_THRESHOLD

extern const unsigned char g_audio_model_data[];
extern const unsigned int g_audio_model_data_len;
extern const char* const kAudioLabels[kAudioNumClasses];
extern const bool kAudioIsAlert[kAudioNumClasses];   // se informa a la app como CMD_AUDIO_EVENT

#endif
"""
    source = f"""{note}#include "audio_model_data.h"

const char* const kAudioLabels[kAudioNumClasses] = {{{labels}}};
const bool kAudioIsAlert[kAudioNumClasses] = {{{alerts}}};

alignas(16) const unsigned char g_audio_model_data[] = {{
{_byte_array(tflite_model)}
}};
const unsigned int g_audio_model_data_len = {len(tflite_model)};
"""
    (include_dir / "audio_model_data.h").write_text(header, encoding="utf-8")
    (src_dir / "audio_model_data.cpp").write_text(source, encoding="utf-8")
    print(f"Modelo ({len(tflite_model) / 1024:.1f} KB) escrito en {src_dir / 'audio_model_data.cpp'}")


if __name__ == "__main__":
    write_frontend_files()
