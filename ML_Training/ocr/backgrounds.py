"""Lista de fotos de fondo SIN texto para el detector (data/ocr/fondos_sin_texto.txt).

    python ocr/backgrounds.py

Si una foto de fondo tiene texto real sin etiquetar (un afiche, un letrero), el detector aprende a
ignorar el texto real. Se usan solo fotos de data/vision_images cuyas etiquetas de imagen fueron
verificadas por personas en Open Images y no incluyen nada con texto.
"""
import pandas as pd

import config

TEXT_LABELS = ["Text", "Poster", "Signage", "Street sign", "Book", "Newspaper", "Banner", "Billboard", "Logo",
               "Traffic sign", "Display device", "Font", "Advertising", "Label", "Handwriting", "Menu", "Brand",
               "Packaging and labeling", "Stop sign", "Whiteboard", "Calligraphy"]
LABEL_FILES = ["oidv7-val-annotations-human-imagelabels.csv", "oidv7-test-annotations-human-imagelabels.csv"]
OUT = config.DATA_DIR / "fondos_sin_texto.txt"


def main() -> None:
    raw = config.ML_DIR / "data" / "raw" / "openimages"
    names = pd.read_csv(raw / "oidv7-class-descriptions.csv")
    text_mids = set(names[names.iloc[:, 1].isin(TEXT_LABELS)].iloc[:, 0])
    verified, with_text = set(), set()
    for file in LABEL_FILES:
        labels = pd.read_csv(raw / file, usecols=["ImageID", "LabelName", "Confidence"])
        verified |= set(labels["ImageID"])
        with_text |= set(labels[(labels["Confidence"] == 1) & labels["LabelName"].isin(text_mids)]["ImageID"])
    available = {p.stem for p in config.BACKGROUNDS_DIR.glob("*.jpg")}
    clean = sorted((available & verified) - with_text)
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(clean), encoding="utf-8")
    print(f"{len(available)} fotos | verificadas {len(available & verified)} | con texto {len(available & with_text)} "
          f"| fondos sin texto: {len(clean)} -> {OUT}")


if __name__ == "__main__":
    main()
