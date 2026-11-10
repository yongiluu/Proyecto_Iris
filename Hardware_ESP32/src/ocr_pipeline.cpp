#include "ocr_pipeline.h"

#include <string.h>

void ocrDownsample2x(const uint8_t* vga, uint8_t* out) {
    for (int y = 0; y < kOcrDetHeight; y++) {
        const uint8_t* row0 = vga + (2 * y) * kOcrVgaWidth;
        const uint8_t* row1 = row0 + kOcrVgaWidth;
        for (int x = 0; x < kOcrDetWidth; x++) {
            const int sum = row0[2 * x] + row0[2 * x + 1] + row1[2 * x] + row1[2 * x + 1];
            out[y * kOcrDetWidth + x] = (uint8_t)((sum + 2) >> 2);
        }
    }
}

int ocrFindLines(const uint8_t* textMap, int threshold, OcrBox* boxes, int maxBoxes) {
    static uint8_t visited[kOcrMapHeight * kOcrMapWidth];
    static int16_t stack[kOcrMapHeight * kOcrMapWidth];
    memset(visited, 0, sizeof(visited));

    static OcrBox found[kOcrMapHeight * kOcrMapWidth / kOcrMinCells];  // estatico: 9,6 KB no van en la pila de la tarea
    int nFound = 0;
    for (int y = 0; y < kOcrMapHeight; y++) {
        for (int x = 0; x < kOcrMapWidth; x++) {
            const int start = y * kOcrMapWidth + x;
            if (textMap[start] < threshold || visited[start]) continue;
            int top = 0, count = 0;
            int x0 = x, x1 = x, y0 = y, y1 = y;
            visited[start] = 1;
            stack[top++] = (int16_t)start;
            while (top > 0) {
                const int cell = stack[--top];
                const int cy = cell / kOcrMapWidth, cx = cell % kOcrMapWidth;
                count++;
                if (cx < x0) x0 = cx;
                if (cx > x1) x1 = cx;
                if (cy < y0) y0 = cy;
                if (cy > y1) y1 = cy;
                const int ny[4] = {cy - 1, cy + 1, cy, cy};
                const int nx[4] = {cx, cx, cx - 1, cx + 1};
                for (int k = 0; k < 4; k++) {
                    if (ny[k] < 0 || ny[k] >= kOcrMapHeight || nx[k] < 0 || nx[k] >= kOcrMapWidth) continue;
                    const int next = ny[k] * kOcrMapWidth + nx[k];
                    if (textMap[next] >= threshold && !visited[next]) {
                        visited[next] = 1;
                        stack[top++] = (int16_t)next;
                    }
                }
            }
            if (count >= kOcrMinCells) found[nFound++] = OcrBox{x0, y0, x1 + 1, y1 + 1};
        }
    }

    // De arriba a abajo y de izquierda a derecha (orden estable, como sorted() de Python)
    for (int i = 1; i < nFound; i++) {
        const OcrBox key = found[i];
        int j = i - 1;
        while (j >= 0 && (found[j].y0 > key.y0 || (found[j].y0 == key.y0 && found[j].x0 > key.x0))) {
            found[j + 1] = found[j];
            j--;
        }
        found[j + 1] = key;
    }
    const int n = nFound < maxBoxes ? nFound : maxBoxes;
    for (int i = 0; i < n; i++) boxes[i] = found[i];
    return n;
}

OcrRect ocrLinePixels(const OcrBox& box) {
    int padY = (box.y1 - box.y0) * kOcrCell / 4;
    if (padY < 2) padY = 2;
    OcrRect r{box.x0 * kOcrCell - kOcrPadX, box.y0 * kOcrCell - padY, box.x1 * kOcrCell + kOcrPadX,
              box.y1 * kOcrCell + padY};
    if (r.x0 < 0) r.x0 = 0;
    if (r.y0 < 0) r.y0 = 0;
    if (r.x1 > kOcrVgaWidth) r.x1 = kOcrVgaWidth;
    if (r.y1 > kOcrVgaHeight) r.y1 = kOcrVgaHeight;
    return r;
}

