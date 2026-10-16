import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:record/record.dart';

import '../../services/hardware/camera_service.dart';
import '../../services/hardware/esp32_speech_service.dart';

/// Recoleccion con la camara y el microfono DEL CELULAR, para avanzar sin el prototipo.
///
/// Las fotos se convierten igual que la camara de la placa (cuadrado central, 96x96, grises) y el
/// audio se graba a 16 kHz mono PCM 16-bit, sin ganancia automatica ni supresion de ruido.
/// No es el mismo sensor que la placa, pero si las mismas escenas: el modelo aprende tus calles,
/// puertas y escaleras, y despues basta poco fine-tuning con la placa.
class PhoneCapture {
  final CameraService camera;
  final AudioRecorder _recorder = AudioRecorder();

  PhoneCapture(this.camera);

  bool get cameraReady => camera.isInitialized;

  /// Foto del celular convertida a lo que ve el modelo de vision (96x96 grises).
  Future<GrayFrame?> takeGrayFrame({int size = 96}) async {
    final jpeg = await camera.captureSingleFrame();
    if (jpeg == null) return null;
    return jpegToGray(jpeg, size: size);
  }

  static Future<GrayFrame> jpegToGray(Uint8List jpeg, {int size = 96}) async {
    // Decodificar ya reducido (solo ancho: se mantiene la proporcion) para no gastar memoria.
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: 320);
    final image = (await codec.getNextFrame()).image;
    final side = math.min(image.width, image.height).toDouble();
    final source = Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side, side);

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      source,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final small = await recorder.endRecording().toImage(size, size);
    final rgba = (await small.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    image.dispose();
    small.dispose();

    final gray = Uint8List(size * size);
    for (int i = 0; i < gray.length; i++) {
      final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
      gray[i] = ((299 * r + 587 * g + 114 * b) / 1000).round();
    }
    return GrayFrame(size, size, gray);
  }

  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Empieza a grabar un WAV en `path`. Devuelve false si no hay permiso o falla.
  Future<bool> startAudio(String path) async {
    if (!await _recorder.hasPermission()) return false;
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
      path: path,
    );
    return true;
  }

  /// Nivel en dBFS cada 200 ms mientras graba.
  Stream<double> audioLevels() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 200)).map((a) => a.current);

  Future<String?> stopAudio() => _recorder.stop();

  Future<void> cancelAudio() => _recorder.cancel();

  Future<void> dispose() => _recorder.dispose();
}
