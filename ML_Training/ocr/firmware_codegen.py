"""Genera Hardware_ESP32/include/ocr_config.h y src/ocr_config.cpp (constantes y alfabeto del lector).

    python ocr/firmware_codegen.py

export_model.py escribe los .tflite, que van a la particion "modelos" (tools/pack_models.py). tests/test_ocr_pipeline.py regenera esto.
"""
import config
import pipeline

NOTE = "// GENERADO por ML_Training/ocr/firmware_codegen.py desde ocr/config.py. No editar a mano.\n"


def c_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> None:
    header = f"""{NOTE}#ifndef OCR_CONFIG_H
#define OCR_CONFIG_H

constexpr int kOcrVgaWidth = {pipeline.VGA_W};
constexpr int kOcrVgaHeight = {pipeline.VGA_H};
constexpr int kOcrDetWidth = {config.DET_WIDTH};        // entrada del detector (frame VGA reducido 2x)
constexpr int kOcrDetHeight = {config.DET_HEIGHT};
constexpr int kOcrMapWidth = {pipeline.MAP_W};          // salida del detector: celdas
constexpr int kOcrMapHeight = {pipeline.MAP_H};
constexpr int kOcrCell = {pipeline.CELL};               // px del frame VGA por celda
constexpr int kOcrMinCells = {pipeline.MIN_CELLS};
constexpr int kOcrMaxLines = {pipeline.MAX_LINES};
constexpr int kOcrPadX = {pipeline.PAD_X};
constexpr int kOcrLineHeight = {config.LINE_HEIGHT};    // entrada del lector
constexpr int kOcrLineWidth = {config.LINE_WIDTH};
constexpr int kOcrTimeSteps = {config.TIME_STEPS};      // salida del lector: columnas
constexpr int kOcrNumClasses = {config.NUM_CLASSES};    // 0 = blanco de CTC
constexpr int kOcrMaxPieces = {pipeline.MAX_PIECES};                        // trozos por linea larga
constexpr int kOcrDetectThreshold = {config.DETECT_THRESHOLD};  // celda con texto si probabilidad*255 >= esto

// Nombres de los modelos en la particion "modelos" (model_store.h, ML_Training/tools/pack_models.py)
constexpr const char* kOcrReaderModelName = "ocr_lector";
constexpr const char* kOcrDetectorModelName = "ocr_detector";

// Caracter (UTF-8) de cada clase; kOcrCharset[0] es el blanco.
extern const char* const kOcrCharset[kOcrNumClasses];

#endif
"""
    chars = ['""'] + [c_string(c) for c in config.CHARSET]
    lines = [", ".join(chars[i:i + 12]) for i in range(0, len(chars), 12)]
    source = f"""{NOTE}#include "ocr_config.h"

const char* const kOcrCharset[kOcrNumClasses] = {{
    {(",\n    ").join(lines)}
}};
"""
    (config.FIRMWARE_INCLUDE / "ocr_config.h").write_text(header, encoding="utf-8")
    (config.FIRMWARE_SRC / "ocr_config.cpp").write_text(source, encoding="utf-8")
    print(f"✔ {config.FIRMWARE_INCLUDE / 'ocr_config.h'}")


if __name__ == "__main__":
    main()
