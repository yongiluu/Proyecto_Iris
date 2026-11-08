import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Lector de texto con la camara del celular, SIN internet (ML Kit corre en el telefono).
/// Con la placa conectada se usa su propio lector (CMD_READ_TEXT); este es para el modo Celular
/// o si la placa no tiene el lector instalado.
class PhoneTextReader {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  /// Texto de la foto, de arriba a abajo, con las lineas unidas por ". ". Vacio si no hay texto.
  Future<String> read(Uint8List jpeg) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/iris_leer_${DateTime.now().microsecondsSinceEpoch}.jpg');
    try {
      await file.writeAsBytes(jpeg, flush: true);
      final result = await _recognizer.processImage(InputImage.fromFilePath(file.path));
      return joinBlocks(result.blocks
          .map((b) => (top: b.boundingBox.top, left: b.boundingBox.left, text: b.text))
          .toList());
    } catch (e) {
      debugPrint('[Leer texto celular] $e');
      return '';
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Ordena los bloques como se lee (arriba a abajo; en la misma altura, izquierda a derecha) y
  /// junta sus lineas. Separado para poder probarlo sin camara.
  @visibleForTesting
  static String joinBlocks(List<({double top, double left, String text})> blocks) {
    final sorted = [...blocks]..sort((a, b) {
        final dy = a.top - b.top;
        if (dy.abs() > 20) return dy.sign.toInt();
        return (a.left - b.left).sign.toInt();
      });
    final lines = <String>[];
    for (final block in sorted) {
      for (final line in block.text.split('\n')) {
        final clean = line.replaceAll(RegExp(r'\s+'), ' ').trim();
        // Un solo signo suelto suele ser ruido (un borde, una sombra).
        if (clean.length >= 2 || RegExp(r'[0-9A-Za-z]').hasMatch(clean)) lines.add(clean);
      }
    }
    return lines.join('. ');
  }

  Future<void> dispose() => _recognizer.close();
}
