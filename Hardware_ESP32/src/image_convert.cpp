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

void rgb888ToRgb565(const uint8_t* rgb888, size_t pixelCount, uint8_t* out) {
    for (size_t i = 0; i < pixelCount; i++) {
        const uint16_t v = (uint16_t)(((rgb888[i * 3] >> 3) << 11) | ((rgb888[i * 3 + 1] >> 2) << 5) |
                                      (rgb888[i * 3 + 2] >> 3));
        out[i * 2] = (uint8_t)(v >> 8);
        out[i * 2 + 1] = (uint8_t)(v & 0xFF);
    }
}

namespace {
// Un eje del muestreo bilineal (igual que rgb565ToGray96): indice, vecino y fraccion 0-255.
struct Tap {
    int i0, i1, f;
};

inline Tap axisTap(int o, int32_t scale, int offset, int size) {
    int32_t s = o * scale + scale / 2 - (1 << 15);
    if (s < 0) s = 0;
    int i = s >> 16;
    int f = (s >> 8) & 0xFF;
    if (i >= size - 1) { i = size - 1; f = 0; }
    const int i1 = i + 1 < size ? i + 1 : i;
    return {offset + i, offset + i1, f};
}

// Geometria comun: tamano de la imagen derecha, recorte central y escala por eje.
struct UprightPlan {
    int cw, ch, x0, y0;
    int32_t scaleX, scaleY;
};

inline UprightPlan planUpright(int sw, int sh, uint8_t mount, int dw, int dh, int maxCropW = 0) {
    const int uw = mount == kMountTransverse ? sh : sw;
    const int uh = mount == kMountTransverse ? sw : sh;
    UprightPlan p;
    if ((int64_t)uw * dh > (int64_t)uh * dw) {  // la imagen derecha es mas ancha: recortar los lados
        p.ch = uh;
        p.cw = (int)((int64_t)uh * dw / dh);
    } else {                                     // es mas alta: recortar arriba y abajo
        p.cw = uw;
        p.ch = (int)((int64_t)uw * dh / dw);
    }
    if (maxCropW > 0 && p.cw > maxCropW) {  // zoom digital: solo el centro, sin achicar
        p.cw = maxCropW;
        p.ch = (int)((int64_t)maxCropW * dh / dw);
    }
    p.x0 = (uw - p.cw) / 2;
    p.y0 = (uh - p.ch) / 2;
    p.scaleX = (int32_t)(((int64_t)p.cw << 16) / dw);
    p.scaleY = (int32_t)(((int64_t)p.ch << 16) / dh);
    return p;
}

// Indice del pixel original para el punto (u, v) de la imagen derecha.
inline int sourceIndex(int u, int v, int sw, int sh, uint8_t mount) {
    if (mount == kMountTransverse) return (sh - 1 - u) * sw + (sw - 1 - v);
    return v * sw + u;
}

inline int blend(int a, int b, int c, int d, int fx, int fy) {
    const int top = a * (256 - fx) + b * fx;
    const int bottom = c * (256 - fx) + d * fx;
    return (top * (256 - fy) + bottom * fy + (1 << 15)) >> 16;
}
}  // namespace

void grayUpright(const uint8_t* src, int sw, int sh, uint8_t mount, uint8_t* dst, int dw, int dh,
                 int maxCropW) {
    const UprightPlan p = planUpright(sw, sh, mount, dw, dh, maxCropW);
    for (int oy = 0; oy < dh; oy++) {
        const Tap ty = axisTap(oy, p.scaleY, p.y0, p.ch);
        for (int ox = 0; ox < dw; ox++) {
            const Tap tx = axisTap(ox, p.scaleX, p.x0, p.cw);
            const int a = src[sourceIndex(tx.i0, ty.i0, sw, sh, mount)];
            const int b = src[sourceIndex(tx.i1, ty.i0, sw, sh, mount)];
            const int c = src[sourceIndex(tx.i0, ty.i1, sw, sh, mount)];
            const int d = src[sourceIndex(tx.i1, ty.i1, sw, sh, mount)];
            dst[oy * dw + ox] = (uint8_t)blend(a, b, c, d, tx.f, ty.f);
        }
    }
}

void rgb565UprightToRgb888(const uint8_t* src, int sw, int sh, uint8_t mount, uint8_t* dst, int dw, int dh) {
    const UprightPlan p = planUpright(sw, sh, mount, dw, dh);
    for (int oy = 0; oy < dh; oy++) {
        const Tap ty = axisTap(oy, p.scaleY, p.y0, p.ch);
        for (int ox = 0; ox < dw; ox++) {
            const Tap tx = axisTap(ox, p.scaleX, p.x0, p.cw);
            int c[4][3];
            unpack(src + sourceIndex(tx.i0, ty.i0, sw, sh, mount) * 2, c[0][0], c[0][1], c[0][2]);
            unpack(src + sourceIndex(tx.i1, ty.i0, sw, sh, mount) * 2, c[1][0], c[1][1], c[1][2]);
            unpack(src + sourceIndex(tx.i0, ty.i1, sw, sh, mount) * 2, c[2][0], c[2][1], c[2][2]);
            unpack(src + sourceIndex(tx.i1, ty.i1, sw, sh, mount) * 2, c[3][0], c[3][1], c[3][2]);
            uint8_t* out = dst + (oy * dw + ox) * 3;
            for (int ch = 0; ch < 3; ch++) out[ch] = (uint8_t)blend(c[0][ch], c[1][ch], c[2][ch], c[3][ch], tx.f, ty.f);
        }
    }
}
