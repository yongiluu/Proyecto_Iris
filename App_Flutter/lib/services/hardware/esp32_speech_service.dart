import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/constants/env_config.dart';

class Esp32SpeechService {
  final String _ip;
  WebSocket? _channel;
  bool _isInitialized = false;
  
  // Callbacks para la UI
  VoidCallback? onRecordingStarted;
  VoidCallback? onRecordingStopped;
  
  // Buffer de audio
  final List<int> _audioBuffer = [];
  bool _isRecording = false;
  bool _isSendingAudio = false; // <-- Bandera para poder interrumpir el audio
  Timer? _thinkingTimer;
  
  Esp32SpeechService(this._ip);

  Future<void> initialize() async {
    try {
      _connectWebSocket(); // Se llama sin await para no bloquear la carga inicial de la UI
    } catch (e) {
      debugPrint('⚠️ Esp32SpeechService: Error inicial al conectar (se reintentará): $e');
    }
  }

  Future<void> _connectWebSocket() async {
    try {
      _channel = await WebSocket.connect('ws://$_ip:81/');
      _channel!.pingInterval = const Duration(seconds: 3);
      _isInitialized = true;
      debugPrint('🎙️ Esp32SpeechService: Conectado a WebSocket de ESP32');
      
      _channel!.listen(
        (message) {
          if (message is String) {
            debugPrint('📩 Comando ESP32: $message');
            if (message == 'CMD_PTT_START') {
              _isRecording = true;
              stopAudio(); // <-- Detenemos cualquier audio TTS que se estuviera enviando
              _audioBuffer.clear();
              onRecordingStarted?.call();
            } else if (message == 'CMD_PTT_STOP') {
              _isRecording = false;
              onRecordingStopped?.call(); // Avisa a la UI que comience a procesar
            }
          } else if (message is List<int>) {
            if (_isRecording) {
              _audioBuffer.addAll(message);
            }
          }
        },
        onDone: () {
           debugPrint('🔌 WebSocket cerrado por el servidor. Reconectando en 2s...');
           _isInitialized = false;
           Future.delayed(const Duration(seconds: 2), _connectWebSocket);
        },
        onError: (e) {
           debugPrint('❌ Error WebSocket: $e. Reconectando en 2s...');
           _isInitialized = false;
           Future.delayed(const Duration(seconds: 2), _connectWebSocket);
        },
      );
    } catch (e) {
      debugPrint('⚠️ Error al conectar WebSocket: $e. Reintentando en 3s...');
      _isInitialized = false;
      Future.delayed(const Duration(seconds: 3), _connectWebSocket);
    }
  }

