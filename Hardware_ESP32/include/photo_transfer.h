#ifndef PHOTO_TRANSFER_H
#define PHOTO_TRANSFER_H

// Crea la tarea que captura y envia fotos por BLE.
bool startPhotoTask();

// Pide una foto JPEG (para la IA de la nube). Seguro de llamar desde callbacks BLE (no bloquea).
void requestPhotoCapture();

// Pide un frame 96x96 en grises, el mismo que ve el modelo de vision (modo recoleccion de datos).
// Protocolo: CMD_FRAME_START:<ancho>:<alto> -> pixeles por la caracteristica de foto -> CMD_FRAME_END.
void requestGrayFrameCapture();

#endif
