// Lee un paquete de modelos con el MISMO codigo de la placa (model_store_format.cpp) y escribe lo que
// encuentra, para compararlo con tools/pack_models.py (tests/test_model_store.py).
//   model_store_host PAQUETE NOMBRE...
// Salida, una linea por nombre: "<nombre> <estado> <tamano> <arena> <crc32 de los bytes leidos> <banderas>"
// y antes "count <estado> <n>".
#include <stdio.h>
#include <stdlib.h>

#include <vector>

#include "model_store_format.h"

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    FILE* f = fopen(argv[1], "rb");
    if (!f) return 3;
    std::vector<uint8_t> data;
    uint8_t buffer[65536];
    size_t n;
    while ((n = fread(buffer, 1, sizeof(buffer), f)) > 0) data.insert(data.end(), buffer, buffer + n);
    fclose(f);

    uint32_t count = 0;
    const ModelStoreStatus check = modelStoreCheck(data.data(), data.size(), &count);
    printf("count %d %u\n", (int)check, (unsigned)count);
    for (int i = 2; i < argc; i++) {
        ModelEntry entry{};
        const ModelStoreStatus status = modelStoreFind(data.data(), data.size(), argv[i], true, &entry);
        if (status == kModelStoreOk) {
            printf("%s %d %u %u %u %u\n", argv[i], (int)status, (unsigned)entry.size, (unsigned)entry.arenaBytes,
                   (unsigned)modelStoreCrc32(entry.data, entry.size), (unsigned)entry.flags);
        } else {
            printf("%s %d 0 0 0 0\n", argv[i], (int)status);
        }
    }
    return 0;
}
