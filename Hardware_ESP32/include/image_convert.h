#ifndef IMAGE_CONVERT_H
#define IMAGE_CONVERT_H

// Conversiones de los frames de la camara (RGB565, el formato nativo a color de la OV2640).
// C++ puro (sin Arduino) para probarlo en el PC: ML_Training/tests/test_image_convert.py lo compara
// con la implementacion de referencia de Python (ML_Training/camara/board_image.py).

#include <stddef.h>
#include <stdint.h>

constexpr int kGrayModelSize = 96;  // brillo para el detector de luz (los modelos en grises se retiraron)

// RGB565 de la camara: 2 bytes por pixel, el byte alto primero (big-endian).
// Recorta el cuadrado central (lado = min(ancho, alto)), lo reduce a 96x96 con interpolacion bilineal
// y lo pasa a grises (luma Rec. 601 entera). out debe tener 96*96 bytes.
void rgb565ToGray96(const uint8_t* rgb565, int width, int height, uint8_t* out);

// RGB565 -> RGB888 (3 bytes por pixel, R G B). Para los modelos a color.
void rgb565ToRgb888(const uint8_t* rgb565, size_t pixelCount, uint8_t* out);

// RGB888 -> RGB565 (byte alto primero), para mandar a la app la misma imagen que ve el modelo.
void rgb888ToRgb565(const uint8_t* rgb888, size_t pixelCount, uint8_t* out);

// ─── Imagen derecha segun como va montada la camara ───
// En los lentes la camara va de lado: la imagen llega girada 90 grados y en espejo (medido con
// tools/foto_serial.py). kMountTransverse la endereza: derecha(x, y) = original(ancho-1-y, alto-1-x).
constexpr uint8_t kMountUpright = 0;
constexpr uint8_t kMountTransverse = 1;

// Endereza la imagen (src de sw x sh), recorta el centro con la proporcion de destino y la escala con
// interpolacion bilineal en punto fijo 16.16 a dw x dh. Gris: 1 byte por pixel.
// maxCropW > 0: zoom digital, el recorte central no pasa de maxCropW pixeles de ancho (con maxCropW = dw
// la imagen sale a su tamano nativo, sin achicar: el texto chico se ve mas grande para el lector).
void grayUpright(const uint8_t* src, int sw, int sh, uint8_t mount, uint8_t* dst, int dw, int dh,
                 int maxCropW = 0);
// Lo mismo desde RGB565 de la camara hacia RGB888 (la entrada de Retina).
void rgb565UprightToRgb888(const uint8_t* src, int sw, int sh, uint8_t mount, uint8_t* dst, int dw, int dh);

#endif
