#ifndef IMAGE_CONVERT_H
#define IMAGE_CONVERT_H

// Conversiones de los frames de la camara (RGB565, el formato nativo a color de la OV2640).
// C++ puro (sin Arduino) para probarlo en el PC: ML_Training/tests/test_image_convert.py lo compara
// con la implementacion de referencia de Python (ML_Training/vision/board_image.py).

#include <stddef.h>
#include <stdint.h>

constexpr int kGrayModelSize = 96;  // entrada de los modelos en grises (escenas v1-v6 y cercania)

// RGB565 de la camara: 2 bytes por pixel, el byte alto primero (big-endian).
// Recorta el cuadrado central (lado = min(ancho, alto)), lo reduce a 96x96 con interpolacion bilineal
// y lo pasa a grises (luma Rec. 601 entera). out debe tener 96*96 bytes.
void rgb565ToGray96(const uint8_t* rgb565, int width, int height, uint8_t* out);

// RGB565 -> RGB888 (3 bytes por pixel, R G B). Para los modelos a color.
void rgb565ToRgb888(const uint8_t* rgb565, size_t pixelCount, uint8_t* out);

#endif
