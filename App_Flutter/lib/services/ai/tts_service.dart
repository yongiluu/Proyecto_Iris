import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';
import '../../core/constants/env_config.dart';
import '../hardware/esp32_speech_service.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  final Completer<void> _initCompleter = Completer<void>();

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

      _initCompleter.complete();
    } catch (e) {
      debugPrint('⚠️ Error initializing TTS: $e');
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
      // ─── MODO ESP32: Cloud TTS (Azure) directo a PCM 16kHz 16-bit Mono ───
      _isSpeaking = true;
      try {
        if (EnvConfig.azureSpeechKey.isNotEmpty && EnvConfig.azureSpeechRegion.isNotEmpty) {
          final voiceName = detectedLang == 'en-US' ? 'en-US-AriaNeural' : 'es-ES-ElviraNeural';
          final response = await http.post(
            Uri.parse('https://${EnvConfig.azureSpeechRegion}.tts.speech.microsoft.com/cognitiveservices/v1'),
            headers: {
              'Ocp-Apim-Subscription-Key': EnvConfig.azureSpeechKey,
              'Content-Type': 'application/ssml+xml',
              'X-Microsoft-OutputFormat': 'raw-16khz-16bit-mono-pcm',
            },
            body: '<speak version="1.0" xml:lang="$detectedLang"><voice xml:lang="$detectedLang" name="$voiceName">$textToSpeak</voice></speak>',
          );

          if (response.statusCode == 200) {
            esp32Service.sendAudioToEsp32(response.bodyBytes);
          } else {
            debugPrint('⚠️ Azure TTS Error: ${response.statusCode} - ${response.body}');
          }
        } else {
          debugPrint('⚠️ No hay API Keys configuradas para Azure TTS en Modo ESP32');
        }
      } catch (e) {
        debugPrint('⚠️ Error enviando TTS a ESP32: $e');
      }
      _isSpeaking = false;
    } else {
      // ─── MODO NATIVO: Reproducir por el altavoz del celular ───
      await _tts.speak(textToSpeak);
    }
  }

  Future<void> stop() async {
    await _tts.stop();
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
