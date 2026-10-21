#include "ble_manager.h"

#include "nimble/porting/nimble/include/os/os_mbuf.h"

BleManager bleManager;

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer) override {
        bleManager.deviceConnected = true;
    }

    void onDisconnect(NimBLEServer* pServer) override {
        bleManager.deviceConnected = false;
        bleManager.negotiatedMtu = BLE_DEFAULT_MTU;
        NimBLEDevice::startAdvertising();
    }

    void onMTUChange(uint16_t mtu, ble_gap_conn_desc* desc) override {
        bleManager.negotiatedMtu = mtu;
        Serial.printf("[BLE] MTU negociado: %u\n", mtu);
    }
};

// Esta caracteristica recibe SOLO audio PCM; los comandos van por CmdRxCallbacks.
class RxCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic) override {
        std::string value = pCharacteristic->getValue();
        if (!value.empty() && bleManager.onAudioReceived) {
            bleManager.onAudioReceived((const uint8_t*)value.data(), value.length());
        }
    }
};

class CmdRxCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pCharacteristic) override {
        std::string value = pCharacteristic->getValue();
        if (!value.empty() && bleManager.onCommandReceived) {
            bleManager.onCommandReceived(value.c_str());
        }
    }
};

BleManager::BleManager()
    : pServer(nullptr), pTxCharacteristic(nullptr), pRxCharacteristic(nullptr),
      pCmdCharacteristic(nullptr), pPhotoCharacteristic(nullptr),
      deviceConnected(false), negotiatedMtu(BLE_DEFAULT_MTU),
      onAudioReceived(nullptr), onCommandReceived(nullptr) {}

void BleManager::init(AudioReceiveCallback audioCallback, CommandReceiveCallback commandCallback) {
    onAudioReceived = audioCallback;
    onCommandReceived = commandCallback;

    NimBLEDevice::init(BLE_DEVICE_NAME);
    NimBLEDevice::setMTU(BLE_REQUESTED_MTU);
    // Con dos prototipos (mismo nombre) la app los distingue por esta direccion.
    Serial.printf("[BLE] %s direccion %s\n", BLE_DEVICE_NAME, NimBLEDevice::getAddress().toString().c_str());

    pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());

    NimBLEService* pService = pServer->createService(SERVICE_UUID);

    pTxCharacteristic = pService->createCharacteristic(CHAR_UUID_TX, NIMBLE_PROPERTY::NOTIFY);

    pRxCharacteristic = pService->createCharacteristic(
        CHAR_UUID_RX,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    pRxCharacteristic->setCallbacks(new RxCallbacks());

    pCmdCharacteristic = pService->createCharacteristic(
        CHAR_UUID_CMD_TX,
        NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
    );
    pCmdCharacteristic->setCallbacks(new CmdRxCallbacks());

    pPhotoCharacteristic = pService->createCharacteristic(CHAR_UUID_PHOTO_TX, NIMBLE_PROPERTY::NOTIFY);

    pService->start();

    NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(true);
    pAdvertising->setMinPreferred(0x06);
    pAdvertising->setMaxPreferred(0x12);
    NimBLEDevice::startAdvertising();
}

bool BleManager::isConnected() const {
    return deviceConnected;
}

size_t BleManager::payloadSize() const {
    uint16_t mtu = negotiatedMtu;
    return mtu > BLE_ATT_HEADER_BYTES ? mtu - BLE_ATT_HEADER_BYTES : 1;
}

namespace {
// notify() descarta el paquete EN SILENCIO si NimBLE no tiene buffers libres (fotos incompletas que la
// app descarta, CMD_PTT_STOP perdido). Antes de cada paquete se espera a que haya buffers (cada
// notificacion de ~500 bytes usa unos 3).
constexpr int kMinFreeBuffers = 6;
constexpr uint32_t kBufferWaitMs = 400;

bool waitForBleBuffers(volatile bool& connected) {
    const uint32_t start = millis();
    while (os_msys_num_free() < kMinFreeBuffers) {
        if (!connected || millis() - start > kBufferWaitMs) return false;
        delay(2);
    }
    return true;
}
}  // namespace

// Una notificacion mas grande que MTU-3 se trunca en silencio, asi que se parte aqui.
bool BleManager::notifyInChunks(NimBLECharacteristic* characteristic, const uint8_t* data, size_t length) {
    if (!deviceConnected || characteristic == nullptr || data == nullptr) return false;

    const size_t maxPayload = payloadSize();
    size_t offset = 0;
    while (offset < length) {
        size_t chunk = length - offset;
        if (chunk > maxPayload) chunk = maxPayload;
        if (!waitForBleBuffers(deviceConnected)) return false;
        characteristic->notify(data + offset, chunk);
        offset += chunk;
    }
    return true;
}

bool BleManager::sendAudioChunk(const uint8_t* data, size_t length) {
    return notifyInChunks(pTxCharacteristic, data, length);
}

bool BleManager::sendCommand(const char* command) {
    if (command == nullptr) return false;
    return notifyInChunks(pCmdCharacteristic, (const uint8_t*)command, strlen(command));
}

bool BleManager::sendPhotoChunk(const uint8_t* data, size_t length) {
    return notifyInChunks(pPhotoCharacteristic, data, length);
}
