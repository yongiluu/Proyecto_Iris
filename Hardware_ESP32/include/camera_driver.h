#ifndef CAMERA_DRIVER_H
#define CAMERA_DRIVER_H

#include "esp_camera.h"
#include "esp_http_server.h"

bool initCamera();
void startCameraServer();

#endif
