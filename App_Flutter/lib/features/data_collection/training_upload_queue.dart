import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/backend/backend_service.dart';

/// Un archivo de una mision que falta subir.
class _PendingUpload {
  _PendingUpload({
    required this.path,
    required this.userId,
    required this.kind,
    required this.label,
    required this.environment,
    required this.source,
    this.failures = 0,
  });

  final String path; // archivo local (sigue guardado en el celular como siempre)
  final String userId; // cuenta con la que se grabo: no se sube con otra
  final String kind; // 'audio' | 'foto'
  final String label;
  final String environment;
  final String source; // 'celular' | 'placa'
  int failures; // errores que no son de red

  String get fileName => path.split(RegExp(r'[\\/]')).last;
  String get storagePath => '$userId/$label/$fileName';

  Map<String, dynamic> toJson() => {
        'path': path,
        'user_id': userId,
        'kind': kind,
        'label': label,
        'environment': environment,
        'source': source,
        'failures': failures,
      };

  static _PendingUpload fromJson(Map<String, dynamic> j) => _PendingUpload(
        path: j['path'] as String,
        userId: j['user_id'] as String,
        kind: j['kind'] as String,
        label: j['label'] as String,
        environment: j['environment'] as String? ?? '',
        source: j['source'] as String,
        failures: j['failures'] as int? ?? 0,
      );
}

/// Sube en segundo plano los audios y fotos de las Misiones de datos al bucket privado
/// `datos-entrenamiento` de Supabase (`<user_id>/<clase>/<archivo>`) y registra cada uno en la
/// tabla `training_uploads`.
///
/// Solo encola si hay sesion y la persona dio consentimiento (preferences.training_data_consent).
/// La cola vive en disco (`training_uploads_queue.json`), asi que si no hay internet o se cierra la
/// app, se reintenta despues. Sin backend configurado no hace nada.
class TrainingUploadQueue {
  TrainingUploadQueue._();
  static final TrainingUploadQueue instance = TrainingUploadQueue._();

  static const String bucket = 'datos-entrenamiento';
  static const int _maxFailures = 6;

  /// Archivos que faltan subir (para el indicador de la pantalla de misiones).
  final ValueNotifier<int> pending = ValueNotifier<int>(0);

  final List<_PendingUpload> _queue = [];
  File? _file;
  bool? _consent; // ultimo valor conocido (se guarda en disco para poder encolar sin internet)
  String? _consentUserId;
  Future<void>? _initFuture;
  bool _draining = false;
  Timer? _retryTimer;
  Duration _retryDelay = const Duration(seconds: 30);
  Future<void> _writeChain = Future.value();
  StreamSubscription<AuthState>? _authSub;

