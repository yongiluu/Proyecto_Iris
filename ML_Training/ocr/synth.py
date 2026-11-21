"""Genera lineas de texto sinteticas que parecen recortes de la camara de la placa.

    python ocr/synth.py                         # 160 mil de entrenamiento + 6 mil de validacion
    python ocr/synth.py --train 400000 --val 8000 --workers 12    # en Colab
    python ocr/synth.py --preview 24            # guarda <datos>/preview.png para mirar como quedan

Nadie tiene que sacar fotos: el texto (frases chilenas de OpenSLR 71 + letreros, precios, horarios,
direcciones y etiquetas de remedios) se dibuja con fuentes reales y se "ensucia" como lo veria la OV2640
(ocr/camera.py): letras chicas, gris claro sobre blanco, desenfoque, ruido, luz despareja y JPEG. Al
final la linea se lleva a 32x256 con la MISMA funcion de la placa (pipeline._resize_line).

Se puede cortar y volver a correr: sigue desde la ultima tanda guardada (y si ya esta todo, no hace nada).
Los datos van a config.DATA_DIR (IRIS_OCR_DATA_DIR).
"""
import argparse
import json
import os
import random
import shutil
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import camera
import config
import pipeline
from fonts import font_at, load_fonts  # noqa: F401  (detector.py importa load_fonts desde aqui)

H, W = config.LINE_HEIGHT, config.LINE_WIDTH
LEGIBLE_SEPARATION = 1.5   # (tinta - fondo) / (ruido del fondo + 3): menos que esto no se lee ni a ojo

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
# Texto chico de envases y cajas de remedios (lo que mas se quiere leer de cerca)
LABEL_PHRASES = [
    "Mantener fuera del alcance de los niños", "Conservar en lugar fresco y seco", "Venta bajo receta médica",
    "Venta directa", "Uso oral", "Uso externo", "Comprimidos recubiertos", "Cápsulas blandas",
    "Fecha de vencimiento", "Elaborado por", "Distribuido por", "Registro ISP N° F-12345",
    "Lea el folleto antes de usar", "Proteger de la luz", "Agítese antes de usar", "No exceder la dosis indicada",
    "Cada comprimido contiene", "Excipientes c.s.", "Contenido neto", "Información nutricional",
    "Porción: 1 taza (200 ml)", "Energía (kcal)", "Proteínas (g)", "Grasas totales (g)", "Sodio (mg)",
    "Alto en azúcares", "Alto en sodio", "Alto en calorías", "Alto en grasas saturadas", "Sin gluten",
    "Hecho en Chile", "Consumir preferentemente antes de", "Una vez abierto refrigerar", "Ingredientes:",
    "Dosis: 1 comprimido cada 8 horas", "Tomar con abundante agua", "Suspender en caso de reacción",
    "Solución oftálmica", "Jarabe infantil", "Gotas orales", "Crema tópica", "Antialérgico",
    "Analgésico antipirético", "Antiinflamatorio", "Vitamina C 500 mg", "Ácido acetilsalicílico",
]


def load_sentences() -> list[str]:
    """Frases reales: IRIS_OCR_SENTENCES, <datos>/frases.txt (paquete de Colab) u OpenSLR 71 (PC)."""
    env = os.environ.get("IRIS_OCR_SENTENCES", "").strip()
    for path in ([env] if env else []) + [config.SENTENCES_FILE]:
        if path and os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                sentences = [line.strip() for line in f if line.strip()]
            if sentences:
                return sentences
    sentences = []
    for path in config.SPEECH_TRANSCRIPTS:
        if path.exists():
            for line in path.read_text(encoding="utf-8").splitlines():
                parts = line.split("\t")
                if len(parts) == 2:
                    sentences.append(parts[1].strip())
    if not sentences:
        print("OJO: no encontre frases (OpenSLR 71 ni frases.txt): uso solo frases de etiquetas y letreros. "
              "Arma el paquete con python ocr/paquete_colab.py en el PC.")
        sentences = LABEL_PHRASES + SIGNS
    return sentences


def normalize(text: str) -> str:
    text = text.replace("“", '"').replace("”", '"').replace("’", "'").replace("–", "-").replace("—", "-")
    return "".join(c for c in text if c in config.CHAR_TO_INDEX)


def _words_window(rng: random.Random, sentence: str, max_words: int) -> str:
    words = sentence.split()
    n = rng.randint(1, min(max_words, len(words)))
    start = rng.randint(0, len(words) - n)
    return " ".join(words[start:start + n])


