/// Lo que la persona pide por voz y que Iris resuelve SIN preguntarle al modelo de lenguaje:
/// leer texto, buscar luz, reconocer personas conocidas. Es instantaneo y funciona sin internet.
///
/// Una persona ciega no puede buscar un boton en la pantalla: "Oye Iris, ¿que dice aqui?" tiene
/// que bastar. Todo lo que no calce aqui sigue al agente (descripciones, preguntas, clima...).
library;

enum IrisIntentType {
  /// "¿Que dice aqui?", "leeme esto", "¿que dice el letrero?"
  readText,

  /// "Busca la luz", "detector de luz", "¿hay luz?"
  lightOn,

  /// "Apaga el detector de luz", "deja de buscar luz"
  lightOff,

  /// "¿Quien esta aqui?", "¿hay alguien conocido?"
  whoIsHere,

  /// "Recuerda a Raul", "esta es Ana", "guarda la cara de Raul"
  rememberPerson,

  /// "Olvida a Raul", "borra la cara de Raul"
  forgetPerson,

  /// Cualquier otra cosa: va al agente.
  none,
}

class IrisIntent {
  const IrisIntent(this.type, {this.name});

  final IrisIntentType type;

  /// Nombre de la persona (rememberPerson / forgetPerson), con mayuscula inicial.
  final String? name;

  static const IrisIntent none = IrisIntent(IrisIntentType.none);

  @override
  String toString() => name == null ? type.name : '${type.name}($name)';
}

class VoiceIntents {
  VoiceIntents._();

  static final RegExp _readText = RegExp(
    r'(que dice|que es lo que dice|que pone|que esta escrito|que hay escrito|'
    r'\blee(me|lo|la)?\b|\bleer\b|\blectura\b|leeme|lector de texto|que texto)',
  );

  static final RegExp _lightOff = RegExp(
    r'((apaga|desactiva|deten|para|quita|cierra)( el| la)? (detector|modo|busqueda)? ?(de )?(la )?luz|'
    r'deja de buscar (la )?luz|ya (encontre|halle) la luz|sin luz)',
  );

  static final RegExp _lightOn = RegExp(
    r'(detector de luz|busca(r)? (la )?luz|donde (hay|esta) (la )?luz|hay luz|'
    r'(esta|estan) (prendida|encendida|prendidas|encendidas) (la|las)? ?luz|modo luz|la luz esta)',
  );

  static final RegExp _whoIsHere = RegExp(
    r'(quien (esta|es|hay)|quienes (estan|son)|hay alguien( conocido)?|reconoce(s)?( a)?( la)? (persona|cara)|'
    r'conozco a (esta|alguien)|a quien tengo)',
  );

  // "recuerda a raul", "recuerda la cara de raul", "esta es ana", "este es raul", "guarda a raul"
  static final RegExp _remember = RegExp(
    r'^(recuerda|recordar|aprende|guarda|memoriza|registra)( la cara de| a| la cara)? (?<name>[a-z ]{2,30})$|'
    r'^(esta|este) es (?<name2>[a-z ]{2,30})$',
  );

  static final RegExp _forget = RegExp(
    r'^(olvida|borra|elimina)( la cara de| a| la cara)? (?<name>[a-z ]{2,30})$',
  );

  /// Palabras que no pueden ser un nombre ("esta es la puerta", "recuerda que manana...").
  static const Set<String> _notNames = {
    'que', 'la', 'el', 'una', 'un', 'mi', 'tu', 'esto', 'eso', 'esta', 'este', 'puerta', 'calle',
    'casa', 'hora', 'manana', 'hoy', 'ayer', 'cuando', 'donde', 'como', 'lo', 'todo', 'nada',
  };

  /// Analiza la transcripcion (ya sin "Oye Iris").
  static IrisIntent parse(String transcript) {
    final text = normalize(transcript);
    if (text.isEmpty) return IrisIntent.none;

    final remember = _remember.firstMatch(text);
    if (remember != null) {
      final name = _cleanName(remember.namedGroup('name') ?? remember.namedGroup('name2'));
      if (name != null) return IrisIntent(IrisIntentType.rememberPerson, name: name);
    }
    final forget = _forget.firstMatch(text);
    if (forget != null) {
      final name = _cleanName(forget.namedGroup('name'));
      if (name != null) return IrisIntent(IrisIntentType.forgetPerson, name: name);
    }
    // "Apaga la luz" antes que "luz": si no, prenderia el detector.
    if (_lightOff.hasMatch(text)) return const IrisIntent(IrisIntentType.lightOff);
    if (_lightOn.hasMatch(text)) return const IrisIntent(IrisIntentType.lightOn);
    if (_readText.hasMatch(text)) return const IrisIntent(IrisIntentType.readText);
    if (_whoIsHere.hasMatch(text)) return const IrisIntent(IrisIntentType.whoIsHere);
    return IrisIntent.none;
  }

  static String? _cleanName(String? raw) {
    if (raw == null) return null;
    final words = raw.trim().split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty || words.length > 3 || _notNames.contains(words.first)) return null;
    return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  /// Minusculas, sin tildes ni signos.
  static String normalize(String text) {
    const from = 'áéíóúüñ';
    const to = 'aeiouun';
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      final i = from.indexOf(char);
      buffer.write(i >= 0 ? to[i] : char);
    }
    return buffer
        .toString()
        .replaceAll(RegExp(r'[¿?¡!.,;:"]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
