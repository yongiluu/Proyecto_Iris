"""Fuentes para dibujar el texto sintetico, en Windows, Linux (Colab) o Mac.

    python ocr/fonts.py             # lista las fuentes usables (y descarga las libres si faltan)

Busca en IRIS_FONTS_DIR, en las fuentes del sistema (Windows/Fonts, /usr/share/fonts, ...) y en el cache de
fuentes descargadas (data/ocr/fuentes). Si hay menos de MIN_FAMILIES familias (Colab solo trae DejaVu y
Liberation), descarga un juego de fuentes libres (licencia OFL) de github.com/google/fonts, fijado a un
commit para que no cambie de una corrida a otra. Se descartan las que no tienen ñ, tildes, ¿¡ o °, y las
que dibujan las minusculas como mayusculas.

Una "fuente" es una ruta o "ruta#Instancia" (fuentes variables: "Roboto[wdth,wght].ttf#Condensed Bold").
"""
import functools
import os
import re
import sys
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import config

REQUIRED_GLYPHS = "ñÑáéíóúÁÉÍÓÚ¿¡$°0123456789"
MIN_FAMILIES = 12
MAX_PER_FAMILY = 6           # que una familia con 30 pesos no domine

# Fuentes legibles de Windows (se excluyen las decorativas, simbolos y caligraficas)
WINDOWS_PATTERNS = re.compile(
    r"^(arial|calibri|cambria|candara|consola|constan|corbel|segoeui|segoe ui|seguisb|tahoma|times|verdana|"
    r"georgia|trebuc|framd|frabk|gil|century|bookos|gara|lucon|l_10646|pala|artifakt|bahnschrift|cour|"
    r"micross|sylfaen|ebrima|nirmala|leelawad|gadugi|javatext|tcm|tcb|rock|sitka|ariblk|impact|arialn)",
    re.I)
# En Linux/Mac se acepta todo lo que pase el chequeo de glifos, menos esto
EXCLUDED = re.compile(r"(emoji|symbol|math|music|braille|dingbat|wingding|webding|ornament|icon|awesome|"
                      r"bebas|smallcap|caps|ocr|barcode|handwrit|script|kacst|lohit)", re.I)

