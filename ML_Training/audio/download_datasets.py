"""Descarga los datasets publicos de audio.

    python audio/download_datasets.py                 # ESC-50 + voz chilena (~2.1 GB)
    python audio/download_datasets.py --urbansound    # + UrbanSound8K (~6 GB, ideal en Lambda)
    python audio/download_datasets.py --cleanup       # borra los .zip/.tar.gz despues de extraer

Fuentes:
  - ESC-50 (CC BY-NC): https://github.com/karolpiczak/ESC-50
  - OpenSLR 71, voz en espanol de Chile (CC BY-SA 4.0): https://www.openslr.org/71/
  - UrbanSound8K (CC BY-NC): https://urbansounddataset.weebly.com/urbansound8k.html
"""
import argparse
import shutil
import tarfile
import zipfile
from pathlib import Path

import requests
from tqdm import tqdm

from config import DATA_DIR

DATASETS = {
    "esc50": ("https://github.com/karolpiczak/ESC-50/archive/master.zip", "ESC-50-master.zip"),
    "slr71_female": ("https://www.openslr.org/resources/71/es_cl_female.zip", "es_cl_female.zip"),
    "slr71_male": ("https://www.openslr.org/resources/71/es_cl_male.zip", "es_cl_male.zip"),
    "urbansound": ("https://zenodo.org/records/1203745/files/UrbanSound8K.tar.gz", "UrbanSound8K.tar.gz"),
}

RAW_DIR = DATA_DIR / "raw"


def download(url: str, target: Path) -> None:
    if target.exists():
        print(f"✔ Ya existe {target.name}")
        return
    partial = target.with_suffix(target.suffix + ".part")
    resume_from = partial.stat().st_size if partial.exists() else 0
    headers = {"Range": f"bytes={resume_from}-"} if resume_from else {}

    with requests.get(url, stream=True, headers=headers, timeout=60) as response:
        response.raise_for_status()
        if resume_from and response.status_code != 206:
            resume_from = 0  # el servidor no soporta reanudar
        total = int(response.headers.get("content-length", 0)) + resume_from
        with open(partial, "ab" if resume_from else "wb") as file, tqdm(
            total=total or None, initial=resume_from, unit="B", unit_scale=True, desc=target.name
        ) as bar:
            for chunk in response.iter_content(chunk_size=1 << 20):
                file.write(chunk)
                bar.update(len(chunk))
    partial.rename(target)


def extract(archive: Path, destination: Path) -> None:
    marker = destination / f".extracted_{archive.name}"
    if marker.exists():
        print(f"✔ Ya extraido {archive.name}")
        return
    print(f"Extrayendo {archive.name}...")
    destination.mkdir(parents=True, exist_ok=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(destination)
    else:
        with tarfile.open(archive) as tf:
            tf.extractall(destination, filter="data")
    marker.touch()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--urbansound", action="store_true", help="incluir UrbanSound8K (~6 GB)")
    parser.add_argument("--no-speech", action="store_true", help="no bajar la voz chilena")
    parser.add_argument("--cleanup", action="store_true", help="borrar los archivos comprimidos al terminar")
    args = parser.parse_args()

    names = ["esc50"]
    if not args.no_speech:
        names += ["slr71_female", "slr71_male"]
    if args.urbansound:
        names.append("urbansound")

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    for name in names:
        url, filename = DATASETS[name]
        archive = RAW_DIR / filename
        download(url, archive)
        extract(archive, RAW_DIR / name)
        if args.cleanup:
            archive.unlink(missing_ok=True)

    free_gb = shutil.disk_usage(DATA_DIR).free / 1e9
    print(f"\nListo. Espacio libre en disco: {free_gb:.1f} GB")
    print("Siguiente paso: python audio/prepare_dataset.py")


if __name__ == "__main__":
    main()
