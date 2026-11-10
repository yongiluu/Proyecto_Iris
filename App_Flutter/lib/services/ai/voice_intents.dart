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

  /// "Repite", "¿que dijiste?", "no te entendi"
  repeat,

  /// "¿Que puedes hacer?", "ayuda"
  help,

  /// "¿Que hora es?", "¿que dia es hoy?"
  time,

  /// "Habla mas lento" / "mas despacio"
  slower,

  /// "Habla mas rapido"
  faster,

  /// "Callate", "silencio", "para" (corta la voz y lo que este haciendo)
  stop,

  /// "Describe en vivo", "avisame lo que veas": la placa describe sola cada cambio
  liveOn,

  /// "Deja de describir", "apaga el modo en vivo"
  liveOff,

  /// "Mas detalle", "describe en detalle": va a la nube (la placa ya dio la version rapida)
  moreDetail,

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

  static final RegExp _liveOff = RegExp(
    r'^((apaga|desactiva|para|deten|termina|quita)( el)? (modo )?(en )?vivo|deja de (describir|avisar|avisarme)|'
    r'ya no (describas|me avises)|para de describir)( por favor| porfa| iris)*$',
  );

  static final RegExp _liveOn = RegExp(
    r'^((activa|prende|enciende|pon|inicia|empieza)( el)? (modo )?(en )?vivo|modo en vivo|'
    r'describe (en vivo|todo el tiempo|mientras camino|lo que vayas viendo)|'
    r'avisame (lo que (veas|vaya apareciendo|aparezca)|si (ves|aparece) algo)|'
    r've (diciendome|describiendome|describiendo) lo que (ves|hay))( por favor| porfa| iris)*$',
  );

  static final RegExp _moreDetail = RegExp(
    r'(mas detalle|con detalle|en detalle|mas detallado|detalladamente|describe(lo)? mejor|'
    r'explicame mejor (que|lo que) (hay|ves))',
  );

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

  // Frases cortas y completas: "describe otra vez" NO es repetir (es pedir otra descripcion).
  static final RegExp _repeat = RegExp(
    r'^((me )?(lo )?(puedes |podrias )?(repite|repetir|repitelo|repiteme|repitemelo|repetirlo)( lo que dijiste| eso| lo ultimo| la respuesta)?|'
    r'que dijiste|que me dijiste|no te (escuche|entendi|oi)|otra vez|de nuevo)( por favor| porfa| iris)*$',
  );

  static final RegExp _help = RegExp(
    r'^((que|en que) (puedes|sabes|me puedes) (hacer|ayudar(me)?)|ayuda|ayudame|como (te uso|funcionas)|'
    r'que comandos (hay|tienes|existen)|cuales son (los|tus) comandos)( por favor| iris)*$',
  );

  static final RegExp _time = RegExp(
    r'^(que hora es|que horas son|me (dices|das) la hora|la hora|que dia es( hoy)?|que fecha es( hoy)?|'
    r'en que (dia|fecha) estamos|a cuanto estamos)( hoy)?( por favor| iris)*$',
  );

  static final RegExp _slower = RegExp(
    r'^((habla|hablame|lee|leeme|dilo|ve) )?(un poco )?mas (lento|despacio)( por favor| porfa| iris)*$|'
    r'^(habla|hablame|lee|leeme) (lento|despacio|lentamente|mas pausado)( por favor| porfa| iris)*$',
  );
  static final RegExp _faster = RegExp(
    r'^((habla|hablame|lee|leeme|dilo|ve) )?(un poco )?mas (rapido|ligero)( por favor| porfa| iris)*$|'
    r'^(habla|hablame|lee|leeme) (rapido|ligero|rapidamente)( por favor| porfa| iris)*$',
  );

  static final RegExp _stop = RegExp(
    r'^(callate|silencio|para|detente|deten|basta|stop|ya basta|cancela|cancelar|para de hablar|deja de hablar)( ya| por favor| iris)*$',
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

    if (_stop.hasMatch(text)) return const IrisIntent(IrisIntentType.stop);
    if (_repeat.hasMatch(text)) return const IrisIntent(IrisIntentType.repeat);
    if (_help.hasMatch(text)) return const IrisIntent(IrisIntentType.help);
    if (_time.hasMatch(text)) return const IrisIntent(IrisIntentType.time);
    if (_slower.hasMatch(text)) return const IrisIntent(IrisIntentType.slower);
    if (_faster.hasMatch(text)) return const IrisIntent(IrisIntentType.faster);

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
    if (_liveOff.hasMatch(text)) return const IrisIntent(IrisIntentType.liveOff);
    if (_liveOn.hasMatch(text)) return const IrisIntent(IrisIntentType.liveOn);
    if (_moreDetail.hasMatch(text)) return const IrisIntent(IrisIntentType.moreDetail);
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

/// Respuestas que Iris da sin internet.
class LocalAnswers {
  LocalAnswers._();

  static const String help = 'Puedes decirme: que hay adelante, y si quieres, mas detalle. '
      'Describe en vivo, para que te avise lo que vaya apareciendo, y deja de describir. '
      'Que dice aqui para leer un letrero, busca la luz, quien esta aqui, o recuerda a y un nombre. '
      'Tambien: repite, que hora es, habla mas lento o mas rapido, y callate. '
      'Y puedes preguntarme lo que quieras, como el clima o donde estas.';

  static const List<String> _days = ['lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo'];
  static const List<String> _months = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];

  /// "Son las 3 y 25 de la tarde. Hoy es domingo 8 de noviembre."
  static String time(DateTime now) {
    final h24 = now.hour, m = now.minute;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final part = h24 < 6
        ? 'de la madrugada'
        : h24 < 12
            ? 'de la manana'
            : h24 < 20
                ? 'de la tarde'
                : 'de la noche';
    final clock = m == 0
        ? '$h12 en punto'
        : m == 15
            ? '$h12 y cuarto'
            : m == 30
                ? '$h12 y media'
                : '$h12 y $m';
    final verb = h12 == 1 ? 'Es la' : 'Son las';
    return '$verb $clock $part. Hoy es ${_days[now.weekday - 1]} ${now.day} de ${_months[now.month - 1]}.';
  }
}
