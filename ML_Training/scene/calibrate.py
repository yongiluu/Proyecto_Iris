"""Umbral propio para cada objeto y cada peligro, "horneado" en el modelo (Retina).

El alumno da una probabilidad por objeto y la placa nombra el objeto si pasa 0,5 (describe.py y
scene_describe.cpp). Un 0,5 igual para todos hace que diga cosas de las que no esta seguro. Aqui se
busca, con las fotos de validacion (que el alumno no uso para aprender), el umbral de cada objeto con el
que acierta al menos PRECISION_OBJETIVO de las veces que lo nombra. Si un objeto nunca llega a eso, se
calla (umbral 0,99).

Para peligros se busca lo contrario: avisar lo mas posible con pocas falsas alarmas (FALSAS_ALARMAS_MAX
de las fotos sin ese peligro) en el nivel "podria haber" (HAZARD_MAYBE).

El umbral se mete en el sesgo de la ultima capa: sigmoid(z - logit(t)) >= 0,5  <=>  sigmoid(z) >= t. Asi
la placa, el modo en vivo y describe.py siguen usando 0,5 y 0,3 sin cambiar una linea de firmware.

    python scene/calibrate.py            # solo muestra los umbrales (no cambia nada)
    (export_model.py lo aplica solo antes de cuantizar; --sin-calibrar para no hacerlo)
"""
import json

import numpy as np

import config
from describe import HAZARD_MAYBE, OBJECT_THRESHOLD, PLACE_THRESHOLD
from vocab import HAZARD_IDS, OBJECT_IDS, PLACES

PRECISION_OBJETIVO = 0.80
# Lugar ("Parece que estas en un bano"): solo se dice si acierta al menos esto en validacion. Con Retina 2
# una pieza de paredes blancas salia "bano" (en Open Images los banos son blancos).
PRECISION_LUGAR = 0.85
FALSAS_ALARMAS_MAX = 0.02
MIN_POSITIVOS = 15          # con menos ejemplos en validacion no se puede medir: queda el umbral base
UMBRAL_CALLAR = 0.99
THRESHOLDS_FILE = config.MODELS_DIR / "scene_thresholds.json"
CANDIDATES = np.round(np.arange(0.20, 0.96, 0.01), 2)


def _logit(p: float) -> float:
    p = min(max(p, 1e-4), 1 - 1e-4)
    return float(np.log(p / (1 - p)))


def object_thresholds(probs: np.ndarray, target: np.ndarray) -> tuple[dict, list[str]]:
    """probs, target: (fotos, objetos); target 1/0/-1 (desconocido)."""
    thresholds, notes = {}, []
    for i, name in enumerate(OBJECT_IDS):
        known = target[:, i] >= 0
        truth = target[:, i] == 1
        positives = int((truth & known).sum())
        if positives < MIN_POSITIVOS:
            thresholds[name] = OBJECT_THRESHOLD
            notes.append(f"  {name:<16} {OBJECT_THRESHOLD:.2f}  (solo {positives} ejemplos: umbral base)")
            continue
        chosen = None
        for t in CANDIDATES:  # el mas bajo que cumple la precision = el que mas encuentra
            guess = (probs[:, i] >= t) & known
            if guess.sum() >= 5 and (guess & truth).sum() / guess.sum() >= PRECISION_OBJETIVO:
                chosen = float(t)
                break
        if chosen is None:
            thresholds[name] = UMBRAL_CALLAR
            notes.append(f"  {name:<16} calla  (nunca acierta {PRECISION_OBJETIVO:.0%}; n={positives})")
        else:
            guess = (probs[:, i] >= chosen) & known
            recall = (guess & truth).sum() / positives
            thresholds[name] = chosen
            notes.append(f"  {name:<16} {chosen:.2f}  (acierta {(guess & truth).sum() / guess.sum():.0%}, "
                         f"encuentra {recall:.0%}; n={positives})")
    return thresholds, notes


def hazard_thresholds(probs: np.ndarray, target: np.ndarray) -> tuple[dict, list[str]]:
    thresholds, notes = {}, []
    for i, name in enumerate(HAZARD_IDS):
        known = target[:, i] >= 0
        truth = (target[:, i] == 1) & known
        negatives = known & ~truth
        if truth.sum() < 5 or negatives.sum() < 50:
            thresholds[name] = HAZARD_MAYBE
            notes.append(f"  {name:<20} {HAZARD_MAYBE:.2f}  (pocos ejemplos: umbral base)")
            continue
        chosen = float(CANDIDATES[-1])
        for t in CANDIDATES:
            if (probs[:, i][negatives] >= t).mean() <= FALSAS_ALARMAS_MAX:
                chosen = float(t)
                break
        recall = (probs[:, i][truth] >= chosen).mean()
        false_alarms = (probs[:, i][negatives] >= chosen).mean()
        thresholds[name] = chosen
        notes.append(f"  {name:<20} {chosen:.2f}  (avisa {recall:.0%}, falsas alarmas {false_alarms:.1%}; "
                     f"n={int(truth.sum())})")
    return thresholds, notes


