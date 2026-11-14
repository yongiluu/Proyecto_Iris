import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:record/record.dart';

import '../../services/hardware/camera_service.dart';
import '../../services/hardware/esp32_speech_service.dart';

/// Recoleccion con la camara y el microfono DEL CELULAR, para avanzar sin el prototipo.
///
/// Las fotos se convierten a lo que ve el modelo de escenas de la placa (160x120 a color, 4:3 como
/// la camara de la placa, recortando al centro) y el audio se graba a 16 kHz mono PCM 16-bit, sin
/// ganancia automatica ni supresion de ruido. No es el mismo sensor que la placa, pero si las mismas
/// escenas: el modelo aprende tus calles, puertas y escaleras, y despues basta poco fine-tuning con
/// la placa.
class PhoneCapture {
  static const int frameWidth = 160;
  static const int frameHeight = 120;

  final CameraService camera;
  final AudioRecorder _recorder = AudioRecorder();

  PhoneCapture(this.camera);

  bool get cameraReady => camera.isInitialized;

  /// Foto del celular convertida a lo que ve el modelo de escenas (160x120 RGB).
  Future<CameraFrame?> takeColorFrame() async {
    final jpeg = await camera.captureSingleFrame();
    if (jpeg == null) return null;
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: 640);
    return _colorFromImage((await codec.getNextFrame()).image);
  }

  /// Frame 160x120 RGB + la misma foto a color en JPEG (`colorShortSide` px de lado corto),
  /// para las misiones de cercania que se etiquetan con un modelo de profundidad en el PC.
  Future<({CameraFrame frame, Uint8List colorJpeg})?> takeFrameAndJpeg({int colorShortSide = 320}) async {
    final jpeg = await camera.captureSingleFrame();
    if (jpeg == null) return null;
    final buffer = await ui.ImmutableBuffer.fromUint8List(jpeg);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      final scale = colorShortSide / math.min(w, h);
      return ui.TargetImageSize(width: (w * scale).round(), height: (h * scale).round());
    });
    final image = (await codec.getNextFrame()).image;
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer;
    final color = img.Image.fromBytes(
        width: image.width, height: image.height, bytes: rgba, numChannels: 4, order: img.ChannelOrder.rgba);
    final colorJpeg = img.encodeJpg(color, quality: 90);
    final frame = await _colorFromImage(image);
    return (frame: frame, colorJpeg: colorJpeg);
  }

  static Future<CameraFrame> jpegToGray(Uint8List jpeg, {int size = 96}) async {
    // Decodificar ya reducido (solo ancho: se mantiene la proporcion) para no gastar memoria.
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: 320);
    return _grayFromImage((await codec.getNextFrame()).image, size);
  }

  /// Dibuja `source` de `image` reducido a `width` x `height` y devuelve sus pixeles RGBA. Libera `image`.
  static Future<Uint8List> _resizeToRgba(ui.Image image, Rect source, int width, int height) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      source,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final small = await recorder.endRecording().toImage(width, height);
    final rgba = (await small.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    image.dispose();
    small.dispose();
    return rgba;
  }

  /// Recorte central 4:3 reducido a 160x120 RGB. Libera `image`.
  static Future<CameraFrame> _colorFromImage(ui.Image image) async {
    const aspect = frameWidth / frameHeight;
    double w = image.width.toDouble(), h = image.height.toDouble();
    if (w / h > aspect) {
      w = h * aspect;
    } else {
      h = w / aspect;
    }
    final source = Rect.fromLTWH((image.width - w) / 2, (image.height - h) / 2, w, h);
    final rgba = await _resizeToRgba(image, source, frameWidth, frameHeight);
    final rgb = Uint8List(frameWidth * frameHeight * 3);
    for (int i = 0; i < frameWidth * frameHeight; i++) {
      rgb[i * 3] = rgba[i * 4];
      rgb[i * 3 + 1] = rgba[i * 4 + 1];
      rgb[i * 3 + 2] = rgba[i * 4 + 2];
    }
    return CameraFrame(frameWidth, frameHeight, rgb, channels: 3);
  }

  /// Cuadrado central reducido a `size` x `size` en grises. Libera `image`.
  static Future<CameraFrame> _grayFromImage(ui.Image image, int size) async {
    final side = math.min(image.width, image.height).toDouble();
    final source = Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side, side);
    final rgba = await _resizeToRgba(image, source, size, size);

    final gray = Uint8List(size * size);
    for (int i = 0; i < gray.length; i++) {
      final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
      gray[i] = ((299 * r + 587 * g + 114 * b) / 1000).round();
    }
    return CameraFrame(size, size, gray);
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
