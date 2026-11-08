// GENERADO por ML_Training/ocr/firmware_codegen.py desde ocr/config.py. No editar a mano.
#ifndef OCR_CONFIG_H
#define OCR_CONFIG_H

constexpr int kOcrVgaWidth = 640;
constexpr int kOcrVgaHeight = 480;
constexpr int kOcrDetWidth = 320;        // entrada del detector (frame VGA reducido 2x)
constexpr int kOcrDetHeight = 240;
constexpr int kOcrMapWidth = 40;          // salida del detector: celdas
constexpr int kOcrMapHeight = 30;
constexpr int kOcrCell = 16;               // px del frame VGA por celda
constexpr int kOcrMinCells = 2;
constexpr int kOcrMaxLines = 8;
constexpr int kOcrPadX = 8;
constexpr int kOcrLineHeight = 32;    // entrada del lector
constexpr int kOcrLineWidth = 256;
constexpr int kOcrTimeSteps = 64;      // salida del lector: columnas
constexpr int kOcrNumClasses = 100;    // 0 = blanco de CTC
constexpr int kOcrMaxPieces = 4;                        // trozos por linea larga

// Caracter (UTF-8) de cada clase; kOcrCharset[0] es el blanco.
extern const char* const kOcrCharset[kOcrNumClasses];

#endif
