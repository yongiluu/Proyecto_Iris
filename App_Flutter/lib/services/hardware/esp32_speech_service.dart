import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  // Si se pierde la notificacion BLE de CMD_PTT_STOP, la app no debe quedar "escuchando placa".
  static const Duration _pttStopGrace = Duration(milliseconds: 1500);
  static const Duration _maxPttRecording = Duration(seconds: 15);
  Timer? _pttStopTimer;
  Timer? _pttSafetyTimer;

  final BytesBuilder _micBuffer = BytesBuilder(copy: false);
  final BytesBuilder _photoBuffer = BytesBuilder(copy: false);
  bool _isRecording = false;
  bool _isReceivingPhoto = false;
  int _expectedPhotoSize = 0;
  Completer<Uint8List?>? _photoCompleter;

  // Frame 96x96 en grises (modo recoleccion). Comparte la caracteristica de foto con el JPEG.
  final BytesBuilder _frameBuffer = BytesBuilder(copy: false);
  bool _isReceivingFrame = false;
  int _frameWidth = 0;
  int _frameHeight = 0;
  Completer<GrayFrame?>? _frameCompleter;

  int _audioSession = 0;
  bool _isSendingAudio = false;
  bool _isInitialized = false;
  bool _isConnecting = false;

  bool isConnected = false;

  // ─── Varias placas con el mismo nombre (ej. dos prototipos en la final) ───
  static const String _prefBoardId = 'iris_board_id';
  static const String _prefNickPrefix = 'iris_board_nick_';
  SharedPreferences? _prefs;
  String? _preferredBoardId;
  bool _isScanning = false;

  /// Placas Iris vistas en el ultimo escaneo (la conectada no anuncia: se agrega aparte).
  final ValueNotifier<List<IrisBoard>> boardsFound = ValueNotifier(const []);

  /// Se encontro mas de una placa y el usuario todavia no eligio: la UI debe preguntar.
  void Function(List<IrisBoard> boards)? onChooseBoard;

  /// La placa oyo "Oye Iris" (CMD_WAKE_WORD:<%>).
  void Function(int percent)? onWakeWord;

  /// Problema visible para el usuario (sin permisos, Bluetooth apagado, ninguna placa), o null.
  final ValueNotifier<String?> problem = ValueNotifier(null);

  /// true si faltan permisos de Bluetooth: la UI muestra un boton a los ajustes de la app.
  bool get needsPermissions => _missingPermissions;
  bool _missingPermissions = false;

  String? get preferredBoardId => _preferredBoardId;
  String? get connectedBoardId => isConnected ? _device?.remoteId.str : null;

  Function()? onRecordingStarted;
  Function()? onRecordingStopped;
  Function(bool)? onConnectionChanged;

  /// Alerta de sonido detectada por el modelo de la placa (ej. 'sirena', 87).
  void Function(String label, int confidencePercent)? onAudioEvent;

  /// Algo visto por la camara de la placa (ej. 'escalera', 84).
  void Function(String label, int confidencePercent)? onVisionEvent;

  /// Resumen silencioso cada ~10 s de lo que oye / ve la placa (clase mas frecuente y su %).
  void Function(String label, int percent)? onAudioContext;
  void Function(String label, int percent)? onVisionContext;

  /// Cercania de la placa (ella misma pita): 0 libre, 1 cerca, 2 muy cerca. Solo al cambiar.
  void Function(int level, int percent)? onProximity;

  /// Audio crudo del microfono (PCM 16-bit, 16 kHz) para la recoleccion de datos.
  void Function(List<int> pcm)? onRawMicAudio;

  /// true mientras la pantalla de misiones graba: el asistente no debe hablar encima.
  bool isCollectingData = false;

  /// Ultima foto recibida de la placa, para mostrarla en la UI.
  final ValueNotifier<Uint8List?> lastPhotoNotifier = ValueNotifier(null);

  // ───────────────────────── Ciclo de vida ─────────────────────────

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    await _requestPermissions();
    _prefs = await SharedPreferences.getInstance();
    _preferredBoardId = _prefs?.getString(_prefBoardId);

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
    await _hasBlePermissions();
  }

  /// Pide los permisos de Bluetooth (y microfono) si faltan. Llamar al entrar al modo Modulo.
  /// Devuelve true si se puede escanear.
  Future<bool> ensurePermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.microphone,
    ].request();
    final ok = await _hasBlePermissions();
    if (ok) unawaited(_scanAndConnect());
    return ok;
  }

  /// Android 12+: BLUETOOTH_SCAN (neverForLocation en el manifiesto) y BLUETOOTH_CONNECT.
  /// (En Android 11 o menor esos dos quedan "granted" y escanear usa la ubicacion, que se pide
  /// en _requestPermissions.)
  Future<bool> _hasBlePermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    final ok = await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted;
    _missingPermissions = !ok;
    if (!ok) {
      problem.value = 'Iris necesita permiso de Bluetooth (dispositivos cercanos) para buscar la placa.';
    } else if (problem.value?.startsWith('Iris necesita permiso') ?? false) {
      problem.value = null;
    }
    return ok;
  }

  // ───────────────────────── Conexion ─────────────────────────

  Future<void> _scanAndConnect() async {
    if (isConnected || _isConnecting) return;
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      problem.value = 'Activa el Bluetooth del celular para conectar la placa.';
      return;
    }
    if (!await _hasBlePermissions()) return;

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

  /// Con una placa elegida, se conecta apenas la ve. Sin eleccion: si hay una sola, a esa;
  /// si hay varias, avisa a la UI (onChooseBoard) y espera.
  Future<BluetoothDevice?> _findIrisDevice() async {
    final preferred = _preferredBoardId;
    final boards = await _scanBoards(stopWhenSeen: preferred);
    if (boards == null) return null;
    if (boards.isEmpty) {
      problem.value = 'No encontre placas Iris: revisa que este encendida y el Bluetooth activado.';
      return null;
    }
    if (preferred != null) {
      final match = boards.where((b) => b.id == preferred).map((b) => b.device).firstOrNull;
      problem.value = match != null
          ? null
          : 'No encuentro ${IrisBoard.labelFor(preferred, nicknameOf(preferred))}. '
              'Hay otra placa cerca: usa "Cambiar placa".';
      return match;
    }
    problem.value = null;
    if (boards.length == 1) return boards.first.device;
    onChooseBoard?.call(boards);
    return null;
  }

  /// Escanea las placas Iris por `_scanTimeout` (o hasta ver `stopWhenSeen`). null si ya habia
  /// otro escaneo en curso.
  Future<List<IrisBoard>?> _scanBoards({String? stopWhenSeen}) async {
    if (_isScanning) return null;
    _isScanning = true;
    final seen = <String, IrisBoard>{};
    final stop = Completer<void>();
    final resultsSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        final name = result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : result.device.platformName;
        if (name != deviceName) continue;
        final id = result.device.remoteId.str;
        seen[id] = IrisBoard(id: id, device: result.device, rssi: result.rssi, nickname: nicknameOf(id));
        if (id == stopWhenSeen && !stop.isCompleted) stop.complete();
      }
    });

    try {
      debugPrint('Buscando $deviceName por BLE...');
      await FlutterBluePlus.startScan(withServices: [_serviceUuid], timeout: _scanTimeout);
      await Future.any<void>([
        stop.future,
        FlutterBluePlus.isScanning.where((scanning) => !scanning).first,
      ]);
    } finally {
      await resultsSubscription.cancel();
      await FlutterBluePlus.stopScan();
      _isScanning = false;
    }
    final boards = seen.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    _publishBoards(boards);
    return boards;
  }

  void _publishBoards(List<IrisBoard> scanned) {
    final list = [...scanned];
    final device = _device;
    if (isConnected && device != null && !list.any((b) => b.id == device.remoteId.str)) {
      final id = device.remoteId.str;
      list.insert(0, IrisBoard(id: id, device: device, rssi: 0, nickname: nicknameOf(id)));
    }
    boardsFound.value = list;
  }

  /// Escaneo pedido por la UI (pantalla "Cambiar placa"), tambien estando conectado.
  Future<void> refreshBoards() async {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      problem.value = 'Activa el Bluetooth del celular para conectar la placa.';
      return;
    }
    if (!await _hasBlePermissions()) return;
    await _scanBoards();
  }

  /// true mientras busca placas (para que la UI muestre "Buscando..." en vez de "no hay").
  bool get isScanning => _isScanning;

  /// Guarda la placa elegida y se conecta a ella (desconectando la actual si es otra).
  Future<void> selectBoard(String id) async {
    _preferredBoardId = id;
    await _prefs?.setString(_prefBoardId, id);
    if (isConnected && connectedBoardId != id) {
      await _dropConnection();
      onConnectionChanged?.call(false);
    }
    unawaited(_scanAndConnect());
  }

  String? nicknameOf(String id) => _prefs?.getString('$_prefNickPrefix$id');

  Future<void> setNickname(String id, String nickname) async {
    final clean = nickname.trim();
    if (clean.isEmpty) {
      await _prefs?.remove('$_prefNickPrefix$id');
    } else {
      await _prefs?.setString('$_prefNickPrefix$id', clean);
    }
    boardsFound.value = [
      for (final b in boardsFound.value) b.id == id ? b.copyWith(nickname: nicknameOf(id)) : b,
    ];
  }

  /// Nombre para mostrar de la placa conectada (apodo o "Iris · 46:24").
  String? get connectedBoardLabel {
    final id = connectedBoardId;
    return id == null ? null : IrisBoard.labelFor(id, nicknameOf(id));
  }

  /// Boton "Manten para hablar" de la app (mientras la placa no tenga boton fisico): la placa
  /// responde igual que con su boton, con CMD_PTT_START / audio / CMD_PTT_STOP.
  Future<void> sendAppPttStart() => _sendCommand('CMD_APP_PTT_START');
  Future<void> sendAppPttStop() async {
    await _sendCommand('CMD_APP_PTT_STOP');
    _pttStopTimer?.cancel();
    _pttStopTimer = Timer(_pttStopGrace, () => _finishRecording('no llego CMD_PTT_STOP'));
  }

  /// Termina la grabacion de la placa (una sola vez) y procesa el audio que haya llegado.
  void _finishRecording(String? reason) {
    _pttStopTimer?.cancel();
    _pttSafetyTimer?.cancel();
    if (!_isRecording) return;
    if (reason != null) debugPrint('Grabacion de la placa cerrada por la app: $reason');
    _isRecording = false;
    onRecordingStopped?.call();
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
    debugPrint('Conectado a Iris ${device.remoteId.str} por BLE (MTU ${device.mtuNow}).');
    // Sin eleccion guardada (habia una sola placa): recordar esta.
    if (_preferredBoardId == null) {
      _preferredBoardId = device.remoteId.str;
      await _prefs?.setString(_prefBoardId, _preferredBoardId!);
    }
    _publishBoards(boardsFound.value);
    problem.value = null;
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
    _isReceivingFrame = false;
    _micBuffer.clear();
    _photoBuffer.clear();
    _frameBuffer.clear();
    final frameCompleter = _frameCompleter;
    if (frameCompleter != null && !frameCompleter.isCompleted) frameCompleter.complete(null);
    _audioSession++;
    _isSendingAudio = false;
    _thinkingTimer?.cancel();
    _pttStopTimer?.cancel();
    _pttSafetyTimer?.cancel();
    _completePhoto(null);
  }

  // ───────────────────────── Recepcion desde la placa ─────────────────────────

  void _onMicAudioReceived(List<int> value) {
    onRawMicAudio?.call(value);
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
      _pttSafetyTimer?.cancel();
      _pttSafetyTimer = Timer(_maxPttRecording, () => _finishRecording('tope de ${_maxPttRecording.inSeconds} s'));
      onRecordingStarted?.call();
    } else if (command == 'CMD_PTT_STOP') {
      _finishRecording(null);
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
    } else if (command.startsWith('CMD_VISION_EVENT:')) {
      // CMD_VISION_EVENT:<clase>:<porcentaje>
      final parts = command.split(':');
      if (parts.length >= 3) onVisionEvent?.call(parts[1], int.tryParse(parts[2]) ?? 0);
    } else if (command.startsWith('CMD_WAKE_WORD:')) {
      onWakeWord?.call(int.tryParse(command.split(':')[1]) ?? 0);
    } else if (command.startsWith('CMD_PROXIMITY:')) {
      // CMD_PROXIMITY:<nivel>:<porcentaje>
      final parts = command.split(':');
      if (parts.length >= 3) onProximity?.call(int.tryParse(parts[1]) ?? 0, int.tryParse(parts[2]) ?? 0);
    } else if (command.startsWith('CMD_AUDIO_CONTEXT:')) {
      final parts = command.split(':');
      if (parts.length >= 3) onAudioContext?.call(parts[1], int.tryParse(parts[2]) ?? 0);
    } else if (command.startsWith('CMD_VISION_CONTEXT:')) {
      final parts = command.split(':');
      if (parts.length >= 3) onVisionContext?.call(parts[1], int.tryParse(parts[2]) ?? 0);
    } else if (command.startsWith('CMD_FRAME_START:')) {
      // CMD_FRAME_START:<ancho>:<alto>
      final parts = command.split(':');
      _frameWidth = parts.length >= 3 ? int.tryParse(parts[1]) ?? 0 : 0;
      _frameHeight = parts.length >= 3 ? int.tryParse(parts[2]) ?? 0 : 0;
      _frameBuffer.clear();
      _isReceivingFrame = true;
    } else if (command == 'CMD_FRAME_END' || command == 'CMD_FRAME_ERROR') {
      _finishFrame(ok: command == 'CMD_FRAME_END');
    } else if (command == 'CMD_PHOTO_ERROR') {
      _isReceivingPhoto = false;
      _photoBuffer.clear();
      _completePhoto(null);
    }
  }

  void _onPhotoChunkReceived(List<int> value) {
    if (_isReceivingFrame) {
      _frameBuffer.add(value);
    } else if (_isReceivingPhoto) {
      _photoBuffer.add(value);
    }
  }

  void _finishFrame({required bool ok}) {
    _isReceivingFrame = false;
    final bytes = _frameBuffer.takeBytes();
    final complete = ok && _frameWidth > 0 && bytes.length == _frameWidth * _frameHeight;
    if (ok && !complete) debugPrint('Frame descartado: ${bytes.length} bytes de ${_frameWidth * _frameHeight}');
    final completer = _frameCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(complete ? GrayFrame(_frameWidth, _frameHeight, bytes) : null);
    }
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

  // ───────────────────────── Recoleccion de datos ─────────────────────────

  /// Pide el frame 96x96 en grises que ve el modelo de vision. null si falla o expira.
  Future<GrayFrame?> captureGrayFrame() async {
    final command = _commandCharacteristic;
    if (command == null || !isConnected) return null;
    if (_frameCompleter != null && !_frameCompleter!.isCompleted) return null;

    final completer = Completer<GrayFrame?>();
    _frameCompleter = completer;
    final timeout = Timer(const Duration(seconds: 5), () {
      _isReceivingFrame = false;
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      await command.write(utf8.encode('CMD_COLLECT_FRAME'), withoutResponse: true);
      return await completer.future;
    } catch (e) {
      debugPrint('Error pidiendo frame: $e');
      return null;
    } finally {
      timeout.cancel();
      if (!completer.isCompleted) completer.complete(null);
    }
  }

  /// Activa o corta el envio continuo del microfono (sin apretar el boton de la placa).
  Future<bool> setMicStreaming(bool enabled) async {
    final command = _commandCharacteristic;
    if (command == null || !isConnected) return false;
    try {
      await command.write(utf8.encode(enabled ? 'CMD_COLLECT_AUDIO_START' : 'CMD_COLLECT_AUDIO_STOP'),
          withoutResponse: true);
      return true;
    } catch (e) {
      debugPrint('Error cambiando el envio del microfono: $e');
      return false;
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

  Uint8List _buildWav(Uint8List pcm) => buildWav(pcm);

  /// WAV PCM 16-bit mono 16 kHz (el formato del microfono de la placa).
  static Uint8List buildWav(Uint8List pcm) {
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
    boardsFound.dispose();
    problem.dispose();
  }
}

/// Una placa Iris encontrada por BLE. Todas se llaman "Iris_ESP32": se distinguen por direccion.
class IrisBoard {
  final String id; // direccion BLE, ej. 44:B1:76:AF:46:26
  final BluetoothDevice device;
  final int rssi; // 0 = conectada (no anuncia)
  final String? nickname;

  const IrisBoard({required this.id, required this.device, required this.rssi, this.nickname});

  IrisBoard copyWith({String? nickname}) => IrisBoard(id: id, device: device, rssi: rssi, nickname: nickname);

  String get label => labelFor(id, nickname);

  /// Apodo, o "Iris · " + los ultimos 5 caracteres de la direccion.
  static String labelFor(String id, String? nickname) =>
      (nickname != null && nickname.isNotEmpty) ? nickname : 'Iris · ${id.length > 5 ? id.substring(id.length - 5) : id}';
}

/// Imagen en grises (1 byte por pixel) tal como la entrega la camara de la placa.
class GrayFrame {
  final int width;
  final int height;
  final Uint8List pixels;

  const GrayFrame(this.width, this.height, this.pixels);
}
