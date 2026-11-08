import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:iris_app/services/ai/known_faces_service.dart';

/// Foto gris con dos "ojos" blancos de 5x5 en las posiciones dadas.
img.Image _photoWithEyes(int w, int h, List<(int, int)> eyes) {
  final photo = img.Image(width: w, height: h);
  img.fill(photo, color: img.ColorRgb8(60, 60, 60));
  for (final (x, y) in eyes) {
    img.fillRect(photo, x1: x - 2, y1: y - 2, x2: x + 2, y2: y + 2, color: img.ColorRgb8(255, 255, 255));
  }
  return photo;
}

/// Centro de los pixeles brillantes en la mitad izquierda o derecha de la cara alineada.
(double, double) _brightCenter(img.Image face, {required bool left}) {
  var sx = 0.0, sy = 0.0, n = 0;
  for (var y = 0; y < face.height; y++) {
    for (var x = 0; x < face.width; x++) {
      if ((x < 56) != left) continue;
      if (face.getPixel(x, y).r > 150) {
        sx += x;
        sy += y;
        n++;
      }
    }
  }
  return (sx / n, sy / n);
}

void main() {
  const t = KnownFacesService.eyeTemplate;

  void expectEyesOnTemplate(img.Image face) {
    expect(face.width, 112);
    final (lx, ly) = _brightCenter(face, left: true);
    final (rx, ry) = _brightCenter(face, left: false);
    expect(lx, closeTo(t[0], 1.5));
    expect(ly, closeTo(t[1], 1.5));
    expect(rx, closeTo(t[2], 1.5));
    expect(ry, closeTo(t[3], 1.5));
  }

  test('ojos derechos: van a la plantilla', () {
    final photo = _photoWithEyes(640, 480, [(300, 200), (380, 200)]);
    expectEyesOnTemplate(KnownFacesService.alignByEyes(photo, 300, 200, 380, 200));
  });

  test('ojos en orden de ML Kit (izquierdo de la persona a la derecha de la foto)', () {
    final photo = _photoWithEyes(640, 480, [(300, 200), (380, 200)]);
    expectEyesOnTemplate(KnownFacesService.alignByEyes(photo, 380, 200, 300, 200));
  });

  test('cara inclinada y mas chica: se endereza y escala', () {
    final photo = _photoWithEyes(640, 480, [(200, 300), (240, 270)]); // ~37 grados
    expectEyesOnTemplate(KnownFacesService.alignByEyes(photo, 200, 300, 240, 270));
  });

  test('fuera de la foto queda negro', () {
    final photo = _photoWithEyes(200, 200, [(10, 10), (50, 10)]);
    final face = KnownFacesService.alignByEyes(photo, 10, 10, 50, 10);
    expect(face.getPixel(0, 0).r, 0);
  });

  test('frases', () {
    expect(KnownFacesService.describe([]), contains('No veo a nadie'));
    expect(
      KnownFacesService.describe(const [
        FaceMatch(name: 'Raul', similarity: 0.6, position: 'a tu izquierda'),
        FaceMatch(name: null, similarity: 0.1, position: 'al frente'),
      ]),
      'Aqui esta Raul a tu izquierda y otra persona que no conozco.',
    );
  });
}
