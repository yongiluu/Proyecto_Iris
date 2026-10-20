"""Sube el firmware a la XIAO por WiFi (caja cerrada), desde Windows.

    python tools/subir_por_wifi.py

Antes: pon la placa en modo actualizacion (mantén el botón de Iris 15 s hasta oír tres tonos
subiendo, o "Actualizar por WiFi" en la app). Este script:
  1. conecta el WiFi del PC a la red "Iris-Actualizar" que abre la placa,
  2. compila y sube el firmware (entorno seeed_xiao_esp32s3_ota),
  3. vuelve a conectar el PC a la red WiFi que tenía antes.
Mientras tanto el PC no tiene internet (1-2 minutos).
"""
import configparser
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HW_DIR = Path(__file__).resolve().parent.parent
SSID = "Iris-Actualizar"
BOARD_IP = "192.168.4.1"


def ota_password() -> str:
    config = configparser.ConfigParser(interpolation=None, strict=False)
    files = [HW_DIR / "platformio.ini"] + sorted(HW_DIR.glob("secrets*.ini"))
    config.read([str(f) for f in files], encoding="utf-8")
    return config.get("ota", "password").strip()


def netsh(*args) -> str:
    result = subprocess.run(["netsh", "wlan", *args], capture_output=True)
    return result.stdout.decode("cp850", errors="replace")


def current_profile() -> str | None:
    match = re.search(r"^\s*(?:Perfil|Profile)\s*:\s*(.+?)\s*$", netsh("show", "interfaces"), re.MULTILINE)
    return match.group(1) if match else None


def connect_board_network(password: str) -> None:
    profile = f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>{SSID}</name>
  <SSIDConfig><SSID><name>{SSID}</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>{password}</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>"""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "iris_wifi.xml"
        path.write_text(profile, encoding="utf-8")
        netsh("add", "profile", f"filename={path}", "user=current")
    netsh("connect", f"name={SSID}", f"ssid={SSID}")


def board_reachable() -> bool:
    result = subprocess.run(["ping", "-n", "1", "-w", "1000", BOARD_IP], capture_output=True)
    return result.returncode == 0


def pio_executable() -> str:
    local = Path.home() / ".platformio" / "penv" / "Scripts" / "pio.exe"
    return str(local) if local.exists() else "pio"


def upload(password: str) -> bool:
    """Manda el .bin a la placa (la placa se reinicia sola al terminar bien)."""
    firmware = HW_DIR / ".pio" / "build" / "seeed_xiao_esp32s3_ota" / "firmware.bin"
    result = subprocess.run(["curl.exe", "--fail", "--show-error", "--max-time", "180", "-u", f"iris:{password}",
                             "-F", f"firmware=@{firmware}", f"http://{BOARD_IP}/update"])
    return result.returncode == 0


def main() -> int:
    # 1. Compilar ANTES de cambiar de red: Windows se pasa solo a otra red con internet si la espera es larga.
    print("Compilando el firmware...")
    build = subprocess.run([pio_executable(), "run", "-e", "seeed_xiao_esp32s3_ota"], cwd=HW_DIR,
                           env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    if build.returncode != 0:
        return build.returncode

    password = ota_password()
    previous = current_profile()
    print(f"Red actual del PC: {previous or '(ninguna)'}")
    try:
        for attempt in range(1, 4):
            print(f"Conectando el PC a la red '{SSID}' de la placa (intento {attempt})...")
            connect_board_network(password)
            for _ in range(30):
                if board_reachable():
                    break
                time.sleep(1)
            else:
                print("No se encontro la placa. ¿Esta en modo actualizacion (tres tonos subiendo)?")
                continue
            print("Placa encontrada. Subiendo (unos 30 s)...")
            if upload(password):
                print("\nListo: la placa se reinicia con el firmware nuevo.")
                return 0
        return 1
    finally:
        if previous and previous != SSID:
            print(f"Volviendo a conectar el PC a '{previous}'...")
            netsh("connect", f"name={previous}")


if __name__ == "__main__":
    sys.exit(main())
