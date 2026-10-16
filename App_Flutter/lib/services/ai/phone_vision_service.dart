import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../features/data_collection/phone_capture.dart';
import '../hardware/camera_service.dart';
import '../hardware/esp32_speech_service.dart' show GrayFrame;

typedef VisionCallback = void Function(String label, int percent);

/// El mismo modelo Edge AI de vision de la placa, corriendo en el celular (modo "Celular").
///
/// Replica Hardware_ESP32/src/tflite_vision.cpp: foto 96x96 grises (PhoneCapture.jpegToGray), red
/// int8 1 vez por segundo, promedio con el frame anterior, umbral 0,75 y sin repetir la misma clase
/// antes de 8 s. Cada 10 s manda la clase mas vista como contexto, igual que CMD_VISION_CONTEXT.
/// Todo es local: no usa internet.
class PhoneVisionService {
  static const String modelAsset = 'assets/vision_scenes_int8.tflite';
  static const List<String> labels = ['nada', 'persona', 'vehiculo', 'escalera', 'puerta'];
  static const List<bool> isAlert = [false, true, true, true, true];
  static const double alertThreshold = 0.75; // kVisionAlertThreshold
  static const int imageSize = 96;
  static const Duration framePeriod = Duration(seconds: 1);
  static const Duration eventCooldown = Duration(seconds: 8); // VISION_EVENT_COOLDOWN_MS
  static const Duration contextPeriod = Duration(seconds: 10); // AMBIENT_CONTEXT_PERIOD_MS

  VisionCallback? onEvent;
  VisionCallback? onContext;

  Interpreter? _interpreter;
  final Uint8List _pixelToInput = Uint8List(256); // int8 guardado como byte
  double _outputScale = 1;
  int _outputZeroPoint = 0;

  final List<double> _previousScores = List.filled(labels.length, 0);
  final List<DateTime?> _lastEvent = List.filled(labels.length, null);
  final List<int> _contextCounts = List.filled(labels.length, 0);
  DateTime _lastContext = DateTime.now();

  bool _running = false;
  int _generation = 0; // un stop()+start() rapido no debe dejar dos ciclos corriendo
  Completer<void>? _inFlight;

  bool get isLoaded => _interpreter != null;
  bool get isRunning => _running;

  Future<void> load() async {
    final interpreter = await Interpreter.fromAsset(modelAsset, options: InterpreterOptions()..threads = 2);
    final input = interpreter.getInputTensor(0);
    final output = interpreter.getOutputTensor(0);
    if (input.type != TensorType.int8 ||
        input.numElements() != imageSize * imageSize ||
        output.type != TensorType.int8 ||
        output.shape.last != labels.length) {
      interpreter.close();
      throw StateError('El modelo de vision no calza con 96x96x1 int8 -> ${labels.length} clases');
    }

    final inScale = input.params.scale;
    final inZero = input.params.zeroPoint;
    for (int p = 0; p < 256; p++) {
      _pixelToInput[p] = quantizePixel(p, inScale, inZero) & 0xFF;
    }
    _outputScale = output.params.scale;
    _outputZeroPoint = output.params.zeroPoint;
    _interpreter = interpreter;
    debugPrint('[Vision IA celular] Listo: ${labels.length} clases');
  }

  /// Pixel 0..255 -> int8 de entrada, identico a kVisionInputLut de la placa (export_model.input_lut):
  /// aritmetica float32 y redondeo a par como np.round. Con esta escala muchos pixeles caen justo en
  /// x,5, y un `round()` comun daria 1 de diferencia en la mitad de ellos.
  static int quantizePixel(int pixel, double scale, int zeroPoint) {
    final f = Float32List(1);
    double f32(double v) {
      f[0] = v;
      return f[0];
    }

    // Entrada float del modelo: pixel / 127.5 - 1 (augment.to_model_input).
    final x = f32(f32(pixel / 127.5) - 1.0);
    final v = f32(f32(x / f32(scale)) + zeroPoint);
    final floor = v.floorToDouble();
    final diff = v - floor;
    final q = (diff > 0.5 || (diff == 0.5 && floor % 2 != 0)) ? floor + 1 : floor;
    return q.toInt().clamp(-128, 127);
  }

