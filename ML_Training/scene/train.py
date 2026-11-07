"""Entrena al alumno de descripcion de escenas.

    python scene/train.py                       # etiquetas del profesor si hay; si no, las automaticas
    python scene/train.py --labels auto         # solo etiquetas automaticas (prueba del pipeline)
    python scene/train.py --epochs 40           # en Lambda (GPU)

Dos etapas: primero solo las cabezas (la MobileNet preentrenada congelada), despues todo junto con un
learning rate mas bajo. Guarda models/scene_student.keras y models/scene_report.txt con metricas y
frases de ejemplo (alumno vs etiquetas).
"""
import argparse
import json
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf

import config
from dataset import load_rows, make_dataset, split_of, targets_array
from describe import describe, scene_from_labels, scene_from_predictions
from model import LOSS_WEIGHTS, build_model, losses
from vocab import HAZARD_IDS, OBJECT_IDS

KERAS_MODEL = config.MODELS_DIR / "scene_student.keras"
META = config.MODELS_DIR / "scene_student.json"   # que aprendio el modelo (ej. si vio etiquetas de peligros)
REPORT = config.MODELS_DIR / "scene_report.txt"


def load_meta() -> dict:
    return json.loads(META.read_text(encoding="utf-8")) if META.exists() else {"hazards_trained": True}


def evaluate(predict, rows: list[dict], title: str, examples: int = 12, hazards_trained: bool = True) -> str:
    """Metricas sobre las filas (solo donde la etiqueta es conocida) + frases de ejemplo."""
    targets = targets_array(rows)
    preds = predict(rows)
    lines = [f"== {title} ({len(rows)} fotos) =="]

    known = targets["presence"] >= 0
    truth = targets["presence"] == 1
    guess = preds["presence"] >= 0.5
    tp = (guess & truth & known).sum(0)
    fp = (guess & ~truth & known).sum(0)
    fn = (~guess & truth & known).sum(0)
    precision, recall = tp.sum() / max(1, tp.sum() + fp.sum()), tp.sum() / max(1, tp.sum() + fn.sum())
    f1 = 2 * precision * recall / max(1e-9, precision + recall)
    lines.append(f"Objetos: precision {precision:.1%}, recall {recall:.1%}, F1 {f1:.1%} (umbral 0,5)")
    per_object = []
    for i, name in enumerate(OBJECT_IDS):
        support = int((truth[:, i] & known[:, i]).sum())
        if support >= 10:
            f = 2 * tp[i] / max(1, 2 * tp[i] + fp[i] + fn[i])
            per_object.append((f, name, support))
    per_object.sort()
    lines.append("  peores: " + ", ".join(f"{n} {f:.0%} (n={s})" for f, n, s in per_object[:6]))
    lines.append("  mejores: " + ", ".join(f"{n} {f:.0%} (n={s})" for f, n, s in per_object[-6:]))

    for key, name in (("position", "Posicion"), ("distance", "Distancia"), ("color", "Color")):
        mask = targets[key].sum(-1) > 0
        if mask.any():
            acc = (preds[key].argmax(-1) == targets[key].argmax(-1))[mask].mean()
            lines.append(f"{name} (objetos presentes con etiqueta): {acc:.1%} de acierto (n={int(mask.sum())})")
    for key, name in (("people", "Personas"), ("place", "Lugar"), ("quality", "Calidad")):
        mask = targets[key].sum(-1) > 0
        if mask.any():
            acc = (preds[key].argmax(-1) == targets[key].argmax(-1))[mask].mean()
            lines.append(f"{name}: {acc:.1%} de acierto (n={int(mask.sum())})")
    hazard_known = targets["hazards"] >= 0
    if hazard_known.any():
        for i, h in enumerate(HAZARD_IDS):
            m = hazard_known[:, i]
            pos = (targets["hazards"][:, i] == 1) & m
            if pos.sum() >= 5:
                rec = (preds["hazards"][:, i][pos] >= 0.3).mean()
                fa = (preds["hazards"][:, i][m & ~pos] >= 0.3).mean()
                lines.append(f"Peligro {h}: avisa {rec:.0%} de las veces (umbral 0,3), falsas alarmas {fa:.1%}")
    else:
        lines.append("Peligros: sin etiquetas todavia (las pone el profesor)")

    lines.append("\nFrases de ejemplo (alumno | etiquetas):")
    for i in range(min(examples, len(rows))):
        p = {k: v[i] for k, v in preds.items()}
        lines.append(f"- {rows[i]['image']}\n    alumno:    {describe(scene_from_predictions(p, hazards_trained))}"
                     f"\n    etiquetas: {describe(scene_from_labels(rows[i]['labels']))}")
    return "\n".join(lines)


