#include <Arduino.h>
#include <WiFi.h>
#include <WebSocketsServer.h>

#include "config.h"
#include "camera_driver.h"
#include "audio_player.h"

const char* WIFI_SSID = "Diego";
const char* WIFI_PASS = "Pepinillos";

WebSocketsServer webSocket = WebSocketsServer(81);

void webSocketEvent(uint8_t num, WStype_t type, uint8_t * payload, size_t length) {
  switch(type) {
    case WStype_CONNECTED:
      Serial.printf("[%u] App conectada por WebSocket\n", num);
      break;
    case WStype_DISCONNECTED:
      Serial.printf("[%u] App desconectada\n", num);
      break;
    case WStype_BIN:
      playAudioBuffer(payload, length);
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);

  if (!initCamera()) {
    Serial.println("Error al inicializar la cámara");
  }

  initAudioPlayer();

  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) {
    delay(100);
  }

  Serial.print("IP asignada al ESP32: ");
  Serial.println(WiFi.localIP());

  startCameraServer();
  webSocket.begin();
  webSocket.onEvent(webSocketEvent);
}

void loop() {
  webSocket.loop();
}
