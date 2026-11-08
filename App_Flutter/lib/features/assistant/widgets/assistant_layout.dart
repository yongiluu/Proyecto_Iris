import 'package:flutter/material.dart';

/// Ordena la pantalla principal sobre la camara:
///
///   [topBar]   una linea: fase, chip del hardware, engranaje
///   [status]   una o dos lineas de estado
///   [alert]    aviso de vision (si hay)
///   [answer]   respuesta desplazable (si hay); se lleva el espacio libre pero no mas del que usa
///   [carousel] pestañas de modo + pagina con el boton grande
///
/// Separado de la pantalla para poder probarlo sin servicios (letra 2x en 360x640, etc.).
class AssistantLayout extends StatelessWidget {
  const AssistantLayout({
    super.key,
    required this.background,
    required this.topBar,
    required this.status,
    required this.carousel,
    this.alert,
    this.answer,
  });

  final Widget background;
  final Widget topBar;
  final Widget status;
  final Widget? alert;
  final Widget? answer;
  final Widget carousel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        background,
        const _Scrims(),
        SafeArea(
          child: LayoutBuilder(
            builder:
                (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    topBar,
                    // Estado y aviso: con letra muy grande no pueden comerse la pantalla (maximo un
                    // cuarto del alto); si no caben, se desplazan.
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.25),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            status,
                            if (alert != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: alert),
                          ],
                        ),
                      ),
                    ),
                    if (answer != null)
                      Flexible(
                        flex: 4,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Align(alignment: Alignment.topCenter, child: answer),
                        ),
                      ),
                    // Sin respuesta, el carrusel ocupa todo el espacio libre (el boton queda abajo).
                    Expanded(flex: answer != null ? 7 : 1, child: carousel),
                  ],
                ),
          ),
        ),
      ],
    );
  }
}

/// Velos oscuros arriba y abajo: el texto se lee aunque la camara muestre algo claro.
class _Scrims extends StatelessWidget {
  const _Scrims();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              heightFactor: 0.25,
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.5,
              widthFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xD9000000)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
