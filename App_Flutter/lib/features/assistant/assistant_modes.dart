import 'package:flutter/material.dart';

/// De donde salen la camara y el microfono.
enum HardwareMode { standalone, esp32 }

/// Paginas del carrusel de la pantalla principal. Cada una es una sola cosa que hace Iris; el
/// boton grande del centro actua en el modo visible. Por voz todos funcionan desde cualquier pagina.
enum IrisMode {
  assistant(
    shortName: 'Iris',
    spokenName: 'Iris, asistente',
    icon: Icons.auto_awesome,
    hint: 'Pregunta lo que quieras o pide que describa lo que hay al frente',
  ),
  live(
    shortName: 'En vivo',
    spokenName: 'En vivo',
    icon: Icons.sensors,
    hint: 'Iris describe sola lo que va apareciendo adelante',
  ),
  readText(
    shortName: 'Leer',
    spokenName: 'Leer texto',
    icon: Icons.chrome_reader_mode_outlined,
    hint: 'Apunta la camara a un letrero o papel y toca el boton',
  ),
  light(
    shortName: 'Luz',
    spokenName: 'Buscar luz',
    icon: Icons.light_mode_outlined,
    hint: 'Un tono mas agudo significa mas luz',
  ),
  people(
    shortName: 'Personas',
    spokenName: 'Personas',
    icon: Icons.people_alt_outlined,
    hint: 'Reconoce a las personas que guardaste',
  );

  const IrisMode({
    required this.shortName,
    required this.spokenName,
    required this.icon,
    required this.hint,
  });

  /// Nombre corto de la pestaña.
  final String shortName;

  /// Lo que se dice al llegar a esta pagina.
  final String spokenName;
  final IconData icon;

  /// Una linea de ayuda (tambien es la pista de TalkBack).
  final String hint;

  /// "Modo Leer texto, 2 de 4": anuncio para el lector de pantalla.
  String get announcement => 'Modo $spokenName, ${index + 1} de ${IrisMode.values.length}';
}
