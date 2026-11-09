"""Paquete de modelos para la particion "modelos" de la placa (Hardware_ESP32/include/model_store_format.h).

Cada exportador anota su modelo en models/firmware_models.json (nombre -> .tflite y arena). Este script
junta todos en un solo archivo que se graba en la placa:

    python tools/pack_models.py                    # escribe models/modelos_placa.bin
    python tools/pack_models.py --listar           # que modelos hay anotados

Para subirlo a la placa: Hardware_ESP32/tools/subir_modelos.py (por WiFi o USB).
"""
import argparse
import json
import struct
import zlib
from pathlib import Path

ML_DIR = Path(__file__).resolve().parent.parent
MODELS_DIR = ML_DIR / "models"
MANIFEST = MODELS_DIR / "firmware_models.json"
DEFAULT_OUT = MODELS_DIR / "modelos_placa.bin"

MAGIC = b"IRISMDL1"
VERSION = 1
HEADER_BYTES = 32
ENTRY_BYTES = 48
NAME_BYTES = 24
ALIGN = 16
PARTITION_BYTES = 0x200000  # partitions_iris_8MB.csv: modelos


def _load_manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else {}


def register(name: str, tflite: Path, arena_bytes: int) -> None:
    """Anota (o reemplaza) un modelo. La ruta queda relativa a ML_Training para que sirva en otro PC."""
    if len(name.encode()) >= NAME_BYTES:
        raise ValueError(f"nombre muy largo: {name}")
    manifest = _load_manifest()
    manifest[name] = {"tflite": Path(tflite).resolve().relative_to(ML_DIR).as_posix(), "arena": int(arena_bytes)}
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Anotado para la placa: {name} ({Path(tflite).name}, arena {arena_bytes} bytes)")


def pack(models: list[tuple[str, bytes, int]]) -> bytes:
    """[(nombre, bytes del .tflite, arena)] -> paquete."""
    table_end = HEADER_BYTES + ENTRY_BYTES * len(models)
    offset = -(-table_end // ALIGN) * ALIGN
    entries, blobs = b"", b""
    cursor = offset
    for name, data, arena in models:
        encoded = name.encode()
        if not data or len(encoded) >= NAME_BYTES:
            raise ValueError(f"modelo invalido: {name}")
        entries += struct.pack("<24sIIII8x", encoded, cursor, len(data), arena, zlib.crc32(data))
        padded = data + b"\0" * (-len(data) % ALIGN)
        blobs += padded
        cursor += len(padded)
    total = cursor
    header = MAGIC + struct.pack("<IIII8x", VERSION, len(models), total, zlib.crc32(entries))
    return header + entries + b"\0" * (offset - table_end) + blobs


def unpack(blob: bytes) -> dict[str, tuple[bytes, int]]:
    """Inverso de pack (para las pruebas). Lanza ValueError si el paquete esta mal."""
    if blob[:8] != MAGIC:
        raise ValueError("magic")
    version, count, total, table_crc = struct.unpack_from("<IIII", blob, 8)
    entries = blob[HEADER_BYTES:HEADER_BYTES + count * ENTRY_BYTES]
    if version != VERSION or total > len(blob) or zlib.crc32(entries) != table_crc:
        raise ValueError("cabecera o tabla")
    out = {}
    for i in range(count):
        raw_name, off, size, arena, crc = struct.unpack_from("<24sIIII", entries, i * ENTRY_BYTES)
        data = blob[off:off + size]
        if zlib.crc32(data) != crc:
            raise ValueError(f"crc de {raw_name}")
        out[raw_name.split(b"\0")[0].decode()] = (data, arena)
    return out


def build(out: Path = DEFAULT_OUT) -> Path:
    manifest = _load_manifest()
    if not manifest:
        raise SystemExit(f"No hay modelos anotados en {MANIFEST} (se anotan al exportar, ej. ocr/export_model.py)")
    models = []
    for name in sorted(manifest):
        path = ML_DIR / manifest[name]["tflite"]
        if not path.exists():
            raise SystemExit(f"Falta {path} (modelo {name})")
        models.append((name, path.read_bytes(), manifest[name]["arena"]))
    blob = pack(models)
    if len(blob) > PARTITION_BYTES:
        raise SystemExit(f"El paquete ({len(blob) / 1e6:.2f} MB) no cabe en la particion ({PARTITION_BYTES / 1e6:.2f} MB)")
    out.write_bytes(blob)
    for name, data, arena in models:
        print(f"  {name:24s} {len(data) / 1024:7.0f} KB  arena {arena / 1024:.0f} KB")
    print(f"Paquete: {out} ({len(blob) / 1024:.0f} KB de {PARTITION_BYTES // 1024} KB)")
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--salida", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--listar", action="store_true")
    args = parser.parse_args()
    if args.listar:
        for name, info in sorted(_load_manifest().items()):
            print(f"{name}: {info['tflite']} (arena {info['arena']})")
        return
    build(args.salida)


if __name__ == "__main__":
    main()