  /// Puntajes 0..1 de cada clase para una imagen 96x96 en grises.
  List<double> classify(GrayFrame frame) {
    final interpreter = _interpreter!;
    final pixels = frame.pixels;
    final input = Uint8List(pixels.length);
    for (int i = 0; i < pixels.length; i++) {
      input[i] = _pixelToInput[pixels[i]];
    }
    interpreter.getInputTensor(0).data = input;
    interpreter.invoke();
    final raw = Int8List.view(interpreter.getOutputTensor(0).data.buffer);
    return [for (int i = 0; i < labels.length; i++) (raw[i] - _outputZeroPoint) * _outputScale];
  }

  /// Saca una foto por segundo mientras `canCapture()` sea true (ej. no mientras se habla con la IA).
  void start(CameraService camera, bool Function() canCapture) {
    if (_running || _interpreter == null) return;
    _running = true;
    _resetSmoothing();
    _loop(camera, canCapture, ++_generation);
  }

  void stop() {
    _running = false;
    _resetSmoothing();
  }

  /// Espera a que termine la foto en curso, para no chocar con otra captura de la camara.
  Future<void> waitIdle() => _inFlight?.future ?? Future.value();

  Future<void> _loop(CameraService camera, bool Function() canCapture, int generation) async {
    bool alive() => _running && generation == _generation;
    while (alive()) {
      final started = DateTime.now();
      if (canCapture() && camera.isInitialized) {
        final done = _inFlight = Completer<void>();
        try {
          final jpeg = await camera.captureSingleFrame();
          if (jpeg != null && alive()) {
            final frame = await PhoneCapture.jpegToGray(jpeg, size: imageSize);
            if (alive()) _handleScores(classify(frame));
          }
        } catch (e) {
          debugPrint('[Vision IA celular] Error: $e');
        } finally {
          done.complete();
          _inFlight = null;
        }
      } else {
        // Sin fotos seguidas (ej. tras hablar con la IA) el promedio con un frame viejo no sirve.
        _resetSmoothing();
      }
      final wait = framePeriod - DateTime.now().difference(started);
      await Future.delayed(wait.isNegative ? Duration.zero : wait);
    }
  }

  void _handleScores(List<double> scores) {
    _updateContext(scores);
    // Promedio con el frame anterior (~1 s antes) para no avisar por un frame suelto.
    int best = -1;
    double bestScore = 0;
    for (int i = 0; i < labels.length; i++) {
      final smoothed = 0.5 * (scores[i] + _previousScores[i]);
      _previousScores[i] = scores[i];
      if (isAlert[i] && smoothed > bestScore) {
        bestScore = smoothed;
        best = i;
      }
    }
    if (best < 0 || bestScore < alertThreshold) return;

    final now = DateTime.now();
    final last = _lastEvent[best];
    if (last != null && now.difference(last) < eventCooldown) return;
    _lastEvent[best] = now;

    final percent = (bestScore * 100).round();
    debugPrint('[Vision IA celular] Aviso: ${labels[best]} ($percent%)');
    onEvent?.call(labels[best], percent);
  }

  // Resumen periodico: clase mas vista desde el ultimo resumen.
  void _updateContext(List<double> scores) {
    int top = 0;
    for (int i = 1; i < labels.length; i++) {
      if (scores[i] > scores[top]) top = i;
    }
    _contextCounts[top]++;

    final now = DateTime.now();
    if (now.difference(_lastContext) < contextPeriod) return;
    _lastContext = now;
    int best = 0, total = 0;
    for (int i = 0; i < labels.length; i++) {
      total += _contextCounts[i];
      if (_contextCounts[i] > _contextCounts[best]) best = i;
    }
    if (total > 0) onContext?.call(labels[best], _contextCounts[best] * 100 ~/ total);
    _contextCounts.fillRange(0, _contextCounts.length, 0);
  }

  void _resetSmoothing() => _previousScores.fillRange(0, _previousScores.length, 0);

  void dispose() {
    stop();
    _interpreter?.close();
    _interpreter = null;
  }
}
