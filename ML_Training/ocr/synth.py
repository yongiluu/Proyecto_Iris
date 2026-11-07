"""Genera lineas de texto sinteticas que parecen recortes de la camara de la placa.

    python ocr/synth.py                 # 160 mil de entrenamiento + 6 mil de validacion (~15 min)
    python ocr/synth.py --preview 24    # guarda data/ocr/preview.png para mirar como quedan

Nadie tiene que sacar fotos: el texto (frases chilenas de OpenSLR 71 + letreros, precios, horarios,
direcciones y etiquetas) se dibuja con fuentes reales y se "ensucia" como lo veria la OV2640: fondos de
fotos reales, inclinacion, baja resolucion, desenfoque, ruido, poca luz y recortes imperfectos.
"""
import argparse
import os
import random
import re
from multiprocessing import Pool
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import config

H, W = config.LINE_HEIGHT, config.LINE_WIDTH

# Fuentes legibles (se excluyen las decorativas, simbolos y caligraficas)
FONT_PATTERNS = re.compile(
    r"^(arial|calibri|cambria|candara|consola|constan|corbel|segoeui|segoe ui|seguisb|tahoma|times|verdana|"
    r"georgia|trebuc|framd|frabk|gil|century|bookos|gara|lucon|l_10646|pala|artifakt|bahnschrift|cour|"
    r"micross|sylfaen|ebrima|nirmala|leelawad|gadugi|javatext|tcm|tcb|rock|sitka|ariblk|impact|arialn)",
    re.I)
REQUIRED_GLYPHS = "ñÑáéíóúÁÉÍÓÚ¿¡$°0123456789"

SIGNS = [
    "SALIDA", "ENTRADA", "BAÑOS", "BAÑO", "DAMAS", "VARONES", "EMERGENCIA", "SALIDA DE EMERGENCIA",
    "PRECAUCIÓN", "PELIGRO", "NO PASAR", "PROHIBIDO FUMAR", "ASCENSOR", "ESCALERA", "PISO", "FARMACIA",
    "ABIERTO", "CERRADO", "EMPUJE", "TIRE", "OFERTA", "CAJA", "PAGO", "INFORMACIÓN", "RECEPCIÓN", "PARADERO",
    "METRO", "ANDÉN", "HOSPITAL", "URGENCIA", "CONSULTORIO", "ALMACÉN", "SUPERMERCADO", "PANADERÍA",
    "CUIDADO PISO MOJADO", "PASO PEATONAL", "PARE", "CEDA EL PASO", "ESTACIONAMIENTO", "BOLETERÍA",
    "Sala", "Oficina", "Biblioteca", "Laboratorio", "Auditorio", "Casino", "Secretaría", "Dirección",
]
STREETS = ["O'Higgins", "Barros Arana", "Colo Colo", "Caupolicán", "Prat", "Freire", "Maipú", "Rengo",
           "Tucapel", "Castellón", "Lincoyán", "Aníbal Pinto", "Los Carrera", "Chacabuco", "Paicaví"]
PRODUCTS = ["Leche entera", "Pan amasado", "Paracetamol", "Ibuprofeno", "Losartán", "Metformina",
            "Arroz grado 2", "Azúcar", "Té", "Café", "Aceite", "Fideos", "Agua mineral", "Jugo", "Yogur"]


def load_fonts() -> list[str]:
    fonts_dir = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    candidates = sorted(p for p in fonts_dir.glob("*") if p.suffix.lower() in (".ttf", ".otf")
                        and FONT_PATTERNS.match(p.name))
    usable = []
    for path in candidates:
        try:
            font = ImageFont.truetype(str(path), 40)

            def glyph(char: str, font=font) -> bytes:
                canvas = Image.new("L", (64, 64), 0)
                ImageDraw.Draw(canvas).text((8, 4), char, font=font, fill=255)
                return canvas.tobytes()

            missing = glyph("\u0378")  # caracter sin glifo -> cuadro "tofu" (o nada)
            if all(glyph(c) != missing for c in REQUIRED_GLYPHS):
                usable.append(str(path))
        except OSError:
            continue
    return usable


def load_sentences() -> list[str]:
    sentences = []
    for path in config.SPEECH_TRANSCRIPTS:
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                parts = line.split("\t")
                if len(parts) == 2:
                    sentences.append(parts[1].strip())
    if not sentences:
        raise SystemExit("No encontre las frases de OpenSLR 71 (corre audio/download_datasets.py)")
    return sentences


def normalize(text: str) -> str:
    text = text.replace("“", '"').replace("”", '"').replace("’", "'").replace("–", "-").replace("—", "-")
    return "".join(c for c in text if c in config.CHAR_TO_INDEX)