  /// Envía audio crudo (PCM 16-bit) a la placa ESP32 para que lo reproduzca
  Future<void> sendAudioToEsp32(Uint8List pcmData) async {
    if (!_isInitialized || _channel == null || _channel!.readyState != WebSocket.open) return;

    _isSendingAudio = true;

    // 1. PROCESAMIENTO DE AUDIO (Control de Volumen)
    // El usuario indicó que sigue sonando un poco desgarrado.
    // Como el sonido ya no se corta, el "desgarro" actual es saturación ANALÓGICA del pequeño
    // amplificador I2S al intentar empujar demasiado volumen y quedarse sin corriente (o chocar con el techo de voltaje).
    // Solución: Como estará cerca del oído, reducimos el volumen digital al 35% aquí.
    // (La ESP32 lo multiplica por 2, por lo que el volumen final real será del 70%, 
    // completamente limpio y sin distorsión).
    final processedData = Uint8List(pcmData.length);
    final ByteData inData = ByteData.sublistView(pcmData);
    final ByteData outData = ByteData.sublistView(processedData);

    for (int i = 0; i < pcmData.length; i += 2) {
      if (i + 1 < pcmData.length) {
        int sample = inData.getInt16(i, Endian.little);
        
        // Convertimos a float
        double x = sample / 32768.0;
        
        // Volumen al 35% digital (que al multiplicarse por 2 en la ESP32, será 70% real)
        x = x * 0.35;
        
        // Volvemos a entero
        int outSample = (x * 32767.0).round();
        outData.setInt16(i, outSample, Endian.little);
      }
    }

    // 2. ENVÍO INTELIGENTE (Pacing con Stopwatch)
    // Para evitar que se corte a los 4/5 (Timeout de Ping por saturación) y 
    // evitar el sonido desgarrado por falta de datos (Starvation),
    // enviamos el audio manteniendo siempre exactamente 500ms de "ventaja" sobre el tiempo real.
    final stopwatch = Stopwatch()..start();
    const int chunkSize = 2048; // 64ms de audio a 16kHz
    
    for (int i = 0; i < processedData.length; i += chunkSize) {
      if (!_isSendingAudio || _channel!.readyState != WebSocket.open) break;

      int end = (i + chunkSize < processedData.length) ? i + chunkSize : processedData.length;
      _channel!.add(processedData.sublist(i, end));

      // Calculamos cuántos milisegundos de audio hemos enviado en total
      double sentAudioTimeMs = (end / 32000.0) * 1000.0;
      
      // Esperamos hasta que el tiempo real alcance al audio enviado menos 500ms
      // Esto asegura que la ESP32 siempre tenga 500ms de audio en su buffer (ni más, ni menos).
      while (stopwatch.elapsedMilliseconds < sentAudioTimeMs - 500) {
        if (!_isSendingAudio) break;
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }
    
    _isSendingAudio = false;
  }

  /// Detiene el envío de audio actual (ej. si el usuario presiona el botón para hablar)
  void stopAudio() {
    _isSendingAudio = false;
  }

  /// Inicia la reproducción periódica de un suave tono de "pensando" en la ESP32
  void startThinkingSound() {
    if (!_isInitialized || _channel == null || _channel!.readyState != WebSocket.open) return;
    _channel!.add('CMD_BEEP_THINKING');
    
    _thinkingTimer?.cancel();
    _thinkingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_channel!.readyState == WebSocket.open) {
        _channel!.add('CMD_BEEP_THINKING');
      } else {
        timer.cancel();
      }
    });
  }

  /// Detiene el sonido de "pensando"
  void stopThinkingSound() {
    _thinkingTimer?.cancel();
  }

  /// Retorna el texto transcrito del audio acumulado
  Future<String> stopListeningAndTranscribe() async {
    if (_audioBuffer.isEmpty) {
      debugPrint('⚠️ No hay audio grabado.');
      return '';
    }
    
    debugPrint('💾 Procesando audio de ${_audioBuffer.length} bytes...');
    
    // Convertir PCM crudo a WAV
    final wavBytes = _createWavHeader(_audioBuffer);
    
    // Enviar a Hugging Face Whisper
    return await _transcribeWithHuggingFace(wavBytes);
  }

  Uint8List _createWavHeader(List<int> pcmData) {
    int numFrames = pcmData.length ~/ 2;
    int numChannels = 1;
    int sampleRate = 16000;
    int byteRate = sampleRate * numChannels * 2;
    int blockAlign = numChannels * 2;
    int bitsPerSample = 16;
    
    var header = ByteData(44);
    // 'RIFF'
    header.setUint8(0, 82); header.setUint8(1, 73); header.setUint8(2, 70); header.setUint8(3, 70);
    header.setUint32(4, 36 + pcmData.length, Endian.little);
    // 'WAVE'
    header.setUint8(8, 87); header.setUint8(9, 65); header.setUint8(10, 86); header.setUint8(11, 69);
    // 'fmt '
    header.setUint8(12, 102); header.setUint8(13, 109); header.setUint8(14, 116); header.setUint8(15, 32);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // 'data'
    header.setUint8(36, 100); header.setUint8(37, 97); header.setUint8(38, 116); header.setUint8(39, 97);
    header.setUint32(40, pcmData.length, Endian.little);
    
    final b = BytesBuilder();
    b.add(header.buffer.asUint8List());
    b.add(pcmData);
    return b.toBytes();
  }

  Future<String> _transcribeWithHuggingFace(Uint8List wavBytes) async {
    final key = EnvConfig.huggingFaceApiKey.trim();
    
    if (key.isEmpty) {
      debugPrint('⚠️ Faltan credenciales de Hugging Face');
      return '';
    }

    try {
      final url = Uri.parse('https://router.huggingface.co/hf-inference/models/openai/whisper-large-v3-turbo');
      
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'audio/wav',
        },
        body: wavBytes,
      );
      
      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        final transcribed = result['text'] ?? '';
        debugPrint('🎙️ Transcripción (ESP32): $transcribed');
        return transcribed.toString().trim();
      } else {
        debugPrint('❌ Error Hugging Face Whisper: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('❌ Error enviando a Hugging Face: $e');
    }
    return '';
  }

  void dispose() {
    _thinkingTimer?.cancel();
    _channel?.close();
  }
}
