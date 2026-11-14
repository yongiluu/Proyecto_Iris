"""Guarda fotos REALES de la camara de la placa, a color 160x120, para Retina (ML_Training/scene).

Las fotos quedan en data/scene_board/<nota>_<fecha>_NNNN.png (la carpeta que lee scene/config.py,
BOARD_IMAGES_DIR) y label_teacher.py las etiqueta con el profesor (fuente "board").

1. Sube el firmware de captura (solo XIAO, prototipo 2):
       cd Hardware_ESP32
       pio run -e seeed_xiao_esp32s3_photo_capture -t upload
2. Graba fotos (apunta la placa como la llevaria la persona):
       python camara/capture_photos.py --note pasillo --count 300
       python camara/capture_photos.py --note casa --manual       (ESPACIO guarda, Q sale)
3. Vuelve a subir el firmware normal (pio run -e seeed_xiao_esp32s3 -t upload).

    python camara/capture_photos.py --list     # ver puertos
"""
import argparse
import struct
import sys
import time
from datetime import datetime
from pathlib import Path

import serial
from PIL import Image
from serial.tools import list_ports

from board_image import unpack_rgb565

ML_DIR = Path(__file__).resolve().parents[1]
SCENE_BOARD_DIR = ML_DIR / "data" / "scene_board"  # = BOARD_IMAGES_DIR de scene/config.py

MAGIC_COLOR = b"IRIC"  # firmware de captura: RGB565 (2 bytes por pixel, byte alto primero)
HEADER = 8  # magic + ancho + alto


def pick_port(requested):
    if requested:
        return requested
    ports = [p for p in list_ports.comports() if p.vid is not None]
    if len(ports) == 1:
        return ports[0].device
    print("Indica el puerto con --port. Puertos encontrados:")
    for p in list_ports.comports():
        print(f"  {p.device}: {p.description}")
    sys.exit(1)


def read_frames(port: serial.Serial):
    """Generador de frames a color: (alto, ancho, 3) uint8. Descarta los que llegan cortados o con error."""
    buffer = bytearray()
    while True:
        buffer += port.read(max(1, port.in_waiting))
        while True:
            start = buffer.find(MAGIC_COLOR)
            if start < 0:
                del buffer[:-3]
                break
            if len(buffer) < start + HEADER:
                break
            width, height = struct.unpack_from("<HH", buffer, start + 4)
            if not (0 < width <= 320 and 0 < height <= 320):
                del buffer[:start + 1]  # cabecera falsa dentro de la imagen
                continue
            end = start + HEADER + width * height * 2 + 2
            if len(buffer) < end:
                break
            pixels = bytes(buffer[start + HEADER:end - 2])
            (checksum,) = struct.unpack_from("<H", buffer, end - 2)
            if sum(pixels) & 0xFFFF != checksum:
                del buffer[:start + 1]
                continue
            del buffer[:end]
            yield unpack_rgb565(pixels, width, height)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--note", default="", help="lugar, para el nombre del archivo (ej. 'casa', 'calle')")
    parser.add_argument("--count", type=int, default=50, help="cuantas fotos guardar")
    parser.add_argument("--every", type=float, default=0.5, help="segundos entre fotos (modo automatico)")
    parser.add_argument("--manual", action="store_true", help="guardar solo al apretar ESPACIO en la ventana")
    parser.add_argument("--no-preview", action="store_true", help="sin ventana (no necesita OpenCV)")
    parser.add_argument("--port")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    if args.list:
        for p in list_ports.comports():
            print(f"{p.device}: {p.description}")
        return
    if not args.note:
        parser.error("indica --note (lugar donde sacas las fotos, ej. pasillo)")
    if args.manual and args.no_preview:
        parser.error("--manual necesita la ventana de vista previa")
    cv2 = None if args.no_preview else __import__("cv2")

    device = pick_port(args.port)
    prefix = f"{args.note}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    print(f"Capturando '{args.note}' desde {device}: "
          f"{'ESPACIO guarda' if args.manual else f'una foto cada {args.every} s'}, Q o Ctrl+C para salir")
    saved = 0
    last_saved = 0.0
    with serial.Serial(device, args.baud, timeout=0.05) as port:
        port.reset_input_buffer()
        try:
            for frame in read_frames(port):
                key = -1
                if cv2 is not None:
                    view = cv2.resize(cv2.cvtColor(frame, cv2.COLOR_RGB2BGR), (480, 360),
                                      interpolation=cv2.INTER_NEAREST)
                    cv2.putText(view, f"{args.note} {saved}/{args.count}", (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                                (255, 255, 255), 2)
                    cv2.imshow("Iris - camara de la placa", view)
                    key = cv2.waitKey(1) & 0xFF
                    if key in (ord("q"), 27):
                        break
                now = time.time()
                wants = key == ord(" ") if args.manual else now - last_saved >= args.every
                if wants:
                    SCENE_BOARD_DIR.mkdir(parents=True, exist_ok=True)
                    Image.fromarray(frame).save(SCENE_BOARD_DIR / f"{prefix}_{saved:04d}.png")
                    saved += 1
                    last_saved = now
                    print(f"\r  {saved}/{args.count} guardadas (brillo medio {frame.mean():5.1f})", end="", flush=True)
                    if saved >= args.count:
                        break
        except KeyboardInterrupt:
            pass
    print()
    if cv2 is not None:
        cv2.destroyAllWindows()
    if saved == 0:
        sys.exit("No se guardo ninguna foto. ¿Subiste el firmware seeed_xiao_esp32s3_photo_capture? ¿Puerto correcto?")
    print(f"✔ {saved} fotos a color en {SCENE_BOARD_DIR}")


if __name__ == "__main__":
    main()
