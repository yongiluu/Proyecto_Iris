import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Ordena la pantalla principal sobre el fondo (camara, foto de la placa o aurora):
///
///   [topBar]   una linea: fase, indicador de conexion, configuracion
///   [status]   una o dos lineas de estado
///   [alert]    aviso de vision (si hay)
///   [carousel] el iris del modo, la respuesta (si hay) y el dial de modos
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
  });

  final Widget background;
  final Widget topBar;
  final Widget status;
  final Widget? alert;
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
                            if (alert != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 6), child: alert),
                          ],
                        ),
                      ),
                    ),
                    Expanded(child: carousel),
                  ],
                ),
          ),
        ),
      ],
    );
  }
}

/// Velos oscuros arriba y abajo: el texto se lee aunque la camara muestre algo claro.
/// Con el tono del fondo (negro azulado) para que se fundan con la aurora.
class _Scrims extends StatelessWidget {
  const _Scrims();

  @override
  Widget build(BuildContext context) {
    final ink = AppTheme.ink;
    Widget veil(Alignment alignment, double height, List<double> alphas) => Align(
          alignment: alignment,
          child: FractionallySizedBox(
            heightFactor: height,
            widthFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [for (final a in alphas) ink.withValues(alpha: a)],
                ),
              ),
            ),
          ),
        );
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          veil(Alignment.topCenter, 0.25, const [0.70, 0]),
          veil(Alignment.bottomCenter, 0.45, const [0, 0.80]),
        ],
      ),
    );
  }
}
