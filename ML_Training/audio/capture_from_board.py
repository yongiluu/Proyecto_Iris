"""Graba audio REAL desde la placa para entrenar (fine-tuning con el microfono verdadero).

1. Sube el firmware de captura:
       cd Hardware_ESP32
       pio run -e esp32-s3-devkitc-1_audio_capture -t upload      (devkit)
       pio run -e seeed_xiao_esp32s3_audio_capture -t upload      (XIAO)
2. Graba ejemplos etiquetados:
       python audio/capture_from_board.py --label fondo --seconds 120
       python audio/capture_from_board.py --label voz --seconds 60
       python audio/capture_from_board.py --label sirena --seconds 30   (reproduce sirenas cerca)
   Los WAV quedan en data/board/<clase>/ y prepare_dataset.py los incluye solos.
3. Vuelve a subir el firmware normal (pio run -t upload).

    python audio/capture_from_board.py --list     # ver puertos
"""
import argparse
import struct
import sys
import time
import wave
from datetime import datetime

import numpy as np
import serial
from serial.tools import list_ports

import config

MAGIC = b"IRAU"


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


def read_packets(port: serial.Serial, seconds: float):
    """Generador de bloques int16 (se resincroniza solo si se pierden bytes)."""
    buffer = bytearray()
    deadline = time.time() + seconds
    while time.time() < deadline:
        buffer += port.read(max(1, port.in_waiting))
        while True:
            start = buffer.find(MAGIC)
            if start < 0:
                del buffer[:-3]
                break
            if len(buffer) < start + 6:
                break
            (count,) = struct.unpack_from("<H", buffer, start + 4)
            if count == 0 or count > 1024:
                del buffer[:start + 1]  # cabecera falsa dentro del audio
                continue
            end = start + 6 + count * 2
            # Si aparece otra cabecera dentro del payload, este paquete llego cortado: descartarlo.
            next_magic = buffer.find(MAGIC, start + 6, end)
            if next_magic >= 0:
                del buffer[:next_magic]
                continue
            if len(buffer) < end:
                break
            yield np.frombuffer(bytes(buffer[start + 6:end]), dtype="<i2")
            del buffer[:end]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", choices=config.CLASSES)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--port")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--note", default="", help="texto para el nombre del archivo (ej. 'cocina', 'calle')")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    if args.list:
        for p in list_ports.comports():
            print(f"{p.device}: {p.description}")
        return
    if not args.label:
        parser.error("falta --label")

    device = pick_port(args.port)
    out_dir = config.BOARD_DIR / args.label
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = out_dir / f"{args.label}_{args.note + '_' if args.note else ''}{stamp}.wav"

    print(f"Grabando '{args.label}' {args.seconds:.0f} s desde {device}... (Ctrl+C para cortar antes)")
    chunks = []
    started = time.time()
    with serial.Serial(device, args.baud, timeout=0.05) as port:
        port.reset_input_buffer()
        try:
            last_print = 0.0
            for block in read_packets(port, args.seconds):
                chunks.append(block)
                now = time.time()
                if now - last_print > 0.25:
                    level = np.sqrt(np.mean(block.astype(np.float32) ** 2))
                    db = 20 * np.log10(level / 32768 + 1e-9)
                    bar = "#" * int(max(0, db + 70) / 2)
                    print(f"\r  {now - started:5.1f}s  {db:6.1f} dBFS  {bar:<35s}", end="", flush=True)
                    last_print = now
        except KeyboardInterrupt:
            pass
    print()

    if not chunks:
        sys.exit("No llegaron datos. ¿Subiste el firmware *_audio_capture? ¿Puerto correcto?")
    audio = np.concatenate(chunks)
    elapsed = time.time() - started
    rate = len(audio) / elapsed
    if rate < config.SAMPLE_RATE * 0.95:
        print(f"⚠ Llegaron {rate:.0f} muestras/s (se esperaban {config.SAMPLE_RATE}): se esta perdiendo audio.")

    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(config.SAMPLE_RATE)
        wav.writeframes(audio.astype("<i2").tobytes())
    peak = np.abs(audio).max()
    print(f"✔ {len(audio) / config.SAMPLE_RATE:.1f} s guardados en {path}  (pico {peak}/32767)")
    if peak >= 32767:
        print("⚠ Hubo saturacion: aleja la fuente de sonido.")


if __name__ == "__main__":
    main()
