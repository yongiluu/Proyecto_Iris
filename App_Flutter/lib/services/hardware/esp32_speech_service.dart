import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../core/constants/env_config.dart';

class Esp32SpeechService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic; // Send TTS
  BluetoothCharacteristic? _txCharacteristic; // Receive Mic
  BluetoothCharacteristic? _cmdCharacteristic; // Receive Commands
  BluetoothCharacteristic? _photoCharacteristic; // Receive Photo

  final List<int> _audioBuffer = [];
  final List<int> _photoBuffer = [];
  bool _isRecording = false;
  bool _isSendingAudio = false;
  bool _isReceivingPhoto = false;
  int _expectedPhotoSize = 0;
  bool _isInitialized = false;

  Timer? _thinkingTimer;

  // UUIDs
  static const String SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String CHAR_UUID_RX = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String CHAR_UUID_TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String CHAR_UUID_CMD_TX = "6E400004-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String CHAR_UUID_PHOTO_TX = "6E400005-B5A3-F393-E0A9-E50E24DCCA9E";

  Function()? onRecordingStarted;
  Function()? onRecordingStopped;
  Function(bool)? onConnectionChanged;
  
  Completer<Uint8List?>? _photoCompleter;
  
  final ValueNotifier<Uint8List?> lastPhotoNotifier = ValueNotifier(null);

  bool isConnected = false;
  Timer? _reconnectTimer;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;
    
    // Escuchar el estado del Bluetooth
    FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
      if (state == BluetoothAdapterState.on) {
        _scanAndConnect();
      } else {
        isConnected = false;
        onConnectionChanged?.call(false);
      }
    });

    // Watchdog para reconexion
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!isConnected && FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
         if (FlutterBluePlus.isScanningNow == false) {
             _scanAndConnect();
         }
      }
    });
  }

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  bool _isConnecting = false;

  Future<void> _scanAndConnect() async {
    if (isConnected || _isConnecting) return;
    _isConnecting = true;
    try {
      debugPrint('Buscando dispositivo Iris_ESP32 por BLE...');
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.device.platformName == "Iris_ESP32" || r.device.advName == "Iris_ESP32") {
            debugPrint('¡Dispositivo Iris encontrado! Conectando...');
            FlutterBluePlus.stopScan();
            _scanSubscription?.cancel();
            
            _device = r.device;

            _connectionSubscription?.cancel();
            _connectionSubscription = _device!.connectionState.listen((BluetoothConnectionState state) {
              if (state == BluetoothConnectionState.connected) {
                debugPrint('Conectado a Iris por BLE.');
                isConnected = true;
                _isConnecting = false;
                onConnectionChanged?.call(true);
              } else if (state == BluetoothConnectionState.disconnected) {
                debugPrint('Iris desconectado.');
                isConnected = false;
                onConnectionChanged?.call(false);
                if (!_isConnecting) {
                  _cleanupAndReconnect();
                }
              }
            });

            try {
              await _device!.connect(license: License.nonprofit);
              
              await Future.delayed(const Duration(milliseconds: 500));
              
              if (defaultTargetPlatform == TargetPlatform.android) {
                try {
                  await _device!.requestMtu(512);
                } catch (e) {
                  debugPrint('Advertencia: No se pudo negociar MTU: $e');
                }
              }

              await Future.delayed(const Duration(milliseconds: 500));
              await _discoverServices();
            } catch (e) {
              debugPrint('Error en conexion BLE: $e');
              _isConnecting = false;
              _cleanupAndReconnect();
            }
            break;
          }
        }
      });
    } catch (e) {
      debugPrint('Error al escanear BLE: $e');
      _isConnecting = false;
    }
  }

  Future<void> _discoverServices() async {
    if (_device == null) return;
    List<BluetoothService> services = await _device!.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString().toUpperCase().replaceAll('-', '') == SERVICE_UUID.replaceAll('-', '')) {
        for (BluetoothCharacteristic c in service.characteristics) {
          if (c.uuid.toString().toUpperCase().replaceAll('-', '') == CHAR_UUID_RX.replaceAll('-', '')) {
            _rxCharacteristic = c;
          } else if (c.uuid.toString().toUpperCase().replaceAll('-', '') == CHAR_UUID_TX.replaceAll('-', '')) {
            _txCharacteristic = c;
            await c.setNotifyValue(true);
            c.onValueReceived.listen(_onAudioReceived);
          } else if (c.uuid.toString().toUpperCase().replaceAll('-', '') == CHAR_UUID_CMD_TX.replaceAll('-', '')) {
            _cmdCharacteristic = c;
            await c.setNotifyValue(true);
            c.onValueReceived.listen(_onCmdReceived);
          } else if (c.uuid.toString().toUpperCase().replaceAll('-', '') == CHAR_UUID_PHOTO_TX.replaceAll('-', '')) {
            _photoCharacteristic = c;
            await c.setNotifyValue(true);
            c.onValueReceived.listen(_onPhotoChunkReceived);
          }
        }
      }
    }
  }

  void _onCmdReceived(List<int> value) {
    String cmd = String.fromCharCodes(value).trim();
    debugPrint('Comando BLE recibido: $cmd');
    if (cmd == 'CMD_PTT_START') {
      _isRecording = true;
      stopAudio();
      _audioBuffer.clear();
      onRecordingStarted?.call();
    } else if (cmd == 'CMD_PTT_STOP') {
      _isRecording = false;
      onRecordingStopped?.call();
    } else if (cmd.startsWith('CMD_PHOTO_START:')) {
      _isReceivingPhoto = true;
      _photoBuffer.clear();
      _expectedPhotoSize = int.tryParse(cmd.split(':')[1]) ?? 0;
      debugPrint('Esperando foto de $_expectedPhotoSize bytes');
    } else if (cmd == 'CMD_PHOTO_END') {
      _isReceivingPhoto = false;
      if (_photoCompleter != null && !_photoCompleter!.isCompleted) {
        final photoBytes = Uint8List.fromList(_photoBuffer);
        lastPhotoNotifier.value = photoBytes;
        _photoCompleter!.complete(photoBytes);
      }
    } else if (cmd == 'CMD_PHOTO_ERROR') {
      _isReceivingPhoto = false;
      if (_photoCompleter != null && !_photoCompleter!.isCompleted) {
        _photoCompleter!.complete(null);
      }
    }
  }

  void _onPhotoChunkReceived(List<int> value) {
    if (_isReceivingPhoto) {
      _photoBuffer.addAll(value);
    }
  }

  Future<Uint8List?> captureSingleFrame() async {
    if (_cmdCharacteristic == null) return null;
    
    _photoCompleter = Completer<Uint8List?>();
    
    // Send command to ESP32 to take photo
    await _cmdCharacteristic!.write(utf8.encode("CMD_TAKE_PHOTO"), withoutResponse: true);
    
    // Timeout in case ESP32 fails silently or photo is large
    return await _photoCompleter!.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _isReceivingPhoto = false;
      return null;
    });
  }

  void _onAudioReceived(List<int> value) {
    if (_isRecording) {
      _audioBuffer.addAll(value);
    }
  }

  void _cleanupAndReconnect() {
    _connectionSubscription?.cancel();
    _scanSubscription?.cancel();
    _device?.disconnect();
    _device = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _cmdCharacteristic = null;
    _isConnecting = false;
    Future.delayed(const Duration(seconds: 3), _scanAndConnect);
  }

  Future<void> sendAudioToEsp32(Uint8List pcmData) async {
    if (_device == null || _rxCharacteristic == null) return;
    _isSendingAudio = true;

    final processedData = Uint8List(pcmData.length);
    final ByteData inData = ByteData.sublistView(pcmData);
    final ByteData outData = ByteData.sublistView(processedData);

    for (int i = 0; i < pcmData.length; i += 2) {
      if (i + 1 < pcmData.length) {
        int sample = inData.getInt16(i, Endian.little);
        double x = sample / 32768.0;
        x = x * 0.35; // Escala de volumen
        int outSample = (x * 32767.0).round();
        outData.setInt16(i, outSample, Endian.little);
      }
    }

    final stopwatch = Stopwatch()..start();
    // Fragmentos de 500 bytes máximo por el límite de MTU en BLE
    const int chunkSize = 500; 
    
    for (int i = 0; i < processedData.length; i += chunkSize) {
      if (!_isSendingAudio) break;

      int end = (i + chunkSize < processedData.length) ? i + chunkSize : processedData.length;
      await _rxCharacteristic!.write(processedData.sublist(i, end), withoutResponse: true);

      // Pacing inteligente
      double sentAudioTimeMs = (end / 32000.0) * 1000.0;
      while (stopwatch.elapsedMilliseconds < sentAudioTimeMs - 100) {
        if (!_isSendingAudio) break;
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }
    
    _isSendingAudio = false;
  }

  void stopAudio() {
    _isSendingAudio = false;
  }

  void startThinkingSound() {
    if (_rxCharacteristic != null) {
      _rxCharacteristic!.write(utf8.encode('CMD_BEEP_THINKING'), withoutResponse: true);
      _thinkingTimer?.cancel();
      _thinkingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_rxCharacteristic != null) {
          _rxCharacteristic!.write(utf8.encode('CMD_BEEP_THINKING'), withoutResponse: true);
        } else {
          timer.cancel();
        }
      });
    }
  }

  void stopThinkingSound() {
    _thinkingTimer?.cancel();
  }

  Future<String> stopListeningAndTranscribe() async {
    if (_audioBuffer.isEmpty) return '';
    
    final wavBytes = _createWavHeader(_audioBuffer);
    return await _transcribeWithHuggingFace(wavBytes);
  }

  Uint8List _createWavHeader(List<int> pcmData) {
    int numFrames = pcmData.length ~/ 2;
    int numChannels = 1;
    int sampleRate = 16000;
    int byteRate = sampleRate * numChannels * 2;
    int blockAlign = numChannels * 2;
    int bitsPerSample = 16;
    
    var header = ByteData(44);
    header.setUint8(0, 82); header.setUint8(1, 73); header.setUint8(2, 70); header.setUint8(3, 70);
    header.setUint32(4, 36 + pcmData.length, Endian.little);
    header.setUint8(8, 87); header.setUint8(9, 65); header.setUint8(10, 86); header.setUint8(11, 69);
    header.setUint8(12, 102); header.setUint8(13, 109); header.setUint8(14, 116); header.setUint8(15, 32);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    header.setUint8(36, 100); header.setUint8(37, 97); header.setUint8(38, 116); header.setUint8(39, 97);
    header.setUint32(40, pcmData.length, Endian.little);
    
    final b = BytesBuilder();
    b.add(header.buffer.asUint8List());
    b.add(pcmData);
    return b.toBytes();
  }

  Future<String> _transcribeWithHuggingFace(Uint8List wavBytes) async {
    final key = EnvConfig.huggingFaceApiKey.trim();
    if (key.isEmpty) return '';

    try {
      final url = Uri.parse('https://router.huggingface.co/hf-inference/models/openai/whisper-large-v3-turbo');
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'audio/wav',
        },
        body: wavBytes,
      );
      
      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        return result['text']?.toString().trim() ?? '';
      }
    } catch (e) {
      debugPrint('Error Hugging Face: $e');
    }
    return '';
  }

  void dispose() {
    _thinkingTimer?.cancel();
    _device?.disconnect();
  }
}
