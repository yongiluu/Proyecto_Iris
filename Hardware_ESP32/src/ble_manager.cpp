#include "ble_manager.h"

BleManager bleManager;

class ServerCallbacks: public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer) {
        bleManager.deviceConnected = true;
    }

    void onDisconnect(NimBLEServer* pServer) {
        bleManager.deviceConnected = false;
        NimBLEDevice::startAdvertising();
    }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();
        if (value.length() > 0) {
            if (bleManager.onAudioReceived) {
                bleManager.onAudioReceived((const uint8_t*)value.data(), value.length());
            }
        }
    }
};

extern void triggerCameraCapture();

class CmdRxCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();
        if (value.length() > 0) {
            std::string cmd = value;
            if (cmd == "CMD_TAKE_PHOTO") {
                triggerCameraCapture();
            }
        }
    }
};

BleManager::BleManager() : pServer(nullptr), pTxCharacteristic(nullptr), pRxCharacteristic(nullptr), pCmdCharacteristic(nullptr), pPhotoCharacteristic(nullptr), deviceConnected(false), onAudioReceived(nullptr) {}

void BleManager::init(AudioReceiveCallback audioCallback) {
    onAudioReceived = audioCallback;

    NimBLEDevice::init(BLE_DEVICE_NAME);
    
    // Maximizar MTU a 512 (NimBLE soporta esto nativamente para BLE 4.2+)
    NimBLEDevice::setMTU(512);

    pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());

    NimBLEService *pService = pServer->createService(SERVICE_UUID);

    // TX Characteristic (Microphone Audio)
    pTxCharacteristic = pService->createCharacteristic(
        CHAR_UUID_TX,
        NIMBLE_PROPERTY::NOTIFY
    );

    // RX Characteristic (TTS Audio)
    pRxCharacteristic = pService->createCharacteristic(
        CHAR_UUID_RX,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    pRxCharacteristic->setCallbacks(new RxCallbacks());

    // CMD Characteristic (Button events and Incoming Commands)
    pCmdCharacteristic = pService->createCharacteristic(
        CHAR_UUID_CMD_TX,
        NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    pCmdCharacteristic->setCallbacks(new CmdRxCallbacks());
    
    // PHOTO Characteristic
    pPhotoCharacteristic = pService->createCharacteristic(
        CHAR_UUID_PHOTO_TX,
        NIMBLE_PROPERTY::NOTIFY
    );

    pService->start();

    NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(true);
    // Min/Max interval para conexion rapida (streaming)
    pAdvertising->setMinPreferred(0x06);  
    pAdvertising->setMaxPreferred(0x12);
    NimBLEDevice::startAdvertising();
}

bool BleManager::isConnected() {
    return deviceConnected;
}

void BleManager::sendAudioChunk(const uint8_t* data, size_t length) {
    if (deviceConnected && pTxCharacteristic) {
        // En BLE, el maximo payload real por paquete es MTU - 3. Si MTU es 512, enviamos max 509.
        pTxCharacteristic->setValue(data, length);
        pTxCharacteristic->notify();
    }
}

void BleManager::sendCommand(const char* cmd) {
    if (deviceConnected && pCmdCharacteristic) {
        pCmdCharacteristic->setValue((const uint8_t*)cmd, strlen(cmd));
        pCmdCharacteristic->notify();
    }
}

void BleManager::sendPhotoChunk(const uint8_t* data, size_t length) {
    if (deviceConnected && pPhotoCharacteristic) {
        pPhotoCharacteristic->setValue(data, length);
        pPhotoCharacteristic->notify();
    }
}