# Juego descargable: sans de etiqueta/envase, condensadas, negritas y algunas serif (todas OFL)
GOOGLE_FONTS_COMMIT = "06bfe0d62a98375cb09c942fa18e68bd32cff057"
GOOGLE_FONTS = [
    "ofl/roboto/Roboto[wdth,wght].ttf", "ofl/robotocondensed/RobotoCondensed[wght].ttf",
    "ofl/opensans/OpenSans[wdth,wght].ttf", "ofl/notosans/NotoSans[wdth,wght].ttf",
    "ofl/oswald/Oswald[wght].ttf", "ofl/sourcesans3/SourceSans3[wght].ttf",
    "ofl/montserrat/Montserrat[wght].ttf", "ofl/archivonarrow/ArchivoNarrow[wght].ttf",
    "ofl/worksans/WorkSans[wght].ttf", "ofl/librefranklin/LibreFranklin[wght].ttf",
    "ofl/arimo/Arimo[wght].ttf", "ofl/asap/Asap[wdth,wght].ttf",
    "ofl/merriweather/Merriweather[opsz,wdth,wght].ttf",
    "ofl/lato/Lato-Regular.ttf", "ofl/lato/Lato-Bold.ttf",
    "ofl/ptsans/PT_Sans-Web-Regular.ttf", "ofl/ptsans/PT_Sans-Web-Bold.ttf",
    "ofl/ptsansnarrow/PT_Sans-Narrow-Web-Regular.ttf", "ofl/ptsansnarrow/PT_Sans-Narrow-Web-Bold.ttf",
    "ofl/firasans/FiraSans-Regular.ttf", "ofl/firasans/FiraSans-Bold.ttf",
    "ofl/firasanscondensed/FiraSansCondensed-Regular.ttf", "ofl/firasanscondensed/FiraSansCondensed-SemiBold.ttf",
    "ofl/barlow/Barlow-Regular.ttf", "ofl/barlow/Barlow-Bold.ttf",
    "ofl/barlowcondensed/BarlowCondensed-Regular.ttf", "ofl/barlowcondensed/BarlowCondensed-SemiBold.ttf",
    "ofl/poppins/Poppins-Regular.ttf", "ofl/poppins/Poppins-SemiBold.ttf",
    "ofl/titilliumweb/TitilliumWeb-Regular.ttf", "ofl/anton/Anton-Regular.ttf",
    "ofl/hind/Hind-Regular.ttf", "ofl/hind/Hind-SemiBold.ttf",
    "ofl/sairacondensed/SairaCondensed-Regular.ttf", "ofl/sairasemicondensed/SairaSemiCondensed-Regular.ttf",
    "ofl/encodesanscondensed/EncodeSansCondensed-Regular.ttf",
    "ofl/ptserif/PT_Serif-Web-Regular.ttf", "ofl/arvo/Arvo-Regular.ttf", "ofl/crimsontext/CrimsonText-Regular.ttf",
    "ofl/tinos/Tinos-Regular.ttf",
]
# Instancias de las fuentes variables que se usan (las que existan en cada archivo)
# (en orden de preferencia: con el tope por familia, las condensadas no deben quedar afuera)
VARIABLE_INSTANCES = ["Regular", "Bold", "Condensed Regular", "Condensed Bold", "SemiCondensed Regular",
                      "ExtraCondensed Bold", "Medium", "Light", "Black", "SemiBold", "SemiCondensed Bold"]


