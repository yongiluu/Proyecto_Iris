#ifndef OCR_PIPELINE_H
#define OCR_PIPELINE_H

// Todo lo que rodea a los dos modelos del lector de texto: reducir el frame, juntar las celdas del
// detector en lineas, recortar y escalar cada linea para el lector, y decodificar el texto (CTC).
// C++ puro (sin Arduino): ML_Training/tests/test_ocr_pipeline.py lo compara con ocr/pipeline.py.

#include <stddef.h>
#include <stdint.h>
#include "ocr_config.h"

struct OcrBox {  // en celdas del mapa del detector; x1/y1 exclusivos
    int x0, y0, x1, y1;
};

struct OcrRect {  // en pixeles del frame VGA; x1/y1 exclusivos
    int x0, y0, x1, y1;
};

// Frame VGA en grises -> entrada del detector (promedio 2x2, redondeado).
void ocrDownsample2x(const uint8_t* vga, uint8_t* out);

// Mapa del detector (probabilidad 0-255 por celda) -> lineas ordenadas de arriba a abajo.
// Devuelve cuantas cajas escribio (como mucho maxBoxes).
int ocrFindLines(const uint8_t* textMap, int threshold, OcrBox* boxes, int maxBoxes);

// Caja en celdas -> rectangulo a recortar del frame VGA (con margen).
OcrRect ocrLinePixels(const OcrBox& box);

// Recorta y escala una linea a 32x256 (puede partirla en trozos si es muy larga).
// out debe tener kOcrMaxPieces * 32 * 256 bytes. Devuelve la cantidad de trozos.
int ocrCropLine(const uint8_t* vga, const OcrRect& rect, uint8_t* out);

// Indice mas probable por columna (kOcrTimeSteps valores) -> texto UTF-8 en out. Devuelve el largo.
size_t ocrCtcDecode(const uint8_t* best, char* out, size_t outSize);

#endif
