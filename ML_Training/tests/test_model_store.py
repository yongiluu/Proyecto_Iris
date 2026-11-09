"""Verifica que la placa (model_store_format.cpp) lea el paquete de modelos igual que lo arma
tools/pack_models.py, y que rechace paquetes dañados en vez de usarlos.

    python tests/test_model_store.py
"""
import subprocess
import sys
import zlib
from pathlib import Path

import numpy as np

ML_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ML_DIR / "tools"))
import pack_models  # noqa: E402

REPO_DIR = ML_DIR.parent
TESTS_DIR = Path(__file__).resolve().parent
BUILD_DIR = TESTS_DIR / "build"

OK, EMPTY, BAD_HEADER, BAD_TABLE, NOT_FOUND, BAD_MODEL = range(6)


def build() -> Path:
    BUILD_DIR.mkdir(exist_ok=True)
    binary = BUILD_DIR / ("model_store_host.exe" if sys.platform == "win32" else "model_store_host")
    subprocess.run([sys.executable, "-m", "ziglang", "c++", "-O2", "-std=c++17",
                    f"-I{REPO_DIR / 'Hardware_ESP32' / 'include'}", str(TESTS_DIR / "model_store_host_main.cpp"),
                    str(REPO_DIR / "Hardware_ESP32" / "src" / "model_store_format.cpp"), "-o", str(binary)], check=True)
    return binary


def run(binary: Path, blob: bytes, names: list[str]) -> tuple[tuple[int, int], dict]:
    path = BUILD_DIR / "paquete.bin"
    path.write_bytes(blob)
    lines = subprocess.run([str(binary), str(path), *names], check=True, capture_output=True, text=True).stdout.split("\n")
    _, status, count = lines[0].split()
    found = {}
    for line in lines[1:]:
        if line.strip():
            name, *values = line.split()
            found[name] = tuple(int(v) for v in values)
    return (int(status), int(count)), found


def main() -> None:
    binary = build()
    rng = np.random.default_rng(7)
    failures = 0

    def expect(condition: bool, what: str) -> None:
        nonlocal failures
        print(("  ok   " if condition else "  FALLA ") + what)
        failures += not condition

    # Paquetes al azar: tamaños raros (alineacion), nombres largos, muchos modelos.
    for case in range(200):
        count = int(rng.integers(1, 12))
        models = []
        for i in range(count):
            name = f"m{case}_{i}_" + "x" * int(rng.integers(0, 14))
            data = rng.integers(0, 256, int(rng.integers(1, 5000))).astype(np.uint8).tobytes()
            models.append((name, data, int(rng.integers(0, 2 ** 31))))
        blob = pack_models.pack(models)
        # Lo que venga despues del paquete (resto de la particion) no debe importar.
        blob += b"\xff" * int(rng.integers(0, 64))
        (status, n), found = run(binary, blob, [m[0] for m in models] + ["no_existe"])
        same = status == OK and n == count and found["no_existe"][0] == NOT_FOUND and all(
            found[name] == (OK, len(data), arena, zlib.crc32(data)) for name, data, arena in models)
        if not same:
            expect(False, f"paquete al azar {case}")
            break
        assert pack_models.unpack(blob) == {name: (data, arena) for name, data, arena in models}
    else:
        expect(True, "200 paquetes al azar: la placa lee lo mismo que arma Python (y Python lo desarma igual)")

    models = [("ocr_lector", b"L" * 1000, 400000), ("ocr_detector", b"D" * 333, 500000)]
    good = pack_models.pack(models)

    (status, _), _ = run(binary, b"\xff" * 4096, ["ocr_lector"])
    expect(status == EMPTY, "particion recien borrada (0xFF) = sin modelos, no error")

    bad = bytearray(good)
    bad[0] ^= 1
    (status, _), _ = run(binary, bytes(bad), ["ocr_lector"])
    expect(status == BAD_HEADER, "magic cambiado = paquete invalido")

    bad = bytearray(good)
    bad[pack_models.HEADER_BYTES + 30] ^= 1  # tamaño del primer modelo
    (status, _), _ = run(binary, bytes(bad), ["ocr_lector"])
    expect(status == BAD_TABLE, "tabla modificada = tabla dañada (CRC)")

    bad = bytearray(good)
    offset = good.index(b"L" * 10)
    bad[offset + 500] ^= 0x40
    _, found = run(binary, bytes(bad), ["ocr_lector", "ocr_detector"])
    expect(found["ocr_lector"][0] == BAD_MODEL and found["ocr_detector"][0] == OK,
           "un byte malo en un modelo: ese modelo se rechaza, el otro sigue sirviendo")

    (status, _), _ = run(binary, good[: len(good) - 100], ["ocr_lector"])
    expect(status == BAD_HEADER, "paquete cortado (subida incompleta) = invalido")

    (status, n), found = run(binary, good, ["ocr_lector", "ocr_detector"])
    expect(status == OK and n == 2 and found["ocr_detector"][1:3] == (333, 500000), "paquete del lector de texto")

    if failures:
        raise SystemExit(f"{failures} pruebas fallaron")
    print("Paquete de modelos: la placa y Python coinciden")


if __name__ == "__main__":
    main()
