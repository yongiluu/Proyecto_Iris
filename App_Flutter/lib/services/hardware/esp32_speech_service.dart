import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../../core/constants/env_config.dart';

/// Comunicacion BLE con la placa Iris_ESP32: audio del microfono, audio TTS,
/// comandos (boton push-to-talk, beep, foto) y fotos JPEG.
class Esp32SpeechService {
  static const String deviceName = 'Iris_ESP32';

  static final Guid _serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _ttsAudioUuid = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // app -> placa
  static final Guid _micAudioUuid = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // placa -> app
  static final Guid _commandUuid = Guid('6E400004-B5A3-F393-E0A9-E50E24DCCA9E'); // ambos sentidos
  static final Guid _photoUuid = Guid('6E400005-B5A3-F393-E0A9-E50E24DCCA9E'); // placa -> app

  static const int _sampleRate = 16000;
  static const int _maxRecordingBytes = 60 * _sampleRate * 2; // 60 s de PCM 16-bit
  static const int _minRecordingBytes = _sampleRate ~/ 10 * 2; // 100 ms
  static const int _maxAudioChunkBytes = 500;
  static const int _attHeaderBytes = 3;
  static const double _ttsVolumeScale = 0.35;

  static const Duration _scanTimeout = Duration(seconds: 6);
  static const Duration _watchdogPeriod = Duration(seconds: 5);
  static const Duration _photoTimeout = Duration(seconds: 15);
  static const Duration _transcriptionTimeout = Duration(seconds: 30);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _ttsAudioCharacteristic;
  BluetoothCharacteristic? _commandCharacteristic;

  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  final List<StreamSubscription<List<int>>> _notificationSubscriptions = [];
  Timer? _watchdogTimer;
  Timer? _thinkingTimer;

  final BytesBuilder _micBuffer = BytesBuilder(copy: false);
  final BytesBuilder _photoBuffer = BytesBuilder(copy: false);
  bool _isRecording = false;
  bool _isReceivingPhoto = false;
  int _expectedPhotoSize = 0;
  Completer<Uint8List?>? _photoCompleter;

  int _audioSession = 0;
  bool _isSendingAudio = false;
  bool _isInitialized = false;
  bool _isConnecting = false;

  bool isConnected = false;

  Function()? onRecordingStarted;
  Function()? onRecordingStopped;
  Function(bool)? onConnectionChanged;

  /// Alerta de sonido detectada por el modelo de la placa (ej. 'sirena', 87).
  void Function(String label, int confidencePercent)? onAudioEvent;

  /// Ultima foto recibida de la placa, para mostrarla en la UI.
  final ValueNotifier<Uint8List?> lastPhotoNotifier = ValueNotifier(null);

