#include "ota_update.h"

#include <HTTPUpdateServer.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>

#include "config.h"

#ifndef IRIS_OTA_PASSWORD
#define IRIS_OTA_PASSWORD "IrisOTA2026"  // se cambia en platformio.ini / secrets.ini ([ota] password)
#endif

namespace {
// Subida por HTTP (el PC manda el .bin con curl): solo el PC abre conexiones, asi el firewall de
// Windows no la bloquea (ArduinoOTA necesita que la placa se conecte de vuelta al PC).
WebServer* server = nullptr;
HTTPUpdateServer updater;
bool active = false;
uint32_t startedMs = 0;
}  // namespace

bool startOtaUpdate() {
    if (active) return true;
    WiFi.mode(WIFI_AP);
    if (!WiFi.softAP(OTA_AP_SSID, IRIS_OTA_PASSWORD)) {
        Serial.println("[OTA] No se pudo crear la red WiFi");
        WiFi.mode(WIFI_OFF);
        return false;
    }
    server = new WebServer(80);
    // Usuario "iris" y la misma clave de la red. Al terminar bien, la placa se reinicia sola.
    updater.setup(server, "/update", "iris", IRIS_OTA_PASSWORD);
    server->begin();

    active = true;
    startedMs = millis();
    Serial.printf("[OTA] Red WiFi \"%s\" lista. Sube el firmware a http://%s/update "
                  "(entorno seeed_xiao_esp32s3_ota)\n", OTA_AP_SSID, WiFi.softAPIP().toString().c_str());
    return true;
}

void handleOtaUpdate() {
    if (!active) return;
    server->handleClient();
    if (!Update.isRunning() && millis() - startedMs > OTA_TIMEOUT_MS) {
        Serial.println("[OTA] Nadie subio firmware: se reinicia en modo normal");
        delay(100);
        ESP.restart();
    }
}

bool otaActive() {
    return active;
}
