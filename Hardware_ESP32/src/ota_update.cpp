#include "ota_update.h"

#include <HTTPUpdateServer.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>

#include "config.h"
#include "model_store.h"

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
bool modelsOk = false;

// POST /modelos (campo "modelos"): paquete de ML_Training/tools/pack_models.py a la particion
// "modelos". Mismo usuario y clave que /update. Al terminar bien, la placa se reinicia.
void handleModelsUpload() {
    HTTPUpload& upload = server->upload();
    if (upload.status == UPLOAD_FILE_START) {
        modelsOk = false;
        if (!server->authenticate("iris", IRIS_OTA_PASSWORD)) return;
        modelStoreSetWriting(true);  // nadie lee modelos mientras se borra y escribe la particion
        Serial.printf("[OTA] Modelos: recibiendo %s\n", upload.filename.c_str());
        if (!Update.begin(UPDATE_SIZE_UNKNOWN, U_SPIFFS, -1, LOW, "modelos")) Update.printError(Serial);
    } else if (upload.status == UPLOAD_FILE_WRITE && Update.isRunning()) {
        if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) Update.printError(Serial);
    } else if (upload.status == UPLOAD_FILE_END && Update.isRunning()) {
        modelsOk = Update.end(true);
        if (!modelsOk) Update.printError(Serial);
        Serial.printf("[OTA] Modelos: %u bytes %s\n", (unsigned)upload.totalSize, modelsOk ? "OK" : "con error");
    } else if (upload.status == UPLOAD_FILE_ABORTED) {
        Update.abort();
    }
}

void handleModelsDone() {
    if (!server->authenticate("iris", IRIS_OTA_PASSWORD)) {
        server->requestAuthentication();
        return;
    }
    server->sendHeader("Connection", "close");
    server->send(modelsOk ? 200 : 500, "text/plain", modelsOk ? "Modelos OK, reiniciando" : "Error al grabar los modelos");
    delay(200);
    ESP.restart();  // tambien si fallo: la placa vuelve a revisar la particion al arrancar
}
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
    server->on("/modelos", HTTP_POST, handleModelsDone, handleModelsUpload);
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