  // ───────────────────────── Ciclo de vida ─────────────────────────

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    await _requestPermissions();

    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _scanAndConnect();
      } else {
        _onDisconnected();
      }
    });

    // Red de seguridad: si no hay conexion (o fallo un intento), reintenta periodicamente.
    _watchdogTimer = Timer.periodic(_watchdogPeriod, (_) => _scanAndConnect());
  }

  Future<void> _requestPermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // necesario para escanear BLE en Android 11 o menor
    ].request();
    debugPrint('Permisos BLE: $statuses');
  }

  // ───────────────────────── Conexion ─────────────────────────

  Future<void> _scanAndConnect() async {
    if (isConnected || _isConnecting) return;
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) return;

    _isConnecting = true;
    try {
      final device = await _findIrisDevice();
      if (device == null) return; // El watchdog reintenta

      debugPrint('Iris encontrado, conectando...');
      await _connect(device);
    } catch (e) {
      debugPrint('Error en conexion BLE: $e');
      await _dropConnection();
    } finally {
      _isConnecting = false;
    }
  }

  Future<BluetoothDevice?> _findIrisDevice() async {
    final found = Completer<BluetoothDevice?>();
    final resultsSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        final name = result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : result.device.platformName;
        if (name == deviceName && !found.isCompleted) {
          found.complete(result.device);
        }
      }
    });

    try {
      debugPrint('Buscando $deviceName por BLE...');
      await FlutterBluePlus.startScan(withServices: [_serviceUuid], timeout: _scanTimeout);
      return await Future.any<BluetoothDevice?>([
        found.future,
        FlutterBluePlus.isScanning.where((scanning) => !scanning).first.then<BluetoothDevice?>((_) => null),
      ]);
    } finally {
      await resultsSubscription.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;

    // TODO(licencia): flutter_blue_plus exige licencia comercial para organizaciones con fines de lucro.
    await device.connect(license: License.nonprofit, mtu: 512);

    // Suscribirse despues de conectar: el stream emite "disconnected" como estado inicial.
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) _onDisconnected();
    });

    await _discoverCharacteristics(device);

    isConnected = true;
    debugPrint('Conectado a Iris por BLE (MTU ${device.mtuNow}).');
    onConnectionChanged?.call(true);
  }

  Future<void> _discoverCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    final service = services.where((s) => s.uuid == _serviceUuid).firstOrNull;
    if (service == null) throw StateError('Servicio Iris no encontrado en la placa');

    BluetoothCharacteristic? find(Guid uuid) =>
        service.characteristics.where((c) => c.uuid == uuid).firstOrNull;

    final micAudio = find(_micAudioUuid);
    final command = find(_commandUuid);
    final photo = find(_photoUuid);
    final ttsAudio = find(_ttsAudioUuid);
    if (micAudio == null || command == null || photo == null || ttsAudio == null) {
      throw StateError('Faltan caracteristicas BLE en la placa');
    }

    _ttsAudioCharacteristic = ttsAudio;
    _commandCharacteristic = command;

    await _subscribe(micAudio, _onMicAudioReceived);
    await _subscribe(command, _onCommandReceived);
    await _subscribe(photo, _onPhotoChunkReceived);
  }

  Future<void> _subscribe(BluetoothCharacteristic characteristic, void Function(List<int>) handler) async {
    _notificationSubscriptions.add(characteristic.onValueReceived.listen(handler));
    await characteristic.setNotifyValue(true);
  }

  void _onDisconnected() {
    final wasConnected = isConnected;
    final wasRecording = _isRecording;
    _resetConnectionState();
    if (wasConnected) {
      debugPrint('Iris desconectado.');
      onConnectionChanged?.call(false);
    }
    // Si se cayo la conexion con el boton apretado, procesar lo grabado hasta ahora.
    if (wasRecording) onRecordingStopped?.call();
  }

  Future<void> _dropConnection() async {
    final device = _device;
    _resetConnectionState();
    try {
      await device?.disconnect();
    } catch (e) {
      debugPrint('Error al desconectar: $e');
    }
  }

  void _resetConnectionState() {
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    for (final subscription in _notificationSubscriptions) {
      subscription.cancel();
    }
    _notificationSubscriptions.clear();

    _device = null;
    _ttsAudioCharacteristic = null;
    _commandCharacteristic = null;
    isConnected = false;

    _isRecording = false;
    _isReceivingPhoto = false;
    _micBuffer.clear();
    _photoBuffer.clear();
    _audioSession++;
    _isSendingAudio = false;
    _thinkingTimer?.cancel();
    _completePhoto(null);
  }

  // ───────────────────────── Recepcion desde la placa ─────────────────────────

  void _onMicAudioReceived(List<int> value) {
    if (_isRecording && _micBuffer.length < _maxRecordingBytes) {
      _micBuffer.add(value);
    }
  }

  void _onCommandReceived(List<int> value) {
    final command = utf8.decode(value, allowMalformed: true).trim();
    debugPrint('Comando BLE recibido: $command');

    if (command == 'CMD_PTT_START') {
      _isRecording = true;
      stopAudio();
      _micBuffer.clear();
      onRecordingStarted?.call();
    } else if (command == 'CMD_PTT_STOP') {
      _isRecording = false;
      onRecordingStopped?.call();
    } else if (command.startsWith('CMD_PHOTO_START:')) {
      _isReceivingPhoto = true;
      _photoBuffer.clear();
      _expectedPhotoSize = int.tryParse(command.split(':')[1]) ?? 0;
      debugPrint('Esperando foto de $_expectedPhotoSize bytes');
    } else if (command == 'CMD_PHOTO_END') {
      _finishPhoto();
    } else if (command.startsWith('CMD_AUDIO_EVENT:')) {
      // CMD_AUDIO_EVENT:<clase>:<porcentaje>
      final parts = command.split(':');
      if (parts.length >= 3) onAudioEvent?.call(parts[1], int.tryParse(parts[2]) ?? 0);
    } else if (command == 'CMD_PHOTO_ERROR') {
      _isReceivingPhoto = false;
      _photoBuffer.clear();
      _completePhoto(null);
    }
  }

  void _onPhotoChunkReceived(List<int> value) {
    if (_isReceivingPhoto) _photoBuffer.add(value);
  }

  void _finishPhoto() {
    _isReceivingPhoto = false;
    final bytes = _photoBuffer.takeBytes();

    final isComplete = bytes.length == _expectedPhotoSize;
    final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (!isComplete || !isJpeg) {
      debugPrint('Foto descartada: ${bytes.length} de $_expectedPhotoSize bytes, jpeg=$isJpeg');
      _completePhoto(null);
      return;
    }

    lastPhotoNotifier.value = bytes;
    _completePhoto(bytes);
  }

  void _completePhoto(Uint8List? bytes) {
    final completer = _photoCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(bytes);
  }

  // ───────────────────────── Foto ─────────────────────────

  /// Pide una foto JPEG a la placa. Devuelve null si falla, expira o ya hay una captura en curso.
  Future<Uint8List?> captureSingleFrame() async {
    final command = _commandCharacteristic;
    if (command == null || !isConnected) return null;
    if (_photoCompleter != null && !_photoCompleter!.isCompleted) return null;

    final completer = Completer<Uint8List?>();
    _photoCompleter = completer;
    _isReceivingPhoto = false;
    _photoBuffer.clear();

    final timeout = Timer(_photoTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      await command.write(utf8.encode('CMD_TAKE_PHOTO'), withoutResponse: true);
      return await completer.future;
    } catch (e) {
      debugPrint('Error pidiendo foto: $e');
      return null;
    } finally {
      timeout.cancel();
      _isReceivingPhoto = false;
      if (!completer.isCompleted) completer.complete(null);
    }
  }

  // ───────────────────────── Audio hacia la placa ─────────────────────────

  /// Envia PCM 16-bit mono 16 kHz a la placa, a la velocidad de reproduccion.
  Future<void> sendAudioToEsp32(Uint8List pcmData) async {
    final device = _device;
    final characteristic = _ttsAudioCharacteristic;
    if (device == null || characteristic == null || !isConnected) return;

    final session = ++_audioSession;
    _isSendingAudio = true;

    final scaled = _scaleVolume(pcmData);

    // Cada escritura debe caber en MTU-3; si no, el stack la rechaza o la trunca.
    final maxPayload = math.min(_maxAudioChunkBytes, device.mtuNow - _attHeaderBytes);
    final chunkSize = maxPayload & ~1;
    if (chunkSize < 2) return;

    final stopwatch = Stopwatch()..start();
    try {
      for (int offset = 0; offset < scaled.length; offset += chunkSize) {
        if (!_isSendingAudio || session != _audioSession) break;

        final end = math.min(offset + chunkSize, scaled.length);
        await characteristic.write(scaled.sublist(offset, end), withoutResponse: true);

        // Pacing: no ir mas de 100 ms adelante de la reproduccion (32000 bytes/s).
        final sentAudioMs = end / 32000.0 * 1000.0;
        while (stopwatch.elapsedMilliseconds < sentAudioMs - 100) {
          if (!_isSendingAudio || session != _audioSession) break;
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }
    } catch (e) {
      debugPrint('Error enviando audio a la placa: $e');
    } finally {
      if (session == _audioSession) _isSendingAudio = false;
    }
  }

  Uint8List _scaleVolume(Uint8List pcm) {
    final scaled = Uint8List(pcm.length);
    final input = ByteData.sublistView(pcm);
    final output = ByteData.sublistView(scaled);
    for (int i = 0; i + 1 < pcm.length; i += 2) {
      final sample = input.getInt16(i, Endian.little);
      output.setInt16(i, (sample * _ttsVolumeScale).round(), Endian.little);
    }
    return scaled;
  }

  void stopAudio() {
    _audioSession++;
    _isSendingAudio = false;
  }

  // ───────────────────────── Sonido "pensando" ─────────────────────────

  void startThinkingSound() {
    _thinkingTimer?.cancel();
    _sendCommand('CMD_BEEP_THINKING');
    _thinkingTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sendCommand('CMD_BEEP_THINKING'));
  }

  void stopThinkingSound() {
    _thinkingTimer?.cancel();
  }

  Future<void> _sendCommand(String command) async {
    final characteristic = _commandCharacteristic;
    if (characteristic == null || !isConnected) {
      _thinkingTimer?.cancel();
      return;
    }
    try {
      await characteristic.write(utf8.encode(command), withoutResponse: true);
    } catch (e) {
      debugPrint('Error enviando $command: $e');
    }
  }

  // ───────────────────────── Transcripcion ─────────────────────────

  Future<String> stopListeningAndTranscribe() async {
    final pcm = _micBuffer.takeBytes();
    if (pcm.length < _minRecordingBytes) return '';
    return _transcribeWithHuggingFace(_buildWav(pcm));
  }

  Uint8List _buildWav(Uint8List pcm) {
    const channels = 1;
    const bitsPerSample = 16;
    const byteRate = _sampleRate * channels * bitsPerSample ~/ 8;

    final header = ByteData(44);
    void writeAscii(int offset, String text) {
      for (int i = 0; i < text.length; i++) {
        header.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, _sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(pcm))
        .toBytes();
  }

  Future<String> _transcribeWithHuggingFace(Uint8List wavBytes) async {
    final key = EnvConfig.huggingFaceApiKey.trim();
    if (key.isEmpty) {
      debugPrint('HUGGINGFACE_API_KEY no configurada');
      return '';
    }

    try {
      final response = await http
          .post(
            Uri.parse('https://router.huggingface.co/hf-inference/models/openai/whisper-large-v3-turbo'),
            headers: {'Authorization': 'Bearer $key', 'Content-Type': 'audio/wav'},
            body: wavBytes,
          )
          .timeout(_transcriptionTimeout);

      if (response.statusCode != 200) {
        debugPrint('Error Hugging Face ${response.statusCode}: ${response.body}');
        return '';
      }
      final result = jsonDecode(response.body);
      return result['text']?.toString().trim() ?? '';
    } catch (e) {
      debugPrint('Error Hugging Face: $e');
      return '';
    }
  }

  Future<void> dispose() async {
    _watchdogTimer?.cancel();
    _thinkingTimer?.cancel();
    await _adapterSubscription?.cancel();
    final device = _device;
    _resetConnectionState();
    try {
      await FlutterBluePlus.stopScan();
      await device?.disconnect();
    } catch (e) {
      debugPrint('Error al cerrar BLE: $e');
    }
    lastPhotoNotifier.dispose();
  }
}