def _softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def place_calibration(probs: np.ndarray, target: np.ndarray) -> tuple[dict, list[str]]:
    """Lugar (softmax): sesgo por lugar + temperatura, para que superar PLACE_THRESHOLD (el umbral de la
    placa) signifique acertar >= PRECISION_LUGAR. probs (fotos, lugares); target one-hot (fila de ceros =
    sin etiqueta). Devuelve {"bias": [...], "temperature": T}."""
    known = target.sum(1) > 0
    truth = target.argmax(1)
    logp = np.log(np.clip(probs, 1e-6, 1.0))  # = logits menos una constante por foto (no cambia el softmax)
    bias = np.zeros(probs.shape[1])

    def said(temperature, b):
        q = _softmax(temperature * (logp + b))
        return q.argmax(1), (q.max(1) >= PLACE_THRESHOLD) & known

    # 1) Bajar el peso de los lugares que se dicen mal (ej. bano en una pieza blanca).
    for _ in range(40):
        pred, spoken = said(1.0, bias)
        worst, worst_precision = None, PRECISION_LUGAR
        for c in range(len(bias)):
            mask = spoken & (pred == c)
            if mask.sum() >= 20:
                precision = (truth[mask] == c).mean()
                if precision < worst_precision:
                    worst, worst_precision = c, precision
        if worst is None:
            break
        bias[worst] -= 0.25
    # 2) Temperatura: la que mas veces dice el lugar cumpliendo la precision (o, si ninguna, la mas precisa).
    best_t, best_cov, best_prec = 1.0, -1.0, 0.0
    for temperature in np.round(np.arange(0.3, 2.01, 0.05), 2):
        pred, spoken = said(temperature, bias)
        if spoken.sum() == 0:
            continue
        precision = (pred[spoken] == truth[spoken]).mean()
        coverage = spoken.sum() / max(1, known.sum())
        if precision >= PRECISION_LUGAR and coverage > best_cov:
            best_t, best_cov, best_prec = float(temperature), coverage, precision
    if best_cov < 0:  # nunca llega a la precision pedida: la mas precisa (dice muy poco el lugar)
        for temperature in np.round(np.arange(0.3, 2.01, 0.05), 2):
            pred, spoken = said(temperature, bias)
            if spoken.sum() >= 20:
                precision = (pred[spoken] == truth[spoken]).mean()
                if precision > best_prec:
                    best_t, best_prec = float(temperature), precision
                    best_cov = spoken.sum() / max(1, known.sum())
    notes = [f"  lugar: temperatura {best_t:.2f}, dice el lugar en {max(best_cov, 0):.0%} de las fotos, "
             f"acierta {best_prec:.0%}"]
    notes += [f"    menos peso a {PLACES[c]}: {bias[c]:+.2f}" for c in range(len(bias)) if bias[c] != 0]
    return {"bias": [float(x) for x in bias], "temperature": best_t}, notes


def calibrate(predict, val_rows: list[dict]) -> dict:
    from dataset import targets_array
    targets = targets_array(val_rows)
    preds = predict(val_rows)
    objects, object_notes = object_thresholds(preds["presence"], targets["presence"])
    hazards, hazard_notes = hazard_thresholds(preds["hazards"], targets["hazards"])
    print(f"Umbrales por objeto (nombra solo si acierta >= {PRECISION_OBJETIVO:.0%} en validacion):")
    print("\n".join(object_notes))
    print(f"Umbrales de peligro (nivel 'podria haber', falsas alarmas <= {FALSAS_ALARMAS_MAX:.0%}):")
    print("\n".join(hazard_notes))
    place, place_notes = place_calibration(preds["place"], targets["place"])
    print(f"Lugar (lo dice solo si acierta >= {PRECISION_LUGAR:.0%} en validacion):")
    print("\n".join(place_notes))
    return {"objects": objects, "hazards": hazards, "place": place, "precision_objetivo": PRECISION_OBJETIVO,
            "falsas_alarmas_max": FALSAS_ALARMAS_MAX, "validacion": len(val_rows)}


def apply_thresholds(model, thresholds: dict) -> None:
    """Corre el sesgo de presence_logits y hazards_logits para que 0,5 (objetos) y HAZARD_MAYBE
    (peligros) caigan en los umbrales calibrados."""
    layer = model.get_layer("presence_logits")
    kernel, bias = layer.get_weights()
    shift = np.array([_logit(thresholds["objects"][n]) - _logit(OBJECT_THRESHOLD) for n in OBJECT_IDS])
    layer.set_weights([kernel, bias - shift.astype(bias.dtype)])

    layer = model.get_layer("hazards_logits")
    kernel, bias = layer.get_weights()
    shift = np.array([_logit(thresholds["hazards"][n]) - _logit(HAZARD_MAYBE) for n in HAZARD_IDS])
    layer.set_weights([kernel, bias - shift.astype(bias.dtype)])

    # Lugar: logits' = T * (logits + b)  ->  kernel * T, (bias + b) * T
    place = thresholds.get("place")
    if place:
        layer = model.get_layer("place_logits")
        kernel, bias = layer.get_weights()
        t = place["temperature"]
        b = np.asarray(place["bias"], dtype=bias.dtype)
        layer.set_weights([kernel * t, (bias + b) * t])


def save(thresholds: dict) -> None:
    THRESHOLDS_FILE.write_text(json.dumps(thresholds, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    import tensorflow as tf
    from dataset import load_rows, split_of
    from train import KERAS_MODEL, keras_predictor

    model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    val = [r for r in load_rows("mix") if split_of(r["image"]) == "val"]
    calibrate(keras_predictor(model), val)


if __name__ == "__main__":
    main()
