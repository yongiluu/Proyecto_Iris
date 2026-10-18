import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/hardware/esp32_speech_service.dart';
import 'missions.dart';

/// Guarda en el celular lo que se recolecta, con la misma estructura que espera
/// ML_Training/import_phone_data.py:
/// ```text
/// iris_dataset/audio/<clase>/<clase>__<ambiente>__<mision>__<origen>-<fecha>.wav
/// iris_dataset/vision/<clase>/<clase>__<ambiente>__<mision>__<origen>-<fecha>_<n>.bmp
/// iris_dataset/vision/cercania/...<n>.jpg   (solo misiones de cercania en modo Celular)
/// iris_dataset/registro.csv
/// ```
class DatasetStore {
  late Directory root;

  Future<void> init() async {
    // Android/data/<app>/files/iris_dataset: visible desde el PC por USB.
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    root = Directory('${base.path}/iris_dataset');
    await root.create(recursive: true);
  }

  Directory _folder(Mission mission) =>
      Directory('${root.path}/${mission.kind == MissionKind.audio ? 'audio' : 'vision'}/${mission.label}');

  String _prefix(Mission mission) => '${mission.label}__${mission.scene}__${mission.id}__';

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// Archivos ya guardados de una mision (grabaciones o fotos BMP; los JPEG a color acompanan
  /// a su BMP y no cuentan aparte).
  Future<List<File>> files(Mission mission) async {
    final folder = _folder(mission);
    if (!await folder.exists()) return [];
    final prefix = _prefix(mission);
    final found = await folder
        .list()
        .where((e) =>
            e is File && e.uri.pathSegments.last.startsWith(prefix) && !e.path.endsWith('.jpg'))
        .cast<File>()
        .toList();
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  Future<int> progress(Mission mission) async => (await files(mission)).length;

  /// `source` queda en el nombre ('placa' o 'cel') para poder separar los datos al entrenar.
  Future<File> saveAudio(Mission mission, Uint8List pcm,
      {required double receivedRatio, String source = 'placa'}) async {
    final folder = _folder(mission);
    await folder.create(recursive: true);
    final file = File('${folder.path}/${_prefix(mission)}$source-${_stamp()}.wav');
    await file.writeAsBytes(Esp32SpeechService.buildWav(pcm));
    await _log(mission, file, 'audio ${(pcm.length / 32000).toStringAsFixed(1)} s, '
        'recibido ${(receivedRatio * 100).round()}%');
    return file;
  }

  /// Mueve un WAV ya grabado (microfono del celular) a la carpeta de la mision.
  Future<File> saveAudioFile(Mission mission, String wavPath, {String source = 'cel'}) async {
    final folder = _folder(mission);
    await folder.create(recursive: true);
    final target = '${folder.path}/${_prefix(mission)}$source-${_stamp()}.wav';
    final file = await File(wavPath).copy(target);
    await File(wavPath).delete();
    final seconds = (await file.length() - 44) / 32000;
    await _log(mission, file, 'audio ${seconds.toStringAsFixed(1)} s, microfono del celular');
    return file;
  }

  /// Guarda una tanda de fotos. `take` = marca de tiempo comun a la tanda.
  Future<File> savePhoto(Mission mission, GrayFrame frame, String take, int index, {Uint8List? colorJpeg}) async {
    final folder = _folder(mission);
    await folder.create(recursive: true);
    final base = '${folder.path}/${_prefix(mission)}${take}_${index.toString().padLeft(3, '0')}';
    final file = File('$base.bmp');
    await file.writeAsBytes(encodeGrayBmp(frame));
    if (colorJpeg != null) await File('$base.jpg').writeAsBytes(colorJpeg);
    return file;
  }

  String newTakeStamp({String source = 'placa'}) => '$source-${_stamp()}';

  Future<void> logPhotoTake(Mission mission, String take, int count) async {
    await _log(mission, File(take), '$count fotos');
  }

  Future<void> _log(Mission mission, File file, String detail) async {
    final log = File('${root.path}/registro.csv');
    if (!await log.exists()) await log.writeAsString('fecha,mision,clase,ambiente,archivo,detalle\n');
    await log.writeAsString(
      '${DateTime.now().toIso8601String()},${mission.id},${mission.label},${mission.scene},'
      '${file.uri.pathSegments.last},$detail\n',
      mode: FileMode.append,
    );
  }

  /// Comprime todo en un zip (para mandarlo al PC por Drive, correo, etc.).
  Future<File> exportZip() async {
    final temp = await getTemporaryDirectory();
    final zip = File('${temp.path}/iris_dataset_${_stamp()}.zip');
    await ZipFileEncoder().zipDirectory(root, filename: zip.path);
    return zip;
  }

  Future<({int audios, int photos, int bytes})> totals() async {
    int audios = 0, photos = 0, bytes = 0;
    if (!await root.exists()) return (audios: 0, photos: 0, bytes: 0);
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.wav')) audios++;
      if (entity.path.endsWith('.bmp')) photos++;
      bytes += await entity.length();
    }
    return (audios: audios, photos: photos, bytes: bytes);
  }
}

/// BMP de 8 bits en grises (paleta de 256 tonos): lo lee Flutter para la vista previa y
/// Python/PIL al importarlo en el PC, sin librerias extra.
Uint8List encodeGrayBmp(GrayFrame frame) {
  final rowSize = (frame.width + 3) & ~3;
  const headerSize = 14 + 40 + 256 * 4;
  final fileSize = headerSize + rowSize * frame.height;
  final data = ByteData(fileSize);

  data.setUint8(0, 0x42); // 'B'
  data.setUint8(1, 0x4D); // 'M'
  data.setUint32(2, fileSize, Endian.little);
  data.setUint32(10, headerSize, Endian.little);
  data.setUint32(14, 40, Endian.little);
  data.setInt32(18, frame.width, Endian.little);
  data.setInt32(22, frame.height, Endian.little); // positivo = filas de abajo hacia arriba
  data.setUint16(26, 1, Endian.little);
  data.setUint16(28, 8, Endian.little);
  data.setUint32(34, rowSize * frame.height, Endian.little);
  data.setUint32(46, 256, Endian.little);
  for (int i = 0; i < 256; i++) {
    final offset = 54 + i * 4;
    data.setUint8(offset, i);
    data.setUint8(offset + 1, i);
    data.setUint8(offset + 2, i);
  }

  final bytes = data.buffer.asUint8List();
  for (int y = 0; y < frame.height; y++) {
    final src = y * frame.width;
    final dst = headerSize + (frame.height - 1 - y) * rowSize;
    bytes.setRange(dst, dst + frame.width, frame.pixels, src);
  }
  return bytes;
}