def random_text(rng: random.Random, sentences: list[str]) -> str:
    kind = rng.random()
    if kind < 0.40:  # trozo de una frase real
        text = _words_window(rng, rng.choice(sentences), 4)
    elif kind < 0.50:  # texto de envase / caja de remedio
        text = _words_window(rng, rng.choice(LABEL_PHRASES), 5)
    elif kind < 0.62:
        text = rng.choice(SIGNS)
        if rng.random() < 0.3:
            text += f" {rng.randint(1, 20)}"
    elif kind < 0.70:
        text = f"{rng.choice(['Av.', 'Calle', 'Pasaje', ''])} {rng.choice(STREETS)} {rng.randint(1, 3999)}".strip()
    elif kind < 0.79:
        price = rng.choice([rng.randint(1, 99) * 10, rng.randint(1, 499) * 100 - 10, rng.randint(1, 50) * 1000])
        text = f"${price:,}".replace(",", ".")
        if rng.random() < 0.5:
            text = f"{rng.choice(PRODUCTS)} {text}"
    elif kind < 0.87:
        h1, h2 = rng.randint(6, 12), rng.randint(13, 22)
        text = rng.choice([f"{h1:02d}:00 - {h2:02d}:30", f"{rng.randint(1, 28)}/{rng.randint(1, 12)}/20{rng.randint(20, 30)}",
                           f"+56 9 {rng.randint(1000, 9999)} {rng.randint(1000, 9999)}", f"{rng.randint(1, 100)}%",
                           f"Lote {rng.choice('ABCDEFGHKLMNP')}{rng.randint(1000, 99999)}",
                           f"Vence {rng.randint(1, 12):02d}/20{rng.randint(25, 32)}"])
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


def background_photos() -> list:
    if not config.BACKGROUNDS_DIR.exists():
        return []
    return sorted(config.BACKGROUNDS_DIR.glob("*.jpg"))[:20000]


