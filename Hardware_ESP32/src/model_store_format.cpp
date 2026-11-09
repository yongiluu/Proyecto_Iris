#include "model_store_format.h"

#include <string.h>

namespace {
uint32_t readU32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

const uint8_t* entryAt(const uint8_t* base, uint32_t index) {
    return base + kModelStoreHeaderBytes + (size_t)index * kModelStoreEntryBytes;
}
}  // namespace

uint32_t modelStoreCrc32(const uint8_t* data, size_t length, uint32_t crc) {
    static uint32_t table[256];
    static bool ready = false;
    if (!ready) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = true;
    }
    crc = ~crc;
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

ModelStoreStatus modelStoreCheck(const uint8_t* base, size_t length, uint32_t* count) {
    if (count) *count = 0;
    if (base == nullptr || length < kModelStoreHeaderBytes) return kModelStoreEmpty;
    if (memcmp(base, "IRISMDL1", 8) != 0) {
        // Una particion recien borrada tiene todo en 0xFF: no es un error, es que no hay modelos.
        bool erased = true;
        for (size_t i = 0; i < 8; i++) erased = erased && base[i] == 0xFF;
        return erased ? kModelStoreEmpty : kModelStoreBadHeader;
    }
    const uint32_t version = readU32(base + 8);
    const uint32_t n = readU32(base + 12);
    const uint32_t total = readU32(base + 16);
    const size_t tableBytes = (size_t)n * kModelStoreEntryBytes;
    if (version != kModelStoreVersion || n > kModelStoreMaxModels || total > length ||
        kModelStoreHeaderBytes + tableBytes > total) {
        return kModelStoreBadHeader;
    }
    if (modelStoreCrc32(base + kModelStoreHeaderBytes, tableBytes) != readU32(base + 20)) {
        return kModelStoreBadTable;
    }
    if (count) *count = n;
    return kModelStoreOk;
}

const char* modelStoreNameAt(const uint8_t* base, size_t length, uint32_t index) {
    uint32_t n = 0;
    if (modelStoreCheck(base, length, &n) != kModelStoreOk || index >= n) return nullptr;
    const uint8_t* entry = entryAt(base, index);
    // Debe tener su \0 dentro de los 24 bytes.
    if (memchr(entry, 0, kModelStoreNameBytes) == nullptr) return nullptr;
    return (const char*)entry;
}

ModelStoreStatus modelStoreFind(const uint8_t* base, size_t length, const char* name, bool verifyCrc,
                                ModelEntry* out) {
    uint32_t n = 0;
    const ModelStoreStatus status = modelStoreCheck(base, length, &n);
    if (status != kModelStoreOk) return status;
    const uint32_t total = readU32(base + 16);
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t* entry = entryAt(base, i);
        if (memchr(entry, 0, kModelStoreNameBytes) == nullptr) continue;
        if (strcmp((const char*)entry, name) != 0) continue;
        const uint32_t offset = readU32(entry + 24);
        const uint32_t size = readU32(entry + 28);
        const size_t firstModel = kModelStoreHeaderBytes + (size_t)n * kModelStoreEntryBytes;
        if (offset % 16 != 0 || offset < firstModel || size == 0 || (uint64_t)offset + size > total) {
            return kModelStoreBadModel;
        }
        const uint32_t crc = readU32(entry + 36);
        if (verifyCrc && modelStoreCrc32(base + offset, size) != crc) return kModelStoreBadModel;
        if (out) {
            out->data = base + offset;
            out->size = size;
            out->arenaBytes = readU32(entry + 32);
            out->crc = crc;
        }
        return kModelStoreOk;
    }
    return kModelStoreNotFound;
}

const char* modelStoreStatusText(ModelStoreStatus status) {
    switch (status) {
        case kModelStoreOk: return "ok";
        case kModelStoreEmpty: return "sin modelos cargados";
        case kModelStoreBadHeader: return "paquete de modelos invalido";
        case kModelStoreBadTable: return "tabla de modelos danada";
        case kModelStoreNotFound: return "modelo no encontrado";
        case kModelStoreBadModel: return "modelo danado";
    }
    return "?";
}
