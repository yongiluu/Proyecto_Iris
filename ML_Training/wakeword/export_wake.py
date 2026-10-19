"""Cuantiza el detector de "Oye Iris" a int8, elige el umbral y genera los archivos del firmware.

    python wakeword/export_wake.py
    python wakeword/export_wake.py --max-falsas-hora 0.5     # mas exigente con las activaciones falsas
    python wakeword/export_wake.py --umbral 0.9              # umbral fijo

El umbral se elige con el audio continuo de test (tomas que el modelo nunca vio): el mas bajo cuyo
promedio de activaciones falsas por hora (frases parecidas, voz chilena, fondos de la app) no pase
--max-falsas-hora. Asi se despierta con la mayor cantidad posible de "Oye Iris".

Escribe models/wakeword_int8.tflite, models/wakeword_report_int8.txt y
Hardware_ESP32/include/wakeword_model_data.h + src/wakeword_model_data.cpp.
"""
import argparse
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import wake_config as wc
from wake_common import load_streams, negative_hours, score_streams, stream_metrics, stream_report
from export_model import check_ops_and_estimate_arena, convert, int8_predictor  # audio/
from firmware_codegen import HEADER_NOTE, _byte_array, _float_literal, _int_array  # audio/
from train import build_model  # audio/


def choose_threshold(cache, max_false_per_hour):
    best = None
    for th in np.round(np.arange(0.5, 0.995, 0.01), 2):
        hits, total, fa = stream_metrics(cache, th)
        negatives = [n for n in cache if cache[n][2] is None]
        combined = sum(fa[n] * cache[n][3] for n in negatives) / max(1e-9, sum(cache[n][3] for n in negatives))
        if combined <= max_false_per_hour:
            return float(th), hits, total, combined
        best = (float(th), hits, total, combined)
    return best


