#ifndef PHOTO_TRANSFER_H
#define PHOTO_TRANSFER_H

// Crea la tarea que captura y envia fotos por BLE.
bool startPhotoTask();

// Pide una foto. Seguro de llamar desde callbacks BLE (no bloquea).
void requestPhotoCapture();

#endif