class Renderer:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.np_rng = np.random.default_rng(seed)
        self.fonts = load_fonts()
        self.sentences = load_sentences()
        self.backgrounds = background_photos()

    def background(self, width: int, height: int) -> np.ndarray:
        rng = self.rng
        if camera.chance(rng, "bright_paper_prob"):  # carton/papel claro y liso, con algo de textura
            base = rng.uniform(195, 250)
            return np.full((height, width), base, np.float32) + self.np_rng.normal(0, rng.uniform(0, 4), (height, width)).astype(np.float32)
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
        """Linea en alta resolucion (texto de ~28-48 px) -> (imagen float, alto del texto en px)."""
        rng = self.rng
        spec = rng.choice(self.fonts)
        font = font_at(spec, rng.randint(28, 48))
        left, top, right, bottom = font.getbbox(text)
        tw, th = right - left, bottom - top
        # Margenes como los del recorte de la placa: caja del detector en celdas de 16 px + PAD_X, asi que
        # con letras chicas sobra bastante alrededor (a veces mas arriba que abajo).
        def margin(lo, hi, wide):
            return int(th * (rng.uniform(lo, hi) if rng.random() > 0.4 else rng.uniform(hi, wide)))
        pad_l, pad_r = margin(0.05, 0.6, 1.4), margin(0.05, 0.6, 1.4)
        pad_t, pad_b = margin(0.05, 0.45, 1.0), margin(0.05, 0.45, 1.0)
        width, height = tw + pad_l + pad_r, th + pad_t + pad_b

        main = Image.new("L", (width, height), 0)          # solo el texto de la etiqueta
        ImageDraw.Draw(main).text((pad_l - left, pad_t - top), text, font=font, fill=255)
        mask = main.copy()                                  # + lo que se cuele de otras lineas
        if rng.random() < 0.2:  # trozo de la linea de arriba o de abajo que entra en el recorte (10-40% de su alto)
            other = random_text(rng, self.sentences) or "Texto"
            o_top, o_bottom = font.getbbox(other)[1], font.getbbox(other)[3]
            visible = int((o_bottom - o_top) * rng.uniform(0.1, 0.4))
            x = pad_l - left + rng.randint(-th, th)
            if rng.random() < 0.5 and visible < pad_t - 2:
                ImageDraw.Draw(mask).text((x, visible - o_bottom), other, font=font, fill=255)
            elif visible < pad_b - 2:
                ImageDraw.Draw(mask).text((x, height - visible - o_top), other, font=font, fill=255)
        ops = camera.random_geometry(width, height, rng)
        if rng.random() < 0.3:
            shear = rng.uniform(-0.25, 0.25)
            ops = [("affine", (1, shear, -shear * height / 2, 0, 1, 0))] + ops
        mask = camera.apply_geometry(mask, ops, fill=0, expand=True)
        main = camera.apply_geometry(main, ops, fill=0, expand=True)
        alpha = np.asarray(mask, np.float32) / 255.0
        height, width = alpha.shape

        bg = self.background(width, height)
        ink = camera.ink_level(rng, float(bg.mean()))
        image = bg * (1 - alpha) + ink * alpha
        if rng.random() < 0.15:  # trazo algo engordado o adelgazado (tinta corrida / impresion debil)
            pil = Image.fromarray(np.clip(image, 0, 255).astype(np.uint8))
            image = np.asarray(pil.filter(ImageFilter.MinFilter(3) if rng.random() < 0.5 else ImageFilter.MaxFilter(3)), np.float32)
        text_alpha = np.asarray(main, np.float32) / 255.0

        # Recorte imperfecto del detector: a veces corta un poco arriba/abajo.
        if rng.random() < 0.3:
            cut, cut_b = int(height * rng.uniform(0, 0.07)), int(height * rng.uniform(0, 0.07))
            image, text_alpha = image[cut:height - cut_b or None], text_alpha[cut:height - cut_b or None]
        return image, text_alpha, th

    def degrade(self, image: np.ndarray, text_alpha: np.ndarray, text_height: int):
        """Lleva la linea al tamaño que tendria en el frame VGA, la ensucia como la camara y la lleva a
        32x256 igual que la placa. None si la placa la partiria en trozos (muy larga)."""
        rng, cam = self.rng, config.CAMERA
        clean = rng.random() < cam["clean_fraction"]
        if clean:
            text_px = rng.uniform(*cam["clean_text_px"])
        elif camera.chance(rng, "small_text_prob"):
            text_px = rng.uniform(*cam["small_text_px"])
        else:
            text_px = rng.uniform(*cam["text_px"])
        scale = text_px / max(1, text_height)
        crop_h = max(6, int(round(image.shape[0] * scale)))
        crop_w = max(4, int(round(image.shape[1] * scale)))
        natural = crop_w * H // crop_h
        if natural > W * 5 // 4:   # pipeline.crop_line la partiria: no sirve como una sola linea
            return None
        pil = Image.fromarray(np.clip(image, 0, 255).astype(np.uint8))
        crop = np.asarray(pil.resize((crop_w, crop_h), Image.BOX), np.float32)   # el sensor promedia
        crop = camera.degrade(crop, rng, self.np_rng, clean=clean)
        line = pipeline._resize_line(crop, 0, 0, crop_w, crop_h)
        # Que siga siendo legible: si la camara dejo la tinta hundida en el ruido, la etiqueta seria
        # ruido para el CTC. Se compara la tinta con el fondo en la misma linea de 32x256.
        ink_mask = Image.fromarray((text_alpha * 255).astype(np.uint8)).resize((crop_w, crop_h), Image.BOX)
        ink_mask = pipeline._resize_line(np.asarray(ink_mask), 0, 0, crop_w, crop_h)[:, :natural] / 255.0
        visible = line[:, :natural].astype(np.float32)
        ink, paper = visible[ink_mask > 0.6], visible[ink_mask < 0.05]
        if len(ink) < 8 or len(paper) < 8:
            return None
        separation = abs(float(ink.mean()) - float(paper.mean())) / (float(paper.std()) + 3.0)
        return line if separation >= LEGIBLE_SEPARATION else None

    def sample(self):
        while True:
            text = random_text(self.rng, self.sentences)
            if not text:
                continue
            line = self.degrade(*self.render(text))
            if line is not None:
                return line, text


def encode(text: str) -> np.ndarray:
    labels = np.zeros(config.MAX_TEXT_LENGTH, np.int16)
    indices = [config.CHAR_TO_INDEX[c] for c in text]
    labels[:len(indices)] = indices
    return labels


def make_chunk(args):
    index, seed, count = args
    renderer = Renderer(seed)
    images = np.empty((count, H, W), np.uint8)
    labels = np.empty((count, config.MAX_TEXT_LENGTH), np.int16)
    lengths = np.empty(count, np.int16)
    texts = []
    for i in range(count):
        image, text = renderer.sample()
        images[i], labels[i], lengths[i] = image, encode(text), len(text)
        texts.append(text)
    return index, images, {"labels": labels, "lengths": lengths, "texts": np.array(texts)}


# ───────────────────────── Generacion que se puede retomar ─────────────────────────

