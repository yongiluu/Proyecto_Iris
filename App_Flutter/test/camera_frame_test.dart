import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:iris_app/features/data_collection/dataset_store.dart';
import 'package:iris_app/services/hardware/esp32_speech_service.dart';

/// Pixel RGB565 big-endian (byte alto primero, como lo manda esp_camera).
List<int> _rgb565(int r5, int g6, int b5) {
  final v = (r5 << 11) | (g6 << 5) | b5;
  return [(v >> 8) & 0xFF, v & 0xFF];
}

void main() {
  test('RGB565 big-endian se convierte a RGB de 8 bits', () {
    final data = Uint8List.fromList([
      ..._rgb565(31, 0, 0), // rojo puro
      ..._rgb565(0, 63, 0), // verde puro
      ..._rgb565(0, 0, 31), // azul puro
      ..._rgb565(31, 63, 31), // blanco
      ..._rgb565(0, 0, 0), // negro
      ..._rgb565(16, 32, 8), // gris-verdoso intermedio
    ]);
    final frame = CameraFrame.fromRgb565(3, 2, data);

    expect(frame.width, 3);
    expect(frame.height, 2);
    expect(frame.isColor, isTrue);
    expect(frame.pixels, [
      255, 0, 0,
      0, 255, 0,
      0, 0, 255,
      255, 255, 255,
      0, 0, 0,
      (16 << 3) | (16 >> 2), (32 << 2) | (32 >> 4), (8 << 3) | (8 >> 2),
    ]);
  });

  test('el byte alto va primero (no little-endian)', () {
    // 0xF800 = rojo puro en big-endian; leido al reves (0x00F8) seria casi negro con algo de azul/verde.
    final frame = CameraFrame.fromRgb565(1, 1, Uint8List.fromList([0xF8, 0x00]));
    expect(frame.pixels, [255, 0, 0]);
  });

  test('un frame a color se guarda como PNG RGB del mismo tamano', () {
    final rgb = Uint8List(160 * 120 * 3);
    for (int i = 0; i < 160 * 120; i++) {
      rgb[i * 3] = 200;
      rgb[i * 3 + 1] = 100;
      rgb[i * 3 + 2] = 50;
    }
    final frame = CameraFrame(160, 120, rgb, channels: 3);
    expect(frameExtension(frame), 'png');

    final decoded = img.decodePng(encodeFrame(frame))!;
    expect(decoded.width, 160);
    expect(decoded.height, 120);
    expect(decoded.numChannels, 3);
    final p = decoded.getPixel(80, 60);
    expect([p.r, p.g, p.b], [200, 100, 50]);
  });

  test('un frame en grises (firmware anterior) sigue saliendo como BMP', () {
    final frame = CameraFrame(96, 96, Uint8List(96 * 96));
    expect(frame.isColor, isFalse);
    expect(frameExtension(frame), 'bmp');
    final bytes = encodeFrame(frame);
    expect(String.fromCharCodes(bytes.sublist(0, 2)), 'BM');
  });
}
