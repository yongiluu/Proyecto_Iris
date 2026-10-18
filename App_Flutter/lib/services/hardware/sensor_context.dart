/// Contexto silencioso de los modelos Edge AI de la placa (audio y vision) o, en modo Celular, de la
/// vision local del celular (PhoneVisionService, mismo modelo).
///
/// La placa manda cada ~10 s lo que mas oyo y vio (CMD_AUDIO_CONTEXT / CMD_VISION_CONTEXT) y,
/// al momento, las alertas (CMD_AUDIO_EVENT / CMD_VISION_EVENT). Aqui se guarda lo reciente
/// y se resume en texto para darle contexto a la IA cuando el usuario hace una pregunta.
class SensorContext {
  static const Duration _contextMaxAge = Duration(seconds: 30);
  static const Duration _eventMaxAge = Duration(minutes: 2);

  static const Map<String, String> _audioNames = {
    'fondo': 'ruido de fondo sin voces',
    'voz': 'personas hablando',
    'bocina': 'una bocina',
    'sirena': 'una sirena',
    'perro': 'un perro ladrando',
  };
  static const Map<String, String> _visionNames = {
    'nada': 'nada en particular',
    'persona': 'una persona',
    'vehiculo': 'un vehiculo',
    'escalera': 'una escalera',
    'puerta': 'una puerta',
  };

  _Reading? _audio;
  _Reading? _vision;
  final Map<String, DateTime> _audioEvents = {};
  final Map<String, DateTime> _visionEvents = {};
  int _proximityLevel = 0;
  DateTime? _proximityTime;

  void onAudioContext(String label, int percent) => _audio = _Reading(label, percent, DateTime.now());
  void onVisionContext(String label, int percent) => _vision = _Reading(label, percent, DateTime.now());
  void onAudioEvent(String label) => _audioEvents[label] = DateTime.now();
  void onVisionEvent(String label) => _visionEvents[label] = DateTime.now();
  void onProximity(int level) {
    _proximityLevel = level;
    _proximityTime = DateTime.now();
  }

  /// Texto para la IA, o null si no hay nada reciente.
  String? describe() {
    final now = DateTime.now();
    final lines = <String>[];

    final audio = _audio;
    if (audio != null && now.difference(audio.time) < _contextMaxAge) {
      lines.add('- Sonido ambiente: ${_audioNames[audio.label] ?? audio.label} (${audio.percent}% del tiempo).');
    }
    final vision = _vision;
    if (vision != null && now.difference(vision.time) < _contextMaxAge) {
      lines.add('- Camara: ${_visionNames[vision.label] ?? vision.label} al frente (${vision.percent}% de los cuadros).');
    }
    final proximityTime = _proximityTime;
    if (_proximityLevel > 0 && proximityTime != null && now.difference(proximityTime) < _contextMaxAge) {
      lines.add('- Cercania: hay algo ${_proximityLevel >= 2 ? 'muy cerca' : 'cerca'} al frente (a menos de ~1 m).');
    }
    for (final entry in _audioEvents.entries) {
      final age = now.difference(entry.value);
      if (age < _eventMaxAge) lines.add('- Se escucho ${_audioNames[entry.key] ?? entry.key} hace ${age.inSeconds} s.');
    }
    for (final entry in _visionEvents.entries) {
      final age = now.difference(entry.value);
      if (age < _eventMaxAge) lines.add('- Se vio ${_visionNames[entry.key] ?? entry.key} hace ${age.inSeconds} s.');
    }
    if (lines.isEmpty) return null;

    return 'Contexto de los sensores del usuario (placa o celular; modelos pequenos, pueden equivocarse; '
        'usalo solo si ayuda a responder y no lo menciones si no es relevante):\n${lines.join('\n')}';
  }
}

class _Reading {
  final String label;
  final int percent;
  final DateTime time;

  const _Reading(this.label, this.percent, this.time);
}
