"""Convierte NYU Depth V2 (fotos de interiores con profundidad REAL de Kinect) al formato de
data/proximity_labels/, el mismo que genera depth_labels.py con el modelo profesor.

    python vision/nyu_to_labels.py data/raw/nyu/nyu_depth_v2_labeled.mat --delete

Fuente: https://cs.nyu.edu/~silberman/datasets/nyu_depth_v2.html (1.449 fotos de 464 escenas).
El nombre de cada foto lleva su escena (nyu_<escena>_<n>), para separar train/test por escena.
"""
import argparse
from pathlib import Path

import h5py
import numpy as np
from PIL import Image

import config
from depth_labels import MAP_SIZE, OUT_DIR, center_square


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mat", help="nyu_depth_v2_labeled.mat")
    parser.add_argument("--delete", action="store_true", help="borrar el .mat (3 GB) al terminar")
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with h5py.File(args.mat, "r") as f:
        images = f["images"]          # (N, 3, 640, 480): canales, ancho, alto (orden de MATLAB)
        depths = f["depths"]          # (N, 640, 480) en metros
        scenes = ["".join(chr(c) for c in f[ref][:].flatten()) for ref in f["scenes"][0]]
        names, maps, crops = [], [], []
        for i in range(images.shape[0]):
            rgb = Image.fromarray(np.transpose(images[i], (2, 1, 0)))
            depth = Image.fromarray(np.ascontiguousarray(depths[i].T).astype(np.float32))
            square = center_square(rgb)
            depth_square = center_square(depth)
            names.append(f"nyu_{scenes[i]}_{i:04d}")
            maps.append(np.asarray(depth_square.resize((MAP_SIZE, MAP_SIZE), Image.BOX), np.float16))
            crops.append(np.asarray(square.convert("L").resize((config.CROP_SIZE, config.CROP_SIZE), Image.BILINEAR)))
    out = OUT_DIR / "nyu_0000.npz"
    np.savez_compressed(out, names=np.array(names), depth=np.stack(maps), images=np.stack(crops))
    near = np.mean([np.percentile(m[6:24, 8:24], 10) < config.PROXIMITY_NEAR_M for m in maps])
    print(f"✔ {out}: {len(names)} fotos de {len(set(scenes))} escenas; {near * 100:.0f}% con algo a < "
          f"{config.PROXIMITY_NEAR_M} m al frente")
    if args.delete:
        Path(args.mat).unlink()
        print("Borrado el .mat")


if __name__ == "__main__":
    main()
