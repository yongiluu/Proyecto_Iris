#ifndef MODEL_STORE_FORMAT_H
#define MODEL_STORE_FORMAT_H

// Formato del paquete de modelos que vive en la particion "modelos" (fuera del programa).
// Lo escribe ML_Training/tools/pack_models.py; aqui solo se lee. Sin dependencias de la placa:
// tests/test_model_store.py compila este mismo archivo en el PC y lo compara con Python.
//
//   Cabecera (32 bytes, little-endian)
//     0  magic   "IRISMDL1"
//     8  u32     version del formato (1)
//    12  u32     cantidad de modelos
//    16  u32     bytes totales del paquete (cabecera + tabla + modelos)
//    20  u32     CRC32 de la tabla de modelos
//    24  8 bytes reservado (ceros)
//   Tabla: un registro de 48 bytes por modelo
//     0  char[24] nombre (terminado en \0)
//    24  u32     offset desde el inicio del paquete (multiplo de 16)
//    28  u32     bytes del modelo (.tflite)
//    32  u32     arena declarada para TFLM (bytes)
//    36  u32     CRC32 del modelo
//    40  8 bytes reservado
//   Modelos alineados a 16 bytes (TFLM lee los flatbuffers sin copiarlos).

#include <stddef.h>
#include <stdint.h>

constexpr uint32_t kModelStoreVersion = 1;
constexpr size_t kModelStoreHeaderBytes = 32;
constexpr size_t kModelStoreEntryBytes = 48;
constexpr size_t kModelStoreNameBytes = 24;
constexpr uint32_t kModelStoreMaxModels = 32;

struct ModelEntry {
    const uint8_t* data;  // apunta dentro del paquete
    uint32_t size;
    uint32_t arenaBytes;
    uint32_t crc;
};

enum ModelStoreStatus {
    kModelStoreOk = 0,
    kModelStoreEmpty,        // particion borrada (todo 0xFF) o sin paquete
    kModelStoreBadHeader,    // magic, version o tamaños imposibles
    kModelStoreBadTable,     // CRC de la tabla no calza
    kModelStoreNotFound,
    kModelStoreBadModel,     // fuera de rango, desalineado o CRC del modelo no calza
};

// CRC-32 (IEEE, el mismo que zlib.crc32 de Python).
uint32_t modelStoreCrc32(const uint8_t* data, size_t length, uint32_t crc = 0);

// Revisa la cabecera y la tabla. Si [count] no es nulo, devuelve la cantidad de modelos.
ModelStoreStatus modelStoreCheck(const uint8_t* base, size_t length, uint32_t* count);

// Busca un modelo por nombre. Con [verifyCrc], revisa tambien el CRC del modelo (lee todos sus bytes).
ModelStoreStatus modelStoreFind(const uint8_t* base, size_t length, const char* name, bool verifyCrc,
                                ModelEntry* out);

// Nombre del modelo [index] (0..count-1), o nullptr.
const char* modelStoreNameAt(const uint8_t* base, size_t length, uint32_t index);

const char* modelStoreStatusText(ModelStoreStatus status);

#endif
