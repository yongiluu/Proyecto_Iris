import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// La camara de la placa va de lado en los lentes: la foto JPEG llega girada 90 grados y en espejo.
/// La placa lo avisa con "girada" en CMD_HELLO. Se endereza igual que en el firmware
/// (image_convert.cpp, kMountTransverse): derecha(x, y) = original(ancho-1-y, alto-1-x).
/// Pensada para correr en un isolate (compute): decodificar y recodificar 640x480 toma unos 100 ms.
Uint8List uprightTransverseJpeg(Uint8List jpeg) {
  final src = img.decodeJpg(jpeg);
  if (src == null) return jpeg;
  final out = uprightTransverse(src);
  return Uint8List.fromList(img.encodeJpg(out, quality: 90));
}

img.Image uprightTransverse(img.Image src) {
  final w = src.width, h = src.height;
  final out = img.Image(width: h, height: w, numChannels: src.numChannels);
  for (var y = 0; y < w; y++) {
    for (var x = 0; x < h; x++) {
      out.setPixel(x, y, src.getPixel(w - 1 - y, h - 1 - x));
    }
  }
  return out;
}
