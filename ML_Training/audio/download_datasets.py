"""Descarga los datasets publicos de audio.

    python audio/download_datasets.py                 # ESC-50 + voz chilena (~2.1 GB)
    python audio/download_datasets.py --urbansound    # + UrbanSound8K (~7 GB de descarga, ~30 min)
    python audio/download_datasets.py --cleanup       # borra los .zip/.tar.gz despues de extraer

Fuentes:
  - ESC-50 (CC BY-NC): https://github.com/karolpiczak/ESC-50
  - OpenSLR 71, voz en espanol de Chile (CC BY-SA 4.0): https://www.openslr.org/71/
  - UrbanSound8K (CC BY-NC): https://urbansounddataset.weebly.com/urbansound8k.html
    Se baja del espejo en Hugging Face (danavery/urbansound8K): Zenodo suele ir a ~50 kB/s.
"""
import argparse
import shutil
import tarfile
import time
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
URBANSOUND_HF = "https://huggingface.co/api/datasets/danavery/urbansound8K/tree/main/data"
URBANSOUND_FILE = "https://huggingface.co/datasets/danavery/urbansound8K/resolve/main/{path}"


URBANSOUND_CLASSES = ["air_conditioner", "car_horn", "children_playing", "dog_bark", "drilling",
                      "engine_idling", "gun_shot", "jackhammer", "siren", "street_music"]


def download_urbansound_hf(cleanup: bool) -> None:
    """Reconstruye UrbanSound8K/audio/foldN/*.wav + metadata/UrbanSound8K.csv desde los parquet
    del espejo de Hugging Face (misma estructura que el .tar.gz original). Una parte a la vez y
    reanudable: cada parte terminada deja una marca en metadata/partes/."""
    import csv
    import pyarrow.parquet as pq

    root = RAW_DIR / "urbansound" / "UrbanSound8K"
    meta_path = root / "metadata" / "UrbanSound8K.csv"
    if meta_path.exists():
        print("✔ Ya extraido UrbanSound8K")
        return
    shards = sorted(f["path"] for f in requests.get(URBANSOUND_HF, timeout=60).json() if f["path"].endswith(".parquet"))
    progress = root / "metadata" / "partes"
    progress.mkdir(parents=True, exist_ok=True)
    for shard in shards:
        done = progress / (Path(shard).stem + ".done")
        if done.exists():
            continue
        local = RAW_DIR / Path(shard).name
        download(URBANSOUND_FILE.format(path=shard), local)
        for item in pq.read_table(local, columns=["audio", "slice_file_name", "fold"]).to_pylist():
            target = root / "audio" / f"fold{item['fold']}" / item["slice_file_name"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(item["audio"]["bytes"])
        done.touch()
        if cleanup:
            local.unlink()

    # El nombre de cada archivo es <fsID>-<classID>-<ocurrencia>-<corte>.wav: la clase sale de ahi.
    rows = []
    for wav in sorted(root.glob("audio/fold*/*.wav")):
        class_id = int(wav.stem.split("-")[1])
        rows.append({"slice_file_name": wav.name, "fold": wav.parent.name[4:], "classID": class_id,
                     "class": URBANSOUND_CLASSES[class_id]})
    with open(meta_path, "w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=["slice_file_name", "fold", "classID", "class"])
        writer.writeheader()
        writer.writerows(rows)
    print(f"✔ UrbanSound8K: {len(rows)} audios")


def download(url: str, target: Path, retries: int = 8) -> None:
    """Descarga reanudable: si se corta la conexion, reintenta desde donde quedo."""
    for attempt in range(retries):
        try:
            return _download_once(url, target)
        except (requests.ConnectionError, requests.exceptions.ChunkedEncodingError, requests.Timeout) as e:
            if attempt == retries - 1:
                raise
            print(f"\n⚠ Conexion cortada ({e.__class__.__name__}), reintentando en 10 s...")
            time.sleep(10)


def _download_once(url: str, target: Path) -> None:
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

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    for name in names:
        url, filename = DATASETS[name]
        archive = RAW_DIR / filename
        if (RAW_DIR / name / f".extracted_{filename}").exists():
            print(f"✔ Ya extraido {filename}")  # con --cleanup el comprimido ya no esta: no re-descargar
            continue
        download(url, archive)
        extract(archive, RAW_DIR / name)
        if args.cleanup:
            archive.unlink(missing_ok=True)

    if args.urbansound:
        download_urbansound_hf(args.cleanup)

    free_gb = shutil.disk_usage(DATA_DIR).free / 1e9
    print(f"\nListo. Espacio libre en disco: {free_gb:.1f} GB")
    print("Siguiente paso: python audio/prepare_dataset.py")


if __name__ == "__main__":
    main()
