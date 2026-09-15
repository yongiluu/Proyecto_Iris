#ifndef BLE_MANAGER_H
#define BLE_MANAGER_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "config.h"

// Callback type for receiving audio from phone
typedef void (*AudioReceiveCallback)(const uint8_t* data, size_t length);

class BleManager {
public:
    BleManager();
    void init(AudioReceiveCallback audioCallback);
    bool isConnected();
    void sendAudioChunk(const uint8_t* data, size_t length);
    void sendCommand(const char* cmd);
    void sendPhotoChunk(const uint8_t* data, size_t length);

private:
    NimBLEServer* pServer;
    NimBLECharacteristic* pTxCharacteristic; // Mic audio
    NimBLECharacteristic* pRxCharacteristic; // TTS audio
    NimBLECharacteristic* pCmdCharacteristic; // Commands (PTT)
    NimBLECharacteristic* pPhotoCharacteristic; // Photo data
    bool deviceConnected;
    AudioReceiveCallback onAudioReceived;

    friend class ServerCallbacks;
    friend class RxCallbacks;
};

extern BleManager bleManager;

#endif