def random_text(rng: random.Random, sentences: list[str]) -> str:
    kind = rng.random()
    if kind < 0.45:  # trozo de una frase real
        words = rng.choice(sentences).split()
        n = rng.randint(1, min(4, len(words)))
        start = rng.randint(0, len(words) - n)
        text = " ".join(words[start:start + n])
    elif kind < 0.6:
        text = rng.choice(SIGNS)
        if rng.random() < 0.3:
            text += f" {rng.randint(1, 20)}"
    elif kind < 0.7:
        text = f"{rng.choice(['Av.', 'Calle', 'Pasaje', ''])} {rng.choice(STREETS)} {rng.randint(1, 3999)}".strip()
    elif kind < 0.8:
        price = rng.choice([rng.randint(1, 99) * 10, rng.randint(1, 499) * 100 - 10, rng.randint(1, 50) * 1000])
        text = f"${price:,}".replace(",", ".")
        if rng.random() < 0.5:
            text = f"{rng.choice(PRODUCTS)} {text}"
    elif kind < 0.87:
        h1, h2 = rng.randint(6, 12), rng.randint(13, 22)
        text = rng.choice([f"{h1:02d}:00 - {h2:02d}:30", f"{rng.randint(1, 28)}/{rng.randint(1, 12)}/20{rng.randint(20, 30)}",
                           f"+56 9 {rng.randint(1000, 9999)} {rng.randint(1000, 9999)}", f"{rng.randint(1, 100)}%"])
    elif kind < 0.94:
        text = f"{rng.choice(PRODUCTS)} {rng.choice(['500 mg', '1 L', '1 kg', '250 g', '20 comprimidos', '10 mg'])}"
    else:
        text = f"{rng.choice(['Micro', 'Bus', 'Línea', 'Sala', 'Piso', 'Puerta'])} {rng.randint(1, 99)}{rng.choice(['', 'A', 'B', 'J'])}"

    case = rng.random()
    if case < 0.3:
        text = text.upper()
    elif case < 0.4:
        text = text.title()
    text = normalize(text)
    return text[:config.MAX_TEXT_LENGTH].strip()


class Renderer:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.np_rng = np.random.default_rng(seed)
        self.fonts = load_fonts()
        self.sentences = load_sentences()
        self.backgrounds = sorted(config.BACKGROUNDS_DIR.glob("*.jpg"))[:20000] if config.BACKGROUNDS_DIR.exists() else []

    def background(self, width: int, height: int) -> np.ndarray:
        rng = self.rng
        if self.backgrounds and rng.random() < 0.5:
            image = Image.open(rng.choice(self.backgrounds)).convert("L")
            scale = max(width / image.width, height / image.height) * rng.uniform(1.0, 2.0)
            image = image.resize((max(width, int(image.width * scale)), max(height, int(image.height * scale))))
            x, y = rng.randint(0, image.width - width), rng.randint(0, image.height - height)
            bg = np.asarray(image.crop((x, y, x + width, y + height)), np.float32)
            # Fondo atenuado: con textura real pero sin tapar el texto (un letrero se lee sobre su fondo).
            return bg * rng.uniform(0.12, 0.45) + rng.uniform(0, 150)
        base = rng.uniform(0, 255)
        gradient = np.linspace(0, rng.uniform(-60, 60), width)[np.newaxis, :]
        return np.clip(np.full((height, width), base, np.float32) + gradient, 0, 255)

    def render(self, text: str):
        rng = self.rng
        font = ImageFont.truetype(rng.choice(self.fonts), rng.randint(28, 48))
        left, top, right, bottom = font.getbbox(text)
        tw, th = right - left, bottom - top
        pad_x, pad_y = int(th * rng.uniform(0.05, 0.6)), int(th * rng.uniform(0.05, 0.45))
        width, height = tw + 2 * pad_x, th + 2 * pad_y

        mask = Image.new("L", (width, height), 0)
        ImageDraw.Draw(mask).text((pad_x - left, pad_y - top), text, font=font, fill=255)
        if rng.random() < 0.6:  # inclinacion y cizalle (camara no paralela al letrero)
            mask = mask.rotate(rng.uniform(-4, 4), resample=Image.BILINEAR, expand=False)
        if rng.random() < 0.3:
            shear = rng.uniform(-0.25, 0.25)
            mask = mask.transform(mask.size, Image.AFFINE, (1, shear, -shear * height / 2, 0, 1, 0), Image.BILINEAR)
        alpha = np.asarray(mask, np.float32) / 255.0

        bg = self.background(width, height)
        bg_level = float(bg.mean())
        contrast = rng.uniform(80, 230)
        ink = bg_level - contrast if bg_level > 127 else bg_level + contrast
        if rng.random() < 0.08:  # pocas veces, poco contraste (dificil pero legible)
            ink = bg_level + (-1 if bg_level > 127 else 1) * rng.uniform(50, 80)
        image = bg * (1 - alpha) + np.clip(ink, 0, 255) * alpha

        # Recorte imperfecto del detector: a veces corta un poco arriba/abajo o deja mucho margen.
        if rng.random() < 0.3:
            cut = int(height * rng.uniform(0, 0.07))
            image = image[cut:height - int(height * rng.uniform(0, 0.07)) or None]
        return image

    def degrade(self, image: np.ndarray) -> np.ndarray:
        """Baja resolucion de la camara, desenfoque, ruido y exposicion."""
        rng = self.rng
        pil = Image.fromarray(np.clip(image, 0, 255).astype(np.uint8))
        # El texto ocupa pocos pixeles en la foto: se achica y se vuelve a agrandar.
        small_h = rng.randint(9, H)
        small_w = max(4, int(pil.width * small_h / pil.height))
        pil = pil.resize((small_w, small_h), Image.BILINEAR)
        out_w = int(small_w * H / small_h)
        if out_w > W:
            return None
        pil = pil.resize((out_w, H), Image.BILINEAR)
        if rng.random() < 0.5:
            pil = pil.filter(ImageFilter.GaussianBlur(rng.uniform(0.2, 1.3)))
        x = np.asarray(pil, np.float32)
        x = (x - x.mean()) * rng.uniform(0.6, 1.2) + x.mean() * rng.uniform(0.5, 1.3)  # contraste y luz
        x += self.np_rng.normal(0, rng.uniform(0, 9), x.shape)                           # ruido del sensor

        line = np.empty((H, W), np.float32)
        # Relleno a la derecha con el borde de la imagen (como el recorte real, no negro)
        edge = float(np.median(x[:, -2:]))
        line[:] = edge
        offset = rng.randint(0, max(0, W - out_w)) if rng.random() < 0.3 else 0
        line[:, offset:offset + out_w] = x
        return np.clip(np.round(line), 0, 255).astype(np.uint8)

    def sample(self):
        while True:
            text = random_text(self.rng, self.sentences)
            if not text:
                continue
            line = self.degrade(self.render(text))
            if line is not None:
                return line, text


