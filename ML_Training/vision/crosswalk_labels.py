"""Busca fotos de cruces peatonales en Open Images (etiquetas de imagen verificadas por personas).

    python vision/crosswalk_labels.py           # ~2,8 GB en streaming (no se guardan), ~30 min

"Zebra crossing" y "Pedestrian crossing" no tienen cajas en Open Images, solo etiquetas de la foto
completa. Este script lee el CSV de etiquetas de train (2,7 GB) por partes, se queda con las fotos
positivas (Confidence = 1) y las guarda en data/raw/openimages/crosswalk-images.csv, junto con las de
validation y test. Despues download_datasets.py las baja como clase "cruce".
"""
import io

import pandas as pd
import requests
from tqdm import tqdm

import config

LABELS = {"/m/014v7p": "Zebra crossing", "/m/014xcs": "Pedestrian crossing"}
SOURCES = {
    "train": "https://storage.googleapis.com/openimages/v7/oidv7-train-annotations-human-imagelabels.csv",
    "validation": "https://storage.googleapis.com/openimages/v7/oidv7-val-annotations-human-imagelabels.csv",
    "test": "https://storage.googleapis.com/openimages/v7/oidv7-test-annotations-human-imagelabels.csv",
}
OUT = config.RAW_DIR / "crosswalk-images.csv"


def stream_positives(url: str, folder: str) -> pd.DataFrame:
    kept = []
    with requests.get(url, stream=True, timeout=60) as response:
        response.raise_for_status()
        response.raw.decode_content = True
        total = int(response.headers.get("content-length", 0))
        bar = tqdm(total=total, unit="B", unit_scale=True, desc=folder)

        class Counting(io.RawIOBase):
            def readable(self):
                return True

            def readinto(self, buffer):
                data = response.raw.read(len(buffer))
                buffer[:len(data)] = data
                bar.update(len(data))
                return len(data)

        for chunk in pd.read_csv(io.BufferedReader(Counting(), 1 << 20),
                                 usecols=["ImageID", "LabelName", "Confidence"], chunksize=1_000_000):
            hit = chunk[chunk.LabelName.isin(LABELS) & (chunk.Confidence == 1)]
            kept.append(hit[["ImageID"]].assign(folder=folder))
            bar.set_postfix(fotos=sum(len(k) for k in kept))
        bar.close()
    return pd.concat(kept).drop_duplicates("ImageID")


def main() -> None:
    if OUT.exists():
        print(f"✔ Ya existe {OUT.name}")
        return
    frames = [stream_positives(url, folder) for folder, url in SOURCES.items()]
    result = pd.concat(frames).drop_duplicates("ImageID")
    result.to_csv(OUT, index=False)
    print(f"✔ {len(result)} fotos con cruce peatonal -> {OUT}")


if __name__ == "__main__":
    main()
