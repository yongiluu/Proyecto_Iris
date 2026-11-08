import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/data_collection/phone_capture.dart';
import 'camera_service.dart';

/// Detector de luz con la camara del celular: un tono mas agudo cuanta mas luz hay al centro de
/// la imagen. Misma escala que la placa (Hardware_ESP32/src/light_meter.cpp): nivel 0-100 con
/// raiz cuadrada perceptual y tono exponencial de 150 a 2400 Hz. Se apaga solo a los 3 minutos.
class PhoneLightMeter {
  PhoneLightMeter(this._camera);

  final CameraService _camera;
  static const MethodChannel _sound = MethodChannel('com.iris.visual.iris_app/sound');
  static const Duration autoOff = Duration(minutes: 3);
  static const int minHz = 150, maxHz = 2400;

  /// Nivel 0-100 mientras esta encendido; null apagado.
  final ValueNotifier<int?> level = ValueNotifier(null);
  bool get isOn => level.value != null || _running;

  bool _running = false;
  int _generation = 0;
  DateTime _startedAt = DateTime.now();

  /// [canCapture]: false mientras otra cosa usa la camara (una foto para la IA, por ejemplo).
  void start({bool Function()? canCapture}) {
    if (_running) return;
    _running = true;
    _startedAt = DateTime.now();
    final generation = ++_generation;
    unawaited(_loop(generation, canCapture));
  }

  void stop() {
    _running = false;
    _generation++;
    level.value = null;
  }

  Future<void> _loop(int generation, bool Function()? canCapture) async {
    while (_running && generation == _generation) {
      if (DateTime.now().difference(_startedAt) > autoOff) {
        stop();
        return;
      }
      if (canCapture == null || canCapture()) {
        final jpeg = await _camera.captureSingleFrame();
        if (jpeg != null && generation == _generation) {
          final frame = await PhoneCapture.jpegToGray(jpeg, size: 32);
          final value = levelFromGray(frame.pixels, 32);
          level.value = value;
          unawaited(_sound
              .invokeMethod('pitch', {'hz': frequencyFor(value), 'ms': 140})
              .catchError((_) {}));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Brillo medio del cuadrado central (la mitad del lado) -> nivel 0-100 perceptual.
  @visibleForTesting
  static int levelFromGray(Uint8List pixels, int size) {
    final from = size ~/ 4, to = size - size ~/ 4;
    var sum = 0, count = 0;
    for (var y = from; y < to; y++) {
      for (var x = from; x < to; x++) {
        sum += pixels[y * size + x];
        count++;
      }
    }
    final mean = count == 0 ? 0.0 : sum / count / 255.0;
    return (math.sqrt(mean) * 100).round().clamp(0, 100);
  }

  /// 0 -> 150 Hz, 100 -> 2400 Hz, exponencial (cada paso suena igual de distinto).
  static int frequencyFor(int level) =>
      (minHz * math.pow(maxHz / minHz, level.clamp(0, 100) / 100)).round();

  void dispose() => stop();
}
