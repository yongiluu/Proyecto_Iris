#ifndef OTA_UPDATE_H
#define OTA_UPDATE_H

#include <Arduino.h>

// Actualizar el firmware por WiFi con la caja cerrada (sin USB).
// La placa crea su propia red WiFi (OTA_AP_SSID, clave [ota] password) con IP fija 192.168.4.1 y espera
// el firmware nuevo por HTTP (http://192.168.4.1/update). El PC se conecta a esa red y sube con el entorno
// seeed_xiao_esp32s3_ota (o tools/subir_por_wifi.py, que hace todo). Ver ACTUALIZAR_POR_WIFI.md.
// Si no llega nada en OTA_TIMEOUT_MS, la placa se reinicia y vuelve a funcionar normal.

// Abre la red y el servidor de actualizacion. Devuelve false si el WiFi no pudo arrancar.
bool startOtaUpdate();

// Llamar en cada vuelta del loop mientras otaActive().
void handleOtaUpdate();

bool otaActive();

#endif
