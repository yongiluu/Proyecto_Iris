import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/env_config.dart';

/// Respuesta del agente en el servidor.
class AgentReply {
  const AgentReply({this.text, this.needsImage = false});

  /// Lo que hay que decir en voz alta.
  final String? text;

  /// El modelo quiere mirar: hay que sacar una foto y preguntar de nuevo con ella.
  final bool needsImage;
}

class Companion {
  const Companion({required this.linkId, required this.name, required this.iAmCompanion,
      required this.canSeeAlerts, required this.canSeeLocation});

  final String linkId;
  final String name;
  final bool iAmCompanion; // true: yo acompaño a esta persona; false: esta persona me acompaña
  final bool canSeeAlerts;
  final bool canSeeLocation;
}

class MemoryDay {
  const MemoryDay({required this.id, required this.day, required this.summary, this.diary});

  final int id;
  final DateTime day;
  final String summary;
  final String? diary;
}

class MemoryMessage {
  const MemoryMessage({required this.fromUser, required this.text, required this.time});

  final bool fromUser;
  final String text;
  final DateTime time;
}

/// Cuenta, base de datos y agente en el servidor (Backend_Supabase).
///
/// Si el .env no tiene SUPABASE_URL, [enabled] es false y la app funciona como antes (sin cuentas,
/// con las llaves de IA en el celular). Con backend, las llaves viven solo en el servidor.
class BackendService {
  BackendService._();
  static final BackendService instance = BackendService._();

  static const Duration _timeout = Duration(seconds: 45);

  bool _initialized = false;

  bool get enabled => _initialized;
  SupabaseClient get _db => Supabase.instance.client;
  User? get user => enabled ? _db.auth.currentUser : null;
  bool get signedIn => user != null;

  /// Usar el agente/voz/transcripcion del servidor (hay backend y sesion).
  bool get useServer => signedIn;

  String? get displayName {
    final meta = user?.userMetadata ?? const {};
    return (meta['full_name'] ?? meta['name'])?.toString();
  }

  Stream<AuthState> get authChanges =>
      enabled ? _db.auth.onAuthStateChange : const Stream<AuthState>.empty();

  Future<void> init() async {
    if (_initialized || !EnvConfig.backendConfigured) return;
    try {
      await Supabase.initialize(url: EnvConfig.supabaseUrl, publishableKey: EnvConfig.supabaseAnonKey);
      if (EnvConfig.googleWebClientId.isNotEmpty) {
        await GoogleSignIn.instance.initialize(serverClientId: EnvConfig.googleWebClientId);
      }
      _initialized = true;
    } catch (e) {
      debugPrint('⚠️ No se pudo iniciar el backend: $e');
    }
  }

  // ───────────────────────── Sesion ─────────────────────────

