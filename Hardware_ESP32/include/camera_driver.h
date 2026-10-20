#ifndef CAMERA_DRIVER_H
#define CAMERA_DRIVER_H

#include "esp_camera.h"

// La camara vive normalmente en modo escala de grises 96x96 (Edge AI). Para una foto JPEG
// hay que reconfigurarla, por eso todo acceso pasa por un mutex: siempre se debe llamar
// a release*() despues de un acquire*() que devolvio un frame.
bool initCamera();

// Frame 96x96 en grises para la vision local. nullptr si la camara esta ocupada o fallo.
camera_fb_t* acquireGrayFrame();
void releaseGrayFrame(camera_fb_t* frame);

// Foto JPEG para enviar al telefono. Reconfigura la camara y la restaura en release.
camera_fb_t* acquireJpegFrame();
void releaseJpegFrame(camera_fb_t* frame);

// Apaga la camara (antes de actualizar por WiFi: su tarea se cae mientras se escribe la flash).
void shutdownCamera();

#endif
