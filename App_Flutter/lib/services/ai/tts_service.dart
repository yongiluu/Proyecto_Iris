import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/app_constants.dart';
import '../../core/constants/env_config.dart';
import '../hardware/esp32_speech_service.dart';
import '../backend/backend_service.dart';

/// Hasta donde va la voz de Iris en el texto que esta diciendo. La pantalla lo usa para ir
/// escribiendo la respuesta al ritmo de la voz (tipo karaoke).
@immutable
class SpeechProgress {
  const SpeechProgress(this.text, this.end, {this.done = false});

  /// Nada sonando.
  static const SpeechProgress idle = SpeechProgress('', 0, done: true);

  /// Texto que se esta diciendo (ya sin la etiqueta [es]/[en]).
  final String text;

  /// Caracteres ya dichos (fin de la palabra actual).
  final int end;

  /// true = termino, se corto o no se pudo decir: se muestra completo.
  final bool done;

  int get visibleEnd => done ? text.length : end.clamp(0, text.length);

  SpeechProgress finished() => SpeechProgress(text, text.length, done: true);

  @override
  bool operator ==(Object other) =>
      other is SpeechProgress && other.text == text && other.end == end && other.done == done;

  @override
  int get hashCode => Object.hash(text, end, done);
}

class TtsService {
  static const Duration _cloudTtsTimeout = Duration(seconds: 20);
  static const String _spanishVoice = 'es-CL-CatalinaNeural';
  static const String _englishVoice = 'en-US-AriaNeural';

  /// Voz de Google en español a velocidad normal (rate 0.5 de flutter_tts = 1.0 de Android).
  static const double _charsPerSecondAtNormalRate = 14;

  static final RegExp _langTag = RegExp(r'^\[(en|es)\]\s*', caseSensitive: false);

  final FlutterTts _tts = FlutterTts();
  final Completer<void> _initCompleter = Completer<void>();
  bool _isSpeaking = false;
  Esp32SpeechService? _activeEsp32;

  /// Progreso de la voz actual (cualquier camino: celular, servidor o placa).
  final ValueNotifier<SpeechProgress> progress = ValueNotifier(SpeechProgress.idle);

  /// Texto que esta diciendo el motor del celular (para ignorar avisos de una frase anterior).
  String? _nativeText;
  bool _nativeHasRealProgress = false;
  Timer? _estimateTimer;

  bool get isSpeaking => _isSpeaking;

  /// Lo que se muestra en pantalla de una respuesta: sin la etiqueta de idioma y sin espacios
  /// sobrantes. Es exactamente el texto que reporta [progress].
  static String displayText(String text) => text.trim().replaceFirst(_langTag, '').trim();

