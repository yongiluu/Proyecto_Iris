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
  final int photosPerTake;  // fotos, una cada ~0,5 s

  const Mission.audio({
    required this.id,
    required this.label,
    required this.scene,
    required this.title,
    required this.instructions,
    required this.takes,
    this.secondsPerTake = 30,
  })  : kind = MissionKind.audio,
        photosPerTake = 0;

  const Mission.photo({
    required this.id,
    required this.label,
    required this.scene,
    required this.title,
    required this.instructions,
    required this.takes,
    this.photosPerTake = 25,
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
];
