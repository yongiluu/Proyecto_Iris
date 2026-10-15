// Ejecuta el front-end del firmware en el PC: lee PCM int16 crudo y escribe los frames log-mel (float32).
// Uso: frontend_host <entrada.raw> <salida.f32>
#include <stdio.h>
#include <stdlib.h>
#include <vector>

#include "audio_frontend.h"

static void onFrame(const float* mel, void* context) {
    FILE* out = (FILE*)context;
    fwrite(mel, sizeof(float), kAfNumMel, out);
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "uso: %s entrada.raw salida.f32\n", argv[0]);
        return 2;
    }
    FILE* in = fopen(argv[1], "rb");
    FILE* out = fopen(argv[2], "wb");
    if (!in || !out) {
        fprintf(stderr, "no se pudo abrir los archivos\n");
        return 1;
    }

    // Se alimenta en bloques de 250 muestras, igual que el loop del firmware.
    AudioFrontend frontend;
    std::vector<int16_t> block(250);
    size_t read;
    while ((read = fread(block.data(), sizeof(int16_t), block.size(), in)) > 0) {
        frontend.process(block.data(), read, onFrame, out);
    }
    fclose(in);
    fclose(out);
    return 0;
}
