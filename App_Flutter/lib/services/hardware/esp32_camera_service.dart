import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class Esp32CameraService {
  final String _ip;
  Timer? _streamTimer;
  Uint8List? _latestFrame;
  
  /// Permite a la UI escuchar cambios en el frame para dibujar el video fluido
  final ValueNotifier<Uint8List?> frameNotifier = ValueNotifier(null);
  
  bool _isStreaming = false;

  Esp32CameraService(this._ip);

  Future<void> initialize() async {
    startStreaming();
  }

  void startStreaming() {
    if (_isStreaming) return;
    _isStreaming = true;
    
    // Obtenemos un frame de la ESP32 cada 200ms (~5 FPS)
    _streamTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) async {
      try {
        final url = Uri.parse('http://$_ip/capture?t=${DateTime.now().millisecondsSinceEpoch}');
        final response = await http.get(url).timeout(const Duration(milliseconds: 1000));
        
        if (response.statusCode == 200) {
          _latestFrame = response.bodyBytes;
          frameNotifier.value = _latestFrame;
        }
      } catch (e) {
        // Ignoramos errores de red silenciosamente para que la UI no colapse si se pierden frames
      }
    });
  }

  void stopStreaming() {
    _isStreaming = false;
    _streamTimer?.cancel();
  }

  /// Retorna el último frame capturado. Inmediato, sin latencia.
  Future<Uint8List?> captureSingleFrame() async {
    return _latestFrame;
  }

  Future<void> dispose() async {
    stopStreaming();
    frameNotifier.dispose();
  }
}
