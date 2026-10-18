/// Misiones de recoleccion de datos con la placa (para reentrenar los modelos Edge AI).
///
/// `label` es la clase de entrenamiento: debe existir en ML_Training/audio/config.py (audio) o en
/// ML_Training/vision/config.py (fotos). `scene` es el contexto del ambiente: va en el nombre del
/// archivo para entrenar mas adelante un modelo de ambiente (casa, calle, transporte).
///
/// Total aproximado: ~15 min de audio y ~750 fotos (~7 min caminando). Edita la lista para
/// pedir mas o menos.
library;

enum MissionKind { audio, photo }

class Mission {
  final String id;
  final MissionKind kind;
  final String label;
  final String scene;
  final String title;
  final String instructions;
  final int takes;          // grabaciones (audio) o tandas de fotos
  final int secondsPerTake; // audio
  final int photosPerTake;  // fotos
  final int photoIntervalMs; // pausa entre fotos de una tanda
  /// Ademas del BMP 96x96, guarda en modo Celular un JPEG a color de 320 px de lado corto
  /// (lo etiqueta en el PC un modelo de profundidad: ML_Training/vision/depth_labels.py).
  final bool saveColorJpeg;
  /// Titulo de seccion en la lista (null = sin seccion propia).
  final String? section;

  const Mission.audio({
    required this.id,
    required this.label,
    required this.scene,
    required this.title,
    required this.instructions,
    required this.takes,
    this.secondsPerTake = 30,
    this.section,
  })  : kind = MissionKind.audio,
        photosPerTake = 0,
        photoIntervalMs = 0,
        saveColorJpeg = false;

  const Mission.photo({
    required this.id,
    required this.label,
    required this.scene,
    required this.title,
    required this.instructions,
    required this.takes,
    this.photosPerTake = 25,
    this.photoIntervalMs = 500,
    this.saveColorJpeg = false,
    this.section,
  })  : kind = MissionKind.photo,
        secondsPerTake = 0;

  /// Lo que se cuenta para el progreso: grabaciones (audio) o fotos.
  int get target => kind == MissionKind.audio ? takes : takes * photosPerTake;
}

