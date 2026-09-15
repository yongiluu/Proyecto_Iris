#ifndef CAMERA_DRIVER_H
#define CAMERA_DRIVER_H

#include "esp_camera.h"

bool initCamera();
// Retorna un puntero al frame capture. Recuerda llamar a esp_camera_fb_return(fb) despues de usarlo.
camera_fb_t* capturePhoto();

#endif
