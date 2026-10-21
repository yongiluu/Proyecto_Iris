import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';
import '../../core/constants/env_config.dart';
import '../hardware/esp32_speech_service.dart';

class TtsService {
  static const Duration _cloudTtsTimeout = Duration(seconds: 20);
  static const String _spanishVoice = 'es-CL-CatalinaNeural';
  static const String _englishVoice = 'en-US-AriaNeural';

  final FlutterTts _tts = FlutterTts();
  final Completer<void> _initCompleter = Completer<void>();
  bool _isSpeaking = false;
  Esp32SpeechService? _activeEsp32;

  bool get isSpeaking => _isSpeaking;

  Future<void> initialize() async {
    try {
      await _tts.setLanguage(AppConstants.ttsLanguage);
      await _tts.setSpeechRate(AppConstants.ttsSpeechRate);
      await _tts.setPitch(AppConstants.ttsPitch);
      await _tts.setVolume(AppConstants.ttsVolume);
      await _tts.setEngine('com.google.android.tts');

      _tts.setStartHandler(() => _isSpeaking = true);
      _tts.setCompletionHandler(() => _isSpeaking = false);
      _tts.setCancelHandler(() => _isSpeaking = false);
      _tts.setErrorHandler((message) {
        _isSpeaking = false;
        debugPrint('⚠️ TTS Error: $message');
      });
    } catch (e) {
      debugPrint('⚠️ Error initializing TTS: $e');
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  Future<void> speak(String text, {Esp32SpeechService? esp32Service}) async {
    await _initCompleter.future;
    if (text.trim().isEmpty) return;

    String textToSpeak = text.trim();
    String detectedLang = AppConstants.ttsLanguage;

    final match = RegExp(r'^\[(en|es)\]\s*').firstMatch(textToSpeak.toLowerCase());
    if (match != null) {
      detectedLang = match.group(1) == 'en' ? 'en-US' : 'es-CL';
      textToSpeak = textToSpeak.substring(match.end).trim();
    }

    await _tts.setLanguage(detectedLang);

    if (_isSpeaking) {
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 50));
    }

    if (esp32Service != null) {
      _activeEsp32 = esp32Service;
      await _speakThroughEsp32(textToSpeak, detectedLang, esp32Service);
    } else {
      // Modo nativo: altavoz del celular
      await _tts.speak(textToSpeak);
    }
  }

  /// Modo ESP32: Azure TTS en PCM 16 kHz 16-bit mono, enviado por BLE a la placa.
  Future<void> _speakThroughEsp32(String text, String lang, Esp32SpeechService esp32Service) async {
    if (EnvConfig.azureSpeechKey.isEmpty || EnvConfig.azureSpeechRegion.isEmpty) {
      debugPrint('⚠️ No hay API Keys configuradas para Azure TTS en Modo ESP32');
      return;
    }

    _isSpeaking = true;
    try {
      final voice = lang == 'en-US' ? _englishVoice : _spanishVoice;
      final response = await http
          .post(
            Uri.parse('https://${EnvConfig.azureSpeechRegion}.tts.speech.microsoft.com/cognitiveservices/v1'),
            headers: {
              'Ocp-Apim-Subscription-Key': EnvConfig.azureSpeechKey,
              'Content-Type': 'application/ssml+xml',
              'X-Microsoft-OutputFormat': 'raw-16khz-16bit-mono-pcm',
            },
            body: '<speak version="1.0" xml:lang="$lang"><voice xml:lang="$lang" name="$voice">'
                '${_escapeXml(text)}</voice></speak>',
          )
          .timeout(_cloudTtsTimeout);

      if (response.statusCode == 200) {
        // Toda la respuesta (todas sus frases) es un solo PCM de Azure y va en un solo envio.
        // Sin await: la placa ya puede ir sonando mientras termina de llegar.
        unawaited(esp32Service.sendAudioToEsp32(response.bodyBytes));
      } else {
        debugPrint('⚠️ Azure TTS Error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('⚠️ Error enviando TTS a ESP32: $e');
    } finally {
      _isSpeaking = false;
    }
  }

  // El texto viene del modelo: sin escapar, un "&" o "<" invalida el SSML y Azure responde 400.
  String _escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> stop() async {
    await _tts.stop();
    _activeEsp32?.stopAudio();
    _isSpeaking = false;
  }

  Future<void> speakStatus(String text, {Esp32SpeechService? esp32Service}) async {
    await _initCompleter.future;
    await _tts.setLanguage(AppConstants.ttsLanguage);
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 50));
    await speak(text, esp32Service: esp32Service);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}
