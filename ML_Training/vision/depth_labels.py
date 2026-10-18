"""Etiqueta fotos con la distancia al frente usando un modelo "profesor" de profundidad.

    python vision/depth_labels.py --n 15000            # fotos de data/vision_images (Open Images)
    python vision/depth_labels.py --source data/vision_board/nada --n 0   # todas las de una carpeta

El profesor es Depth Anything V2 metrico (interior, version chica): estima en metros la distancia a
cada pixel. Es demasiado grande para la placa; aqui solo genera etiquetas para entrenar el modelo
chico de cercania (proximity_*.py), que si corre en la placa.

Se usa el mismo encuadre que la camara: el cuadrado central de la foto. Por cada foto se guarda un
mapa de profundidad de 32x32 (asi se puede cambiar la zona o los umbrales sin volver a correr el
profesor). Guarda por partes en data/proximity_labels/: si se corta, se retoma donde quedo.
"""
import argparse
import os
from pathlib import Path

import numpy as np
from PIL import Image
from tqdm import tqdm

import config

TEACHER = "depth-anything/Depth-Anything-V2-Metric-Indoor-Small-hf"
OUT_DIR = config.DATA_DIR / "proximity_labels"
MAP_SIZE = 32
CHUNK = 500


def center_square(image: Image.Image) -> Image.Image:
    w, h = image.size
    side = min(w, h)
    return image.crop(((w - side) // 2, (h - side) // 2, (w - side) // 2 + side, (h - side) // 2 + side))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=str(config.IMAGES_DIR), help="carpeta con fotos (jpg/png/bmp)")
    parser.add_argument("--n", type=int, default=15000, help="cuantas fotos (0 = todas)")
    parser.add_argument("--name", default="openimages", help="prefijo de los archivos de salida")
    parser.add_argument("--threads", type=int, default=max(1, (os.cpu_count() or 4) // 2))
    args = parser.parse_args()

    import torch
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation
    torch.set_num_threads(args.threads)

    paths = sorted(p for p in Path(args.source).rglob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"})
    rng = np.random.default_rng(config.SEED)
    if args.n and len(paths) > args.n:
        paths = [paths[i] for i in sorted(rng.choice(len(paths), args.n, replace=False))]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"{len(paths)} fotos de {args.source}")

    processor = AutoImageProcessor.from_pretrained(TEACHER)
    model = AutoModelForDepthEstimation.from_pretrained(TEACHER).eval()

    for start in range(0, len(paths), CHUNK):
        out = OUT_DIR / f"{args.name}_{start // CHUNK:04d}.npz"
        if out.exists():
            continue
        names, maps, crops = [], [], []
        for path in tqdm(paths[start:start + CHUNK], desc=f"parte {start // CHUNK}", leave=False):
            try:
                square = center_square(Image.open(path).convert("RGB"))
            except Exception:  # noqa: BLE001 - una foto mala no corta el etiquetado
                continue
            with torch.no_grad():
                depth = model(**processor(images=square, return_tensors="pt")).predicted_depth[0].numpy()
            # Mapa chico (promedio por bloques) y la foto 96x96 en grises, igual que la camara.
            depth_small = np.asarray(Image.fromarray(depth.astype(np.float32)).resize(
                (MAP_SIZE, MAP_SIZE), Image.BOX), np.float16)
            names.append(path.name)
            maps.append(depth_small)
            crops.append(np.asarray(square.convert("L").resize((config.CROP_SIZE, config.CROP_SIZE), Image.BILINEAR)))
        np.savez_compressed(out, names=np.array(names), depth=np.stack(maps), images=np.stack(crops))
        print(f"✔ {out.name}: {len(names)} fotos", flush=True)


if __name__ == "__main__":
    main()
