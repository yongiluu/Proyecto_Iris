"""El umbral por objeto metido en el sesgo (scene/calibrate.py) hace exactamente lo prometido:
despues de aplicarlo, el modelo pasa 0,5 en un objeto si y solo si antes pasaba su umbral calibrado
(y lo mismo con los peligros en HAZARD_MAYBE). Asi la placa no necesita cambios.

    python tests/test_scene_calibrate.py
"""
import os
import sys
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scene"))

import numpy as np
import tensorflow as tf

import calibrate
from describe import HAZARD_MAYBE, OBJECT_THRESHOLD
from model import build_model
from vocab import HAZARD_IDS, OBJECT_IDS, PLACES


def main() -> None:
    tf.keras.utils.set_random_seed(7)
    model = build_model(pretrained=False)
    # Sesgos aleatorios grandes para que las probabilidades se repartan entre 0 y 1.
    for name in ("presence_logits", "hazards_logits"):
        layer = model.get_layer(name)
        kernel, bias = layer.get_weights()
        layer.set_weights([kernel * 40, np.random.default_rng(1).normal(0, 2, bias.shape).astype(bias.dtype)])

    images = np.random.default_rng(2).integers(0, 256, (64, 120, 160, 3)).astype(np.float32)
    before = model.predict(images, verbose=0)

    rng = np.random.default_rng(3)
    thresholds = {"objects": {n: float(rng.choice([0.2, 0.5, 0.75, 0.9, 0.99])) for n in OBJECT_IDS},
                  "hazards": {n: float(rng.choice([0.1, 0.3, 0.6])) for n in HAZARD_IDS},
                  "place": {"bias": [float(x) for x in rng.normal(0, 0.5, len(PLACES))], "temperature": 0.7}}
    calibrate.apply_thresholds(model, thresholds)
    after = model.predict(images, verbose=0)

    t_obj = np.array([thresholds["objects"][n] for n in OBJECT_IDS])
    t_haz = np.array([thresholds["hazards"][n] for n in HAZARD_IDS])
    margin = 1e-4  # evita contar diferencias de redondeo justo en el borde
    p, q = before["presence"], after["presence"]
    clear = np.abs(p - t_obj) > margin
    assert ((q >= OBJECT_THRESHOLD) == (p >= t_obj))[clear].all(), "objetos: el umbral no quedo en 0,5"
    p, q = before["hazards"], after["hazards"]
    clear = np.abs(p - t_haz) > margin
    assert ((q >= HAZARD_MAYBE) == (p >= t_haz))[clear].all(), "peligros: el umbral no quedo en HAZARD_MAYBE"
    # Lugar: softmax(T * (logits + b)), calculado desde las probabilidades de antes.
    b = np.array(thresholds["place"]["bias"])
    expected_place = calibrate._softmax(0.7 * (np.log(before["place"]) + b))
    assert np.allclose(after["place"], expected_place, atol=1e-4), "lugar: temperatura y sesgo mal aplicados"
    print("  ok   lugar: temperatura y sesgo por lugar quedan dentro del modelo")
    for head in ("position", "distance", "color", "people", "interior", "quality"):
        assert np.allclose(before[head], after[head]), f"{head} cambio y no debia"
    named_before = (before["presence"] >= OBJECT_THRESHOLD).mean()
    named_after = (after["presence"] >= OBJECT_THRESHOLD).mean()
    print(f"  ok   objetos nombrados: {named_before:.0%} con 0,5 igual para todos -> {named_after:.0%} con umbral propio")
    print("  ok   peligros: HAZARD_MAYBE cae en el umbral calibrado de cada uno")
    print("  ok   el resto de las cabezas no cambia")

    # Elegir umbrales: un objeto facil (separable) recibe umbral bajo; uno al azar se calla.
    n = 400
    truth = np.zeros((n, len(OBJECT_IDS)))
    truth[: n // 2, 0] = 1
    probs = np.full((n, len(OBJECT_IDS)), 0.1)
    probs[: n // 2, 0] = 0.7                                   # objeto 0: separable
    truth[::2, 1] = 1
    probs[:, 1] = np.random.default_rng(4).uniform(0, 1, n)    # objeto 1: al azar
    chosen, _ = calibrate.object_thresholds(probs, truth)
    assert chosen[OBJECT_IDS[0]] <= 0.7, chosen[OBJECT_IDS[0]]
    assert chosen[OBJECT_IDS[1]] == calibrate.UMBRAL_CALLAR, chosen[OBJECT_IDS[1]]
    print("  ok   un objeto que el modelo distingue se nombra; uno al azar se calla")

    # Un lugar que el modelo dice de mas (como "bano" en piezas blancas) pierde peso.
    n, c = 600, len(PLACES)
    truth = np.random.default_rng(5).integers(0, c, n)
    target = np.eye(c)[truth]
    probs = np.full((n, c), 0.02)
    probs[np.arange(n), truth] = 0.9
    bano = PLACES.index("bano")
    wrong = np.random.default_rng(6).random(n) < 0.3
    probs[wrong] = 0.02
    probs[wrong, bano] = 0.9                                    # 30 % de las fotos: dice bano y no es
    probs /= probs.sum(1, keepdims=True)
    place, _ = calibrate.place_calibration(probs, target)
    assert place["bias"][bano] < 0, place
    print(f"  ok   un lugar que se dice mal pierde peso (bano {place['bias'][bano]:+.2f})")
    print("Umbral por objeto: OK")


if __name__ == "__main__":
    main()
