#include "image_convert.h"

namespace {
// Expande los canales de 5/6 bits a 8 bits repitiendo los bits altos (31 -> 255, 63 -> 255).
inline void unpack(const uint8_t* p, int& r, int& g, int& b) {
    const uint16_t v = (uint16_t)((p[0] << 8) | p[1]);
    const int r5 = (v >> 11) & 0x1F, g6 = (v >> 5) & 0x3F, b5 = v & 0x1F;
    r = (r5 << 3) | (r5 >> 2);
    g = (g6 << 2) | (g6 >> 4);
    b = (b5 << 3) | (b5 >> 2);
}

inline int luma(const uint8_t* p) {
    int r, g, b;
    unpack(p, r, g, b);
    return (77 * r + 150 * g + 29 * b + 128) >> 8;  // Rec. 601: 0.299 R + 0.587 G + 0.114 B
}
}  // namespace

void rgb565ToGray96(const uint8_t* rgb565, int width, int height, uint8_t* out) {
    const int side = width < height ? width : height;
    const int x0 = (width - side) / 2;
    const int y0 = (height - side) / 2;

    // Bilineal en punto fijo (16.16): el centro del pixel de salida cae en (i + 0.5) * escala - 0.5.
    const int32_t scale = (int32_t)(((int64_t)side << 16) / kGrayModelSize);
    for (int oy = 0; oy < kGrayModelSize; oy++) {
        int32_t sy = oy * scale + scale / 2 - (1 << 15);
        if (sy < 0) sy = 0;
        int y = sy >> 16;
        int fy = (sy >> 8) & 0xFF;
        if (y >= side - 1) { y = side - 1; fy = 0; }
        const int y1 = y + 1 < side ? y + 1 : y;

        for (int ox = 0; ox < kGrayModelSize; ox++) {
            int32_t sx = ox * scale + scale / 2 - (1 << 15);
            if (sx < 0) sx = 0;
            int x = sx >> 16;
            int fx = (sx >> 8) & 0xFF;
            if (x >= side - 1) { x = side - 1; fx = 0; }
            const int x1 = x + 1 < side ? x + 1 : x;

            const uint8_t* row0 = rgb565 + ((y0 + y) * width + x0) * 2;
            const uint8_t* row1 = rgb565 + ((y0 + y1) * width + x0) * 2;
            const int a = luma(row0 + x * 2), b = luma(row0 + x1 * 2);
            const int c = luma(row1 + x * 2), d = luma(row1 + x1 * 2);
            const int top = a * (256 - fx) + b * fx;
            const int bottom = c * (256 - fx) + d * fx;
            out[oy * kGrayModelSize + ox] = (uint8_t)((top * (256 - fy) + bottom * fy + (1 << 15)) >> 16);
        }
    }
}

void rgb565ToRgb888(const uint8_t* rgb565, size_t pixelCount, uint8_t* out) {
    for (size_t i = 0; i < pixelCount; i++) {
        int r, g, b;
        unpack(rgb565 + i * 2, r, g, b);
        out[i * 3] = (uint8_t)r;
        out[i * 3 + 1] = (uint8_t)g;
        out[i * 3 + 2] = (uint8_t)b;
    }
}
