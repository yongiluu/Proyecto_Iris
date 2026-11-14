import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';

class SpeechService {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;
  String _lastWords = '';
  VoidCallback? onSpeechDone;

  Future<void> initialize() async {
    // Request microphone permission
    final status = await Permission.microphone.request();
    if (status.isGranted) {
      _isInitialized = await _speech.initialize(
        onError: (error) {
          debugPrint('⚠️ STT Error: $error');
          // Algunos errores (sin voz, sin red) no llegan con el estado "done": avisar igual, o la
          // pantalla queda "escuchando" hasta que alguien toque algo.
          if (error.permanent) onSpeechDone?.call();
        },
        onStatus: (status) {
          debugPrint('🎙️ STT Status: $status');
          if (status == 'done' && onSpeechDone != null) {
            onSpeechDone!();
          }
        },
      );
    } else {
      debugPrint('⚠️ Microphone permission denied.');
    }
  }

  /// false si no hay permiso de microfono o el celular no tiene reconocimiento de voz.
  bool get isAvailable => _isInitialized;

  Future<void> startListening() async {
    if (!_isInitialized) return;
    _lastWords = '';
    
    await _speech.listen(
      onResult: (result) {
        _lastWords = result.recognizedWords;
      },
      cancelOnError: true,
      partialResults: true,
      listenMode: ListenMode.confirmation,
    );
  }

  Future<String> stopListening() async {
    if (!_isInitialized) return '';

    if (_speech.isListening) {
      await _speech.stop();
    }
    
    // Short delay to ensure the final partial result is captured
    await Future.delayed(const Duration(milliseconds: 400));
    return _lastWords.trim();
  }
}
