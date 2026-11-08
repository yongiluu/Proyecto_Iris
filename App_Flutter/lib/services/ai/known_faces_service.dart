import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Una cara encontrada en la foto y, si la conocemos, de quien es.
class FaceMatch {
  const FaceMatch({required this.name, required this.similarity, required this.position});

  /// null = persona desconocida.
  final String? name;
  final double similarity;

  /// "a tu izquierda", "al frente", "a tu derecha".
  final String position;
}

/// Personas conocidas, 100 % en el celular y sin internet: "Recuerda a Raul" guarda la huella de
/// su cara y despues, al apuntar el celular, Iris dice "Aqui esta Raul".
///
/// 1. ML Kit encuentra las caras (y los ojos) en la foto.
/// 2. Cada cara se endereza con la linea de los ojos, se recorta y se reduce a la entrada del modelo.
/// 3. El modelo (assets/face_embedder.tflite, ver ML_Training/faces/README.md) da un vector.
/// 4. Se compara (coseno) con los vectores guardados de cada persona.
///
/// PRIVACIDAD: no se guardan fotos, solo los vectores (no se puede rehacer la cara con ellos), en
/// un archivo de la app que no sale del celular. "Olvida a Raul" los borra.
class KnownFacesService {
  static const String modelAsset = 'assets/face_embedder.tflite';
  static const String _fileName = 'personas_conocidas.json';

  // ─── Contrato del modelo (ML_Training/faces/README.md) ───
  static int inputSize = 112;
  static bool inputIsBgr = false;
  static double inputMean = 127.5, inputStd = 128.0; // (pixel - mean) / std
  /// Margen alrededor de la caja de ML Kit antes de recortar (fraccion del lado).
  static double cropMargin = 0.0;

  /// Coseno minimo para decir que es esa persona. Mas alto = menos confusiones, mas "no se".
  static double matchThreshold = 0.40;