namespace {
void coords(int n, int32_t scale, int size, int* index, int* next, int* frac) {
    for (int i = 0; i < n; i++) {
        int32_t c = i * scale + scale / 2 - (1 << 15);
        if (c < 0) c = 0;
        int idx = c >> 16;
        int f = (c >> 8) & 0xFF;
        if (idx >= size - 1) {
            idx = size - 1;
            f = 0;
        }
        index[i] = idx;
        next[i] = idx + 1 < size ? idx + 1 : idx;
        frac[i] = f;
    }
}

void resizeLine(const uint8_t* vga, int x0, int y0, int x1, int y1, uint8_t* line) {
    const int width = x1 - x0, height = y1 - y0;
    int outW = width * kOcrLineHeight / height;
    if (outW < 1) outW = 1;
    if (outW > kOcrLineWidth) outW = kOcrLineWidth;
    const int32_t scaleY = (int32_t)(((int64_t)height << 16) / kOcrLineHeight);
    const int32_t scaleX = (int32_t)(((int64_t)width << 16) / outW);

    int yi[kOcrLineHeight], yn[kOcrLineHeight], fy[kOcrLineHeight];
    static int xi[kOcrLineWidth], xn[kOcrLineWidth], fx[kOcrLineWidth];
    coords(kOcrLineHeight, scaleY, height, yi, yn, fy);
    coords(outW, scaleX, width, xi, xn, fx);

    for (int oy = 0; oy < kOcrLineHeight; oy++) {
        const uint8_t* r0 = vga + (y0 + yi[oy]) * kOcrVgaWidth + x0;
        const uint8_t* r1 = vga + (y0 + yn[oy]) * kOcrVgaWidth + x0;
        for (int ox = 0; ox < outW; ox++) {
            const int top = r0[xi[ox]] * (256 - fx[ox]) + r0[xn[ox]] * fx[ox];
            const int bottom = r1[xi[ox]] * (256 - fx[ox]) + r1[xn[ox]] * fx[ox];
            line[oy * kOcrLineWidth + ox] = (uint8_t)((top * (256 - fy[oy]) + bottom * fy[oy] + (1 << 15)) >> 16);
        }
    }
    if (outW < kOcrLineWidth) {  // relleno a la derecha: promedio de las 2 ultimas columnas
        const int first = outW >= 2 ? outW - 2 : 0;
        const int cols = outW - first;
        int sum = 0;
        for (int oy = 0; oy < kOcrLineHeight; oy++) {
            for (int ox = first; ox < outW; ox++) sum += line[oy * kOcrLineWidth + ox];
        }
        const uint8_t edge = (uint8_t)(sum / (kOcrLineHeight * cols));
        for (int oy = 0; oy < kOcrLineHeight; oy++) {
            memset(line + oy * kOcrLineWidth + outW, edge, kOcrLineWidth - outW);
        }
    }
}
}  // namespace

int ocrCropLine(const uint8_t* vga, const OcrRect& rect, uint8_t* out) {
    const int width = rect.x1 - rect.x0, height = rect.y1 - rect.y0;
    if (width <= 0 || height <= 0) return 0;
    const int natural = width * kOcrLineHeight / height;
    int pieces = natural <= kOcrLineWidth * 5 / 4 ? 1 : (natural + kOcrLineWidth - 1) / kOcrLineWidth;
    if (pieces > kOcrMaxPieces) pieces = kOcrMaxPieces;
    for (int p = 0; p < pieces; p++) {
        const int px0 = rect.x0 + width * p / pieces;
        const int px1 = rect.x0 + width * (p + 1) / pieces;
        resizeLine(vga, px0, rect.y0, px1, rect.y1, out + p * kOcrLineHeight * kOcrLineWidth);
    }
    return pieces;
}

size_t ocrCtcDecode(const uint8_t* best, char* out, size_t outSize) {
    size_t len = 0;
    int previous = 0;
    for (int t = 0; t < kOcrTimeSteps; t++) {
        const int index = best[t];
        if (index != previous && index != 0 && index < kOcrNumClasses) {
            // El caracter entero o nada: una letra con tilde son 2 bytes y no se debe cortar al medio.
            const char* c = kOcrCharset[index];
            const size_t bytes = strlen(c);
            if (len + bytes + 1 <= outSize) {
                memcpy(out + len, c, bytes);
                len += bytes;
            }
        }
        previous = index;
    }
    // Sin espacios al principio ni al final (como .strip() en Python)
    size_t start = 0;
    while (start < len && out[start] == ' ') start++;
    while (len > start && out[len - 1] == ' ') len--;
    if (start > 0) memmove(out, out + start, len - start);
    len -= start;
    if (outSize) out[len] = '\0';
    return len;
}
