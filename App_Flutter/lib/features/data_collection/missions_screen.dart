import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vibration/vibration.dart';

import '../../services/hardware/camera_service.dart';
import '../../services/hardware/esp32_speech_service.dart';
import 'dataset_store.dart';
import 'missions.dart';
import 'phone_capture.dart';

/// Lista de misiones de recoleccion con su progreso (ej. "Audio de calle 3/8").
class MissionsScreen extends StatefulWidget {
  final Esp32SpeechService esp32;
  final CameraService phoneCamera;

  const MissionsScreen({super.key, required this.esp32, required this.phoneCamera});

  @override
  State<MissionsScreen> createState() => _MissionsScreenState();
}

class _MissionsScreenState extends State<MissionsScreen> {
  final DatasetStore _store = DatasetStore();
  late final PhoneCapture _phone = PhoneCapture(widget.phoneCamera);
  final Map<String, int> _progress = {};
  ({int audios, int photos, int bytes})? _totals;
  bool _ready = false;
  bool _exporting = false;
  Timer? _connectionTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // El estado de conexion lo maneja la pantalla del asistente; aqui solo se muestra.
    _connectionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_ready) await _store.init();
    for (final mission in missions) {
      _progress[mission.id] = await _store.progress(mission);
    }
    _totals = await _store.totals();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final zip = await _store.exportZip();
      await SharePlus.instance.share(ShareParams(
        files: [XFile(zip.path)],
        text: 'Datos de Iris para entrenar (ML_Training/import_phone_data.py)',
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.esp32.isConnected;
    final totals = _totals;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Misiones de datos'),
        actions: [
          IconButton(
            tooltip: 'Exportar todo (zip)',
            onPressed: _ready && !_exporting ? _export : null,
            icon: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  leading: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                      color: connected ? Colors.green : Colors.orange),
                  title: Text(connected
                      ? 'Placa conectada'
                      : 'Sin placa: puedes usar la camara y el microfono del celular'),
                  subtitle: totals == null
                      ? null
                      : Text('${totals.audios} audios, ${totals.photos} fotos, '
                          '${(totals.bytes / 1e6).toStringAsFixed(1)} MB\n${_store.root.path}'),
                  isThreeLine: totals != null,
                ),
                const Divider(),
                for (final mission in missions) _missionTile(mission),
              ],
            ),
    );
  }

  Widget _missionTile(Mission mission) {
    final done = _progress[mission.id] ?? 0;
    final unit = mission.kind == MissionKind.audio ? 'grabaciones' : 'fotos';
    final complete = done >= mission.target;
    return ListTile(
      leading: Icon(mission.kind == MissionKind.audio ? Icons.mic : Icons.photo_camera,
          color: complete ? Colors.green : null),
      title: Text(mission.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$done/${mission.target} $unit'),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: math.min(1.0, done / mission.target)),
        ],
      ),
      trailing: complete ? const Icon(Icons.check_circle, color: Colors.green) : const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MissionScreen(mission: mission, esp32: widget.esp32, phone: _phone, store: _store),
        ));
        _load();
      },
    );
  }
}

/// Una mision: grabar audio o tomar una tanda de fotos con la placa.
class MissionScreen extends StatefulWidget {
  final Mission mission;
  final Esp32SpeechService esp32;
  final PhoneCapture phone;
  final DatasetStore store;

  const MissionScreen(
      {super.key, required this.mission, required this.esp32, required this.phone, required this.store});

  @override
  State<MissionScreen> createState() => _MissionScreenState();
}

class _MissionScreenState extends State<MissionScreen> {
  static const Duration _photoInterval = Duration(milliseconds: 500);
  static const double _minReceivedRatio = 0.7;

  int _done = 0;
  bool _busy = false;
  bool _cancelRequested = false;
  String _status = '';
  double _secondsLeft = 0;
  double _levelDb = -90;
  int _photosThisTake = 0;
  Uint8List? _preview;
  // true = camara/microfono del celular (sin placa). Con placa conectada se usa la placa.
  late bool _usePhone = !widget.esp32.isConnected;

