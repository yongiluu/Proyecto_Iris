#ifndef PHOTO_TRANSFER_H
#define PHOTO_TRANSFER_H

// Crea la tarea que captura y envia fotos por BLE.
bool startPhotoTask();

// Pide una foto JPEG (para la IA de la nube). Seguro de llamar desde callbacks BLE (no bloquea).
void requestPhotoCapture();

// Pide un frame a color 160x120 RGB565, el mismo que ve el modelo de escenas (modo recoleccion de datos).
// Protocolo: CMD_FRAME_START:<ancho>:<alto>:rgb565 -> pixeles (2 bytes c/u, byte alto primero) por la
// caracteristica de foto -> CMD_FRAME_END.
void requestColorFrameCapture();

#endif
