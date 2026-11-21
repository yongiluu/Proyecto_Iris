"""Arma en el PC el paquete chico que necesita Colab para generar los datos del OCR.

    python ocr/paquete_colab.py                 # data/ocr/iris_ocr_colab.zip (~10 mil fotos, ~330 MB)
    python ocr/paquete_colab.py --fondos 6000   # mas liviano

En Colab no estan las fotos de Open Images (data/vision_images, 63 mil) ni las frases de OpenSLR 71
(1 GB de audio solo por un .tsv). El zip trae:
    frases.txt              frases de OpenSLR 71 (una por linea)
    fondos_sin_texto.txt    ids de las fotos sin texto real (ocr/backgrounds.py) que van en el zip
    fondos/<id>.jpg         esas fotos, tal cual (ya estan en grises y chicas)
Se sube a Google Drive y en Colab se descomprime en IRIS_OCR_DATA_DIR: config.py encuentra solo
<datos>/fondos y <datos>/frases.txt.
"""
import argparse
import random
import zipfile

import config
from synth import load_sentences


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fondos", type=int, default=10_000, help="cuantas fotos sin texto incluir")
    parser.add_argument("--salida", default=str(config.DATA_DIR / "iris_ocr_colab.zip"))
    args = parser.parse_args()

    clean_list = config.DATA_DIR / "fondos_sin_texto.txt"
    if not clean_list.exists():
        raise SystemExit("Falta data/ocr/fondos_sin_texto.txt: corre python ocr/backgrounds.py")
    ids = [i for i in clean_list.read_text(encoding="utf-8").split() if (config.BACKGROUNDS_DIR / f"{i}.jpg").exists()]
    chosen = sorted(random.Random(0).sample(ids, min(args.fondos, len(ids))))
    sentences = sorted(set(load_sentences()))
    with zipfile.ZipFile(args.salida, "w") as pack:
        pack.writestr("frases.txt", "\n".join(sentences) + "\n", compress_type=zipfile.ZIP_DEFLATED)
        pack.writestr("fondos_sin_texto.txt", "\n".join(chosen) + "\n", compress_type=zipfile.ZIP_DEFLATED)
        for n, image_id in enumerate(chosen, 1):
            pack.write(config.BACKGROUNDS_DIR / f"{image_id}.jpg", f"fondos/{image_id}.jpg",
                       compress_type=zipfile.ZIP_STORED)   # los jpg ya vienen comprimidos
            if n % 500 == 0:
                print(f"\r  fotos: {n}/{len(chosen)}", end="", flush=True)
    print(f"\n{len(sentences)} frases, {len(chosen)} fotos sin texto -> {args.salida}")


if __name__ == "__main__":
    main()
