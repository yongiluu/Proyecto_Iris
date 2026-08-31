// lib/services/ai/trigger_manager.dart
// ✅ FALLBACK VERSION - NO VOLUME PACKAGES (LONG PRESS ONLY)
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter/foundation.dart';

enum ListeningState { idle, capturingSpeech, processing }

class PhysicalTriggerManager {
  static final PhysicalTriggerManager _instance = PhysicalTriggerManager._internal();
  factory PhysicalTriggerManager() => _instance;
  PhysicalTriggerManager._internal();

  bool _isListening = false;
  VoidCallback? onTriggerActivated;

  Future<void> initialize({required VoidCallback onCapture}) async {
    onTriggerActivated = onCapture;
    if (kDebugMode) print('⚠️ Volume trigger disabled due to AGP incompatibility.');
  }

  Future<void> _activateAssistant() async {
    if (_isListening) return;
    try {
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate(duration: 50);
      }
    } catch (_) {}
    SystemSound.play(SystemSoundType.click);
    if (kDebugMode) print('📍 SENSORS: 9.1 Physical trigger (Long Press) activated');
    _isListening = true;
    onTriggerActivated?.call();
  }

  bool handleLongPress() {
    _activateAssistant();
    return true;
  }

  Future<void> stopListening() async {
    _isListening = false;
  }

  bool get isListening => _isListening;
}
