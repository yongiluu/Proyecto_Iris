#ifndef MODEL_STORE_H
#define MODEL_STORE_H

// Modelos guardados en la particion "modelos" de la flash, FUERA del programa (partitions_iris_8MB.csv).
// Asi entran mas modelos que en el programa (lector de texto, descripcion de escenas, caras...) y se
// actualizan por WiFi sin recompilar: http://192.168.4.1/modelos (Hardware_ESP32/tools/subir_modelos.py).
// Los modelos se leen directo de la flash (mmap): no gastan RAM.
//
// Si la particion esta vacia, la placa igual funciona (voz, audio, wake word, detector de luz) y la app
// describe y lee con la nube o el celular.

#include "model_store_format.h"

// Abre la particion (una vez). Devuelve el estado; con kModelStoreOk imprime los modelos que hay.
ModelStoreStatus modelStoreBegin();

// Busca un modelo (revisa su CRC la primera vez). nullptr si no esta, con el motivo en el log.
const ModelEntry* modelStoreGet(const char* name);

// Mientras se sube un paquete nuevo por WiFi, nadie debe leer modelos de la particion.
void modelStoreSetWriting(bool writing);
bool modelStoreWriting();

// Las tareas que corren modelos de la particion (escenas, lector de texto) marcan cada uso: la subida
// de modelos (OTA) espera a que terminen antes de borrar la flash. modelStoreBeginUse() devuelve false
// si ya se esta escribiendo (no tocar los modelos); si devuelve true, llamar modelStoreEndUse() al final.
bool modelStoreBeginUse();
void modelStoreEndUse();
// Marca la escritura (desde aqui modelStoreBeginUse() devuelve false) y espera hasta timeoutMs a que
// terminen los usos en curso. true = nadie esta leyendo los modelos.
bool modelStoreLockForWriting(uint32_t timeoutMs);

#endif