def build_resumable(prefix: str, total: int, seed: int, chunk: int, shape: tuple, worker, workers: int,
                    finish) -> None:
    """Genera <prefix>_images.npy (memmap) por tandas. Cada tanda terminada deja partes_<prefix>/NNNNN.npz
    con sus etiquetas; al volver a correr se saltan las tandas hechas. Al final finish(partes) junta las
    etiquetas. Si cambian el total, la semilla o los ajustes de camara, se empieza de cero."""
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    images_path = config.DATA_DIR / f"{prefix}_images.npy"
    parts_dir = config.DATA_DIR / f"partes_{prefix}"
    state_path = config.DATA_DIR / f"{prefix}_estado.json"
    signature = {"total": total, "seed": seed, "chunk": chunk, "shape": list(shape), "camera": config.camera_signature()}
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
    if state.get("signature") == signature and state.get("done") and images_path.exists():
        print(f"  {prefix}: ya estaba listo ({total}), se salta")
        return
    jobs = [(i, seed * 100_000 + i, min(chunk, total - i * chunk)) for i in range((total + chunk - 1) // chunk)]
    resume = state.get("signature") == signature and images_path.exists()
    if resume:
        images = np.load(images_path, mmap_mode="r+")
        if images.shape != (total, *shape):
            resume = False
    if not resume:
        shutil.rmtree(parts_dir, ignore_errors=True)
        images = np.lib.format.open_memmap(images_path, mode="w+", dtype=np.uint8, shape=(total, *shape))
        state_path.write_text(json.dumps({"signature": signature, "done": False}), encoding="utf-8")
    parts_dir.mkdir(parents=True, exist_ok=True)
    pending = [job for job in jobs if not (parts_dir / f"{job[0]:05d}.npz").exists()]
    done = (len(jobs) - len(pending)) * chunk
    if resume and pending:
        print(f"  {prefix}: retomando ({len(jobs) - len(pending)}/{len(jobs)} tandas hechas)")
    if pending:
        with Pool(workers) as pool:
            for index, part_images, extras in pool.imap_unordered(worker, pending):
                start = index * chunk
                images[start:start + len(part_images)] = part_images
                images.flush()
                tmp = parts_dir / f"{index:05d}.tmp.npz"
                np.savez(tmp, **extras)
                os.replace(tmp, parts_dir / f"{index:05d}.npz")   # recien ahora la tanda cuenta como hecha
                done += len(part_images)
                print(f"\r  {prefix}: {min(done, total)}/{total}", end="", flush=True)
        print()
    images.flush()
    del images
    parts = [dict(np.load(parts_dir / f"{i:05d}.npz")) for i in range(len(jobs))]
    finish(parts)
    state_path.write_text(json.dumps({"signature": signature, "done": True}), encoding="utf-8")
    shutil.rmtree(parts_dir, ignore_errors=True)


def build(name: str, total: int, seed: int, workers: int) -> None:
    """Escribe cada tanda directo a disco (memmap): con 160 mil lineas no cabe todo en la RAM del PC."""
    def finish(parts):
        np.savez(config.DATA_DIR / f"lines_{name}_meta.npz",
                 labels=np.concatenate([p["labels"] for p in parts]),
                 lengths=np.concatenate([p["lengths"] for p in parts]),
                 texts=np.concatenate([p["texts"] for p in parts]))
    build_resumable(f"lines_{name}", total, seed, 1000, (H, W), make_chunk, workers, finish)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--preview", type=int, default=0, help="solo guardar N ejemplos en preview.png")
    parser.add_argument("--train", type=int, default=config.TRAIN_LINES)
    parser.add_argument("--val", type=int, default=config.VAL_LINES)
    parser.add_argument("--workers", type=int, default=config.default_workers())
    args = parser.parse_args()

    fonts = load_fonts()   # descarga las fuentes libres (si hace falta) antes de abrir los procesos
    print(f"Fuentes usables: {len(fonts)} | frases: {len(load_sentences())} | fondos: {len(background_photos())} "
          f"| camara x{config.CAMERA_STRENGTH} | datos en {config.DATA_DIR}")
    if args.preview:
        _, images, extras = make_chunk((0, 7, args.preview))
        sheet = Image.new("L", (W, H * args.preview), 255)
        for i, image in enumerate(images):
            sheet.paste(Image.fromarray(image), (0, i * H))
        config.DATA_DIR.mkdir(parents=True, exist_ok=True)
        sheet.resize((W * 2, H * 2 * args.preview), Image.NEAREST).save(config.DATA_DIR / "preview.png")
        print("\n".join(str(t) for t in extras["texts"]))
        print(config.DATA_DIR / "preview.png")
        return

    build("val", args.val, seed=2, workers=args.workers)
    build("train", args.train, seed=1, workers=args.workers)
    print(f"✔ {config.DATA_DIR}")


if __name__ == "__main__":
    main()
