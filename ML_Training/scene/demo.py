"""Galeria HTML: la foto como la ve la placa (160x120 a color), la frase del alumno y la de las etiquetas.

    python scene/demo.py                 # 40 fotos del test con el modelo float
    python scene/demo.py --int8 --n 80   # con el modelo int8 (lo que correria en la placa)
    python scene/demo.py --board         # solo fotos reales de la placa

Abre data/scene/demo_alumno.html en el navegador.
"""
import argparse
import base64
import html
import io
import os

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf
from PIL import Image

import config
from dataset import load_eval_image, load_rows, image_file, split_of
from describe import describe, scene_from_labels, scene_from_predictions
from train import KERAS_MODEL, keras_predictor, load_meta

OUT = config.DATA_DIR / "demo_alumno.html"


def to_data_url(image: np.ndarray) -> str:
    buffer = io.BytesIO()
    Image.fromarray(image.astype(np.uint8)).save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--n", type=int, default=40)
    parser.add_argument("--int8", action="store_true")
    parser.add_argument("--board", action="store_true", help="solo fotos reales de la placa")
    args = parser.parse_args()

    rows = [r for r in load_rows("mix") if split_of(r["image"]) == "test" or r["image"].startswith("board/")]
    if args.board:
        rows = [r for r in rows if r["image"].startswith("board/")]
    rng = np.random.default_rng(0)
    rows = [rows[i] for i in rng.permutation(len(rows))[:args.n]]

    if args.int8:
        from export_model import TFLITE_MODEL, int8_predictor
        predict, _ = int8_predictor(TFLITE_MODEL.read_bytes())
        model_name = "alumno int8"
    else:
        predict = keras_predictor(tf.keras.models.load_model(KERAS_MODEL, compile=False))
        model_name = "alumno float32"
    preds = predict(rows)
    hazards_trained = load_meta().get("hazards_trained", True)

    cards = []
    for i, row in enumerate(rows):
        p = {k: v[i] for k, v in preds.items()}
        image = load_eval_image(image_file(row["image"]))
        cards.append(f"""<figure>
  <img src="{to_data_url(image)}" alt="">
  <figcaption><b>Iris ({model_name}):</b> {html.escape(describe(scene_from_predictions(p, hazards_trained)))}<br>
  <span class="ref"><b>Etiquetas ({html.escape(row['source'])}):</b> {html.escape(describe(scene_from_labels(row['labels'])))}</span><br>
  <span class="id">{html.escape(row['image'])}</span></figcaption>
</figure>""")

    note = "" if hazards_trained else "<p class='warn'>Este modelo aún no vio etiquetas de peligros (solo etiquetas automáticas): no dice nada de peligros.</p>"
    OUT.write_text(f"""<!doctype html><html lang="es"><meta charset="utf-8"><title>Iris: descripción de escenas</title>
<style>body{{font-family:system-ui,sans-serif;margin:16px;background:#f6f6f4;color:#222}}
main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}}
figure{{margin:0;background:#fff;border-radius:8px;padding:10px;box-shadow:0 1px 3px #0002}}
img{{width:320px;height:240px;image-rendering:pixelated;display:block;margin-bottom:8px}}
.ref{{color:#555}} .id{{color:#999;font-size:12px}} .warn{{background:#fff3cd;padding:8px;border-radius:6px}}</style>
<h1>Iris: descripción de escenas ({model_name})</h1>
<p>Cada foto se muestra como la ve la placa: 160x120 a color con la pérdida de color de la cámara (RGB565), ampliada.</p>
{note}<main>{''.join(cards)}</main></html>""", encoding="utf-8")
    print(f"✔ {OUT}")


if __name__ == "__main__":
    main()
