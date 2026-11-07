// Ejecuta las conversiones de imagen del firmware en el PC.
// Uso: image_convert_host <entrada.rgb565> <ancho> <alto> <salida_gris96.raw> <salida_rgb888.raw>
#include <stdio.h>
#include <stdlib.h>
#include <vector>

#include "image_convert.h"

int main(int argc, char** argv) {
    if (argc != 6) {
        fprintf(stderr, "uso: %s entrada.rgb565 ancho alto gris96.raw rgb888.raw\n", argv[0]);
        return 2;
    }
    const int width = atoi(argv[2]), height = atoi(argv[3]);
    std::vector<uint8_t> input((size_t)width * height * 2);
    FILE* in = fopen(argv[1], "rb");
    if (!in || fread(input.data(), 1, input.size(), in) != input.size()) {
        fprintf(stderr, "no se pudo leer la entrada\n");
        return 1;
    }
    fclose(in);

    std::vector<uint8_t> gray(kGrayModelSize * kGrayModelSize);
    rgb565ToGray96(input.data(), width, height, gray.data());
    std::vector<uint8_t> rgb((size_t)width * height * 3);
    rgb565ToRgb888(input.data(), (size_t)width * height, rgb.data());

    FILE* outGray = fopen(argv[4], "wb");
    FILE* outRgb = fopen(argv[5], "wb");
    if (!outGray || !outRgb) return 1;
    fwrite(gray.data(), 1, gray.size(), outGray);
    fwrite(rgb.data(), 1, rgb.size(), outRgb);
    fclose(outGray);
    fclose(outRgb);
    return 0;
}