def write_firmware(tflite_model, arena, threshold, summary, selftest_input, selftest_expected):
    include = wc.audio_config.FIRMWARE_INCLUDE
    src = wc.audio_config.FIRMWARE_SRC
    note = HEADER_NOTE.format(script="../wakeword/export_wake.py")
    metric_lines = "".join(f"// {line}\n" for line in summary.strip().splitlines())
    header = f"""{note}{metric_lines}#ifndef WAKEWORD_MODEL_DATA_H
#define WAKEWORD_MODEL_DATA_H

#include <stdint.h>

// Detector de "Oye Iris": entrada = el mismo segundo de log-mel que el modelo de eventos de audio.
constexpr int kWakeTensorArenaSize = {arena};
constexpr int kWakeOutputIndex = {wc.CLASSES.index("oye_iris")};
constexpr float kWakeThreshold = {_float_literal(threshold)};
constexpr int kWakeStrideFrames = {wc.STRIDE_FRAMES};          // una inferencia cada {wc.STRIDE_FRAMES * 20} ms
constexpr uint32_t kWakeRefractoryMs = {int(wc.REFRACTORY_S * 1000)};

extern const unsigned char g_wakeword_model_data[];
extern const unsigned int g_wakeword_model_data_len;
extern const int8_t kWakeSelfTestInput[{len(selftest_input)}];
extern const int8_t kWakeSelfTestExpected[{len(selftest_expected)}];

#endif
"""
    source = f"""{note}#include "wakeword_model_data.h"

const int8_t kWakeSelfTestInput[{len(selftest_input)}] = {{
{_int_array(selftest_input, per_line=24)}
}};
const int8_t kWakeSelfTestExpected[{len(selftest_expected)}] = {{{", ".join(str(int(v)) for v in selftest_expected)}}};

alignas(16) const unsigned char g_wakeword_model_data[] = {{
{_byte_array(tflite_model)}
}};
const unsigned int g_wakeword_model_data_len = {len(tflite_model)};
"""
    (include / "wakeword_model_data.h").write_text(header, encoding="utf-8")
    (src / "wakeword_model_data.cpp").write_text(source, encoding="utf-8")
    print(f"Modelo ({len(tflite_model) / 1024:.1f} KB) escrito en {src / 'wakeword_model_data.cpp'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max-falsas-hora", type=float, default=1.0)
    parser.add_argument("--umbral", type=float, help="usar este umbral en vez de elegirlo")
    parser.add_argument("--tflite", help="usar un .tflite int8 ya exportado")
    parser.add_argument("--solo-medir", action="store_true", help="solo imprime la medicion (no escribe nada)")
    args = parser.parse_args()
    data = np.load(wc.DATASET_FILE)

    if args.tflite:
        tflite_model = open(args.tflite, "rb").read()
    else:
        trained = tf.keras.models.load_model(wc.KERAS_MODEL)
        width = trained.layers[1].filters / 32
        model = build_model(len(wc.CLASSES), width, batch_size=1)  # batch fijo: sin SHAPE/PACK en TFLM
        model.set_weights(trained.get_weights())
        rng = np.random.default_rng(wc.SEED)
        representative = data["x_train"][np.sort(rng.choice(len(data["x_train"]), 1000, replace=False))]
        tflite_model = convert(model, representative.astype(np.float32))
    if not args.solo_medir:
        wc.TFLITE_MODEL.write_bytes(tflite_model)
    print(f"Modelo int8: {len(tflite_model) / 1024:.1f} KB -> {wc.TFLITE_MODEL}")

    predict, interpreter = int8_predictor(tflite_model)
    arena = check_ops_and_estimate_arena(interpreter)

    def score(x):
        return predict(np.asarray(x, np.float32))[:, 1]

    print("Midiendo en audio continuo de test (int8, kernels de referencia)...")
    cache = score_streams(score, load_streams())
    if args.umbral is not None:
        threshold = args.umbral
    else:
        threshold, hits, total, combined = choose_threshold(cache, args.max_falsas_hora)
        print(f"Umbral elegido: {threshold:.2f} ({hits}/{total} Oye Iris, {combined:.2f} activaciones falsas/hora "
              f"en {negative_hours(cache):.2f} h de audio sin la frase)")
    hits, total, fa = stream_metrics(cache, threshold)
    table = stream_report(cache, sorted({0.5, 0.7, 0.8, 0.9, 0.95, round(threshold, 2)}))
    y = data["y_test"]
    window_scores = score(data["x_test"])
    window_line = (f"Ventanas de test sueltas: Oye Iris {np.mean(window_scores[y == 1] >= threshold) * 100:.1f}%, "
                   f"otro sobre el umbral {np.mean(window_scores[y == 0] >= threshold) * 100:.3f}%")
    report = (f"== Wake word 'Oye Iris' (int8) ==\nUmbral {threshold:.2f}: {hits}/{total} = "
              f"{hits / max(1, total) * 100:.1f}% detectados; activaciones falsas/hora: "
              + ", ".join(f"{k} {v:.1f}" for k, v in fa.items()) + f"\n{window_line}\n\n{table}\n")
    print("\n" + report)
    if args.solo_medir:
        return
    wc.REPORT_FILE.write_text(report, encoding="utf-8")

    # Autotest del firmware: un "Oye Iris" de test ya cuantizado y la salida int8 que da el PC.
    sample = data["x_test"][int(np.argmax(y == 1))].astype(np.float32)
    inp, out = interpreter.get_input_details()[0], interpreter.get_output_details()[0]
    scale, zero = inp["quantization"]
    q = np.clip(np.round(sample / scale + zero), -128, 127).astype(np.int8)
    interpreter.set_tensor(inp["index"], q[np.newaxis])
    interpreter.invoke()
    expected = interpreter.get_tensor(out["index"])[0].copy()
    print(f"Autotest del firmware: salida esperada {expected.tolist()}")
    write_firmware(tflite_model, arena, threshold, "\n".join(report.splitlines()[:3]), q.reshape(-1), expected)
    print("\nListo. Compila y sube el firmware: cd Hardware_ESP32 && pio run -e seeed_xiao_esp32s3 -t upload")


if __name__ == "__main__":
    main()
