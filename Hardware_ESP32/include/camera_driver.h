#ifndef CAMERA_DRIVER_H
#define CAMERA_DRIVER_H

#include "esp_camera.h"

// La camara vive normalmente a color, 160x120 RGB565 (CAMERA_COLOR_FRAME_SIZE): lo que miran los modelos
// locales. Para una foto JPEG (la que va a la nube) hay que reconfigurarla, por eso todo acceso pasa por
// un mutex: siempre se debe llamar a release*() despues de un acquire*() que devolvio un frame.
bool initCamera();

// Frame a color RGB565 (2 bytes por pixel, byte alto primero). nullptr si la camara esta ocupada o fallo.
camera_fb_t* acquireColorFrame();
void releaseColorFrame(camera_fb_t* frame);

// Toma un frame a color y lo deja en out como 96x96 en grises (cuadrado central), la entrada de los
// modelos en grises (escenas y cercania). out debe tener 96*96 bytes. false si no hubo frame.
bool captureGray96(uint8_t* out);

// Foto JPEG para enviar al telefono. Reconfigura la camara y la restaura en release.
camera_fb_t* acquireJpegFrame();
void releaseJpegFrame(camera_fb_t* frame);

// Detector de luz: con exposicion y ganancia FIJAS el brillo del frame mide la luz real (con la
// automatica, la camara compensa y todo se ve igual de claro). Se mantiene aunque la camara se
// reinicie para sacar una foto JPEG.
void setCameraFixedExposure(bool fixed);

// Apaga la camara (antes de actualizar por WiFi: su tarea se cae mientras se escribe la flash).
void shutdownCamera();

#endif
