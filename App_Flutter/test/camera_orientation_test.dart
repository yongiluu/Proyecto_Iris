import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:iris_app/services/hardware/camera_orientation.dart';

void main() {
  test('enderezar camara de lado = la regla del firmware (derecha(x,y) = original(W-1-y, H-1-x))', () {
    const w = 4, h = 3;
    final src = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        src.setPixelRgb(x, y, x * 10, y * 10, 0);
      }
    }
    final out = uprightTransverse(src);
    expect(out.width, h);
    expect(out.height, w);
    for (var y = 0; y < w; y++) {
      for (var x = 0; x < h; x++) {
        final p = out.getPixel(x, y);
        expect(p.r, (w - 1 - y) * 10, reason: 'x=$x y=$y');
        expect(p.g, (h - 1 - x) * 10, reason: 'x=$x y=$y');
      }
    }
  });

  test('una foto JPEG de 640x480 de lado sale de 480x640', () {
    final jpeg = img.encodeJpg(img.Image(width: 640, height: 480));
    final upright = img.decodeJpg(uprightTransverseJpeg(jpeg))!;
    expect(upright.width, 480);
    expect(upright.height, 640);
  });
}
