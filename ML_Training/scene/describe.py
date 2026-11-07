"""Convierte el formulario de la escena (del profesor o predicho por el alumno) en una frase en español.

    python scene/describe.py data/scene/labels_auto.jsonl --n 10    # frases de ejemplo

Reglas pensadas para una persona ciega:
  - Primero los peligros. Si el modelo duda, dice "podria haber..." en vez de callarse.
  - Nunca dice "no hay peligros": a lo mas "No detecto peligros", y solo si la imagen es buena y TODOS
    los peligros tienen puntaje muy bajo.
  - Si la imagen esta oscura, borrosa o tapada, lo dice en vez de describir con falsa seguridad.
  - Corto: el lugar, lo que hay adelante, a los lados y al fondo (maximo MAX_OBJECTS cosas).
Mas adelante esta logica se porta a C++ para que la placa arme la frase sola.
"""
import argparse
import json

import numpy as np

from vocab import (COLOR_FORMS, COLOR_IDS, DISTANCES, HAZARD_IDS, HAZARD_TEXT, OBJECT_IDS, OBJECT_INFO,
                   PEOPLE_BINS, PLACE_NAMES, PLACES, POSITIONS, QUALITY)

MAX_OBJECTS = 5
OBJECT_THRESHOLD = 0.5      # presencia minima para nombrar un objeto
HAZARD_SURE = 0.6           # "Cuidado: ..."
HAZARD_MAYBE = 0.3          # "Atencion: podria haber ..."
HAZARD_NONE = 0.15          # todos bajo esto (y buena imagen) -> "No detecto peligros."
PLACE_THRESHOLD = 0.6
COLOR_THRESHOLD = 0.5
QUALITY_BAD = 0.5

NUMBERS = {2: "dos", 3: "tres"}


# ───────────────────────── Predicciones -> escena ─────────────────────────

def scene_from_predictions(p: dict, hazards_trained: bool = True) -> dict:
    """Salidas del modelo (probabilidades, sin batch) -> escena con confianzas.
    hazards_trained=False: el modelo nunca vio etiquetas de peligros (solo etiquetas automaticas), asi
    que esa salida es ruido y NO se dice nada de peligros (ni "No detecto peligros")."""
    objects = []
    for i, name in enumerate(OBJECT_IDS):
        if p["presence"][i] < OBJECT_THRESHOLD:
            continue
        color = None
        if OBJECT_INFO[name]["has_color"] and p["color"][i].max() >= COLOR_THRESHOLD:
            color = COLOR_IDS[int(p["color"][i].argmax())]
        objects.append({"objeto": name, "posicion": POSITIONS[int(p["position"][i].argmax())],
                        "distancia": DISTANCES[int(p["distance"][i].argmax())], "color": color,
                        "confianza": float(p["presence"][i])})
    return {
        "calidad": QUALITY[int(p["quality"].argmax())],
        "calidad_conf": float(p["quality"].max()),
        "lugar": PLACES[int(p["place"].argmax())] if p["place"].max() >= PLACE_THRESHOLD else None,
        "personas": PEOPLE_BINS[int(p["people"].argmax())],
        "objetos": objects,
        "peligros_conf": {h: float(p["hazards"][i]) for i, h in enumerate(HAZARD_IDS)} if hazards_trained else None,
    }


def scene_from_labels(labels: dict) -> dict:
    """Etiquetas del profesor -> escena (con confianza 1), para comparar frases."""
    hazards = labels.get("peligros")
    return {
        "calidad": labels.get("calidad") or "buena",
        "calidad_conf": 1.0,
        "lugar": labels.get("lugar"),
        "personas": labels.get("personas"),
        "objetos": [dict(o, confianza=1.0) for o in (labels.get("objetos") or [])],
        "peligros_conf": None if hazards is None else {h: float(h in hazards) for h in HAZARD_IDS},
    }


# ───────────────────────── Escena -> frase ─────────────────────────

def noun_phrase(item: dict, people: str | None) -> str:
    info = OBJECT_INFO[item["objeto"]]
    if item["objeto"] == "persona" and people in ("2", "3+"):
        return "dos personas" if people == "2" else "varias personas"
    article = "una" if info["gender"] == "f" else "un"
    text = f"{article} {info['singular']}"
    if item.get("color"):
        text += f" {COLOR_FORMS[item['color']][info['gender']]}"
    return text


def join(parts: list[str]) -> str:
    return parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " y " + parts[-1]


def describe(scene: dict) -> str:
    sentences = []

    if scene["calidad"] != "buena" and scene["calidad_conf"] >= QUALITY_BAD:
        reason = {"oscura": "está muy oscura", "borrosa": "está borrosa", "tapada": "parece tapada"}[scene["calidad"]]
        sentences.append(f"La imagen {reason}; no puedo describir bien.")

    hazards = scene["peligros_conf"]
    if hazards:
        sure = [HAZARD_TEXT[h]["sure"] for h, v in sorted(hazards.items(), key=lambda kv: -kv[1]) if v >= HAZARD_SURE]
        maybe = [HAZARD_TEXT[h]["maybe"] for h, v in sorted(hazards.items(), key=lambda kv: -kv[1])
                 if HAZARD_MAYBE <= v < HAZARD_SURE]
        if sure:
            sentences.append(f"Cuidado: {join(sure[:2])}.")
        if maybe:
            sentences.append(f"Atención: {join(maybe[:2])}.")

    if scene.get("lugar") and PLACE_NAMES.get(scene["lugar"]):
        sentences.append(f"Parece que estás en {PLACE_NAMES[scene['lugar']]}.")

    # Agrupar por donde estan. Lo lejano va "al fondo"; lo cercano, primero.
    groups = {"Adelante": [], "A tu izquierda": [], "A tu derecha": [], "Al fondo": []}
    order = sorted(scene["objetos"], key=lambda o: (DISTANCES.index(o.get("distancia") or "medio"), -o["confianza"]))
    for item in order[:MAX_OBJECTS]:
        if item.get("distancia") == "lejos":
            key = "Al fondo"
        else:
            key = {"izquierda": "A tu izquierda", "derecha": "A tu derecha"}.get(item.get("posicion"), "Adelante")
        groups[key].append(item)
    for place, items in groups.items():
        if not items:
            continue
        near = place == "Adelante" and any(i.get("distancia") == "cerca" for i in items)
        phrases = [noun_phrase(i, scene.get("personas")) for i in items]
        verb = "hay" if not near else "muy cerca, hay"
        sentences.append(f"{place}{',' if near else ''} {verb} {join(phrases)}.")

    if not scene["objetos"] and not any(s.startswith("La imagen") for s in sentences):
        sentences.append("No reconozco objetos claros adelante.")

    image_ok = scene["calidad"] == "buena" or scene["calidad_conf"] < QUALITY_BAD
    if hazards is not None and image_ok and max(hazards.values()) < HAZARD_NONE:
        sentences.append("No detecto peligros.")
    return " ".join(sentences)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("labels_file")
    parser.add_argument("--n", type=int, default=10)
    args = parser.parse_args()
    with open(args.labels_file, encoding="utf-8") as file:
        for line_number, line in zip(range(args.n), file):
            row = json.loads(line)
            print(f"{row['image']}\n  -> {describe(scene_from_labels(row['labels']))}\n")


if __name__ == "__main__":
    main()
