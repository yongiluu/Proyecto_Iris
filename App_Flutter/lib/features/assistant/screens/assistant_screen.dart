// ============================================================================
// IRIS - Main Assistant Screen (Dual Mode: Standalone & ESP32)
// ============================================================================
//
// Pantalla principal: camara de fondo, una barra compacta arriba y un carrusel de modos
// (Iris, Leer texto, Buscar luz, Personas). Todo se puede pedir tambien por voz desde
// cualquier pagina ("Oye Iris, ¿que dice aqui?"). Los ajustes poco usados van en el engranaje.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import '../assistant_modes.dart';
import '../modes/assistant_mode_page.dart';
import '../modes/light_mode_page.dart';
import '../modes/people_mode_page.dart';
import '../modes/read_text_mode_page.dart';
import '../widgets/assistant_header.dart';
import '../widgets/assistant_layout.dart';
import '../widgets/board_picker.dart';
import '../widgets/mode_carousel.dart';
import '../widgets/people_sheets.dart';
import '../widgets/settings_sheet.dart';
import '../widgets/streaming_answer.dart';
import '../widgets/vision_alert_banner.dart';
import '../../../services/hardware/camera_service.dart';
import '../../../services/hardware/esp32_speech_service.dart';
import '../../../services/hardware/phone_light_meter.dart';
import '../../../services/ai/known_faces_service.dart';
import '../../../services/ai/phone_text_reader.dart';
import '../../../services/ai/speech_service.dart';
import '../../../services/ai/occipital_agent_service.dart';
import '../../../services/ai/voice_intents.dart';
import '../../../services/backend/backend_service.dart';
import '../../account/account_screen.dart';
import '../../../services/ai/phone_vision_service.dart';
import '../../../services/hardware/sensor_context.dart';
import '../../data_collection/missions_screen.dart';
import '../../../services/ai/tts_service.dart';
import '../../../services/hardware/haptic_service.dart';


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
  late final PhoneLightMeter _phoneLight = PhoneLightMeter(_nativeCameraService);
  // Se crean al primer uso (abren recursos nativos).
  PhoneTextReader? _textReaderInstance;
  KnownFacesService? _facesInstance;
  PhoneTextReader get _textReader => _textReaderInstance ??= PhoneTextReader();
  KnownFacesService get _faces => _facesInstance ??= KnownFacesService();

  // ─── State ───
  HardwareMode _hardwareMode = HardwareMode.standalone;
  bool _isListening = false;
  bool _isInitialized = false;
  bool _isProcessing = false;
  String _lastDescription = '';
  String _answerTitle = 'Respuesta';
  /// En reposo no hay linea de estado: el texto bajo el boton ya dice que hacer.
  static const String _idleStatus = '';
  String _statusText = _idleStatus;

  // ─── Carrusel de modos ───
  IrisMode _mode = IrisMode.assistant;
  final PageController _pageController = PageController();
  /// true mientras el carrusel se mueve por codigo (comando de voz o pestaña): no anunciar
  /// cada pagina intermedia.
  bool _programmaticPageChange = false;

  /// Sube con cada setState: la hoja de ajustes (otra ruta) se reconstruye con el estado nuevo.
  final ValueNotifier<int> _revision = ValueNotifier(0);
  bool _settingsOpen = false;

  // ─── Tareas de los modos ───
  bool _readingText = false;
  bool _peopleBusy = false;
  String? _enrollStatus;
  int _enrollGeneration = 0;

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
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

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
        _boardHasNoReader = false; // otra placa (o la misma con firmware nuevo): volver a probar
        if (!connected) {
          // El detector de luz de la placa se apago con ella.
          _esp32SpeechService.lightMeterOn.value = false;
          _esp32SpeechService.lightLevel.value = null;
        }
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
      _esp32SpeechService.onTextRead = _onTextRead;
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
        _initSafely('personas', _faces.load()),
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
    return _capturePhonePhoto();
  }

  /// Foto para los analisis locales (leer texto en el celular, personas): en modo Modulo, de la
  /// camara de la PLACA (la que la persona lleva puesta; el celular suele ir en el bolsillo). Si la
  /// placa no responde, la del celular.
  Future<Uint8List?> _captureForLocalAnalysis() async {
    if (_moduleConnected) {
      final jpeg = await _esp32SpeechService.captureSingleFrame();
      if (jpeg != null) return jpeg;
      debugPrint('La placa no mando la foto: se usa la camara del celular');
    }
    return _capturePhonePhoto();
  }

  /// Foto con la camara del celular.
  /// La camara saca una foto a la vez: espera a la de la vision local si hay una en curso.
  Future<Uint8List?> _capturePhonePhoto() async {
    if (!_nativeCameraService.isInitialized) return null;
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
      // Leer texto, personas y el detector de luz usan la misma camara.
      !_readingText &&
      !_peopleBusy &&
      !_peopleScanning &&
      !_phoneLight.isOn &&
      // Las misiones de datos usan la misma camara.
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// A donde mandar la voz de Iris. Con "Escuchar respuestas en el celular" (por defecto, mientras
  /// la placa no tenga altavoz) suena en el celular aunque el modo sea Modulo.
  Esp32SpeechService? get _activeEsp32 =>
      _hardwareMode == HardwareMode.esp32 && !_answersOnPhone ? _esp32SpeechService : null;

  /// Modo Modulo con la placa conectada: leer texto y luz usan la placa.
  bool get _moduleConnected => _hardwareMode == HardwareMode.esp32 && _esp32SpeechService.isConnected;

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
      builder: (context) => BoardPicker(service: _esp32SpeechService),
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
    unawaited(BackendService.instance.reportAlert(label, detail: 'Se escucha $what'));  // la ven sus acompañantes
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
    if (_isListening || _isProcessing || _isTaskBusy || _ttsService.isSpeaking) return;

    final now = DateTime.now();
    final last = _lastVisionAlert[label];
    if (last != null && now.difference(last) < _visionAlertCooldown) return;
    _lastVisionAlert[label] = now;

    final what = _visionAlertPhrases[label] ?? label;
    setState(() => _statusText = 'Adelante: $what ($confidence%)');
    await _hapticService.vibrateTick();
    await _ttsService.speakStatus('Adelante hay $what', esp32Service: _activeEsp32);
    if (label == 'vehiculo') {
      unawaited(BackendService.instance.reportAlert(label, detail: 'Vehiculo adelante'));  // la ven sus acompañantes
    }
  }

  /// Doble pitido al mandar una consulta a la IA: una persona ciega no ve la pantalla y necesita
  /// saber por audio que la pregunta salio (pedido del profesor Raul).
  /// Con las respuestas en la placa, el aviso es su propio pitido de "pensando" (que empieza al
  /// mismo tiempo): asi nunca suenan la placa y el celular a la vez.
  Future<void> _playQuerySentCue() async {
    if (_activeEsp32 != null) return;
    await _playCue('querySent');
  }

  /// La placa manda ~0,5 s de audio previo al "Oye Iris": la transcripcion puede empezar con
  /// "Oye Iris", "oye iris," o "Iris,". Se quita del comienzo antes de pasarla al agente.
  static final RegExp _wakeWordPrefix =
      RegExp(r'^[\s¡¿,.]*((oye|hey|oi|hoy)[\s,.!]*)?iris\b[\s,.:;!?¡¿]*', caseSensitive: false);

  static String _stripWakeWord(String text) => text.replaceFirst(_wakeWordPrefix, '').trim();

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
      if (_isListening || _isProcessing || _isTaskBusy) return;

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
    final String? desc = await _withBoardScene('Describe la vista actual.', await _agentService.processWithAgenticReasoning(
      userPrompt: "Describe la vista actual.",
      onStatusUpdate: (status) {
        if (mounted) setState(() => _statusText = status);
      },
      captureImageCallback: _captureImage,
      sensorContext: _sensorContext.describe(),
      visionFallback: _sensorContext.lastSeen,
    ));
    if (desc != null && mounted) {
      setState(() {
        _answerTitle = 'Descripcion';
        _lastDescription = TtsService.displayText(desc);
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

    prompt = _stripWakeWord(prompt);
    if (prompt.isEmpty) {
      _stopThinking();
      _resetState('No entendi o hubo ruido, por favor intenta de nuevo');
      await _ttsService.speak('No escuche claramente, puedes repetir?', esp32Service: _activeEsp32);
      return;
    }

    // Comandos de voz del modo continuo
    final lowerPrompt = prompt.toLowerCase();
    final activateKeywords = ['activa el modo continuo', 'descripcion continua', 'describe todo el tiempo'];
    final deactivateKeywords = ['deja de describir', 'desactiva continuo'];

    if (activateKeywords.any((k) => lowerPrompt.contains(k))) {
       _stopThinking();
       _resetState('Activando modo continuo...');
       _goToMode(IrisMode.assistant);
       _toggleContinuousMode(true);
       return;
    } else if (deactivateKeywords.any((k) => lowerPrompt.contains(k))) {
       _stopThinking();
       _resetState('Desactivando modo continuo...');
       _toggleContinuousMode(false);
       return;
    }

    // Leer texto, luz y personas se resuelven en el celular, sin preguntarle al modelo.
    final intent = VoiceIntents.parse(prompt);
    if (intent.type != IrisIntentType.none) {
      _stopThinking();
      _resetState(null);
      await _runIntent(intent);
      return;
    }

    setState(() {
      _statusText = 'Analizando con Occipital...';
    });
    await _playQuerySentCue();

    // Si la ESP32 va a analizar la imagen, que vuelva a sonar "Pensando..." durante el GPT
    if (_hardwareMode == HardwareMode.esp32) _startThinking();

    try {
      final String? description = await _withBoardScene(prompt, await _agentService.processWithAgenticReasoning(
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
      ));

      if (_hardwareMode == HardwareMode.esp32) _stopThinking();

      _resetState(null);
      setState(() {
        _answerTitle = 'Respuesta';
        _lastDescription = TtsService.displayText(description ?? 'No se obtuvo respuesta.');
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

  /// Si la nube no respondio a una pregunta de vision (sin internet, servidor caido), la placa describe
  /// la escena con su propio modelo, sin internet. Si no puede, queda la respuesta de error original.
  Future<String?> _withBoardScene(String prompt, String? cloudReply) async {
    if (!OccipitalAgentService.isFailureReply(cloudReply) || !OccipitalAgentService.wantsVision(prompt)) {
      return cloudReply;
    }
    if (!_moduleConnected || _esp32SpeechService.boardHas('escena') != true) return cloudReply;
    if (mounted) setState(() => _statusText = 'Sin conexion: describe la placa...');
    final local = await _esp32SpeechService.describeSceneOnBoard();
    if (local == null || local.isEmpty) return cloudReply;
    return 'Sin internet. Lo que ve la placa: $local';
  }

  void _resetState(String? errorMessage) {
    if (mounted) {
      setState(() {
         _isListening = false;
         _isProcessing = false;
         _statusText = errorMessage ?? _idleStatus;
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Comandos de voz y modos
  // ══════════════════════════════════════════════════════════════════════════

  bool get _isTaskBusy => _readingText || _peopleBusy;

  Future<void> _runIntent(IrisIntent intent) async {
    switch (intent.type) {
      case IrisIntentType.readText:
        _goToMode(IrisMode.readText);
        await _readText();
      case IrisIntentType.lightOn:
        _goToMode(IrisMode.light);
        await _setLight(true);
      case IrisIntentType.lightOff:
        _goToMode(IrisMode.light);
        await _setLight(false);
      case IrisIntentType.whoIsHere:
        _goToMode(IrisMode.people);
        await _whoIsHere();
      case IrisIntentType.rememberPerson:
        _goToMode(IrisMode.people);
        await _enrollPerson(intent.name ?? '');
      case IrisIntentType.forgetPerson:
        _goToMode(IrisMode.people);
        await _forgetPerson(intent.name ?? '');
      case IrisIntentType.repeat:
        await _ttsService.speak(
            _lastDescription.isEmpty ? 'Todavia no te he dicho nada.' : _lastDescription,
            esp32Service: _activeEsp32);
      case IrisIntentType.help:
        await _showResult(LocalAnswers.help, status: 'Lo que puedo hacer', title: 'Ayuda');
      case IrisIntentType.time:
        await _showResult(LocalAnswers.time(DateTime.now()), status: 'Hora', title: 'Hora');
      case IrisIntentType.slower:
      case IrisIntentType.faster:
        final slower = intent.type == IrisIntentType.slower;
        final changed = await _ttsService.changeRate(slower ? -1 : 1);
        await _ttsService.speakStatus(
            changed
                ? (slower ? 'Listo, hablo mas lento.' : 'Listo, hablo mas rapido.')
                : (slower ? 'Ya estoy hablando lo mas lento que puedo.' : 'Ya estoy hablando lo mas rapido que puedo.'),
            esp32Service: _activeEsp32);
      case IrisIntentType.stop:
        await _stopEverything();
      case IrisIntentType.none:
        break;
    }
  }

  /// "Callate": corta la voz y lo que este en curso (descripcion continua, luz, guardar una cara).
  Future<void> _stopEverything() async {
    await _ttsService.stop();
    if (_continuousMode) {
      _continuousTimer?.cancel();
      setState(() => _continuousMode = false);
    }
    if (_peopleBusy && _enrollStatus != null) _enrollGeneration++;
    if (_lightIsOn) await _setLight(false, speak: false);
    if (!mounted) return;
    setState(() {
      _peopleBusy = false;
      _enrollStatus = null;
      _statusText = 'En silencio';
    });
    await _hapticService.vibrateTick();
  }

  /// Respuesta de un modo (texto leido, personas...): va al cuadro de respuesta y se dice.
  Future<void> _showResult(String sentence, {required String status, String title = 'Respuesta'}) async {
    if (!mounted) return;
    setState(() {
      _statusText = status;
      _answerTitle = title;
      _lastDescription = TtsService.displayText(sentence);
    });
    await _ttsService.speak(sentence, esp32Service: _activeEsp32);
  }

  /// Mueve el carrusel por codigo (comando de voz o pestaña). Las paginas intermedias no se
  /// anuncian; con [announce] se anuncia la de destino.
  void _goToMode(IrisMode target, {bool announce = false}) {
    if (!mounted) return;
    final previous = _mode;
    if (previous != target) {
      setState(() => _mode = target);
      _afterModeSwitch(previous, target);
      if (announce) _announceMode(target);
    }
    if (!_pageController.hasClients || _pageController.page?.round() == target.index) return;
    _programmaticPageChange = true;
    void done() {
      _programmaticPageChange = false;
      // Si el usuario deslizo durante la animacion, manda la pagina donde quedo.
      final page = _pageController.hasClients ? _pageController.page?.round() : null;
      if (mounted && page != null && page != _mode.index) _onPageSwiped(page);
    }

    if (_reduceMotion) {
      _pageController.jumpToPage(target.index);
      WidgetsBinding.instance.addPostFrameCallback((_) => done());
    } else {
      _pageController
          .animateToPage(target.index, duration: const Duration(milliseconds: 320), curve: Curves.easeOut)
          .whenComplete(done);
    }
  }

  /// La persona deslizo el carrusel (con el dedo o con dos dedos en TalkBack).
  void _onPageSwiped(int page) {
    if (_programmaticPageChange || !mounted) return;
    final target = IrisMode.values[page];
    if (target == _mode) return;
    final previous = _mode;
    setState(() => _mode = target);
    _afterModeSwitch(previous, target);
    _announceMode(target);
  }

  void _afterModeSwitch(IrisMode previous, IrisMode next) {
    // El detector de luz solo vive en su pagina: asi no queda pitando olvidado.
    if (previous == IrisMode.light && next != IrisMode.light && _lightIsOn) {
      unawaited(_setLight(false, speak: false));
    }
    // En la pagina Personas el celular mira solo y avisa a quien reconoce.
    if (next == IrisMode.people) {
      _startPeopleScan();
    } else {
      _stopPeopleScan();
    }
  }

  // ─── Personas: aviso automatico ("Aqui esta Raul") mientras se esta en la pagina ───
  static const Duration _peopleScanPeriod = Duration(milliseconds: 2500);
  static const Duration _personCooldown = Duration(seconds: 30);
  Timer? _peopleScanTimer;
  bool _peopleScanning = false;
  final Map<String, DateTime> _lastPersonAnnounced = {};

  Future<void> _startPeopleScan() async {
    _stopPeopleScan();
    await _faces.load();
    // Sin modelo o sin nadie guardado no hay a quien reconocer.
    if (!mounted || _mode != IrisMode.people || !_faces.isAvailable || _faces.names.isEmpty) return;
    // Con la placa cada foto viaja por Bluetooth (~2 s): mirar mas espaciado para no saturarla.
    final period = _moduleConnected ? const Duration(seconds: 5) : _peopleScanPeriod;
    _peopleScanTimer = Timer.periodic(period, (_) => _scanPeopleOnce());
  }

  void _stopPeopleScan() {
    _peopleScanTimer?.cancel();
    _peopleScanTimer = null;
  }

  Future<void> _scanPeopleOnce() async {
    if (_peopleScanning || !mounted || _mode != IrisMode.people) return;
    // No interrumpir: ni mientras habla, escucha o hace otra cosa con la camara.
    if (_isBusy || _isTaskBusy || _readingText || _ttsService.isSpeaking || _cloudCaptureBusy) return;
    if (ModalRoute.of(context)?.isCurrent == false) return; // hoja de ajustes o lista abierta
    _peopleScanning = true;
    try {
      final jpeg = await _captureForLocalAnalysis();
      if (jpeg == null || !mounted || _mode != IrisMode.people) return;
      final matches = await _faces.recognize(jpeg);
      final now = DateTime.now();
      final fresh = matches.where((m) {
        if (m.name == null) return false; // a los desconocidos no se los anuncia solos
        final last = _lastPersonAnnounced[m.name!];
        return last == null || now.difference(last) > _personCooldown;
      }).toList();
      if (fresh.isEmpty || !mounted || _mode != IrisMode.people || _isBusy || _isTaskBusy) return;
      for (final m in fresh) {
        _lastPersonAnnounced[m.name!] = now;
      }
      await _hapticService.vibrateTick();
      await _showResult(KnownFacesService.describe(fresh), status: 'Personas', title: 'Personas');
    } finally {
      _peopleScanning = false;
    }
  }

  /// Vibracion corta y, sin TalkBack, el nombre del modo en voz (con TalkBack lo anuncia la
  /// region viva del carrusel; decirlo dos veces se superpone).
  void _announceMode(IrisMode mode) {
    _hapticService.vibrateTick();
    final talkBack = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    if (talkBack || _isListening || _isProcessing || _isTaskBusy || _ttsService.isSpeaking) return;
    _ttsService.speakStatus(mode.spokenName, esp32Service: _activeEsp32);
  }

  // ─── Leer texto: placa si esta conectada; si no (o si no responde), celular sin internet ───
  Timer? _readTextTimeout;
  /// La placa no respondio a CMD_READ_TEXT (firmware sin lector): no hacer esperar de nuevo.
  bool _boardHasNoReader = false;

  Future<void> _readText() async {
    if (_readingText) return;
    if (_lightIsOn) await _setLight(false, speak: false);
    setState(() {
      _readingText = true;
      _statusText = 'Leyendo texto...';
    });
    await _hapticService.vibrateTick();
    // La placa dice en su saludo si tiene el lector; si no lo dice (firmware antiguo), se prueba.
    final boardReader = _esp32SpeechService.boardHas('ocr');
    if (_moduleConnected && boardReader != false && !_boardHasNoReader) {
      _readTextTimeout?.cancel();
      // La placa lee en 1-3 s; 8 s cubre el Bluetooth lento sin dejar esperando a la persona.
      _readTextTimeout = Timer(const Duration(seconds: 8), () {
        _readTextTimeout = null;
        if (!mounted) return;
        // Solo se descarta la placa si NO dijo que tiene lector (firmware antiguo). Si lo anuncio en su
        // saludo, una lectura lenta (muchas lineas) no debe dejarla sin usar el resto de la sesion.
        if (boardReader != true) _boardHasNoReader = true;
        // La placa puede no tener el lector instalado: se lee con la camara del celular.
        setState(() => _statusText = 'La placa no respondio. Leo con el celular...');
        unawaited(_readWithPhone());
      });
      await _esp32SpeechService.requestReadText();
      return;
    }
    await _readWithPhone();
  }

  Future<void> _readWithPhone() async {
    try {
      final jpeg = await _captureForLocalAnalysis();
      if (!mounted) return;
      if (jpeg == null) {
        await _showResult('No pude sacar la foto. Intenta de nuevo.', status: 'Sin camara', title: 'Texto leido');
        return;
      }
      final text = await _textReader.read(jpeg);
      if (!mounted) return;
      await _deliverReadText(text);
    } finally {
      if (mounted) setState(() => _readingText = false);
    }
  }

  Future<void> _onTextRead(String text) async {
    final waiting = _readTextTimeout != null;
    _readTextTimeout?.cancel();
    _readTextTimeout = null;
    if (!mounted) return;
    // Llego tarde y el celular ya esta leyendo: manda el celular.
    if (!waiting && _readingText) return;
    setState(() => _readingText = false);
    await _deliverReadText(text);
  }

  Future<void> _deliverReadText(String text) => _showResult(
        text.isEmpty ? 'No encontre texto. Acerca un poco el letrero.' : 'Dice: $text',
        status: text.isEmpty ? 'No encontre texto' : 'Texto leido',
        title: 'Texto leido',
      );

  // ─── Buscar luz: la placa pita si esta conectada; si no, el celular mide y pita ───
  bool get _lightIsOn => _esp32SpeechService.lightMeterOn.value || _phoneLight.isOn;

  Future<void> _setLight(bool on, {bool speak = true}) async {
    if (on) {
      if (_lightIsOn) {
        if (speak) await _ttsService.speakStatus('El detector de luz ya esta encendido', esp32Service: _activeEsp32);
        return;
      }
      setState(() => _statusText = 'Detector de luz encendido');
      if (_moduleConnected) {
        await _esp32SpeechService.setLightMeter(true);
        if (speak) await _ttsService.speakStatus('Detector de luz. Mas agudo, mas luz.', esp32Service: _activeEsp32);
      } else {
        // Primero la voz y despues los tonos, para que no se tapen.
        if (speak) await _ttsService.speakAndWait('Detector de luz. Mas agudo, mas luz.');
        if (!mounted || _mode != IrisMode.light) return;
        _phoneLight.start(canCapture: () => mounted && !_cloudCaptureBusy && !_isListening);
      }
    } else {
      final wasOn = _lightIsOn;
      if (_esp32SpeechService.lightMeterOn.value && _esp32SpeechService.isConnected) {
        await _esp32SpeechService.setLightMeter(false);
      }
      _phoneLight.stop();
      if (!mounted) return;
      if (wasOn) setState(() => _statusText = 'Detector de luz apagado');
      if (speak) {
        await _ttsService.speakStatus(wasOn ? 'Detector de luz apagado' : 'El detector de luz ya estaba apagado',
            esp32Service: _activeEsp32);
      }
    }
    if (mounted) setState(() {});
  }

  // ─── Personas conocidas (todo en el celular) ───

  /// Carga la lista y el modelo; si el modelo no esta instalado, lo dice.
  Future<bool> _facesReady() async {
    await _faces.load();
    if (!mounted) return false;
    setState(() {}); // cantidad de personas guardadas
    if (_faces.isAvailable) return true;
    await _showResult('El reconocimiento de personas todavia no esta instalado.',
        status: 'Personas: no instalado', title: 'Personas');
    return false;
  }

  Future<void> _whoIsHere() async {
    if (_peopleBusy) return;
    if (!await _facesReady()) return;
    setState(() {
      _peopleBusy = true;
      _statusText = 'Buscando caras...';
    });
    try {
      await _hapticService.vibrateTick();
      final jpeg = await _captureForLocalAnalysis();
      if (!mounted) return;
      if (jpeg == null) {
        await _showResult('No pude sacar la foto. Intenta de nuevo.', status: 'Sin camara', title: 'Personas');
        return;
      }
      final matches = await _faces.recognize(jpeg);
      var sentence = KnownFacesService.describe(matches);
      if (_faces.names.isEmpty && matches.isNotEmpty) {
        sentence += ' Todavia no conozco a nadie: di "Oye Iris, recuerda a" y su nombre.';
      }
      await _showResult(sentence, status: matches.isEmpty ? 'No veo a nadie' : 'Personas', title: 'Personas');
    } finally {
      if (mounted) setState(() => _peopleBusy = false);
    }
  }

  static const List<String> _enrollPrompts = [
    'Foto 1. Que mire de frente al celular.',
    'Foto 2. Que gire un poco la cara hacia un lado.',
    'Foto 3. Ahora un poco hacia el otro lado.',
    'Foto 4. Que levante un poco la barbilla.',
    'Foto 5. De frente otra vez.',
  ];

  /// "Recuerda a Raul": ~5 fotos guiadas por voz, 1,5 s entre una y otra.
  Future<void> _enrollPerson(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty || _peopleBusy) return;
    if (!await _facesReady()) return;
    final generation = ++_enrollGeneration;
    bool cancelled() => !mounted || generation != _enrollGeneration;
    if (_lightIsOn) await _setLight(false, speak: false);
    setState(() {
      _peopleBusy = true;
      _enrollStatus = 'Agregando a $name';
      _statusText = 'Agregando a $name';
    });
    var saved = 0;
    try {
      await _ttsService.speakAndWait(_moduleConnected
              ? 'Voy a guardar la cara de $name con 5 fotos. Mira hacia su cara.'
              : 'Voy a guardar la cara de $name con 5 fotos. Apunta el celular a su cara.',
          esp32Service: _activeEsp32);
      var step = 0, attempts = 0;
      while (step < _enrollPrompts.length && attempts < _enrollPrompts.length + 4) {
        if (cancelled()) return;
        attempts++;
        setState(() => _enrollStatus = '$name: foto ${step + 1} de ${_enrollPrompts.length}');
        await _ttsService.speakAndWait(_enrollPrompts[step], esp32Service: _activeEsp32);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (cancelled()) return;
        final jpeg = await _captureForLocalAnalysis();
        if (cancelled()) return;
        if (jpeg == null) {
          await _ttsService.speakAndWait('No pude sacar la foto. Intenta de nuevo.', esp32Service: _activeEsp32);
          break;
        }
        final count = await _faces.enroll(name, jpeg);
        if (cancelled()) return;
        if (count == 0) {
          await _ttsService.speakAndWait(_moduleConnected ? 'No veo su cara. Acercate un poco.' : 'No veo su cara. Acerca un poco el celular.', esp32Service: _activeEsp32);
          continue;
        }
        if (count < 0) {
          await _ttsService.speakAndWait('Veo varias caras. Que quede solo $name al frente.',
              esp32Service: _activeEsp32);
          continue;
        }
        saved++;
        step++;
        SystemSound.play(SystemSoundType.click);
        unawaited(_hapticService.vibrateTick());
      }
      if (cancelled()) return;
      await _showResult(
        saved == 0
            ? 'No pude ver la cara de $name. Prueba con mas luz y un poco mas cerca.'
            : 'Listo, ya conozco a $name. Guarde $saved fotos.',
        status: saved == 0 ? 'No se guardo a $name' : '$name guardado',
        title: 'Personas',
      );
      if (saved > 0) {
        // Esta al frente: no anunciarla de inmediato. Y si era la primera persona, empezar a mirar.
        _lastPersonAnnounced[KnownFacesService.nameKey(name)] = DateTime.now();
        if (_mode == IrisMode.people && _peopleScanTimer == null) unawaited(_startPeopleScan());
      }
    } finally {
      if (mounted && generation == _enrollGeneration) {
        setState(() {
          _peopleBusy = false;
          _enrollStatus = null;
        });
      }
    }
  }

  void _cancelEnroll() {
    _enrollGeneration++;
    setState(() {
      _peopleBusy = false;
      _enrollStatus = null;
      _statusText = 'Cancelado';
    });
    _ttsService.speakStatus('Cancelado', esp32Service: _activeEsp32);
  }

  Future<void> _forgetPerson(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) return;
    await _faces.load();
    final removed = await _faces.forget(name);
    if (!mounted) return;
    await _showResult(
      removed ? 'Listo, olvide a $name.' : 'No tengo guardado a $name.',
      status: removed ? '$name olvidado' : 'No conozco a $name',
      title: 'Personas',
    );
  }

  Future<void> _addPersonFromScreen() async {
    if (!await _facesReady() || !mounted) return;
    final name = await askPersonName(context);
    if (name != null && mounted) await _enrollPerson(name);
  }

  Future<void> _showPeopleList() async {
    await _faces.load();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B1116),
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PeopleListSheet(
        names: _faces.names,
        samplesOf: _faces.samplesOf,
        onForget: (name) async {
          await _faces.forget(name);
          if (mounted) setState(() {});
          await _ttsService.speakStatus('Olvide a $name', esp32Service: _activeEsp32);
        },
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _continuousTimer?.cancel();
    _proximityTimer?.cancel();
    _localThinkingTimer?.cancel();
    _phoneVision.dispose();
    _phoneLight.dispose();
    _textReaderInstance?.dispose();
    _facesInstance?.dispose();
    _readTextTimeout?.cancel();
    _pulseController.dispose();
    _fadeController.dispose();
    _peopleScanTimer?.cancel();
    _pageController.dispose();
    _revision.dispose();
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

  /// Fondo de pantalla. Solo imagen: nada de texto aca, porque queda detras de las tarjetas.
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

  /// Cambio de modo (misma logica de siempre).
  void _selectHardwareMode(HardwareMode mode) {
    if (_isListening || _isProcessing) return; // Bloquear cambio si esta ocupado
    if (mode == _hardwareMode) return;
    // El detector de luz y la lectura en curso eran del otro hardware.
    if (_lightIsOn) unawaited(_setLight(false, speak: false));
    final boardReadPending = _readTextTimeout != null;
    _readTextTimeout?.cancel();
    _readTextTimeout = null;
    setState(() {
      if (boardReadPending) _readingText = false;
      _hardwareMode = mode;
      // La respuesta era de la otra camara: no dejarla como si fuera de esta.
      _lastDescription = '';
      _statusText = mode == HardwareMode.standalone
          ? _idleStatus
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

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B1116),
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
      builder: (sheetContext) => ValueListenableBuilder<int>(
        valueListenable: _revision,
        builder: (_, _, _) => SettingsSheet(
          hardwareMode: _hardwareMode,
          onHardwareModeChanged: _selectHardwareMode,
          busy: _isBusy,
          boardConnected: _esp32SpeechService.isConnected,
          boardLabel: _esp32SpeechService.connectedBoardLabel ?? 'la placa',
          problem: _esp32SpeechService.problem,
          needsPermissions: _esp32SpeechService.needsPermissions,
          onRequestPermissions: () async {
            await _esp32SpeechService.ensurePermissions();
            if (mounted) setState(() {});
          },
          onOpenAppSettings: openAppSettings,
          onPickBoard: _showBoardPicker,
          answersOnPhone: _answersOnPhone,
          onAnswersOnPhoneChanged: _setAnswersOnPhone,
          boardVolume: _esp32SpeechService.boardVolume,
          onBoardVolumeChanged: _esp32SpeechService.setBoardVolume,
          onOpenAccount: BackendService.instance.enabled
              ? () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen()));
                }
              : null,
          onOpenMissions: kShowDataMissions
              ? () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => MissionsScreen(esp32: _esp32SpeechService, phoneCamera: _nativeCameraService),
                  ));
                }
              : null,
        ),
      ),
    );
    _settingsOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    // Avisos de vision local: misma fuente de datos (_statusText), pero en su propia tarjeta.
    final visionAlert = VisionAlert.tryParse(_statusText);

    final AssistantPhase phase;
    if (!_isInitialized) {
      phase = AssistantPhase.starting;
    } else if (_isListening) {
      phase = AssistantPhase.listening;
    } else if (_isProcessing || _isTaskBusy) {
      phase = AssistantPhase.thinking;
    } else {
      phase = AssistantPhase.ready;
    }

    final isModule = _hardwareMode == HardwareMode.esp32;
    final connected = _esp32SpeechService.isConnected;

    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: AssistantLayout(
          background: _buildCameraPreview(),
          topBar: AssistantTopBar(
            phase: phase,
            hardwareLabel: !isModule ? 'Celular' : (connected ? 'Modulo conectado' : 'Buscando modulo'),
            hardwareIcon: !isModule
                ? Icons.smartphone
                : (connected ? Icons.bluetooth_connected : Icons.bluetooth_searching),
            hardwareWarning: isModule && !connected,
            onOpenSettings: _openSettings,
          ),
          // Si hay aviso de vision, ese texto va en su tarjeta (con su propio liveRegion).
          status: StatusLine(
            text: visionAlert != null ? '' : _statusText,
            active: _isBusy || _isTaskBusy,
          ),
          alert: visionAlert == null ? null : VisionAlertBanner(alert: visionAlert),
          answer: _lastDescription.isEmpty
              ? null
              : StreamingAnswer(
                  text: _lastDescription,
                  progress: _ttsService.progress,
                  title: _answerTitle,
                ),
          carousel: ModeCarousel(
            controller: _pageController,
            mode: _mode,
            onModeChanged: (mode) => _onPageSwiped(mode.index),
            onTabSelected: (mode) => _goToMode(mode, announce: true),
            pageBuilder: _buildModePage,
          ),
        ),
      ),
    );
  }

  Widget _buildModePage(BuildContext context, IrisMode mode) {
    switch (mode) {
      case IrisMode.assistant:
        final isModule = _hardwareMode == HardwareMode.esp32;
        // En modo Modulo se habla con "Oye Iris" (o el doble toque de volumen): el boton no graba.
        final canTalkHere = !isModule || (kAppPttEnabled && _esp32SpeechService.isConnected);
        return AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, _) => AssistantModePage(
            isListening: _isListening,
            isProcessing: _isProcessing,
            canTalkHere: canTalkHere,
            isModule: isModule,
            moduleConnected: _esp32SpeechService.isConnected,
            continuousMode: _continuousMode,
            onContinuousChanged: _toggleContinuousMode,
            onPressDown: _talkButtonDown,
            onPressUp: _talkButtonUp,
            pulseScale: _pulseAnimation.value,
          ),
        );
      case IrisMode.readText:
        return ReadTextModePage(
          isReading: _readingText,
          usesBoard: _moduleConnected,
          onRead: _readText,
        );
      case IrisMode.light:
        return ListenableBuilder(
          listenable: Listenable.merge([
            _esp32SpeechService.lightMeterOn,
            _esp32SpeechService.lightLevel,
            _phoneLight.level,
          ]),
          builder: (context, _) {
            final boardOn = _esp32SpeechService.lightMeterOn.value;
            return LightModePage(
              isOn: _lightIsOn,
              level: boardOn ? _esp32SpeechService.lightLevel.value : _phoneLight.level.value,
              onToggle: () => _setLight(!_lightIsOn),
            );
          },
        );
      case IrisMode.people:
        return PeopleModePage(
          isAvailable: _facesInstance?.isAvailable ?? false,
          isBusy: _peopleBusy,
          savedCount: _facesInstance?.names.length ?? 0,
          onWhoIsHere: _whoIsHere,
          onAddPerson: _addPersonFromScreen,
          onShowPeople: _showPeopleList,
          enrollStatus: _enrollStatus,
          onCancelEnroll: _cancelEnroll,
        );
    }
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
}
