"""Formato de las etiquetas de escena (el "formulario" que llena el profesor).

Ejemplo (una linea de data/scene/labels_*.jsonl):
{"image": "openimages/0a1b2c.jpg", "source": "qwen2.5-vl-7b", "labels": {
    "calidad": "buena", "interior": true, "lugar": "pasillo", "personas": "1",
    "objetos": [{"objeto": "puerta", "posicion": "centro", "distancia": "medio", "color": "cafe"},
                {"objeto": "cuadro", "posicion": "centro", "distancia": "medio", "color": null}],
    "peligros": [],
    "detalle": "un cuadro colgado en la puerta"}}

Un campo en null (o ausente) significa "no se sabe" y no se entrena. "peligros": [] significa que el
profesor miro y NO hay peligros; null significa que no se reviso (etiquetas automaticas).
"detalle" es texto libre: no lo usa el alumno v0, queda guardado para el decodificador generativo (v2).
"""
import numpy as np

from vocab import (COLOR_IDS, DISTANCES, HAZARD_IDS, OBJECT_IDS, OBJECT_INFO, PEOPLE_BINS, PLACES,
                   POSITIONS, QUALITY)

UNKNOWN = -1.0


def json_schema() -> dict:
    """JSON Schema del formulario, para decodificacion guiada (vLLM response_format=json_schema):
    el profesor no puede devolver valores fuera del vocabulario."""
    obj = {
        "type": "object",
        "properties": {
            "objeto": {"enum": OBJECT_IDS},
            "posicion": {"enum": POSITIONS},
            "distancia": {"enum": DISTANCES},
            "color": {"enum": COLOR_IDS + [None]},
        },
        "required": ["objeto", "posicion", "distancia", "color"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "calidad": {"enum": QUALITY},
            "interior": {"type": "boolean"},
            "lugar": {"enum": PLACES},
            "personas": {"enum": PEOPLE_BINS},
            "objetos": {"type": "array", "items": obj, "maxItems": 12},
            "peligros": {"type": "array", "items": {"enum": HAZARD_IDS}, "maxItems": 5},
            "detalle": {"type": "string", "maxLength": 160},
        },
        "required": ["calidad", "interior", "lugar", "personas", "objetos", "peligros", "detalle"],
        "additionalProperties": False,
    }


def clean(labels: dict) -> tuple[dict, list[str]]:
    """Deja solo valores validos del vocabulario. Devuelve (etiquetas limpias, problemas encontrados)."""
    problems = []
    out = {}

    def pick(key, allowed):
        value = labels.get(key)
        if value is None:
            return None
        if value not in allowed:
            problems.append(f"{key}={value!r} fuera del vocabulario")
            return None
        return value

    out["calidad"] = pick("calidad", QUALITY)
    interior = labels.get("interior")
    out["interior"] = interior if isinstance(interior, bool) else None
    out["lugar"] = pick("lugar", PLACES)
    people = labels.get("personas")
    out["personas"] = pick("personas", PEOPLE_BINS) if not isinstance(people, int) else \
        PEOPLE_BINS[min(max(people, 0), len(PEOPLE_BINS) - 1)]

    objects = labels.get("objetos")
    if objects is None:
        out["objetos"] = None
    else:
        seen = {}
        for item in objects:
            name = item.get("objeto")
            if name not in OBJECT_INFO:
                problems.append(f"objeto {name!r} fuera del vocabulario")
                continue
            if name in seen:
                continue  # el formulario guarda solo el ejemplar principal de cada objeto
            color = item.get("color")
            if color is not None and (color not in COLOR_IDS or not OBJECT_INFO[name]["has_color"]):
                color = None
            seen[name] = {
                "objeto": name,
                "posicion": item.get("posicion") if item.get("posicion") in POSITIONS else None,
                "distancia": item.get("distancia") if item.get("distancia") in DISTANCES else None,
                "color": color,
            }
        out["objetos"] = list(seen.values())

    hazards = labels.get("peligros")
    if hazards is None:
        out["peligros"] = None
    else:
        out["peligros"] = sorted({h for h in hazards if h in HAZARD_IDS})
        problems += [f"peligro {h!r} fuera del vocabulario" for h in hazards if h not in HAZARD_IDS]

    detail = labels.get("detalle")
    out["detalle"] = detail.strip()[:160] if isinstance(detail, str) and detail.strip() else None
    return out, problems


def to_targets(labels: dict) -> dict:
    """Etiquetas limpias -> arreglos para entrenar. Lo desconocido queda en -1 (binarios) o en una fila
    de ceros (categoricos): la funcion de perdida lo ignora."""
    n_obj = len(OBJECT_IDS)
    t = {
        "presence": np.full(n_obj, UNKNOWN, np.float32),
        "position": np.zeros((n_obj, len(POSITIONS)), np.float32),
        "distance": np.zeros((n_obj, len(DISTANCES)), np.float32),
        "color": np.zeros((n_obj, len(COLOR_IDS)), np.float32),
        "hazards": np.full(len(HAZARD_IDS), UNKNOWN, np.float32),
        "people": np.zeros(len(PEOPLE_BINS), np.float32),
        "place": np.zeros(len(PLACES), np.float32),
        "interior": np.full(1, UNKNOWN, np.float32),
        "quality": np.zeros(len(QUALITY), np.float32),
    }
    if labels.get("objetos") is not None:
        t["presence"][:] = 0
        for item in labels["objetos"]:
            i = OBJECT_IDS.index(item["objeto"])
            t["presence"][i] = 1
            if item.get("posicion"):
                t["position"][i, POSITIONS.index(item["posicion"])] = 1
            if item.get("distancia"):
                t["distance"][i, DISTANCES.index(item["distancia"])] = 1
            if item.get("color"):
                t["color"][i, COLOR_IDS.index(item["color"])] = 1
    if labels.get("peligros") is not None:
        t["hazards"][:] = 0
        for h in labels["peligros"]:
            t["hazards"][HAZARD_IDS.index(h)] = 1
    if labels.get("personas") is not None:
        t["people"][PEOPLE_BINS.index(labels["personas"])] = 1
    if labels.get("lugar") is not None:
        t["place"][PLACES.index(labels["lugar"])] = 1
    if labels.get("interior") is not None:
        t["interior"][0] = float(labels["interior"])
    if labels.get("calidad") is not None:
        t["quality"][QUALITY.index(labels["calidad"])] = 1
    return t


TARGET_KEYS = ["presence", "position", "distance", "color", "hazards", "people", "place", "interior", "quality"]