  /// Huellas por persona: varias fotos (luz, angulo) reconocen mejor.
  static const int maxSamplesPerPerson = 12;

  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate, enableLandmarks: true, minFaceSize: 0.08),
  );
  Interpreter? _interpreter;
  final Map<String, List<List<double>>> _people = {};
  bool _loaded = false;

  bool get isAvailable => _interpreter != null;
  List<String> get names => _people.keys.toList()..sort();
  int samplesOf(String name) => _people[_key(name)]?.length ?? 0;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _interpreter = await Interpreter.fromAsset(modelAsset, options: InterpreterOptions()..threads = 2);
      final shape = _interpreter!.getInputTensor(0).shape;
      if (shape.length == 4) inputSize = shape[1] == 3 ? shape[2] : shape[1];
    } catch (e) {
      debugPrint('[Personas] Sin modelo de caras ($modelAsset): $e');
    }
    try {
      final file = await _file();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final entry in data.entries) {
          _people[entry.key] = [
            for (final v in entry.value as List) [for (final x in v as List) (x as num).toDouble()],
          ];
        }
      }
    } catch (e) {
      debugPrint('[Personas] No se pudo leer la lista: $e');
    }
  }

  /// Guarda la cara mas grande de la foto como [name]. Devuelve cuantas huellas tiene ahora,
  /// 0 si no habia cara, -1 si hay mas de una cara del mismo tamaño (no sabemos cual es).
  Future<int> enroll(String name, Uint8List jpeg) async {
    final faces = await _embedFaces(jpeg);
    if (faces.isEmpty) return 0;
    faces.sort((a, b) => b.area.compareTo(a.area));
    if (faces.length > 1 && faces[1].area > faces[0].area * 0.6) return -1;
    final samples = _people.putIfAbsent(_key(name), () => []);
    samples.add(faces.first.embedding);
    if (samples.length > maxSamplesPerPerson) samples.removeAt(0);
    await _save();
    return samples.length;
  }

  Future<bool> forget(String name) async {
    final removed = _people.remove(_key(name)) != null;
    if (removed) await _save();
    return removed;
  }

  /// Caras de la foto, de izquierda a derecha, con su nombre si las conocemos.
  Future<List<FaceMatch>> recognize(Uint8List jpeg) async {
    final faces = await _embedFaces(jpeg);
    faces.sort((a, b) => a.centerX.compareTo(b.centerX));
    return [
      for (final face in faces) _match(face),
    ];
  }

  /// Frase para decir en voz alta.
  static String describe(List<FaceMatch> matches) {
    if (matches.isEmpty) return 'No veo a nadie. Apunta el celular a la cara de la persona.';
    final known = matches.where((m) => m.name != null).toList();
    final unknown = matches.length - known.length;
    final parts = <String>[for (final m in known) '${m.name} ${m.position}'];
    if (unknown == 1) parts.add(known.isEmpty ? 'una persona que no conozco' : 'otra persona que no conozco');
    if (unknown > 1) parts.add('$unknown personas que no conozco');
    if (known.isEmpty) return 'Veo ${parts.join(' y ')}.';
    return 'Aqui esta ${_joinSpanish(parts)}.';
  }

  static String _joinSpanish(List<String> parts) =>
      parts.length <= 1 ? parts.join() : '${parts.sublist(0, parts.length - 1).join(', ')} y ${parts.last}';

  FaceMatch _match(_Face face) {
    String? best;
    double bestScore = -1;
    for (final entry in _people.entries) {
      // Se compara con cada huella y se queda con la mejor (mas robusto que el promedio con pocas fotos).
      for (final sample in entry.value) {
        final score = _cosine(face.embedding, sample);
        if (score > bestScore) {
          bestScore = score;
          best = entry.key;
        }
      }
    }
    return FaceMatch(
      name: bestScore >= matchThreshold ? best : null,
      similarity: bestScore,
      position: face.centerX < 0.36 ? 'a tu izquierda' : (face.centerX > 0.64 ? 'a tu derecha' : 'al frente'),
    );
  }

  Future<List<_Face>> _embedFaces(Uint8List jpeg) async {
    final interpreter = _interpreter;
    if (interpreter == null) return [];
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return [];
    final image = img.bakeOrientation(decoded); // la foto del celular viene rotada en el EXIF

    // ML Kit lee la foto desde un archivo (ya derecha, para que las cajas calcen con `image`).
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/iris_caras_${DateTime.now().microsecondsSinceEpoch}.jpg');
    List<Face> faces;
    try {
      await file.writeAsBytes(img.encodeJpg(image, quality: 92), flush: true);
      faces = await _detector.processImage(InputImage.fromFilePath(file.path));
    } catch (e) {
      debugPrint('[Personas] Deteccion fallo: $e');
      return [];
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }

    final result = <_Face>[];
    for (final face in faces) {
      final crop = alignedCrop(image, face);
      if (crop == null) continue;
      result.add(_Face(
        embedding: _embed(interpreter, crop),
        area: face.boundingBox.width * face.boundingBox.height,
        centerX: face.boundingBox.center.dx / image.width,
      ));
    }
    return result;
  }

  /// Cara enderezada (ojos horizontales) y recortada en un cuadrado de inputSize x inputSize.
  @visibleForTesting
  static img.Image? alignedCrop(img.Image image, Face face) {
    final box = face.boundingBox;
    if (box.width < 24 || box.height < 24) return null; // muy lejos: no hay detalle suficiente
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    var source = image;
    var cx = box.center.dx, cy = box.center.dy;
    if (leftEye != null && rightEye != null) {
      final angle = math.atan2((rightEye.y - leftEye.y).toDouble(), (rightEye.x - leftEye.x).toDouble()) * 180 / math.pi;
      // Solo si esta bastante inclinada: rotar toda la foto cuesta.
      if (angle.abs() > 4 && angle.abs() < 45) {
        // Rotar alrededor del centro de la cara: se recorta primero una zona holgada.
        final side = (math.max(box.width, box.height) * 1.6).round();
        final x0 = (cx - side / 2).round().clamp(0, image.width - 1);
        final y0 = (cy - side / 2).round().clamp(0, image.height - 1);
        final region = img.copyCrop(image, x: x0, y: y0, width: math.min(side, image.width - x0), height: math.min(side, image.height - y0));
        final rotated = img.copyRotate(region, angle: -angle);
        source = rotated;
        cx = rotated.width / 2 + (cx - (x0 + region.width / 2));
        cy = rotated.height / 2 + (cy - (y0 + region.height / 2));
      }
    }
    final side = (math.max(box.width, box.height) * (1 + 2 * cropMargin)).round();
    final x0 = (cx - side / 2).round().clamp(0, math.max(0, source.width - side));
    final y0 = (cy - side / 2).round().clamp(0, math.max(0, source.height - side));
    final crop = img.copyCrop(source, x: x0.toInt(), y: y0.toInt(), width: math.min(side, source.width), height: math.min(side, source.height));
    return img.copyResize(crop, width: inputSize, height: inputSize, interpolation: img.Interpolation.linear);
  }

  static List<double> _embed(Interpreter interpreter, img.Image face) {
    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final p = face.getPixel(x, y);
          final rgb = [p.r.toDouble(), p.g.toDouble(), p.b.toDouble()];
          final ordered = inputIsBgr ? rgb.reversed.toList() : rgb;
          return [for (final c in ordered) (c - inputMean) / inputStd];
        }),
      ),
    );
    final dims = interpreter.getOutputTensor(0).shape.last;
    final output = [List<double>.filled(dims, 0)];
    interpreter.run(input, output);
    return _normalized(output[0]);
  }

  static List<double> _normalized(List<double> v) {
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    return norm == 0 ? v : [for (final x in v) x / norm];
  }

  static double _cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      dot += a[i] * b[i];
    }
    return dot; // ya normalizados
  }

  static String _key(String name) => name.trim().split(RegExp(r'\s+')).map((w) =>
      w.isEmpty ? w : w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');

  Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/$_fileName');

  Future<void> _save() async {
    try {
      await (await _file()).writeAsString(jsonEncode(_people));
    } catch (e) {
      debugPrint('[Personas] No se pudo guardar: $e');
    }
  }

  Future<void> dispose() async {
    await _detector.close();
    _interpreter?.close();
  }
}

class _Face {
  const _Face({required this.embedding, required this.area, required this.centerX});

  final List<double> embedding;
  final double area;
  final double centerX;
}
