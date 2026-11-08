// Ejecuta el procesamiento del lector de texto del firmware en el PC.
// Uso: ocr_pipeline_host <frame_vga.raw> <mapa.raw> <umbral> <mejores.raw> <salida_dir>
//   frame_vga.raw: 640x480 grises; mapa.raw: 30x40 (0-255); mejores.raw: 64 indices (uint8)
// Escribe en salida_dir: det.raw (320x240), boxes.txt, lines.raw (todos los trozos 32x256 seguidos), text.txt
#include <stdio.h>
#include <string>
#include <vector>

#include "ocr_pipeline.h"

static std::vector<uint8_t> readFile(const char* path, size_t size) {
    std::vector<uint8_t> data(size);
    FILE* f = fopen(path, "rb");
    if (!f || fread(data.data(), 1, size, f) != size) {
        fprintf(stderr, "no se pudo leer %s\n", path);
        exit(1);
    }
    fclose(f);
    return data;
}

int main(int argc, char** argv) {
    if (argc != 6) return 2;
    const std::string dir = argv[5];
    auto frame = readFile(argv[1], kOcrVgaWidth * kOcrVgaHeight);
    auto map = readFile(argv[2], kOcrMapWidth * kOcrMapHeight);
    auto best = readFile(argv[4], kOcrTimeSteps);

    std::vector<uint8_t> det(kOcrDetWidth * kOcrDetHeight);
    ocrDownsample2x(frame.data(), det.data());
    FILE* f = fopen((dir + "/det.raw").c_str(), "wb");
    fwrite(det.data(), 1, det.size(), f);
    fclose(f);

    OcrBox boxes[kOcrMaxLines];
    const int n = ocrFindLines(map.data(), atoi(argv[3]), boxes, kOcrMaxLines);
    FILE* fb = fopen((dir + "/boxes.txt").c_str(), "w");
    FILE* fl = fopen((dir + "/lines.raw").c_str(), "wb");
    std::vector<uint8_t> pieces(kOcrMaxPieces * kOcrLineHeight * kOcrLineWidth);
    for (int i = 0; i < n; i++) {
        const OcrRect r = ocrLinePixels(boxes[i]);
        const int count = ocrCropLine(frame.data(), r, pieces.data());
        fprintf(fb, "%d %d %d %d | %d %d %d %d | %d\n", boxes[i].x0, boxes[i].y0, boxes[i].x1, boxes[i].y1,
                r.x0, r.y0, r.x1, r.y1, count);
        fwrite(pieces.data(), 1, (size_t)count * kOcrLineHeight * kOcrLineWidth, fl);
    }
    fclose(fb);
    fclose(fl);

    char text[256];
    ocrCtcDecode(best.data(), text, sizeof(text));
    FILE* ft = fopen((dir + "/text.txt").c_str(), "wb");
    fputs(text, ft);
    fclose(ft);
    return 0;
}