  Future<void> initialize() async {
    try {
      await _tts.setLanguage(AppConstants.ttsLanguage);
      await _tts.setSpeechRate(AppConstants.ttsSpeechRate);
      await _tts.setPitch(AppConstants.ttsPitch);
      await _tts.setVolume(AppConstants.ttsVolume);
      await _tts.setEngine('com.google.android.tts');

      _tts.setStartHandler(() => _isSpeaking = true);
      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _finishNative();
      });
      _tts.setCancelHandler(() {
        _isSpeaking = false;
        _finishNative();
      });
      _tts.setErrorHandler((message) {
        _isSpeaking = false;
        _finishNative();
        debugPrint('⚠️ TTS Error: $message');
      });
      // Android avisa cada palabra que empieza a decir: la pantalla escribe hasta ahi.
      _tts.setProgressHandler((text, start, end, word) {
        final current = progress.value;
        if (_nativeText == null || current.text != _nativeText || current.done) return;
        _nativeHasRealProgress = true;
        _estimateTimer?.cancel();
        if (end > current.end) progress.value = SpeechProgress(current.text, end);
      });
    } catch (e) {
      debugPrint('⚠️ Error initializing TTS: $e');
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  Future<void> speak(String text, {Esp32SpeechService? esp32Service}) async {
    if (text.trim().isEmpty) return;

    String textToSpeak = text.trim();
    String detectedLang = AppConstants.ttsLanguage;

    final match = RegExp(r'^\[(en|es)\]\s*').firstMatch(textToSpeak.toLowerCase());
    if (match != null) {
      detectedLang = match.group(1) == 'en' ? 'en-US' : 'es-CL';
      textToSpeak = textToSpeak.substring(match.end).trim();
    }

    // Antes del primer await: asi la pantalla ya sabe en el mismo frame que este texto va a sonar
    // (y no lo muestra completo de golpe).
    _estimateTimer?.cancel();
    _nativeText = null;
    progress.value = SpeechProgress(textToSpeak, 0);

    await _initCompleter.future;
    await _tts.setLanguage(detectedLang);

    if (_isSpeaking) {
      await _tts.stop();
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Otro speak() empezo mientras esperabamos: ese manda.
    if (progress.value.text != textToSpeak || progress.value.done) return;

    if (esp32Service != null) {
      _activeEsp32 = esp32Service;
      await _speakThroughEsp32(textToSpeak, detectedLang, esp32Service);
    } else {
      // Modo nativo: altavoz del celular
      _nativeText = textToSpeak;
      _nativeHasRealProgress = false;
      await _tts.speak(textToSpeak);
      // Si el motor no avisa palabra por palabra, se estima por tiempo. El primer aviso real
      // cancela la estimacion.
      if (!_nativeHasRealProgress && progress.value.text == textToSpeak && !progress.value.done) {
        _startEstimate(textToSpeak, charsPerSecond: _nativeCharsPerSecond);
      }
    }
  }

  /// Igual que [speak], pero espera a que la voz termine (o se corte). Para guiar paso a paso
  /// ("Foto 1... gira un poco la cara").
  Future<void> speakAndWait(String text, {Esp32SpeechService? esp32Service}) async {
    await speak(text, esp32Service: esp32Service);
    final spoken = displayText(text);
    bool finished() => progress.value.text != spoken || progress.value.done;
    if (finished()) return;
    final completer = Completer<void>();
    void listener() {
      if (finished() && !completer.isCompleted) completer.complete();
    }

    progress.addListener(listener);
    try {
      // Tope por si el motor nunca avisa que termino.
      final limit = Duration(milliseconds: 3000 + (spoken.length / 6 * 1000).round());
      await completer.future.timeout(limit, onTimeout: () {});
    } finally {
      progress.removeListener(listener);
    }
  }

  double get _nativeCharsPerSecond => _charsPerSecondAtNormalRate * (AppConstants.ttsSpeechRate / 0.5);

  void _finishNative() {
    final current = progress.value;
    if (_nativeText == null || current.text != _nativeText || current.done) return;
    _estimateTimer?.cancel();
    progress.value = current.finished();
  }

  void _finishCurrent(String text) {
    final current = progress.value;
    if (current.text != text || current.done) return;
    _estimateTimer?.cancel();
    progress.value = current.finished();
  }

  /// Avanza palabra por palabra segun el tiempo (para los caminos sin aviso de palabras: voz de
  /// la placa o motores que no lo soportan).
  void _startEstimate(String text, {required double charsPerSecond}) {
    _estimateTimer?.cancel();
    if (charsPerSecond <= 0 || text.isEmpty) {
      _finishCurrent(text);
      return;
    }
    final watch = Stopwatch()..start();
    _estimateTimer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      final current = progress.value;
      if (current.text != text || current.done) {
        timer.cancel();
        return;
      }
      final chars = (watch.elapsedMilliseconds / 1000 * charsPerSecond).floor();
      if (chars >= text.length) {
        timer.cancel();
        progress.value = current.finished();
        return;
      }
      final end = wordEndAt(text, chars);
      if (end > current.end) progress.value = SpeechProgress(text, end);
    });
  }

  /// Fin de la palabra que contiene la posicion [index] (para no cortar palabras a la mitad).
  @visibleForTesting
  static int wordEndAt(String text, int index) {
    if (index <= 0) return 0;
    if (index >= text.length) return text.length;
    var i = index;
    while (i < text.length && text[i].trim().isNotEmpty) {
      i++;
    }
    return i;
  }

  /// Modo ESP32: Azure TTS en PCM 16 kHz 16-bit mono, enviado por BLE a la placa.
  Future<void> _speakThroughEsp32(String text, String lang, Esp32SpeechService esp32Service) async {
    // Con cuenta: la voz se genera en el servidor (la llave de Azure Speech no esta en el celular).
    if (BackendService.instance.useServer) {
      _isSpeaking = true;
      try {
        final pcm = await BackendService.instance.boardVoice(text, lang: lang == 'en-US' ? 'en-US' : 'es-CL');
        if (pcm != null) {
          unawaited(esp32Service.sendAudioToEsp32(pcm));
          _estimateFromPcm(text, pcm.length);
        } else {
          _finishCurrent(text);
        }
      } catch (_) {
        _finishCurrent(text);
        rethrow;
      } finally {
        _isSpeaking = false;
      }
      return;
    }
    if (EnvConfig.azureSpeechKey.isEmpty || EnvConfig.azureSpeechRegion.isEmpty) {
      debugPrint('⚠️ No hay API Keys configuradas para Azure TTS en Modo ESP32');
      _finishCurrent(text);
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
        _estimateFromPcm(text, response.bodyBytes.length);
      } else {
        debugPrint('⚠️ Azure TTS Error: ${response.statusCode} - ${response.body}');
        _finishCurrent(text);
      }
    } catch (e) {
      debugPrint('⚠️ Error enviando TTS a ESP32: $e');
      _finishCurrent(text);
    } finally {
      _isSpeaking = false;
    }
  }

  /// PCM 16 kHz 16-bit mono = 32 bytes por milisegundo: la duracion exacta del audio.
  void _estimateFromPcm(String text, int pcmBytes) {
    final ms = math.max(1, pcmBytes ~/ 32);
    _startEstimate(text, charsPerSecond: text.length / (ms / 1000));
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
    // Cortada: se muestra completa para poder leerla.
    _estimateTimer?.cancel();
    if (!progress.value.done) progress.value = progress.value.finished();
  }

  Future<void> speakStatus(String text, {Esp32SpeechService? esp32Service}) async {
    await _initCompleter.future;
    await _tts.setLanguage(AppConstants.ttsLanguage);
    await _tts.stop();
    await Future.delayed(const Duration(milliseconds: 50));
    await speak(text, esp32Service: esp32Service);
  }

  Future<void> dispose() async {
    _estimateTimer?.cancel();
    await _tts.stop();
  }
}
