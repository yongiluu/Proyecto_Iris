/// Contexto silencioso del modelo Edge AI de audio de la placa.
///
/// La placa manda cada ~10 s lo que mas oyo (CMD_AUDIO_CONTEXT) y, al momento, las alertas
/// (CMD_AUDIO_EVENT). Aqui se guarda lo reciente y se resume en texto para darle contexto a la IA
/// cuando el usuario hace una pregunta.
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

  _Reading? _audio;
  final Map<String, DateTime> _audioEvents = {};

  void onAudioContext(String label, int percent) => _audio = _Reading(label, percent, DateTime.now());
  void onAudioEvent(String label) => _audioEvents[label] = DateTime.now();

  /// Texto para la IA, o null si no hay nada reciente.
  String? describe() {
    final now = DateTime.now();
    final lines = <String>[];

    final audio = _audio;
    if (audio != null && now.difference(audio.time) < _contextMaxAge) {
      lines.add('- Sonido ambiente: ${_audioNames[audio.label] ?? audio.label} (${audio.percent}% del tiempo).');
    }
    for (final entry in _audioEvents.entries) {
      final age = now.difference(entry.value);
      if (age < _eventMaxAge) lines.add('- Se escucho ${_audioNames[entry.key] ?? entry.key} hace ${age.inSeconds} s.');
    }
    if (lines.isEmpty) return null;

    return 'Contexto de los sensores del usuario (placa; modelos pequenos, pueden equivocarse; '
        'usalo solo si ayuda a responder y no lo menciones si no es relevante):\n${lines.join('\n')}';
  }
}

class _Reading {
  final String label;
  final int percent;
  final DateTime time;

  const _Reading(this.label, this.percent, this.time);
}
