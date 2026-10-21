/// ============================================================================
/// IRIS - Main Assistant Screen (Dual Mode: Standalone & ESP32)
/// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import '../../../core/theme/app_theme.dart';
import '../widgets/iris_logo.dart';
import '../widgets/shimmer_text.dart';
import '../widgets/vision_alert_banner.dart';
import '../../../services/hardware/camera_service.dart';
import '../../../services/hardware/esp32_speech_service.dart';
import '../../../services/ai/speech_service.dart';
import '../../../services/ai/occipital_agent_service.dart';
import '../../../services/ai/phone_vision_service.dart';
import '../../../services/hardware/sensor_context.dart';
import '../../data_collection/missions_screen.dart';
import '../../../services/ai/tts_service.dart';
import '../../../services/hardware/haptic_service.dart';

enum HardwareMode { standalone, esp32 }

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with TickerProviderStateMixin {
  
  // ─── Services ───
  final CameraService _nativeCameraService = CameraService();
  final SpeechService _nativeSpeechService = SpeechService();
  final Esp32SpeechService _esp32SpeechService = Esp32SpeechService();
  final OccipitalAgentService _agentService = OccipitalAgentService();
  final TtsService _ttsService = TtsService();
  final HapticService _hapticService = HapticService();
  final SensorContext _sensorContext = SensorContext();
  final PhoneVisionService _phoneVision = PhoneVisionService();

  // ─── State ───
  HardwareMode _hardwareMode = HardwareMode.standalone;
  bool _isListening = false;
  bool _isInitialized = false;
  bool _isProcessing = false;
  String _lastDescription = '';
  String _statusText = 'Presiona el boton para hablar';
  
  // ─── Continuous Mode ───
  bool _continuousMode = false;
  Timer? _continuousTimer;
  int _consecutiveCount = 0;

  // ─── Animations ───
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // ─── Volume Button ───
  static const MethodChannel _volumeChannel = MethodChannel('com.iris.visual.iris_app/volume');
  static const MethodChannel _soundChannel = MethodChannel('com.iris.visual.iris_app/sound');
  DateTime? _lastVolumeUpTime;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initServices();
    
    _volumeChannel.setMethodCallHandler((call) async {
      if (call.method == 'volumeUpPressed') {
        _handleVolumeUpPress();
      }
    });
  }

  void _initAnimations() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeIn),
    );
    _fadeController.forward();
  }

  Future<void> _initServices() async {
    try {
      // Callbacks ESP32 WebSocket
      _esp32SpeechService.onRecordingStarted = () async {
        if (mounted && _hardwareMode == HardwareMode.esp32) {
          _isNativeMicActive = false;
          _onRecordingStarted();
        }
      };

      _esp32SpeechService.onRecordingStopped = () {
        if (mounted && _hardwareMode == HardwareMode.esp32) {
          _processAudio();
        }
      };
      
      // Callback Nativo
      _nativeSpeechService.onSpeechDone = () {
        // Tambien en modo Modulo: ahi el microfono del celular se activa con el doble toque de volumen.
        if (mounted && _isListening && _isNativeMicActive) {
          _processAudio();
        }
      };

      _esp32SpeechService.onConnectionChanged = (bool connected) {
        if (mounted && _hardwareMode == HardwareMode.esp32) {
          setState(() {
            _statusText = connected ? 'Modulo conectado (Bluetooth)' : 'Buscando el modulo por Bluetooth...';
          });
          if (!connected) _setProximityAlert(0, fromPhone: false);
          if (connected) {
            _hapticService.vibrateStart();
            _ttsService.speakStatus('Bluetooth conectado');
          }
        }
      };

      _esp32SpeechService.onAudioEvent = _onAudioEvent;
      _esp32SpeechService.onVisionEvent = _onVisionEvent;
      _esp32SpeechService.onAudioContext = _sensorContext.onAudioContext;
      _esp32SpeechService.onVisionContext = _sensorContext.onVisionContext;
      _phoneVision.onEvent = (label, percent) => _onVisionEvent(label, percent, fromPhone: true);
      _phoneVision.onContext = _sensorContext.onVisionContext;
      _phoneVision.onProximity = (level, _) => _setProximityAlert(level, fromPhone: true);
      _esp32SpeechService.onProximity = (level, _) => _setProximityAlert(level, fromPhone: false);
      _esp32SpeechService.onChooseBoard = (_) {
        if (mounted && _hardwareMode == HardwareMode.esp32 && !_boardSheetOpen) _showBoardPicker();
      };
      _esp32SpeechService.onWakeWord = (_) {
        if (mounted && _hardwareMode == HardwareMode.esp32 && !_isListening && !_isProcessing) {
          setState(() => _statusText = 'Te escucho');
        }
      };
      try {
        final prefs = await SharedPreferences.getInstance();
        _answersOnPhone = prefs.getBool(_prefAnswersOnPhone) ?? true;
      } catch (_) {}

      // Un servicio que falla (ej. sin permiso de camara) no debe impedir usar los demas.
      await Future.wait<void>([
        _initSafely('camara', _nativeCameraService.initialize()),
        _initSafely('reconocimiento de voz', _nativeSpeechService.initialize()),
        _initSafely('bluetooth', _esp32SpeechService.init()),
        _initSafely('voz', _ttsService.initialize()),
        _initSafely('vibracion', _hapticService.initialize()),
        _initSafely('vision local', _phoneVision.load()),
      ]);
      if (!mounted) return;

      setState(() => _isInitialized = true);
      _updatePhoneVision();
      
      if (_hardwareMode == HardwareMode.esp32) {
         setState(() {
            _statusText = _esp32SpeechService.isConnected ? 'Modulo conectado (Bluetooth)' : 'Buscando el modulo por Bluetooth...';
         });
      }

      await _ttsService.speakStatus('Iris esta lista.', esp32Service: _activeEsp32);
    } catch (e) {
      debugPrint('⚠️ Error initializing services: $e');
      if (mounted) setState(() => _statusText = 'Error de inicializacion: $e');
    }
  }

  Future<void> _initSafely(String name, Future<void> initialization) async {
    try {
      await initialization;
    } catch (e) {
      debugPrint('⚠️ No se pudo inicializar $name: $e');
    }
  }

  /// Foto para el analisis de vision, segun el hardware activo.
  Future<Uint8List?> _captureImage() async {
    if (_hardwareMode == HardwareMode.esp32) return _esp32SpeechService.captureSingleFrame();
    // La camara saca una foto a la vez: esperar a la de la vision local si hay una en curso.
    _cloudCaptureBusy = true;
    try {
      await _phoneVision.waitIdle();
      return await _nativeCameraService.captureSingleFrame();
    } finally {
      _cloudCaptureBusy = false;
    }
  }

  // ─── Vision local en el celular (modo Celular, mismo modelo Edge AI que la placa) ───
  bool _cloudCaptureBusy = false;

  /// Enciende la vision local solo en modo Celular; la placa corre su propio modelo.
  void _updatePhoneVision() {
    if (_hardwareMode == HardwareMode.standalone) {
      _phoneVision.start(_nativeCameraService, _phoneVisionCanCapture);
    } else {
      _phoneVision.stop();
    }
  }

  bool _phoneVisionCanCapture() =>
      mounted &&
      _hardwareMode == HardwareMode.standalone &&
      !_isListening &&
      !_isProcessing &&
      !_cloudCaptureBusy &&
      // Las misiones de datos usan la misma camara.
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// A donde mandar la voz de Iris. Con "Escuchar respuestas en el celular" (por defecto, mientras
  /// la placa no tenga altavoz) suena en el celular aunque el modo sea Modulo.
  Esp32SpeechService? get _activeEsp32 =>
      _hardwareMode == HardwareMode.esp32 && !_answersOnPhone ? _esp32SpeechService : null;

  // ─── Modo prueba de la final (temporal): placa sin altavoz ni boton ───
  /// Misiones de recoleccion ocultas por ahora (el codigo queda).
  static const bool kShowDataMissions = false;
  /// Boton "Manten para hablar" en modo Modulo: manda CMD_APP_PTT_START/STOP a la placa.
  /// Apagado: en la final se activa con "Oye Iris" (el codigo queda por si hace falta).
  static const bool kAppPttEnabled = false;
  static const String _prefAnswersOnPhone = 'iris_answers_on_phone';
  bool _answersOnPhone = true;
  bool _boardSheetOpen = false;
  Timer? _localThinkingTimer;

  Future<void> _setAnswersOnPhone(bool value) async {
    setState(() => _answersOnPhone = value);
    try {
      (await SharedPreferences.getInstance()).setBool(_prefAnswersOnPhone, value);
    } catch (_) {}
  }

  /// Pitido de "pensando" en la placa o, con respuestas en el celular, en el parlante del celular.
  void _startThinking() {
    if (_activeEsp32 != null) {
      _esp32SpeechService.startThinkingSound();
      return;
    }
    _localThinkingTimer?.cancel();
    _playCue('thinking');
    _localThinkingTimer = Timer.periodic(const Duration(seconds: 2), (_) => _playCue('thinking'));
  }

  void _stopThinking() {
    _esp32SpeechService.stopThinkingSound();
    _localThinkingTimer?.cancel();
    _localThinkingTimer = null;
  }

  Future<void> _showBoardPicker() async {
    if (_boardSheetOpen) return;
    _boardSheetOpen = true;
    unawaited(_esp32SpeechService.refreshBoards());
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B1116),
      isScrollControlled: true,
      builder: (context) => _BoardPicker(service: _esp32SpeechService),
    );
    _boardSheetOpen = false;
    if (mounted) setState(() {});
  }

  bool _isNativeMicActive = false;

  // ─── Alertas de sonido detectadas por la placa (Edge AI) ───
  static const Map<String, String> _audioAlertPhrases = {
    'bocina': 'una bocina',
    'sirena': 'una sirena',
    'perro': 'un perro',
  };
  static const Duration _audioAlertCooldown = Duration(seconds: 10);
  DateTime? _lastAudioAlert;
  // Una persona ciega suele oir la sirena antes que el modelo: por defecto los sonidos solo se
  // guardan como contexto para la IA (SensorContext). true = tambien avisarlos en voz alta
  // (util para personas que ademas oyen poco).
  static const bool _speakAudioAlerts = false;

  Future<void> _onAudioEvent(String label, int confidence) async {
    _sensorContext.onAudioEvent(label);
    if (!_speakAudioAlerts) return;
    if (!mounted || _hardwareMode != HardwareMode.esp32 || _esp32SpeechService.isCollectingData) return;
    // No interrumpir mientras el usuario habla o Iris responde.
    if (_isListening || _isProcessing || _ttsService.isSpeaking) return;

    final now = DateTime.now();
    if (_lastAudioAlert != null && now.difference(_lastAudioAlert!) < _audioAlertCooldown) return;
    _lastAudioAlert = now;

    final what = _audioAlertPhrases[label] ?? 'un sonido: $label';
    setState(() => _statusText = 'Se escucha $what ($confidence%)');
    await _hapticService.vibrateTick();
    await _ttsService.speakStatus('Atencion, se escucha $what', esp32Service: _activeEsp32);
  }

  // ─── Avisos de la camara de la placa (Edge AI) ───
  static const Map<String, String> _visionAlertPhrases = {
    'persona': 'una persona',
    'vehiculo': 'un vehiculo',
    'escalera': 'una escalera',
    'puerta': 'una puerta',
    'cruce': 'un cruce peatonal',
  };
  // Por clase: una escalera no debe callar el aviso de un vehiculo.
  static const Duration _visionAlertCooldown = Duration(seconds: 20);
  final Map<String, DateTime> _lastVisionAlert = {};

  /// Avisos de la placa o, en modo Celular, del mismo modelo corriendo en el celular.
  Future<void> _onVisionEvent(String label, int confidence, {bool fromPhone = false}) async {
    _sensorContext.onVisionEvent(label);
    if (!mounted) return;
    final active = fromPhone
        ? _hardwareMode == HardwareMode.standalone
        : _hardwareMode == HardwareMode.esp32 && !_esp32SpeechService.isCollectingData;
    if (!active) return;
    if (_isListening || _isProcessing || _ttsService.isSpeaking) return;

    final now = DateTime.now();
    final last = _lastVisionAlert[label];
    if (last != null && now.difference(last) < _visionAlertCooldown) return;
    _lastVisionAlert[label] = now;

    final what = _visionAlertPhrases[label] ?? label;
    setState(() => _statusText = 'Adelante: $what ($confidence%)');
    await _hapticService.vibrateTick();
    await _ttsService.speakStatus('Adelante hay $what', esp32Service: _activeEsp32);
  }

  /// Doble pitido al mandar una consulta a la IA: una persona ciega no ve la pantalla y necesita
  /// saber por audio que la pregunta salio (pedido del profesor Raul).
  Future<void> _playQuerySentCue() => _playCue('querySent');

  // ─── Cercania ("voy a chocar con algo?"), como el sensor de retroceso de un auto ───
  // Sin voz: tiene que ser inmediato. En modo Celular pita y vibra; en modo Modulo la placa pita
  // por su parlante y el celular solo vibra al mismo ritmo.
  // APAGADO por ahora: con fotos reales el modelo de cercania da 30-60 % de avisos falsos con el
  // camino libre y el celular pitaba sin motivo. El nivel igual llega a SensorContext (contexto
  // silencioso para la IA). Poner en true para volver a pitar/vibrar (celular y CMD_PROXIMITY).
  static const bool kProximityBeepsEnabled = false;
  static const Duration _proximityNearPeriod = Duration(milliseconds: 800);
  static const Duration _proximityVeryNearPeriod = Duration(milliseconds: 250);
  Timer? _proximityTimer;
  int _proximityAlertLevel = 0;

  void _setProximityAlert(int level, {required bool fromPhone}) {
    _sensorContext.onProximity(level);
    if (!kProximityBeepsEnabled) return;
    final active = fromPhone ? _hardwareMode == HardwareMode.standalone : _hardwareMode == HardwareMode.esp32;
    if (!active) level = 0;
    if (level == _proximityAlertLevel) return;
    _proximityAlertLevel = level;
    _proximityTimer?.cancel();
    _proximityTimer = null;
    if (level == 0 || !mounted) return;

    void tick() {
      if (fromPhone) _soundChannel.invokeMethod('proximity', {'level': level}).catchError((_) {});
      Vibration.vibrate(duration: level >= 2 ? 80 : 40, amplitude: level >= 2 ? 255 : 160).catchError((_) {});
    }

    tick();
    _proximityTimer = Timer.periodic(level >= 2 ? _proximityVeryNearPeriod : _proximityNearPeriod, (_) => tick());
  }

  /// 'querySent' = doble pitido (consulta enviada); 'listening' = pitido agudo (Iris escucha).
  Future<void> _playCue(String cue) async {
    try {
      await _soundChannel.invokeMethod(cue);
    } catch (e) {
      debugPrint('⚠️ No se pudo tocar el aviso $cue: $e');
    }
  }

  // ─── Volume Button Handler ───
  void _handleVolumeUpPress() {
    final now = DateTime.now();
    if (_lastVolumeUpTime != null && now.difference(_lastVolumeUpTime!).inMilliseconds < 500) {
      // Doble toque detectado
      _lastVolumeUpTime = null;
      _interruptAndStartListening();
    } else {
      _lastVolumeUpTime = now;
    }
  }

  Future<void> _interruptAndStartListening() async {
    if (_isListening || _isProcessing) return;
    // Si estaba hablando, paramos. Un pitido (distinto al de "consulta enviada") avisa que Iris
    // ya escucha; es mas rapido que decir "Iris lista" y el microfono no se graba a si mismo.
    if (_ttsService.isSpeaking) await _ttsService.stop();
    await _playCue('listening');

    // Activamos SIEMPRE el microfono nativo del celular (incluso en modo ESP32)
    // Esto es muy util porque el usuario tiene el celular en el bolsillo/mano.
    _startNativeListening();
  }

  // ─── Native Standalone Triggers ───
  void _startNativeListening() async {
    _isNativeMicActive = true;
    _onRecordingStarted();
    await _nativeSpeechService.startListening();
  }

  void _stopNativeListening() async {
    if (_isListening && _isNativeMicActive) {
      _processAudio();
    }
  }

  void _onRecordingStarted() async {
    setState(() {
      _isListening = true;
      _statusText = _isNativeMicActive 
          ? 'Escuchando celular...' 
          : 'Escuchando placa...';
    });
    _pulseController.repeat(reverse: true);
    SystemSound.play(SystemSoundType.click);
    await _ttsService.stop();
    if (_continuousMode) _continuousTimer?.cancel();
  }

  // ─── Continuous Mode ───
  void _toggleContinuousMode(bool value) async {
    setState(() {
      _continuousMode = value;
    });
    if (_continuousMode) {
      _consecutiveCount = 0;
      await _ttsService.speak('Modo continuo activado', esp32Service: _activeEsp32);
      _startContinuousMode();
    } else {
      _continuousTimer?.cancel();
      _consecutiveCount = 0;
      await _ttsService.speak('Modo continuo desactivado', esp32Service: _activeEsp32);
    }
  }

  void _startContinuousMode() {
    _continuousTimer?.cancel();
    
    if (_consecutiveCount == 0) {
      _captureAndDescribeContinuous();
      _consecutiveCount++;
    }

    _continuousTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      if (_consecutiveCount >= 3) {
        _pauseContinuousMode();
        return;
      }
      if (_isListening || _isProcessing) return;

      await _captureAndDescribeContinuous();
      _consecutiveCount++;
    });
  }

  void _pauseContinuousMode() {
    _continuousTimer?.cancel();
    Future.delayed(const Duration(seconds: 60), () {
      _consecutiveCount = 0;
      if (mounted && _continuousMode) {
        _startContinuousMode();
      }
    });
  }

  Future<void> _captureAndDescribeContinuous() async {
    await _playQuerySentCue();
    final String? desc = await _agentService.processWithAgenticReasoning(
      userPrompt: "Describe la vista actual.",
      onStatusUpdate: (status) {
        if (mounted) setState(() => _statusText = status);
      },
      captureImageCallback: _captureImage,
      sensorContext: _sensorContext.describe(),
      visionFallback: _sensorContext.lastSeen,
    );
    if (desc != null && mounted) {
      setState(() {
        _lastDescription = desc.replaceAll(RegExp(r'^\[(en|es)\]\s*', caseSensitive: false), '');
      });
      await _ttsService.speak(desc, esp32Service: _activeEsp32);
    }
    _resetState(null);
  }

  // ─── Procesamiento de Audio STT ───
  Future<void> _processAudio() async {
    if (!_isListening) return;
    
    _pulseController.stop();
    _pulseController.reset();

    setState(() {
      _isListening = false;
      _isProcessing = true;
      _statusText = 'Transcribiendo audio...';
    });
    _pulseController.stop();
    _pulseController.reset();

    try {
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate(duration: 50);
      }
    } catch (_) {}
    SystemSound.play(SystemSoundType.click);

    String prompt = '';
    
    if (_isNativeMicActive) {
       prompt = await _nativeSpeechService.stopListening();
       _isNativeMicActive = false;
       // We can still play the thinking sound on the ESP32 if we are in ESP32 mode
       if (_hardwareMode == HardwareMode.esp32) {
           _startThinking();
       }
    } else if (_hardwareMode == HardwareMode.esp32) {
       // Envia "Pensando..." sonoro al ESP32
       _startThinking();
       prompt = await _esp32SpeechService.stopListeningAndTranscribe();
       // Detenemos sonido pensante al tener la transcripcion
       _stopThinking();
    } else {
       prompt = await _nativeSpeechService.stopListening();
    }
    
    if (prompt.isEmpty) {
      _resetState('No entendi o hubo ruido, por favor intenta de nuevo');
      await _ttsService.speak('No escuche claramente, puedes repetir?', esp32Service: _activeEsp32);
      return;
    }

    // Comandos de voz del modo continuo
    final lowerPrompt = prompt.toLowerCase();
    final activateKeywords = ['activa el modo continuo', 'descripcion continua', 'describe todo el tiempo'];
    final deactivateKeywords = ['deja de describir', 'desactiva continuo'];
    
    if (activateKeywords.any((k) => lowerPrompt.contains(k))) {
       _resetState('Activando modo continuo...');
       _toggleContinuousMode(true);
       return;
    } else if (deactivateKeywords.any((k) => lowerPrompt.contains(k))) {
       _resetState('Desactivando modo continuo...');
       _toggleContinuousMode(false);
       return;
    }

    setState(() {
      _statusText = 'Analizando con Occipital...';
    });
    await _playQuerySentCue();
    
    // Si la ESP32 va a analizar la imagen, que vuelva a sonar "Pensando..." durante el GPT
    if (_hardwareMode == HardwareMode.esp32) _startThinking();

    try {
      final String? description = await _agentService.processWithAgenticReasoning(
        userPrompt: prompt,
        onStatusUpdate: (status) {
          if (mounted) setState(() => _statusText = status);
        },
        captureImageCallback: _captureImage,
        sensorContext: _sensorContext.describe(),
        visionFallback: _sensorContext.lastSeen,
        // En modo Modulo la foto tarda unos segundos por Bluetooth: avisar que ya esta mirando.
        onVisionStart: _hardwareMode == HardwareMode.esp32
            ? () => _ttsService.speakStatus('Dejame mirar', esp32Service: _activeEsp32)
            : null,
      );
      
      if (_hardwareMode == HardwareMode.esp32) _stopThinking();
      
      _resetState(null);
      setState(() {
        _lastDescription = (description ?? 'No se obtuvo respuesta.').replaceAll(RegExp(r'^\[(en|es)\]\s*', caseSensitive: false), '');
      });

      if (description != null) {
        await _ttsService.speak(description, esp32Service: _activeEsp32);
      }
    } catch (e) {
      debugPrint('⚠️ Error del servicio AI: $e');
      if (_hardwareMode == HardwareMode.esp32) _stopThinking();
      _resetState('Error de servicio AI.');
      await _ttsService.speak('Hubo un error, por favor intenta de nuevo.', esp32Service: _activeEsp32);
    }

    if (_continuousMode && _consecutiveCount < 2) {
      _startContinuousMode();
    }
  }

  void _resetState(String? errorMessage) {
    if (mounted) {
      setState(() {
         _isListening = false;
         _isProcessing = false;
         _statusText = errorMessage ?? 'Presiona el boton para hablar';
      });
    }
  }

  @override
  void dispose() {
    _continuousTimer?.cancel();
    _proximityTimer?.cancel();
    _localThinkingTimer?.cancel();
    _phoneVision.dispose();
    _pulseController.dispose();
    _fadeController.dispose();
    _nativeCameraService.dispose();
    _ttsService.dispose();
    _esp32SpeechService.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UI
  // ══════════════════════════════════════════════════════════════════════════

  bool get _isBusy => _isListening || _isProcessing;

  /// true si el sistema pidio quitar animaciones (accesibilidad).
  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  Duration get _uiAnim => _reduceMotion ? Duration.zero : const Duration(milliseconds: 250);

  /// Fondo de pantalla. Solo imagen: nada de texto aca, porque queda detras de las
  /// tarjetas (antes "Buscando el modulo..." se superponia con la descripcion).
  /// El estado de conexion del modulo se muestra dentro de la tarjeta de estado.
  Widget _buildCameraPreview() {
    const emptyBackground = DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.3),
          radius: 1.2,
          colors: [Color(0xFF0A1A20), Colors.black],
        ),
      ),
    );

    if (_hardwareMode == HardwareMode.esp32) {
      return ValueListenableBuilder<Uint8List?>(
        valueListenable: _esp32SpeechService.lastPhotoNotifier,
        builder: (context, photoData, child) {
          if (photoData == null) return emptyBackground;
          return Image.memory(
            photoData,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            excludeFromSemantics: true,
          );
        },
      );
    }

    final controller = _nativeCameraService.controller;
    final previewSize = controller?.value.previewSize;
    if (!_nativeCameraService.isInitialized || controller == null || previewSize == null) {
      return emptyBackground;
    }
    return ExcludeSemantics(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: previewSize.height,
          height: previewSize.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  /// Velos oscuros arriba y abajo: el selector y el boton se leen aunque la camara
  /// muestre algo claro.
  Widget _buildScrims() {
    return const IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              heightFactor: 0.22,
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.35,
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwareToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(32),
        ),
        child: Row(
          children: [
            Expanded(
              child: _buildToggleOption(
                icon: Icons.smartphone,
                label: 'Celular',
                semanticLabel: 'Modo Celular',
                semanticHint: 'Usa la cámara y el micrófono del teléfono',
                mode: HardwareMode.standalone,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _buildToggleOption(
                icon: Icons.memory,
                label: 'Modulo',
                semanticLabel: 'Modo Módulo',
                semanticHint: 'Usa la cámara y el micrófono de la placa',
                mode: HardwareMode.esp32,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Pantalla de recoleccion de datos (para el equipo, no para el usuario final).
  Widget _buildMissionsButton() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        tooltip: 'Misiones de recolección de datos',
        iconSize: 26,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        style: IconButton.styleFrom(backgroundColor: AppTheme.cardDark),
        icon: const Icon(Icons.assignment_outlined, color: AppTheme.textOnDarkMuted),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MissionsScreen(esp32: _esp32SpeechService, phoneCamera: _nativeCameraService),
        )),
      ),
    );
  }

  /// Cambio de modo (misma logica de siempre, solo se saco del onTap).
  void _selectHardwareMode(HardwareMode mode) {
    if (_isListening || _isProcessing) return; // Bloquear cambio si esta ocupado
    setState(() {
      _hardwareMode = mode;
      // La respuesta era de la otra camara: no dejarla como si fuera de esta.
      _lastDescription = '';
      _statusText = mode == HardwareMode.standalone
          ? 'Presiona el boton para hablar'
          : (_esp32SpeechService.isConnected
              ? 'Modulo conectado (Bluetooth)'
              : 'Buscando el modulo por Bluetooth...');
    });
    if (mode == HardwareMode.esp32) {
      _esp32SpeechService.ensurePermissions().then((_) {
        if (mounted) setState(() {});
      });
    }
    // Los pitidos de cercania eran del otro modo.
    _proximityTimer?.cancel();
    _proximityTimer = null;
    _proximityAlertLevel = 0;
    _updatePhoneVision();
    _ttsService.speakStatus(
      mode == HardwareMode.esp32 ? 'Modo modulo activado' : 'Modo Celular activado',
      esp32Service: mode == HardwareMode.esp32 ? _esp32SpeechService : null,
    );
  }

  Widget _buildToggleOption({
    required IconData icon,
    required String label,
    required String semanticLabel,
    required String semanticHint,
    required HardwareMode mode,
  }) {
    final isSelected = _hardwareMode == mode;
    final enabled = !_isBusy;
    final fg = isSelected ? AppTheme.textOnDark : AppTheme.textOnDarkMuted.withValues(alpha: 0.8);

    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: isSelected,
      enabled: enabled,
      label: semanticLabel,
      hint: isSelected ? null : semanticHint,
      onTap: enabled ? () => _selectHardwareMode(mode) : null,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: enabled ? () => _selectHardwareMode(mode) : null,
            child: AnimatedContainer(
              duration: _uiAnim,
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.accentCyan.withValues(alpha: 0.28) : Colors.transparent,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: isSelected ? AppTheme.brightCyan : fg, size: 22),
                  const SizedBox(width: 8),
                  // Con fuente muy grande la etiqueta se achica en vez de desbordar.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          color: fg,
                          fontSize: 17,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Avisos de vision local: misma fuente de datos (_statusText), pero en su propia tarjeta.
    final visionAlert = VisionAlert.tryParse(_statusText);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ─── VISOR DE CÁMARA ───
          _buildCameraPreview(),
          _buildScrims(),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildHardwareToggle()),
                      if (kShowDataMissions) _buildMissionsButton(),
                    ],
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildTopStatus(visionAlert),
                          if (visionAlert != null) ...[
                            const SizedBox(height: 12),
                            VisionAlertBanner(alert: visionAlert),
                          ],
                          if (_lastDescription.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildDescriptionOverlay(),
                          ],
                        ],
                      ),
                    ),
                  ),
                  _buildFloatingIndicator(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopStatus(VisionAlert? visionAlert) {
    final Color accent;
    final String phase;
    final String phaseSpoken;
    final IconData phaseIcon;
    if (!_isInitialized) {
      accent = AppTheme.textOnDarkMuted;
      phase = 'INICIANDO';
      phaseSpoken = 'Iniciando';
      phaseIcon = Icons.hourglass_top;
    } else if (_isListening) {
      accent = AppTheme.listeningRed;
      phase = 'ESCUCHANDO';
      phaseSpoken = 'Escuchando';
      phaseIcon = Icons.mic;
    } else if (_isProcessing) {
      accent = AppTheme.brightCyan;
      phase = 'PENSANDO';
      phaseSpoken = 'Pensando';
      phaseIcon = Icons.auto_awesome;
    } else {
      accent = AppTheme.accentCyan;
      phase = 'IRIS LISTA';
      phaseSpoken = 'Iris lista';
      phaseIcon = Icons.check_circle_outline;
    }

    // Si hay aviso de vision, ese texto va en su tarjeta (con su propio liveRegion) y aca
    // queda la indicacion de reposo, sin anunciarla.
    final statusLine = visionAlert != null ? 'Presiona el boton para hablar' : _statusText;
    // Borde solo mientras escucha o piensa; en reposo la tarjeta va limpia.
    final borderColor = _isBusy ? accent.withValues(alpha: 0.7) : Colors.transparent;
    final showModuleLink = _hardwareMode == HardwareMode.esp32;

    return AnimatedContainer(
      duration: _uiAnim,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Con fuente grande el switch baja a otra linea en vez de achicar el texto.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Semantics(
                header: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isListening)
                      Icon(phaseIcon, color: accent, size: 24)
                    else
                      // Logo de Iris: quieto en reposo, girando mientras piensa o arranca.
                      IrisLogo(
                        size: 26,
                        color: accent,
                        spinning: _isProcessing || !_isInitialized,
                        turnDuration: Duration(milliseconds: _isProcessing ? 1600 : 4000),
                      ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        phase,
                        semanticsLabel: phaseSpoken,
                        style: TextStyle(
                          color: _isBusy ? accent : AppTheme.textOnDark,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _buildContinuousSwitch(),
            ],
          ),
          if (statusLine.isNotEmpty) ...[
            const SizedBox(height: 6),
            // Solo se anuncia cuando cambia el texto; el brillo no afecta la semantica.
            Semantics(
              liveRegion: visionAlert == null,
              child: ShimmerText(
                statusLine,
                active: _isBusy,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500, height: 1.35),
              ),
            ),
          ],
          if (showModuleLink) ...[
            const SizedBox(height: 12),
            _buildModuleLink(),
          ],
        ],
      ),
    );
  }

  Widget _buildContinuousSwitch() {
    return MergeSemantics(
      child: Semantics(
        label: 'Modo continuo',
        hint: 'Describe lo que ve la cámara de forma automática',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: GestureDetector(
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggleContinuousMode(!_continuousMode),
                child: const ExcludeSemantics(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Continuo',
                      style: TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 15),
                    ),
                  ),
                ),
              ),
            ),
            Switch(
              value: _continuousMode,
              onChanged: _toggleContinuousMode,
              activeThumbColor: Colors.black,
              activeTrackColor: AppTheme.accentCyan,
              inactiveThumbColor: AppTheme.textOnDarkMuted,
              inactiveTrackColor: Colors.white24,
            ),
          ],
        ),
      ),
    );
  }

  /// Estado de la conexion con el modulo (antes era un texto centrado en el fondo que
  /// quedaba tapado por la tarjeta de descripcion).
  Widget _buildModuleLink() {
    final connected = _esp32SpeechService.isConnected;
    final label = _esp32SpeechService.connectedBoardLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: connected ? 'Conectado a $label' : 'Buscando el módulo por Bluetooth',
          child: ExcludeSemantics(
            child: Row(
              children: [
                Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                  color: connected ? AppTheme.accentCyan : AppTheme.alertAmber,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connected ? 'Conectado a $label' : 'Buscando el modulo...',
                    style: const TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: _esp32SpeechService.problem,
          builder: (context, problem, _) {
            if (problem == null || connected) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(problem, style: const TextStyle(color: AppTheme.alertAmber, fontSize: 15, height: 1.3)),
                    if (_esp32SpeechService.needsPermissions)
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () async {
                              await _esp32SpeechService.ensurePermissions();
                              if (mounted) setState(() {});
                            },
                            child: const Text('Dar permiso', style: TextStyle(color: AppTheme.accentCyan)),
                          ),
                          TextButton(
                            onPressed: openAppSettings,
                            child: const Text('Abrir ajustes', style: TextStyle(color: AppTheme.accentCyan)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _showBoardPicker,
              icon: const Icon(Icons.swap_horiz, color: AppTheme.accentCyan),
              label: const Text('Cambiar placa', style: TextStyle(color: AppTheme.accentCyan, fontSize: 15)),
            ),
            MergeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(
                    child: Text('Respuestas en el celular',
                        style: TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 15)),
                  ),
                  Switch(
                    value: _answersOnPhone,
                    onChanged: _setAnswersOnPhone,
                    activeThumbColor: Colors.black,
                    activeTrackColor: AppTheme.accentCyan,
                    inactiveThumbColor: AppTheme.textOnDarkMuted,
                    inactiveTrackColor: Colors.white24,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDescriptionOverlay() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: const Row(
              children: [
                Icon(Icons.spatial_audio_off, color: AppTheme.accentCyan, size: 20),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'ULTIMA DESCRIPCION',
                    semanticsLabel: 'Última descripción',
                    style: TextStyle(
                      color: AppTheme.accentCyan,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Alineado a la izquierda: el texto justificado deja huecos que cuestan con baja vision.
          Text(
            _lastDescription,
            style: const TextStyle(color: AppTheme.textOnDark, fontSize: 18, height: 1.45),
          ),
        ],
      ),
    );
  }

  /// Celular: microfono del celular. Modulo: pide a la placa que grabe con su microfono
  /// (como su boton fisico, que el prototipo de la final no tiene).
  void _talkButtonDown() {
    if (_hardwareMode == HardwareMode.standalone) {
      _startNativeListening();
    } else if (kAppPttEnabled && _esp32SpeechService.isConnected && !_isListening && !_isProcessing) {
      _appPttActive = true;
      _esp32SpeechService.sendAppPttStart();
    }
  }

  void _talkButtonUp() {
    if (_hardwareMode == HardwareMode.standalone || _isNativeMicActive) {
      _stopNativeListening();
    } else if (_appPttActive) {
      _appPttActive = false;
      _esp32SpeechService.sendAppPttStop();
    }
  }

  bool _appPttActive = false;

  Widget _buildFloatingIndicator() {
    final isModule = _hardwareMode == HardwareMode.esp32;
    // En modo Modulo se habla con el boton de la placa: el de la pantalla no graba.
    final canTalkHere = !isModule || (kAppPttEnabled && _esp32SpeechService.isConnected);
    final Color fill = _isListening
        ? AppTheme.listeningRed
        : (canTalkHere ? AppTheme.primaryCyan : AppTheme.cardDark);
    final IconData icon = _isListening ? Icons.graphic_eq : (canTalkHere ? Icons.mic : Icons.memory);
    final Color iconColor = (_isListening || canTalkHere) ? const Color(0xFF00161A) : AppTheme.brightCyan;

    final String caption;
    if (_isListening) {
      caption = canTalkHere ? 'Suelta para enviar' : 'Escuchando...';
    } else {
      caption = !isModule
          ? 'Manten presionado para hablar'
          : (canTalkHere
              ? 'Manten presionado: habla al modulo'
              : (_esp32SpeechService.isConnected ? 'Di "Oye Iris" para hablar' : 'Conecta el modulo para hablar'));
    }

    final String semanticLabel;
    final String? semanticHint;
    if (!canTalkHere) {
      semanticLabel = _isListening ? 'Escuchando' : 'Hablar con Iris';
      semanticHint = 'En modo Módulo, habla con el botón de la placa, '
          'o presiona dos veces el botón de subir volumen';
    } else if (_isListening) {
      semanticLabel = 'Escuchando';
      semanticHint = 'Toca dos veces para enviar tu pregunta';
    } else {
      semanticLabel = _isProcessing ? 'Iris está pensando. Hablar con Iris' : 'Hablar con Iris';
      semanticHint = 'Toca dos veces para empezar a escuchar y otra vez para enviar. '
          'Sin lector de pantalla: mantén presionado mientras hablas';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Con TalkBack un toque doble llega como "tap" (bajar y soltar al instante): por eso
          // el lector usa un toque para empezar y otro para enviar. Con el dedo sigue siendo
          // mantener presionado, igual que antes.
          Semantics(
            container: true,
            button: true,
            enabled: canTalkHere,
            label: semanticLabel,
            hint: semanticHint,
            onTap: canTalkHere || (_isListening && _isNativeMicActive)
                ? () {
                    if (_isListening) {
                      _talkButtonUp();
                    } else {
                      _talkButtonDown();
                    }
                  }
                : null,
            child: ExcludeSemantics(
              // Listener y no GestureDetector: no compite en la arena de gestos, asi que soltar el
              // dedo siempre llega (antes podia perderse el "soltar" y no se mandaba CMD_APP_PTT_STOP).
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _talkButtonDown(),
                onPointerUp: (_) => _talkButtonUp(),
                onPointerCancel: (_) => _talkButtonUp(),
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _isListening && !_reduceMotion ? _pulseAnimation.value : 1.0,
                      child: child,
                    );
                  },
                  child: AnimatedContainer(
                    duration: _uiAnim,
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: fill,
                      border: Border.all(
                        color: canTalkHere || _isListening
                            ? Colors.white.withValues(alpha: 0.6)
                            : Colors.white24,
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (_isListening ? AppTheme.listeningRed : AppTheme.primaryCyan)
                              .withValues(alpha: canTalkHere || _isListening ? 0.45 : 0.2),
                          blurRadius: 30,
                          spreadRadius: 6,
                        ),
                      ],
                    ),
                    child: Center(
                      // El boton es solo del microfono: el logo que gira va en la tarjeta de estado.
                      child: Icon(icon, color: iconColor, size: 52),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ExcludeSemantics(
            child: Text(
              caption,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textOnDark,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lista de placas Iris cercanas: elegir a cual conectarse y ponerles apodo ("Iris 1", "Iris 2").
class _BoardPicker extends StatelessWidget {
  const _BoardPicker({required this.service});

  final Esp32SpeechService service;

  Future<void> _rename(BuildContext context, IrisBoard board) async {
    final controller = TextEditingController(text: board.nickname ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apodo de la placa'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'Ej. Iris 1', helperText: board.id),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null) await service.setNickname(board.id, name);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: ValueListenableBuilder<List<IrisBoard>>(
          valueListenable: service.boardsFound,
          builder: (context, boards, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Elige tu placa Iris',
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      tooltip: 'Buscar de nuevo',
                      onPressed: service.refreshBoards,
                      icon: const Icon(Icons.refresh, color: AppTheme.accentCyan),
                    ),
                  ],
                ),
                if (boards.isEmpty)
                  ValueListenableBuilder<String?>(
                    valueListenable: service.problem,
                    builder: (context, problem, _) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          service.isScanning || problem == null
                              ? 'Buscando placas... Enciende la placa y acercala al celular.'
                              : problem,
                          style: const TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 16),
                        ),
                      ),
                    ),
                  ),
                if (service.needsPermissions)
                  const TextButton(
                    onPressed: openAppSettings,
                    child: Text('Abrir ajustes de la app', style: TextStyle(color: AppTheme.accentCyan)),
                  ),
                for (final board in boards)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      board.id == service.connectedBoardId ? Icons.bluetooth_connected : Icons.memory,
                      color: board.id == service.preferredBoardId ? AppTheme.accentCyan : AppTheme.textOnDarkMuted,
                    ),
                    title: Text(board.label, style: const TextStyle(color: Colors.white, fontSize: 18)),
                    subtitle: Text(
                      '${board.id}  ·  ${board.id == service.connectedBoardId ? 'conectada' : 'senal ${board.rssi} dBm'}',
                      style: const TextStyle(color: AppTheme.textOnDarkMuted),
                    ),
                    trailing: IconButton(
                      tooltip: 'Poner apodo',
                      onPressed: () => _rename(context, board),
                      icon: const Icon(Icons.edit, color: AppTheme.textOnDarkMuted),
                    ),
                    onTap: () {
                      service.selectBoard(board.id);
                      Navigator.pop(context);
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