def _system_dirs() -> list[tuple[Path, bool]]:
    """(carpeta, es_windows) donde buscar fuentes del sistema."""
    dirs = []
    if sys.platform == "win32":
        dirs.append((Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts", True))
        local = os.environ.get("LOCALAPPDATA")
        if local:
            dirs.append((Path(local) / "Microsoft" / "Windows" / "Fonts", True))
    else:
        for folder in ("/usr/share/fonts", "/usr/local/share/fonts", "~/.fonts", "~/.local/share/fonts",
                       "/Library/Fonts", "/System/Library/Fonts/Supplemental", "~/Library/Fonts"):
            dirs.append((Path(folder).expanduser(), False))
    return dirs


def _font_files(folder: Path) -> list[Path]:
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.rglob("*") if p.suffix.lower() in (".ttf", ".otf") and p.is_file())


def font_at(spec: str, size: int) -> ImageFont.FreeTypeFont:
    """Abre una fuente ("ruta" o "ruta#Instancia") en un tamaño."""
    path, _, instance = spec.partition("#")
    font = ImageFont.truetype(path, size)
    if instance:
        font.set_variation_by_name(instance)
    return font


def _glyph(font, char: str) -> bytes:
    canvas = Image.new("L", (64, 64), 0)
    ImageDraw.Draw(canvas).text((8, 4), char, font=font, fill=255)
    return canvas.tobytes()


def _usable(spec: str) -> bool:
    try:
        font = font_at(spec, 40)
        missing = _glyph(font, "\u0378")  # caracter sin glifo -> cuadro "tofu" (o nada)
        if any(_glyph(font, c) == missing for c in REQUIRED_GLYPHS):
            return False
        # Fuentes de solo mayusculas / versalitas: la "a" saldria como "A" y la etiqueta quedaria mal
        lower, upper = font.getbbox("aeo"), font.getbbox("AEO")
        return (lower[3] - lower[1]) < 0.85 * (upper[3] - upper[1])
    except (OSError, ValueError):
        return False


def _specs(path: Path) -> list[str]:
    """Una entrada por archivo estatico; varias instancias por archivo variable."""
    try:
        font = ImageFont.truetype(str(path), 40)
        names = [n.decode() if isinstance(n, bytes) else n for n in font.get_variation_names()]
    except (OSError, ValueError):   # no es variable (o FreeType sin soporte de variaciones)
        return [str(path)]
    chosen = [n for n in VARIABLE_INSTANCES if n in names]
    return [f"{path}#{n}" for n in chosen] or [str(path)]


def _family(spec: str) -> str:
    try:
        return font_at(spec, 20).getname()[0] or Path(spec.partition("#")[0]).stem
    except (OSError, ValueError):
        return Path(spec.partition("#")[0]).stem


def download_open_fonts(folder: Path = None) -> int:
    """Descarga el juego de fuentes OFL de google/fonts (una sola vez: queda en el cache)."""
    folder = folder or config.FONTS_CACHE
    folder.mkdir(parents=True, exist_ok=True)
    count = 0
    for rel in GOOGLE_FONTS:
        target = folder / Path(rel).name
        if target.exists() and target.stat().st_size > 1000:
            count += 1
            continue
        url = (f"https://raw.githubusercontent.com/google/fonts/{GOOGLE_FONTS_COMMIT}/"
               + rel.replace("[", "%5B").replace("]", "%5D"))
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            tmp = target.with_suffix(target.suffix + ".part")
            tmp.write_bytes(data)
            os.replace(tmp, target)
            count += 1
        except Exception as error:  # sin internet: se sigue con lo que haya
            print(f"  No se pudo descargar {rel}: {error}")
    print(f"Fuentes libres en {folder}: {count}/{len(GOOGLE_FONTS)}")
    return count


def _collect() -> list[str]:
    found = []   # (spec, es_de_sistema_sin_filtro_windows)
    extra = os.environ.get("IRIS_FONTS_DIR", "").strip()
    for folder in ([Path(extra).expanduser()] if extra else []) + [config.FONTS_CACHE]:
        found += [s for p in _font_files(folder) for s in _specs(p)]
    for folder, is_windows in _system_dirs():
        for path in _font_files(folder):
            if is_windows and not WINDOWS_PATTERNS.match(path.name):
                continue
            if not is_windows and EXCLUDED.search(path.name):
                continue
            found += _specs(path)
    seen, usable, per_family = set(), [], {}
    for spec in found:
        key = Path(spec.partition("#")[0]).name.lower() + "#" + spec.partition("#")[2]
        if key in seen or not _usable(spec):   # la misma fuente en dos carpetas cuenta una vez
            continue
        seen.add(key)
        family = _family(spec)
        if per_family.get(family, 0) >= MAX_PER_FAMILY:
            continue
        per_family[family] = per_family.get(family, 0) + 1
        usable.append(spec)
    return usable


@functools.lru_cache(maxsize=1)
def load_fonts() -> list[str]:
    """Fuentes usables (con ñ y tildes). Descarga las libres si el sistema tiene pocas familias."""
    usable = _collect()
    families = {_family(s) for s in usable}
    forced = os.environ.get("IRIS_OCR_DOWNLOAD_FONTS", "") == "1"
    if len(families) < MIN_FAMILIES or forced:
        print(f"Solo {len(families)} familias de fuentes: descargando fuentes libres de google/fonts...")
        if download_open_fonts():
            usable = _collect()
            families = {_family(s) for s in usable}
    if not usable:
        raise SystemExit("No hay fuentes con ñ y tildes: instala alguna (o pon .ttf en IRIS_FONTS_DIR)")
    if len(families) < MIN_FAMILIES:
        print(f"OJO: solo {len(families)} familias de fuentes; el lector generaliza peor con pocas.")
    return sorted(usable)


if __name__ == "__main__":
    fonts = load_fonts()
    families = sorted({_family(s) for s in fonts})
    print(f"{len(fonts)} fuentes usables, {len(families)} familias:\n  " + "\n  ".join(families))
