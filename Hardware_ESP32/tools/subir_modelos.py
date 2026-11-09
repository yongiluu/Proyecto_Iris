"""Sube los modelos que van FUERA del programa (lector de texto, ...) a la particion "modelos" de la placa.

    python tools/subir_modelos.py          # por WiFi, como subir_por_wifi.py (placa en modo actualizacion)
    python tools/subir_modelos.py --usb    # por el cable USB

Arma el paquete con ML_Training/tools/pack_models.py (los modelos anotados al exportarlos) y lo graba.
La placa se reinicia sola y dice en el monitor serial que modelos encontro. Requisito: la placa ya tiene
la tabla de particiones nueva (se graba una sola vez por USB: pio run -e seeed_xiao_esp32s3 -t upload).
"""
import argparse
import csv
import subprocess
import sys
import time
from pathlib import Path

HW_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = HW_DIR.parent
sys.path.insert(0, str(REPO_DIR / "ML_Training" / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pack_models  # noqa: E402
import subir_por_wifi as wifi  # noqa: E402

PARTITIONS = HW_DIR / "partitions_iris_8MB.csv"


def partition_offset(name: str = "modelos") -> int:
    rows = [r for r in csv.reader(l for l in PARTITIONS.read_text(encoding="utf-8").splitlines()
                                  if l.strip() and not l.startswith("#"))]
    for row in rows:
        if row[0].strip() == name:
            return int(row[3].strip(), 16)
    raise SystemExit(f"No hay particion '{name}' en {PARTITIONS.name}")


def upload_usb(package: Path) -> int:
    esptool = Path.home() / ".platformio" / "packages" / "tool-esptoolpy" / "esptool.py"
    command = ([sys.executable, str(esptool)] if esptool.exists() else [sys.executable, "-m", "esptool"])
    offset = partition_offset()
    print(f"Grabando {package.name} en 0x{offset:X} por USB...")
    return subprocess.run(command + ["--chip", "esp32s3", "write_flash", f"0x{offset:X}", str(package)]).returncode


def upload_wifi(package: Path) -> int:
    password = wifi.ota_password()
    previous = wifi.current_profile()
    try:
        for attempt in range(1, 4):
            print(f"Conectando el PC a la red '{wifi.SSID}' de la placa (intento {attempt})...")
            wifi.connect_board_network(password)
            for _ in range(30):
                if wifi.board_reachable():
                    break
                time.sleep(1)
            else:
                print("No se encontro la placa. ¿Esta en modo actualizacion (tres tonos subiendo)?")
                continue
            print("Placa encontrada. Subiendo los modelos...")
            result = subprocess.run(["curl.exe", "--fail", "--show-error", "--max-time", "300", "-u",
                                     f"iris:{password}", "-F", f"modelos=@{package}",
                                     f"http://{wifi.BOARD_IP}/modelos"])
            if result.returncode == 0:
                print("\nListo: la placa se reinicia con los modelos nuevos.")
                return 0
        return 1
    finally:
        if previous and previous != wifi.SSID:
            print(f"Volviendo a conectar el PC a '{previous}'...")
            wifi.netsh("connect", f"name={previous}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--usb", action="store_true", help="grabar por el cable USB en vez de WiFi")
    args = parser.parse_args()
    package = pack_models.build()
    return upload_usb(package) if args.usb else upload_wifi(package)


if __name__ == "__main__":
    sys.exit(main())