  Mission get _mission => widget.mission;
  String get _source => _usePhone ? 'cel' : 'placa';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _stopCollecting();
    super.dispose();
  }

  Future<void> _refresh() async {
    final done = await widget.store.progress(_mission);
    if (mounted) setState(() => _done = done);
  }

  void _stopCollecting() {
    widget.esp32.onRawMicAudio = null;
    widget.esp32.isCollectingData = false;
  }

  Future<void> _buzz() async {
    try {
      if (await Vibration.hasVibrator() == true) Vibration.vibrate(duration: 120);
    } catch (_) {}
  }

  void _show(String text) {
    if (!mounted) return;
    setState(() => _status = text);
  }

  // ─── Audio ───

  Future<void> _recordAudio() async {
    if (_usePhone) return _recordPhoneAudio();
    if (!widget.esp32.isConnected) return _show('La placa no esta conectada.');
    final seconds = _mission.secondsPerTake;
    final buffer = BytesBuilder(copy: false);

    setState(() {
      _busy = true;
      _cancelRequested = false;
      _status = 'Grabando...';
    });
    widget.esp32.isCollectingData = true;
    widget.esp32.onRawMicAudio = (chunk) {
      buffer.add(chunk);
      _levelDb = _rmsDb(chunk);
    };

    if (!await widget.esp32.setMicStreaming(true)) {
      _stopCollecting();
      setState(() => _busy = false);
      return _show('No se pudo iniciar la grabacion.');
    }
    await _buzz();

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsedMilliseconds < seconds * 1000 && !_cancelRequested && widget.esp32.isConnected) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) setState(() => _secondsLeft = seconds - stopwatch.elapsedMilliseconds / 1000);
    }
    final elapsed = stopwatch.elapsedMilliseconds / 1000;
    await widget.esp32.setMicStreaming(false);
    await Future.delayed(const Duration(milliseconds: 300)); // ultimos paquetes en camino
    _stopCollecting();
    await _buzz();

    if (!mounted) return;
    setState(() => _busy = false);
    if (_cancelRequested) return _show('Grabacion cancelada (no se guardo).');

    var pcm = buffer.takeBytes();
    if (pcm.length.isOdd) pcm = Uint8List.sublistView(pcm, 0, pcm.length - 1);
    final ratio = pcm.length / (elapsed * 32000);
    if (ratio < _minReceivedRatio) {
      return _show('Llego solo el ${(ratio * 100).round()}% del audio por Bluetooth. '
          'Acerca el celular a la placa y repite.');
    }
    await widget.store.saveAudio(_mission, pcm, receivedRatio: ratio, source: 'placa');
    await _refresh();
    _show('Guardado (${(pcm.length / 32000).toStringAsFixed(1)} s, llego el ${(math.min(ratio, 1.0) * 100).round()}%).');
  }

  Future<void> _recordPhoneAudio() async {
    final seconds = _mission.secondsPerTake;
    final path = '${(await getTemporaryDirectory()).path}/mision_${DateTime.now().millisecondsSinceEpoch}.wav';
    if (!await widget.phone.startAudio(path)) return _show('Sin permiso para usar el microfono.');

    setState(() {
      _busy = true;
      _cancelRequested = false;
      _status = 'Grabando con el celular...';
    });
    final levels = widget.phone.audioLevels().listen((db) => _levelDb = db);
    await _buzz();

    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsedMilliseconds < seconds * 1000 && !_cancelRequested) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) setState(() => _secondsLeft = seconds - stopwatch.elapsedMilliseconds / 1000);
    }
    await levels.cancel();
    await _buzz();

    if (_cancelRequested) {
      await widget.phone.cancelAudio();
      if (mounted) setState(() => _busy = false);
      return _show('Grabacion cancelada (no se guardo).');
    }
    final recorded = await widget.phone.stopAudio();
    if (!mounted) return;
    setState(() => _busy = false);
    if (recorded == null) return _show('No se pudo grabar.');
    await widget.store.saveAudioFile(_mission, recorded, source: 'cel');
    await _refresh();
    _show('Guardado (microfono del celular).');
  }

  static double _rmsDb(List<int> chunk) {
    final data = ByteData.sublistView(Uint8List.fromList(chunk));
    double sum = 0;
    final n = chunk.length ~/ 2;
    if (n == 0) return -90;
    for (int i = 0; i < n; i++) {
      final s = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return 10 * math.log(sum / n + 1e-12) / math.ln10;
  }

  // ─── Fotos ───

  Future<void> _takePhotos() async {
    if (_usePhone && !widget.phone.cameraReady) return _show('La camara del celular no esta lista.');
    if (!_usePhone && !widget.esp32.isConnected) return _show('La placa no esta conectada.');
    final take = widget.store.newTakeStamp(source: _source);
    int failures = 0;

    setState(() {
      _busy = true;
      _cancelRequested = false;
      _photosThisTake = 0;
      _status = 'Tomando fotos...';
    });
    widget.esp32.isCollectingData = true;
    await _buzz();

    while (_photosThisTake < _mission.photosPerTake &&
        !_cancelRequested &&
        (_usePhone || widget.esp32.isConnected)) {
      final started = DateTime.now();
      final frame = _usePhone ? await widget.phone.takeGrayFrame() : await widget.esp32.captureGrayFrame();
      if (frame == null) {
        if (++failures >= 5) {
          _show(_usePhone
              ? 'La camara del celular no esta respondiendo.'
              : 'La placa no esta mandando fotos. ¿Firmware actualizado?');
          break;
        }
        continue;
      }
      failures = 0;
      await widget.store.savePhoto(_mission, frame, take, _photosThisTake);
      _photosThisTake++;
      if (mounted) setState(() => _preview = encodeGrayBmp(frame));
      final wait = _photoInterval - DateTime.now().difference(started);
      if (wait > Duration.zero) await Future.delayed(wait);
    }

    _stopCollecting();
    await _buzz();
    if (_photosThisTake > 0) await widget.store.logPhotoTake(_mission, take, _photosThisTake);
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_status == 'Tomando fotos...') _show('$_photosThisTake fotos guardadas.');
  }

  // ─── Deshacer ───

  Future<void> _deleteLast() async {
    final files = await widget.store.files(_mission);
    if (files.isEmpty) return;
    List<File> toDelete;
    if (_mission.kind == MissionKind.audio) {
      toDelete = [files.last];
    } else {
      // Toda la ultima tanda: los archivos que comparten la marca de tiempo.
      final name = files.last.uri.pathSegments.last;
      final takePrefix = name.substring(0, name.lastIndexOf('_'));
      toDelete = files.where((f) => f.uri.pathSegments.last.startsWith(takePrefix)).toList();
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Borrar lo ultimo'),
        content: Text(_mission.kind == MissionKind.audio
            ? 'Se borra la ultima grabacion.'
            : 'Se borra la ultima tanda (${toDelete.length} fotos).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    for (final file in toDelete) {
      await file.delete();
    }
    await _refresh();
    _show('Borrado.');
  }

  // ─── UI ───

  @override
  Widget build(BuildContext context) {
    final isAudio = _mission.kind == MissionKind.audio;
    final takesDone = isAudio ? _done : (_done / _mission.photosPerTake).floor();
    final complete = _done >= _mission.target;

    return Scaffold(
      appBar: AppBar(title: Text(_mission.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_mission.instructions, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.developer_board), label: Text('Placa')),
                  ButtonSegment(value: true, icon: Icon(Icons.smartphone), label: Text('Celular')),
                ],
                selected: {_usePhone},
                onSelectionChanged: _busy ? null : (value) => setState(() => _usePhone = value.first),
              ),
              if (_usePhone)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    isAudio
                        ? 'Lleva el celular donde iria la placa (bolsillo del pecho o colgado).'
                        : 'Celular a la altura del pecho, camara hacia adelante. Revisa que la vista previa salga derecha.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                isAudio
                    ? 'Grabacion ${math.min(_done + 1, _mission.takes)} de ${_mission.takes}'
                    : 'Tanda ${math.min(takesDone + 1, _mission.takes)} de ${_mission.takes}  ($_done/${_mission.target} fotos)',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              if (complete)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('¡Mision completa! Puedes seguir sumando si quieres.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.green)),
                ),
              const SizedBox(height: 16),
              Expanded(child: Center(child: isAudio ? _audioPanel() : _photoPanel())),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_status, textAlign: TextAlign.center),
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
                onPressed: _busy
                    ? () => setState(() => _cancelRequested = true)
                    : (isAudio ? _recordAudio : _takePhotos),
                icon: Icon(_busy ? Icons.stop : (isAudio ? Icons.fiber_manual_record : Icons.photo_camera)),
                label: Text(_busy
                    ? (isAudio ? 'Cancelar' : 'Detener')
                    : (isAudio
                        ? 'Grabar ${_mission.secondsPerTake} s'
                        : 'Tomar ${_mission.photosPerTake} fotos')),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _busy || _done == 0 ? null : _deleteLast,
                icon: const Icon(Icons.undo),
                label: Text(isAudio ? 'Borrar la ultima grabacion' : 'Borrar la ultima tanda'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _audioPanel() {
    if (!_busy) return const Icon(Icons.mic, size: 96, color: Colors.grey);
    final level = ((_levelDb + 70) / 70).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${_secondsLeft.ceil()} s', style: Theme.of(context).textTheme.displayMedium),
        const SizedBox(height: 16),
        SizedBox(width: 240, child: LinearProgressIndicator(value: level, minHeight: 12)),
        const SizedBox(height: 4),
        Text('Nivel del microfono: ${_levelDb.toStringAsFixed(0)} dBFS'),
      ],
    );
  }

  Widget _photoPanel() {
    final preview = _preview;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (preview == null)
          const Icon(Icons.photo_camera, size: 96, color: Colors.grey)
        else
          Image.memory(preview, width: 288, height: 288, gaplessPlayback: true, filterQuality: FilterQuality.none),
        const SizedBox(height: 8),
        Text(preview == null
            ? 'Aqui veras lo que ve el modelo (96x96)'
            : 'Lo que ve el modelo (96x96, ${_usePhone ? 'celular' : 'placa'})'),
        if (_busy) Text('$_photosThisTake/${_mission.photosPerTake}'),
      ],
    );
  }
}
