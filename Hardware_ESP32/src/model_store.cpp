#include "model_store.h"

#include <Arduino.h>
#include <esp_partition.h>
#include <string.h>

namespace {
constexpr const char* kPartitionLabel = "modelos";
constexpr int kMaxCached = 8;

const uint8_t* base = nullptr;
size_t baseLength = 0;
bool started = false;
ModelStoreStatus startStatus = kModelStoreEmpty;
volatile bool writing = false;

struct Cached {
    char name[kModelStoreNameBytes];
    ModelEntry entry;
};
Cached cache[kMaxCached];
int cached = 0;
}  // namespace

ModelStoreStatus modelStoreBegin() {
    if (started) return startStatus;
    started = true;
    const esp_partition_t* partition =
        esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, kPartitionLabel);
    if (partition == nullptr) {
        Serial.println("[Modelos] Esta tabla de particiones no tiene \"modelos\" (grabar por USB el entorno completo)");
        startStatus = kModelStoreEmpty;
        return startStatus;
    }
    const void* mapped = nullptr;
    spi_flash_mmap_handle_t handle;
    if (esp_partition_mmap(partition, 0, partition->size, SPI_FLASH_MMAP_DATA, &mapped, &handle) != ESP_OK) {
        Serial.println("[Modelos] No se pudo mapear la particion");
        startStatus = kModelStoreEmpty;
        return startStatus;
    }
    base = (const uint8_t*)mapped;
    baseLength = partition->size;
    uint32_t count = 0;
    startStatus = modelStoreCheck(base, baseLength, &count);
    if (startStatus != kModelStoreOk) {
        Serial.printf("[Modelos] %s (sube los modelos con tools/subir_modelos.py)\n", modelStoreStatusText(startStatus));
        return startStatus;
    }
    Serial.printf("[Modelos] %u modelos en la flash:", (unsigned)count);
    for (uint32_t i = 0; i < count; i++) Serial.printf(" %s", modelStoreNameAt(base, baseLength, i));
    Serial.println();
    return startStatus;
}

const ModelEntry* modelStoreGet(const char* name) {
    if (writing) {
        Serial.printf("[Modelos] %s: se esta subiendo un paquete nuevo\n", name);
        return nullptr;
    }
    for (int i = 0; i < cached; i++) {
        if (strcmp(cache[i].name, name) == 0) return &cache[i].entry;
    }
    if (modelStoreBegin() != kModelStoreOk) return nullptr;
    ModelEntry entry;
    const ModelStoreStatus status = modelStoreFind(base, baseLength, name, /*verifyCrc=*/true, &entry);
    if (status != kModelStoreOk) {
        Serial.printf("[Modelos] %s: %s\n", name, modelStoreStatusText(status));
        return nullptr;
    }
    if (cached == kMaxCached) return nullptr;
    strncpy(cache[cached].name, name, kModelStoreNameBytes - 1);
    cache[cached].name[kModelStoreNameBytes - 1] = '\0';
    cache[cached].entry = entry;
    return &cache[cached++].entry;
}

void modelStoreSetWriting(bool value) {
    writing = value;
}

bool modelStoreWriting() {
    return writing;
}