  /// Inicia sesion con la cuenta de Google del telefono. Devuelve un mensaje de error o null si funciono.
  Future<String?> signInWithGoogle() async {
    if (!enabled) return 'El servidor de Iris no esta configurado.';
    if (EnvConfig.googleWebClientId.isEmpty) return 'Falta GOOGLE_WEB_CLIENT_ID en la configuracion.';
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) return 'Google no entrego la identificacion. Intenta de nuevo.';
      await _db.auth.signInWithIdToken(provider: OAuthProvider.google, idToken: idToken);
      return null;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return 'Inicio de sesion cancelado.';
      debugPrint('Google: $e');
      return 'No se pudo iniciar sesion con Google.';
    } catch (e) {
      debugPrint('Login: $e');
      return 'No se pudo iniciar sesion. Revisa tu conexion.';
    }
  }

  Future<void> signOut() async {
    if (!enabled) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    await _db.auth.signOut();
  }

  // ───────────────────────── Agente, voz y transcripcion ─────────────────────────

  Future<AgentReply> askAgent({
    required String text,
    Uint8List? image,
    String? sensorContext,
    double? lat,
    double? lon,
  }) async {
    final response = await _db.functions.invoke('agent', body: {
      'text': text,
      if (image != null) 'image_base64': base64Encode(image),
      if (sensorContext != null) 'sensor_context': sensorContext,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
    }).timeout(_timeout);
    final data = response.data as Map<String, dynamic>;
    if (data['need_image'] == true) return const AgentReply(needsImage: true);
    return AgentReply(text: data['reply']?.toString());
  }

  /// PCM 16 kHz 16-bit mono para la placa, o null si fallo.
  Future<Uint8List?> boardVoice(String text, {String lang = 'es-CL'}) async {
    try {
      final response = await _db.functions.invoke('voice', body: {'text': text, 'lang': lang}).timeout(_timeout);
      return response.data is Uint8List ? response.data as Uint8List : null;
    } catch (e) {
      debugPrint('Voz del servidor: $e');
      return null;
    }
  }

  Future<String> transcribe(Uint8List wav) async {
    try {
      final response = await _db.functions.invoke('transcribe', body: wav).timeout(_timeout);
      return (response.data as Map<String, dynamic>)['text']?.toString() ?? '';
    } catch (e) {
      debugPrint('Transcripcion del servidor: $e');
      return '';
    }
  }

  // ───────────────────────── Preferencias ─────────────────────────

  Future<Map<String, dynamic>?> loadPreferences() async {
    if (!signedIn) return null;
    try {
      return await _db.from('preferences').select().eq('user_id', user!.id).single();
    } catch (e) {
      debugPrint('Preferencias: $e');
      return null;
    }
  }

  Future<void> savePreferences(Map<String, dynamic> changes) async {
    if (!signedIn) return;
    try {
      await _db.from('preferences').update(changes).eq('user_id', user!.id);
    } catch (e) {
      debugPrint('Guardar preferencias: $e');
    }
  }

  // ───────────────────────── Acompañantes ─────────────────────────

  /// Codigo de 6 digitos para que un acompañante se vincule (vale 24 horas).
  Future<String> createCompanionInvite() async => (await _db.rpc('create_companion_invite')).toString();

  /// Devuelve null si funciono, o el motivo del error.
  Future<String?> acceptCompanionInvite(String code) async {
    try {
      await _db.rpc('accept_companion_invite', params: {'invite_code': code.trim()});
      return null;
    } on PostgrestException catch (e) {
      return e.message.contains('propio') ? 'Ese codigo es tuyo.' : 'Codigo invalido o vencido.';
    }
  }

  Future<List<Companion>> companions() async {
    if (!signedIn) return const [];
    final me = user!.id;
    final rows = await _db.from('companion_links').select(
        'id, user_id, companion_id, can_see_alerts, can_see_location, '
        'assisted:profiles!companion_links_user_id_fkey(display_name), '
        'companion:profiles!companion_links_companion_id_fkey(display_name)');
    return [
      for (final r in rows)
        Companion(
          linkId: r['id'] as String,
          iAmCompanion: r['companion_id'] == me,
          name: ((r['companion_id'] == me ? r['assisted'] : r['companion']) as Map?)?['display_name']?.toString() ??
              'Sin nombre',
          canSeeAlerts: r['can_see_alerts'] as bool,
          canSeeLocation: r['can_see_location'] as bool,
        ),
    ];
  }

  Future<void> setCompanionPermissions(String linkId, {bool? alerts, bool? location}) async {
    await _db.from('companion_links').update({
      if (alerts != null) 'can_see_alerts': alerts,
      if (location != null) 'can_see_location': location,
    }).eq('id', linkId);
  }

  Future<void> removeCompanion(String linkId) async => _db.from('companion_links').delete().eq('id', linkId);

  // ───────────────────────── Alertas y ubicacion ─────────────────────────

  Future<void> reportAlert(String kind, {String? detail, double? lat, double? lon}) async {
    if (!signedIn) return;
    try {
      await _db.from('alerts').insert(
          {'user_id': user!.id, 'kind': kind, 'detail': detail, 'lat': lat, 'lon': lon});
    } catch (e) {
      debugPrint('Alerta: $e');
    }
  }

  Future<void> updateLocation(double lat, double lon, {double? accuracy}) async {
    if (!signedIn) return;
    try {
      await _db.from('last_locations').upsert({
        'user_id': user!.id, 'lat': lat, 'lon': lon, 'accuracy_m': accuracy,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Ubicacion: $e');
    }
  }

  // ───────────────────────── Memoria (historial) ─────────────────────────

  Future<List<MemoryDay>> memoryDays({int limit = 30}) async {
    if (!signedIn) return const [];
    final days = await _db.from('conversation_days').select('id, day, running_summary')
        .order('day', ascending: false).limit(limit);
    final diaries = await _db.from('daily_diaries').select('day, summary_md')
        .order('day', ascending: false).limit(limit);
    final diaryByDay = {for (final d in diaries) d['day'] as String: d['summary_md'] as String};
    return [
      for (final d in days)
        MemoryDay(
          id: d['id'] as int,
          day: DateTime.parse(d['day'] as String),
          summary: d['running_summary'] as String? ?? '',
          diary: diaryByDay[d['day']],
        ),
    ];
  }

  Future<List<MemoryMessage>> memoryMessages(int dayId) async {
    final rows = await _db.from('messages').select('role, content, created_at').eq('day_id', dayId).order('id');
    return [
      for (final r in rows)
        MemoryMessage(
          fromUser: r['role'] == 'user',
          text: r['content'] as String,
          time: DateTime.parse(r['created_at'] as String).toLocal(),
        ),
    ];
  }

  /// Borra toda la memoria de la persona (conversaciones, resumenes y diarios).
  Future<void> deleteAllMemory() async {
    if (!signedIn) return;
    final id = user!.id;
    await _db.from('messages').delete().eq('user_id', id);
    await _db.from('daily_diaries').delete().eq('user_id', id);
    await _db.from('conversation_days').delete().eq('user_id', id);
  }
}
