/// ============================================================================
/// IRIS - Main Assistant Screen (Dual Mode: Standalone & ESP32)
/// ============================================================================

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:vibration/vibration.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../services/hardware/camera_service.dart';
import '../../../services/hardware/esp32_camera_service.dart';
import '../../../services/hardware/esp32_speech_service.dart';
import '../../../services/ai/speech_service.dart';
import '../../../services/ai/occipital_agent_service.dart';
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
  
  // IP DE LA ESP32 (Actualizala si cambia en el monitor serie)
  static const String ESP32_IP = '10.215.241.172';

  // ─── Services ───
  final CameraService _nativeCameraService = CameraService();
  final SpeechService _nativeSpeechService = SpeechService();
  final Esp32CameraService _esp32CameraService = Esp32CameraService(ESP32_IP);
  final Esp32SpeechService _esp32SpeechService = Esp32SpeechService();
  final OccipitalAgentService _agentService = OccipitalAgentService();
  final TtsService _ttsService = TtsService();
  final HapticService _hapticService = HapticService();

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
        if (mounted && _hardwareMode == HardwareMode.standalone && _isListening) {
          _processAudio();
        }
      };

      _esp32SpeechService.onConnectionChanged = (bool connected) {
        if (mounted && _hardwareMode == HardwareMode.esp32) {
          setState(() {
            _statusText = connected ? 'Conectado a ESP32 (BLE)' : 'Buscando Iris_ESP32 por Bluetooth...';
          });
          if (connected) {
            _hapticService.vibrateStart();
            _ttsService.speakStatus('Bluetooth conectado');
          }
        }
      };

      await Future.wait<void>([
        _nativeCameraService.initialize(),
        _nativeSpeechService.initialize(),
        _esp32CameraService.initialize(),
        _esp32SpeechService.init(),
        _ttsService.initialize(),
        _hapticService.initialize(),
      ]);

      setState(() => _isInitialized = true);
      
      if (_hardwareMode == HardwareMode.esp32) {
         setState(() {
            _statusText = _esp32SpeechService.isConnected ? 'Conectado a ESP32 (BLE)' : 'Buscando Iris_ESP32 por Bluetooth...';
         });
      }

      await _ttsService.speakStatus('Iris esta lista.', esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
    } catch (e) {
      setState(() {
        _statusText = 'Error de inicializacion: $e';
      });
      debugPrint('⚠️ Error initializing services: $e');
    }
  }

  bool _isNativeMicActive = false;

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
    // Si estaba hablando, paramos
    if (_ttsService.isSpeaking) {
      await _ttsService.stop();
      await _ttsService.speakStatus('Iris lista.', esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
    } else {
      await _ttsService.speakStatus('Iris lista.', esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
    }
    
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
      await _ttsService.speak('Modo continuo activado', esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
      _startContinuousMode();
    } else {
      _continuousTimer?.cancel();
      _consecutiveCount = 0;
      await _ttsService.speak('Modo continuo desactivado', esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
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
    final String? desc = await _agentService.processWithAgenticReasoning(
      userPrompt: "Describe la vista actual.",
      onStatusUpdate: (status) {
        if (mounted) setState(() => _statusText = status);
      },
      captureImageCallback: () async {
        if (_hardwareMode == HardwareMode.esp32) {
          return await _esp32CameraService.captureSingleFrame();
        } else {
          return await _nativeCameraService.captureSingleFrame();
        }
      },
    );
    if (desc != null && mounted) {
      setState(() {
        _lastDescription = desc.replaceAll(RegExp(r'^\[(en|es)\]\s*', caseSensitive: false), '');
      });
      await _ttsService.speak(desc, esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
      _resetState(null);
    }
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
           _esp32SpeechService.startThinkingSound();
       }
    } else if (_hardwareMode == HardwareMode.esp32) {
       // Envia "Pensando..." sonoro al ESP32
       _esp32SpeechService.startThinkingSound();
       prompt = await _esp32SpeechService.stopListeningAndTranscribe();
       // Detenemos sonido pensante al tener la transcripcion
       _esp32SpeechService.stopThinkingSound();
    } else {
       prompt = await _nativeSpeechService.stopListening();
    }
    
    if (prompt.isEmpty) {
      _resetState('No entendi o hubo ruido, por favor intenta de nuevo');
      await _ttsService.speak('No escuche claramente, puedes repetir?', esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
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
    
    // Si la ESP32 va a analizar la imagen, que vuelva a sonar "Pensando..." durante el GPT
    if (_hardwareMode == HardwareMode.esp32) _esp32SpeechService.startThinkingSound();

    try {
      final String? description = await _agentService.processWithAgenticReasoning(
        userPrompt: prompt,
        onStatusUpdate: (status) {
          if (mounted) setState(() => _statusText = status);
        },
        captureImageCallback: () async {
          if (_hardwareMode == HardwareMode.esp32) {
            return await _esp32SpeechService.captureSingleFrame();
          } else {
            return await _nativeCameraService.captureSingleFrame();
          }
        },
      );
      
      if (_hardwareMode == HardwareMode.esp32) _esp32SpeechService.stopThinkingSound();
      
      _resetState(null);
      setState(() {
        _lastDescription = (description ?? 'No se obtuvo respuesta.').replaceAll(RegExp(r'^\[(en|es)\]\s*', caseSensitive: false), '');
      });

      if (description != null) {
        await _ttsService.speak(description, esp32Service: _hardwareMode == HardwareMode.esp32 ? _esp32SpeechService : null);
      }
    } catch (e) {
      if (_hardwareMode == HardwareMode.esp32) _esp32SpeechService.stopThinkingSound();
      _resetState('Error de servicio AI.');
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
    _pulseController.dispose();
    _fadeController.dispose();
    _nativeCameraService.dispose();
    _esp32CameraService.dispose();
    _ttsService.dispose();
    _esp32SpeechService.dispose();
    super.dispose();
  }

  Widget _buildCameraPreview() {
    if (_hardwareMode == HardwareMode.esp32) {
      return ValueListenableBuilder<Uint8List?>(
        valueListenable: _esp32SpeechService.lastPhotoNotifier,
        builder: (context, photoData, child) {
          if (photoData != null) {
            return SizedBox.expand(
              child: Image.memory(
                photoData,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            );
          }
          return Container(
            color: Colors.black87,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _esp32SpeechService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                    color: _esp32SpeechService.isConnected ? AppTheme.primaryCyan : Colors.grey,
                    size: 64,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _esp32SpeechService.isConnected ? 'Camara ESP32 (Lista para captura)' : 'Buscando Iris_ESP32 por Bluetooth...',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else {
      if (!_nativeCameraService.isInitialized || _nativeCameraService.controller == null) {
        return const Center(child: CircularProgressIndicator(color: AppTheme.primaryCyan));
      }
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _nativeCameraService.controller!.value.previewSize!.height,
            height: _nativeCameraService.controller!.value.previewSize!.width,
            child: CameraPreview(_nativeCameraService.controller!),
          ),
        ),
      );
    }
  }

  Widget _buildHardwareToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.5)),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildToggleOption(
                icon: Icons.smartphone,
                label: 'Celular',
                mode: HardwareMode.standalone,
              ),
              _buildToggleOption(
                icon: Icons.developer_board,
                label: 'Placa ESP32',
                mode: HardwareMode.esp32,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggleOption({required IconData icon, required String label, required HardwareMode mode}) {
    final isSelected = _hardwareMode == mode;
    return GestureDetector(
      onTap: () {
         if (_isListening || _isProcessing) return; // Bloquear cambio si esta ocupado
         setState(() {
            _hardwareMode = mode;
         });
         _ttsService.speakStatus(
           mode == HardwareMode.esp32 ? 'Modo ESP32 activado' : 'Modo Celular activado',
           esp32Service: mode == HardwareMode.esp32 ? _esp32SpeechService : null
         );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accentCyan.withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? AppTheme.accentCyan : Colors.white54, size: 20),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white54, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ─── VISOR DE CÁMARA ───
          _buildCameraPreview(),

          SafeArea(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildHardwareToggle(),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _buildTopStatus(),
                          if (_lastDescription.isNotEmpty) _buildDescriptionOverlay(),
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

  Widget _buildTopStatus() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _isListening ? Colors.redAccent.withValues(alpha: 0.8) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _isListening ? 'ESCUCHANDO...' : 'IRIS LISTA',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 8), // Anadir un poco de espacio
                  Row(
                    children: [
                      const Text('Continuo', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Switch(
                        value: _continuousMode,
                        onChanged: _toggleContinuousMode,
                        activeColor: AppTheme.accentCyan,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_statusText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  _statusText,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.left,
                ),
              ),
            if (_isProcessing)
              const Padding(
                padding: EdgeInsets.only(top: 16.0),
                child: LinearProgressIndicator(
                  backgroundColor: Colors.white24,
                  valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accentCyan),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescriptionOverlay() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.accentCyan.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.spatial_audio_off, color: AppTheme.accentCyan, size: 18),
                SizedBox(width: 8),
                Text(
                  'ULTIMA DESCRIPCION',
                  style: TextStyle(
                    color: AppTheme.accentCyan,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _lastDescription,
              style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.4),
              maxLines: null,
              textAlign: TextAlign.justify,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 48.0),
      child: GestureDetector(
        onTapDown: (_) {
           if (_hardwareMode == HardwareMode.standalone) _startNativeListening();
        },
        onTapUp: (_) {
           if (_hardwareMode == HardwareMode.standalone) _stopNativeListening();
        },
        onTapCancel: () {
           if (_hardwareMode == HardwareMode.standalone) _stopNativeListening();
        },
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Transform.scale(
              scale: _isListening ? _pulseAnimation.value : 1.0,
              child: child,
            );
          },
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isListening ? Colors.redAccent.withValues(alpha: 0.8) : AppTheme.primaryCyan.withValues(alpha: 0.8),
              boxShadow: [
                BoxShadow(
                  color: _isListening ? Colors.redAccent.withValues(alpha: 0.4) : AppTheme.primaryCyan.withValues(alpha: 0.4),
                  blurRadius: 30,
                  spreadRadius: 8,
                ),
              ],
            ),
            child: Center(
              child: Icon(
                _isListening ? Icons.mic : Icons.sensors,
                color: Colors.white,
                size: 48,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
