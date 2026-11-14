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

#endif