def keras_predictor(model, batch_size=64):
    def predict(rows):
        ds = make_dataset(rows, train=False, batch_size=batch_size).map(lambda x, t: x)
        out = model.predict(ds, verbose=0)
        return {k: np.asarray(v) for k, v in out.items()}
    return predict


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--labels", choices=["mix", "auto", "teacher"], default="mix")
    parser.add_argument("--epochs", type=int, default=14)
    parser.add_argument("--head-epochs", type=int, default=3, help="epocas con la MobileNet congelada")
    parser.add_argument("--batch-size", type=int, default=48)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--alpha", type=float, default=config.BACKBONE_ALPHA)
    parser.add_argument("--finetune", action="store_true", help="partir de models/scene_student.keras")
    args = parser.parse_args()

    tf.keras.utils.set_random_seed(config.SEED)
    rows = load_rows(args.labels)
    splits = {s: [r for r in rows if split_of(r["image"]) == s] for s in ("train", "val", "test")}
    sources = {}
    for r in rows:
        sources[r["source"]] = sources.get(r["source"], 0) + 1
    print(f"Fotos: {', '.join(f'{k}={len(v)}' for k, v in splits.items())} | fuentes: {sources}")

    train_ds = make_dataset(splits["train"], train=True, batch_size=args.batch_size)
    val_ds = make_dataset(splits["val"], train=False, batch_size=args.batch_size)

    if args.finetune and KERAS_MODEL.exists():
        model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    else:
        model = build_model(args.alpha)
    backbone = next(l for l in model.layers if isinstance(l, tf.keras.Model))
    config.MODELS_DIR.mkdir(parents=True, exist_ok=True)

    def compile_and_fit(epochs, lr, initial_epoch=0):
        steps = int(np.ceil(len(splits["train"]) / args.batch_size)) * max(1, epochs - initial_epoch)
        model.compile(optimizer=tf.keras.optimizers.Adam(tf.keras.optimizers.schedules.CosineDecay(lr, steps, alpha=0.05)),
                      loss=losses(), loss_weights=LOSS_WEIGHTS)
        model.fit(train_ds, validation_data=val_ds, epochs=epochs, initial_epoch=initial_epoch, verbose=2,
                  callbacks=[tf.keras.callbacks.ModelCheckpoint(KERAS_MODEL, monitor="val_loss", save_best_only=True)])

    if not args.finetune and args.head_epochs:
        backbone.trainable = False
        print(f"\nEtapa 1: solo las cabezas ({args.head_epochs} epocas)")
        compile_and_fit(args.head_epochs, args.lr)
    backbone.trainable = True
    print(f"\nEtapa 2: todo el modelo")
    compile_and_fit(args.epochs, args.lr / 4 if not args.finetune else args.lr / 10,
                    initial_epoch=0 if args.finetune else args.head_epochs)

    hazards_trained = bool((targets_array(splits["train"])["hazards"] >= 0).any())
    META.write_text(json.dumps({"labels": args.labels, "sources": sources, "hazards_trained": hazards_trained,
                                "alpha": args.alpha, "train_images": len(splits["train"])}, indent=2), encoding="utf-8")
    model = tf.keras.models.load_model(KERAS_MODEL, compile=False)
    report = evaluate(keras_predictor(model), splits["test"], "Test (float32)", hazards_trained=hazards_trained)
    print("\n" + report)
    REPORT.write_text(report, encoding="utf-8")
    print(f"\nModelo: {KERAS_MODEL}\nSiguiente: python scene/demo.py  y  python scene/export_model.py")


if __name__ == "__main__":
    main()
