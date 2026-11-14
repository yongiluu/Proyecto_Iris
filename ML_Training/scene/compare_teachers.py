"""Compara profesores (labels_teacher_*.jsonl) contra lo que marcaron personas en Open Images.

    python scene/compare_teachers.py

Para cada archivo de etiquetas del profesor, mira solo las fotos que tambien estan en labels_auto.jsonl
(cajas dibujadas por personas en Open Images) y mide:
  - encuentra: de los objetos que marco una persona, cuantos nombro el profesor (mas alto = mejor).
  - inventa:   de los objetos que nombro el profesor y que Open Images revisa en esa foto, cuantos NO
               estaban marcados (mas bajo = mejor; es aproximado: las personas no marcan todo).
  - personas:  cuantas veces coincide el numero de personas (0, 1, 2-3, muchas).
  - peligros:  en cuantas fotos aviso algun peligro (no hay respuesta "correcta": sirve para comparar).
Sirve para elegir el profesor antes de etiquetar 100 mil fotos: correr cada candidato con --limit 300 y
comparar aqui.
"""
import json
from pathlib import Path

import config


def load(path: Path) -> dict:
    rows = {}
    with open(path, encoding="utf-8") as file:
        for line in file:
            if line.strip():
                row = json.loads(line)
                rows[row["image"]] = row["labels"]
    return rows


def objects_of(labels: dict) -> set | None:
    objects = labels.get("objetos")
    return None if objects is None else {o["objeto"] for o in objects}


def compare(teacher: dict, human: dict, only: set) -> dict | None:
    shared = [image for image in teacher if image in human and image in only]
    found = marked = invented = named = people_ok = people_n = hazards = 0
    for image in shared:
        t, h = teacher[image], human[image]
        t_obj, h_obj = objects_of(t), objects_of(h)
        if t_obj is not None and h_obj is not None:
            found += len(t_obj & h_obj)
            marked += len(h_obj)
            named += len(t_obj)
            invented += len(t_obj - h_obj)
        if t.get("personas") is not None and h.get("personas") is not None:
            people_n += 1
            people_ok += t["personas"] == h["personas"]
        hazards += bool(t.get("peligros"))
    if not shared:
        return None
    return {"fotos": len(shared), "encuentra": found / max(1, marked), "inventa": invented / max(1, named),
            "personas": people_ok / max(1, people_n), "peligros": hazards / len(shared)}


def main() -> None:
    if not config.AUTO_LABELS.exists():
        raise SystemExit(f"Falta {config.AUTO_LABELS}: primero scene/download_images.py")
    human = load(config.AUTO_LABELS)
    files = sorted(config.DATA_DIR.glob("labels_teacher_*.jsonl"))  # todos, aunque IRIS_PROFESOR elija uno
    if not files:
        raise SystemExit("No hay etiquetas de profesor (labels_teacher_*.jsonl)")
    teachers = {path: load(path) for path in files}
    # Misma comparacion para todos: solo fotos que etiquetaron TODOS los profesores.
    common = set(human)
    for rows in teachers.values():
        common &= set(rows)
    print(f"Fotos en comun (todos los profesores + Open Images): {len(common)}")
    print(f"{'profesor':<44} {'fotos':>6} {'encuentra':>10} {'inventa':>8} {'personas':>9} {'peligros':>9}")
    for path in files:
        result = compare(teachers[path], human, common)
        name = path.stem.replace("labels_teacher_", "")
        if result is None:
            print(f"{name:<44}  (sin fotos en comun con Open Images)")
            continue
        print(f"{name:<44} {result['fotos']:>6} {result['encuentra']:>10.1%} {result['inventa']:>8.1%} "
              f"{result['personas']:>9.1%} {result['peligros']:>9.1%}")
    print("\nMejor profesor: el que mas 'encuentra' sin subir mucho 'inventa' (y acierta las personas).")


if __name__ == "__main__":
    main()