  BackendService get _backend => BackendService.instance;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/training_uploads_queue.json');
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        _consent = data['consent'] as bool?;
        _consentUserId = data['consent_user_id'] as String?;
        for (final item in (data['queue'] as List? ?? const [])) {
          _queue.add(_PendingUpload.fromJson(Map<String, dynamic>.from(item as Map)));
        }
      }
    } catch (e) {
      debugPrint('Cola de subida: no se pudo leer ($e)');
    }
    pending.value = _queue.length;
    if (_backend.enabled) {
      _authSub = _backend.authChanges.listen((_) {
        refreshConsent().then((_) => kick());
      });
    }
    unawaited(refreshConsent().then((_) => kick()));
  }

  /// Hay sesion y consentimiento (segun lo ultimo que se supo del servidor).
  bool get active {
    final user = _backend.user;
    return user != null && _consent == true && _consentUserId == user.id;
  }

  /// Vuelve a leer el consentimiento del servidor. Sin internet se queda con el valor guardado.
  Future<void> refreshConsent() async {
    final user = _backend.user;
    if (user == null) return;
    final prefs = await _backend.loadPreferences();
    if (prefs == null) return; // sin internet: se mantiene lo guardado
    await consentChanged(prefs['training_data_consent'] as bool? ?? false, userId: user.id);
  }

  /// Llamar al cambiar el interruptor en Mi cuenta. Sin consentimiento se vacia la cola
  /// (lo pendiente no se sube; los archivos siguen en el celular).
  Future<void> consentChanged(bool value, {String? userId}) async {
    _consent = value;
    _consentUserId = userId ?? _backend.user?.id;
    if (!value) _queue.removeWhere((e) => e.userId == _consentUserId);
    await _persist();
    if (value) kick();
  }

  /// Encola un archivo recien grabado. No hace nada sin sesion o sin consentimiento.
  Future<void> enqueue(File file,
      {required bool isAudio, required String label, required String environment, required String source}) async {
    await init();
    final user = _backend.user;
    if (user == null || !active) return;
    _queue.add(_PendingUpload(
      path: file.path,
      userId: user.id,
      kind: isAudio ? 'audio' : 'foto',
      label: label,
      environment: environment,
      source: source == 'placa' ? 'placa' : 'celular',
    ));
    await _persist();
    kick();
  }

  /// "Borrar lo ultimo": saca de la cola lo que no se subio y borra del servidor lo que ya estaba
  /// (si hay internet; si no, la copia del servidor queda).
  Future<void> forget(List<File> files) async {
    await init();
    final paths = files.map((f) => f.path).toSet();
    _queue.removeWhere((e) => paths.contains(e.path));
    await _persist();

    final user = _backend.user;
    if (user == null || !_backend.enabled) return;
    try {
      final db = Supabase.instance.client;
      final remote = <String>[];
      for (final f in files) {
        final name = f.path.split(RegExp(r'[\\/]')).last;
        final label = f.parent.path.split(RegExp(r'[\\/]')).last;
        remote.add('${user.id}/$label/$name');
      }
      await db.storage.from(bucket).remove(remote).timeout(const Duration(seconds: 20));
      await db.from('training_uploads').delete().inFilter('storage_path', remote).timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('Cola de subida: no se pudo borrar del servidor ($e)');
    }
  }

  /// Intenta subir lo pendiente ahora (no espera a que termine).
  void kick() {
    if (_queue.isEmpty || _draining) return;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    _retryTimer?.cancel();
    bool retryLater = false;
    try {
      while (_queue.isNotEmpty) {
        final user = _backend.user;
        if (user == null || !active) {
          retryLater = user != null && _consent == null; // aun no se sabe el consentimiento
          break;
        }
        final item = _queue.firstWhere((e) => e.userId == user.id, orElse: () => _queue.first);
        if (item.userId != user.id) break; // lo de otra cuenta espera a que vuelva esa cuenta

        final file = File(item.path);
        if (!await file.exists()) {
          _queue.remove(item); // se borro en el celular: nada que subir
          await _persist();
          continue;
        }
        try {
          await _upload(item, file);
          _queue.remove(item);
          _retryDelay = const Duration(seconds: 30);
          await _persist();
        } catch (e) {
          if (_isNetworkError(e)) {
            debugPrint('Cola de subida: sin conexion, se reintenta despues ($e)');
            retryLater = true;
            break;
          }
          if (_isPermissionError(e)) {
            // RLS rechazo: probablemente se retiro el consentimiento desde otro dispositivo.
            debugPrint('Cola de subida: permiso denegado ($e)');
            await refreshConsent();
            if (active) {
              _bumpFailure(item, e);
              await _persist();
            }
            continue;
          }
          _bumpFailure(item, e);
          await _persist();
          retryLater = true;
          break;
        }
      }
    } finally {
      _draining = false;
    }
    if (retryLater && _queue.isNotEmpty) {
      _retryTimer = Timer(_retryDelay, kick);
      final next = _retryDelay * 2;
      _retryDelay = next > const Duration(minutes: 10) ? const Duration(minutes: 10) : next;
    }
  }

  void _bumpFailure(_PendingUpload item, Object e) {
    item.failures++;
    debugPrint('Cola de subida: fallo ${item.failures}/$_maxFailures en ${item.fileName} ($e)');
    _queue.remove(item);
    if (item.failures < _maxFailures) _queue.add(item); // al final, para no bloquear al resto
  }

  Future<void> _upload(_PendingUpload item, File file) async {
    final db = Supabase.instance.client;
    final contentType = switch (item.fileName.split('.').last.toLowerCase()) {
      'wav' => 'audio/wav',
      'bmp' => 'image/bmp',
      'jpg' || 'jpeg' => 'image/jpeg',
      _ => 'application/octet-stream',
    };
    try {
      await db.storage
          .from(bucket)
          .uploadBinary(item.storagePath, await file.readAsBytes(), fileOptions: FileOptions(contentType: contentType))
          .timeout(const Duration(seconds: 60));
    } on StorageException catch (e) {
      // Ya estaba (un intento anterior subio el archivo pero no alcanzo a registrarlo): seguir.
      final duplicate = e.statusCode == '409' || e.message.toLowerCase().contains('exists') ||
          e.message.toLowerCase().contains('duplicate');
      if (!duplicate) rethrow;
    }
    await db.from('training_uploads').insert({
      'user_id': item.userId,
      'kind': item.kind,
      'label': item.label,
      'environment': item.environment,
      'source': item.source,
      'storage_path': item.storagePath,
    }).timeout(const Duration(seconds: 30));
  }

  static bool _isNetworkError(Object e) {
    if (e is SocketException || e is TimeoutException || e is HttpException) return true;
    final text = e.toString();
    return text.contains('ClientException') || text.contains('SocketException') ||
        text.contains('Failed host lookup') || text.contains('Connection');
  }

  static bool _isPermissionError(Object e) {
    if (e is StorageException) return e.statusCode == '403' || e.message.toLowerCase().contains('security');
    if (e is PostgrestException) return e.code == '42501' || e.message.toLowerCase().contains('security');
    return false;
  }

  Future<void> _persist() {
    pending.value = _queue.length;
    final file = _file;
    if (file == null) return Future.value();
    final json = jsonEncode({
      'consent': _consent,
      'consent_user_id': _consentUserId,
      'queue': [for (final e in _queue) e.toJson()],
    });
    // Escrituras en orden y atomicas (archivo temporal + rename) para no corromper la cola.
    return _writeChain = _writeChain.then((_) async {
      try {
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(json, flush: true);
        await temp.rename(file.path);
      } catch (e) {
        debugPrint('Cola de subida: no se pudo guardar ($e)');
      }
    });
  }

  @visibleForTesting
  Future<void> dispose() async {
    _retryTimer?.cancel();
    await _authSub?.cancel();
  }
}
