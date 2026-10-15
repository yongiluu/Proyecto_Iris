#ifndef BLE_MANAGER_H
#define BLE_MANAGER_H

#include <Arduino.h>
#include <NimBLEDevice.h>
#include "config.h"

// Audio TTS recibido desde el telefono (PCM 16-bit mono)
typedef void (*AudioReceiveCallback)(const uint8_t* data, size_t length);
// Comando de texto recibido desde el telefono (ej. "CMD_TAKE_PHOTO"). Se ejecuta en el hilo BLE: no bloquear.
typedef void (*CommandReceiveCallback)(const char* command);

class BleManager {
public:
    BleManager();
    void init(AudioReceiveCallback audioCallback, CommandReceiveCallback commandCallback);
    bool isConnected() const;

    // Tamano maximo de datos por notificacion con el MTU negociado.
    size_t payloadSize() const;

    // Parten automaticamente el dato segun el MTU. Devuelven false si no hay conexion.
    bool sendAudioChunk(const uint8_t* data, size_t length);
    bool sendCommand(const char* command);
    bool sendPhotoChunk(const uint8_t* data, size_t length);

private:
    bool notifyInChunks(NimBLECharacteristic* characteristic, const uint8_t* data, size_t length);

    NimBLEServer* pServer;
    NimBLECharacteristic* pTxCharacteristic;    // Audio del microfono
    NimBLECharacteristic* pRxCharacteristic;    // Audio TTS
    NimBLECharacteristic* pCmdCharacteristic;   // Comandos
    NimBLECharacteristic* pPhotoCharacteristic; // Foto
    volatile bool deviceConnected;
    volatile uint16_t negotiatedMtu;
    AudioReceiveCallback onAudioReceived;
    CommandReceiveCallback onCommandReceived;

    friend class ServerCallbacks;
    friend class RxCallbacks;
    friend class CmdRxCallbacks;
};

extern BleManager bleManager;

#endif