const List<Mission> missions = [
  // ─── Audio: lo mas importante es el "fondo" en lugares distintos (evita falsas alarmas) ───
  Mission.audio(
    id: 'audio_casa',
    label: 'fondo',
    scene: 'casa',
    title: 'Audio en casa',
    instructions: 'Sin hablar. Cambia de pieza entre grabaciones (cocina, living, baño). '
        'Vale con tele o lavadora sonando.',
    takes: 6,
  ),
  Mission.audio(
    id: 'audio_calle',
    label: 'fondo',
    scene: 'calle',
    title: 'Audio de calle',
    instructions: 'Caminando por la vereda, sin hablar. Calles tranquilas y con trafico. '
        'Lleva la placa donde la usaria la persona.',
    takes: 8,
  ),
  Mission.audio(
    id: 'audio_transporte',
    label: 'fondo',
    scene: 'transporte',
    title: 'Audio en micro o metro',
    instructions: 'Dentro del micro, metro o auto. Sin hablar tu.',
    takes: 4,
  ),
  Mission.audio(
    id: 'audio_voz',
    label: 'voz',
    scene: 'casa',
    title: 'Voces',
    instructions: 'Tu hablando o una conversacion cerca de la placa. Cambia de persona si puedes.',
    takes: 5,
  ),
  Mission.audio(
    id: 'audio_sirena',
    label: 'sirena',
    scene: 'parlante',
    title: 'Sirenas',
    instructions: 'Pon videos de sirenas (ambulancia, bomberos, policia) en un parlante, '
        'a 1, 3 y 5 metros de la placa.',
    takes: 3,
    secondsPerTake: 20,
  ),
  Mission.audio(
    id: 'audio_bocina',
    label: 'bocina',
    scene: 'parlante',
    title: 'Bocinas',
    instructions: 'Videos de bocinas de autos, micros y camiones en un parlante, a distintas distancias.',
    takes: 3,
    secondsPerTake: 20,
  ),
  Mission.audio(
    id: 'audio_perro',
    label: 'perro',
    scene: 'parlante',
    title: 'Perros',
    instructions: 'Un perro de verdad o videos de ladridos en un parlante.',
    takes: 3,
    secondsPerTake: 20,
  ),

  // ─── Wake word "Oye Iris": para que Iris empiece a escuchar sin tocar nada ───
  // No son clases del modelo de audio: import_phone_data.py las copia a data/wakeword_board/.
  Mission.audio(
    id: 'wake_oye_iris',
    label: 'oye_iris',
    scene: 'varios',
    title: 'Decir "Oye Iris"',
    instructions: 'Di "Oye Iris" cada 2 o 3 segundos, con pausas entre medio. Cambia el tono, el volumen '
        'y la distancia (cerca de la boca y a 1 m). Graba en casa y en la calle, y si puedes, que lo digan '
        'otras personas.',
    takes: 20,
    section: 'Iris Wake Word',
  ),
  Mission.audio(
    id: 'wake_parecidas',
    label: 'no_wake',
    scene: 'varios',
    title: 'Frases parecidas (no deben activar)',
    instructions: 'Di cosas que NO deben despertar a Iris: "oye", "Iris" sola, "oye Isis", "hoy es", '
        '"oye, mira", nombres parecidos y conversacion normal.',
    takes: 8,
    section: 'Iris Wake Word',
  ),

  // ─── Fotos: la placa a la altura del pecho, caminando despacio ───
  Mission.photo(
    id: 'foto_nada_casa',
    label: 'nada',
    scene: 'casa',
    title: 'Fotos de "nada" en casa',
    instructions: 'Paredes, pasillos, muebles, piso, ventanas. Sin personas, puertas ni escaleras al frente.',
    takes: 4,
    photosPerTake: 50,
  ),
  Mission.photo(
    id: 'foto_nada_calle',
    label: 'nada',
    scene: 'calle',
    title: 'Fotos de "nada" en la calle',
    instructions: 'Vereda, arboles, rejas, fachadas. Sin autos, personas, puertas ni escaleras al frente.',
    takes: 4,
    photosPerTake: 50,
  ),
  Mission.photo(
    id: 'foto_puerta',
    label: 'puerta',
    scene: 'varios',
    title: 'Puertas',
    instructions: 'Acercate caminando a puertas distintas (casa, edificios, tiendas), de frente y de lado.',
    takes: 4,
  ),
  Mission.photo(
    id: 'foto_escalera',
    label: 'escalera',
    scene: 'varios',
    title: 'Escaleras',
    instructions: 'Acercate a escaleras subiendo y bajando, de interior y exterior. Con cuidado.',
    takes: 4,
  ),
  Mission.photo(
    id: 'foto_vehiculo',
    label: 'vehiculo',
    scene: 'calle',
    title: 'Vehiculos',
    instructions: 'Autos estacionados, micros, bicicletas. Desde la vereda, a distintas distancias.',
    takes: 4,
  ),
  Mission.photo(
    id: 'foto_persona',
    label: 'persona',
    scene: 'varios',
    title: 'Personas',
    instructions: 'Con permiso: alguien parado o caminando frente a ti, cerca y lejos.',
    takes: 4,
    photosPerTake: 15,
  ),
  Mission.photo(
    id: 'foto_cruce',
    label: 'cruce',
    scene: 'calle',
    title: 'Cruces peatonales',
    instructions: 'Parate en la vereda frente a un cruce de cebra, a 1-4 m, celular a la altura del pecho; '
        'muevete un poco entre fotos y prueba cruces distintos.',
    takes: 4,
  ),

  // ─── Cercania: para un detector de "obstaculo muy cerca" (no es clase del modelo de 5 clases) ───
  Mission.photo(
    id: 'cercania_casa',
    label: 'cercania',
    scene: 'casa',
    title: 'Acercarse a obstaculos (casa)',
    instructions: 'Celular a la altura del pecho, camina despacio hasta quedar muy cerca. '
        'Repite con paredes lisas, muebles, puertas cerradas, postes y personas.',
    takes: 6,
    photosPerTake: 40,
    photoIntervalMs: 300,
    saveColorJpeg: true,
  ),
  Mission.photo(
    id: 'cercania_calle',
    label: 'cercania',
    scene: 'calle',
    title: 'Acercarse a obstaculos (calle)',
    instructions: 'Celular a la altura del pecho, camina despacio hasta quedar muy cerca. '
        'Repite con paredes lisas, muebles, puertas cerradas, postes y personas.',
    takes: 6,
    photosPerTake: 40,
    photoIntervalMs: 300,
    saveColorJpeg: true,
  ),
];