def encode(text: str) -> np.ndarray:
    labels = np.zeros(config.MAX_TEXT_LENGTH, np.int16)
    indices = [config.CHAR_TO_INDEX[c] for c in text]
    labels[:len(indices)] = indices
    return labels


def make_chunk(args):
    seed, count = args
    renderer = Renderer(seed)
    images = np.empty((count, H, W), np.uint8)
    labels = np.empty((count, config.MAX_TEXT_LENGTH), np.int16)
    lengths = np.empty(count, np.int16)
    texts = []
    for i in range(count):
        image, text = renderer.sample()
        images[i], labels[i], lengths[i] = image, encode(text), len(text)
        texts.append(text)
    return images, labels, lengths, texts


def build(name: str, total: int, seed: int, workers: int) -> None:
    """Escribe cada tanda directo a disco (memmap): con 160 mil lineas no cabe todo en la RAM del PC."""
    chunk = 1000
    jobs = [(seed * 100_000 + i, min(chunk, total - i * chunk)) for i in range((total + chunk - 1) // chunk)]
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    images = np.lib.format.open_memmap(config.DATA_DIR / f"lines_{name}_images.npy", mode="w+",
                                       dtype=np.uint8, shape=(total, H, W))
    labels = np.empty((total, config.MAX_TEXT_LENGTH), np.int16)
    lengths = np.empty(total, np.int16)
    texts = []
    position = 0
    with Pool(workers) as pool:
        for part in pool.imap(make_chunk, jobs):
            n = len(part[0])
            images[position:position + n] = part[0]
            labels[position:position + n], lengths[position:position + n] = part[1], part[2]
            texts += part[3]
            position += n
            print(f"\r  {name}: {position}/{total}", end="", flush=True)
    print()
    images.flush()
    del images
    np.savez(config.DATA_DIR / f"lines_{name}_meta.npz", labels=labels, lengths=lengths, texts=np.array(texts))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--preview", type=int, default=0, help="solo guardar N ejemplos en preview.png")
    parser.add_argument("--train", type=int, default=config.TRAIN_LINES)
    parser.add_argument("--val", type=int, default=config.VAL_LINES)
    parser.add_argument("--workers", type=int, default=max(1, min(4, (os.cpu_count() or 2) - 2)))
    args = parser.parse_args()

    if args.preview:
        images, _, _, texts = make_chunk((7, args.preview))
        sheet = Image.new("L", (W, H * args.preview), 255)
        for i, image in enumerate(images):
            sheet.paste(Image.fromarray(image), (0, i * H))
        config.DATA_DIR.mkdir(parents=True, exist_ok=True)
        sheet.resize((W * 2, H * 2 * args.preview), Image.NEAREST).save(config.DATA_DIR / "preview.png")
        print("\n".join(texts))
        print(f"Fuentes usables: {len(Renderer(0).fonts)} | {config.DATA_DIR / 'preview.png'}")
        return

    build("val", args.val, seed=2, workers=args.workers)
    build("train", args.train, seed=1, workers=args.workers)
    print(f"✔ {config.DATA_DIR}")


if __name__ == "__main__":
    main()
