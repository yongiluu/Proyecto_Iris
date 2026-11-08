import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'voice_intents.dart';

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
  // SFace (OpenCV Zoo): RGB 0-255 tal cual; la normalizacion va dentro del modelo.
  static double inputMean = 0, inputStd = 1; // (pixel - mean) / std
  /// Sin ojos detectados: recuadro de ML Kit con este margen por lado (peor: ~92 % vs 97 % en LFW).
  static double cropMargin = 0.2;

  /// Donde quedan los ojos en la cara alineada de 112x112 (plantilla de SFace / ArcFace).
  static const List<double> eyeTemplate = [38.2946, 51.6963, 73.5318, 51.5014];

  /// Coseno minimo para decir que es esa persona. Mas alto = menos confusiones, mas "no se".
  /// 0,40 en LFW: 96,8 % de acierto, 0,4 % de extraños aceptados (ML_Training/faces/README.md).
  static double matchThreshold = 0.40;

  /// La mejor persona debe ganarle a la segunda por esto; si no, es "no se".
  static double matchMargin = 0.05;

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
    double bestScore = -1, secondScore = -1;
    for (final entry in _people.entries) {
      // La mejor huella de cada persona (mas robusto que el promedio con pocas fotos).
      var score = -1.0;
      for (final sample in entry.value) {
        score = math.max(score, _cosine(face.embedding, sample));
      }
      if (score > bestScore) {
        secondScore = bestScore;
        bestScore = score;
        best = entry.key;
      } else if (score > secondScore) {
        secondScore = score;
      }
    }
    final sure = bestScore >= matchThreshold && bestScore - secondScore >= matchMargin;
    return FaceMatch(
      name: sure ? best : null,
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

  /// Cara alineada de inputSize x inputSize: los ojos se llevan a [eyeTemplate] (como se entreno
  /// SFace). Sin ojos, el recuadro con margen. null si la cara es muy chica.
  @visibleForTesting
  static img.Image? alignedCrop(img.Image image, Face face) {
    final box = face.boundingBox;
    if (box.width < 40 || box.height < 40) return null; // muy lejos: no hay detalle suficiente
    final a = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final b = face.landmarks[FaceLandmarkType.rightEye]?.position;
    if (a != null && b != null) {
      return alignByEyes(image, a.x.toDouble(), a.y.toDouble(), b.x.toDouble(), b.y.toDouble());
    }
    final side = (math.max(box.width, box.height) * (1 + 2 * cropMargin)).round();
    final x0 = (box.center.dx - side / 2).round().clamp(0, math.max(0, image.width - side)).toInt();
    final y0 = (box.center.dy - side / 2).round().clamp(0, math.max(0, image.height - side)).toInt();
    final crop = img.copyCrop(image, x: x0, y: y0, width: math.min(side, image.width), height: math.min(side, image.height));
    return img.copyResize(crop, width: inputSize, height: inputSize, interpolation: img.Interpolation.linear);
  }

  /// Escala + giro + traslado que lleva los dos ojos (en pixeles de la foto, en cualquier orden) a
  /// la plantilla. El ojo con menor x EN LA FOTO va al punto izquierdo (ojo: el "leftEye" de ML Kit
  /// es el izquierdo de la persona, que en la foto suele quedar a la derecha). Fuera de la foto: negro.
  @visibleForTesting
  static img.Image alignByEyes(img.Image image, double ax, double ay, double bx, double by) {
    if (bx < ax) {
      final tx = ax, ty = ay;
      ax = bx;
      ay = by;
      bx = tx;
      by = ty;
    }
    final d1x = eyeTemplate[0], d1y = eyeTemplate[1], d2x = eyeTemplate[2], d2y = eyeTemplate[3];
    // Como numeros complejos: foto = ojo1 + z * (salida - plantilla1), z = (ojo2-ojo1)/(plant2-plant1)
    final vdx = d2x - d1x, vdy = d2y - d1y, vpx = bx - ax, vpy = by - ay;
    final den = vdx * vdx + vdy * vdy;
    final zr = (vpx * vdx + vpy * vdy) / den, zi = (vpy * vdx - vpx * vdy) / den;
    final out = img.Image(width: inputSize, height: inputSize);
    for (var v = 0; v < inputSize; v++) {
      for (var u = 0; u < inputSize; u++) {
        final du = u - d1x, dv = v - d1y;
        final sx = ax + zr * du - zi * dv, sy = ay + zi * du + zr * dv;
        final x0 = sx.floor(), y0 = sy.floor();
        if (x0 < 0 || y0 < 0 || x0 + 1 >= image.width || y0 + 1 >= image.height) {
          out.setPixelRgb(u, v, 0, 0, 0);
          continue;
        }
        final fx = sx - x0, fy = sy - y0;
        final p00 = image.getPixel(x0, y0), p10 = image.getPixel(x0 + 1, y0);
        final p01 = image.getPixel(x0, y0 + 1), p11 = image.getPixel(x0 + 1, y0 + 1);
        num mix(num c00, num c10, num c01, num c11) =>
            (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy;
        out.setPixelRgb(u, v, mix(p00.r, p10.r, p01.r, p11.r).round(), mix(p00.g, p10.g, p01.g, p11.g).round(),
            mix(p00.b, p10.b, p01.b, p11.b).round());
      }
    }
    return out;
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

  static String _key(String name) => nameKey(name);

  /// "raúl  pérez" y "Raul Perez" son la misma persona: sin tildes (la voz llega sin ellas) y con
  /// mayuscula inicial.
  @visibleForTesting
  static String nameKey(String name) => VoiceIntents.normalize(name)
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');

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
