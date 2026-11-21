"""Pide a la placa (conectada por USB) la foto que ve su camara y la guarda como JPEG.

    python tools/foto_serial.py                 # COM automatico, guarda foto_placa.jpg
    python tools/foto_serial.py COM10 salida.jpg

Sirve para revisar orientacion, enfoque y luz de la camara montada en los lentes (si la placa ve la
imagen girada, el lector de texto y Retina fallan). Usa el comando FOTO del monitor serial (main.cpp).
"""
import sys
import time

import serial
from serial.tools import list_ports


def find_port() -> str:
    for port in list_ports.comports():
        if "303A" in (port.hwid or "").upper():  # Espressif (ESP32-S3 con USB nativo)
            return port.device
    raise SystemExit("No se encontro la placa por USB")


def main() -> None:
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    out = sys.argv[2] if len(sys.argv) > 2 else "foto_placa.jpg"
    with serial.Serial(port, 115200, timeout=0.3) as s:
        s.dtr = True
        time.sleep(0.3)
        s.reset_input_buffer()
        s.write(b"FOTO\n")
        deadline = time.time() + 15
        buffer = b""
        while time.time() < deadline:
            buffer += s.read(8192)
            start = buffer.find(b"FOTO_START ")
            if start >= 0:
                end_header = buffer.find(b"\n", start)
                if end_header > 0:
                    size = int(buffer[start + 11:end_header])
                    data = buffer[end_header + 1:]
                    while len(data) < size and time.time() < deadline:
                        data += s.read(8192)
                    data = data[:size]
                    if len(data) == size:
                        open(out, "wb").write(data)
                        print(f"Foto guardada en {out} ({size} bytes)")
                        return
            if b"FOTO_ERROR" in buffer:
                raise SystemExit("La placa no pudo sacar la foto")
    raise SystemExit("No llego la foto (¿firmware sin el comando FOTO?)")


if __name__ == "__main__":
    main()
