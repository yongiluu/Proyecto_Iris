import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../assistant_modes.dart';

/// Carrusel de modos. De arriba hacia abajo:
///
///   paginas    cada modo con su iris (se deslizan con el dedo, o con dos dedos en TalkBack)
///   [answer]   la respuesta de Iris, si hay
///   dial       el nombre del modo en grande, con los vecinos a los lados y los puntos de pagina
///
/// El dial se mueve con el dedo junto con las paginas y tambien se puede tocar. Al cambiar de
/// modo se anuncia con una region viva ("Modo Leer texto, 3 de 5"): en Android es la forma
/// recomendada (los anuncios directos estan obsoletos y cortan a TalkBack).
class ModeCarousel extends StatelessWidget {
  const ModeCarousel({
    super.key,
    required this.controller,
    required this.mode,
    required this.onModeChanged,
    required this.pageBuilder,
    this.onTabSelected,
    this.answer,
  });

  final PageController controller;

  /// Modo visible ahora.
  final IrisMode mode;

  /// La pagina cambio (deslizando, por el dial o por un comando de voz).
  final ValueChanged<IrisMode> onModeChanged;

  /// Un nombre del dial fue tocado (si es null, se anima el PageController).
  final ValueChanged<IrisMode>? onTabSelected;
  final Widget Function(BuildContext context, IrisMode mode) pageBuilder;

  /// Respuesta de Iris: va entre el iris y el dial.
  final Widget? answer;

  void _selectTab(BuildContext context, IrisMode target) {
    if (onTabSelected != null) {
      onTabSelected!(target);
      return;
    }
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      controller.jumpToPage(target.index);
    } else {
      controller.animateToPage(target.index, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Region viva: solo cambia (y se anuncia) cuando cambia el modo.
        Semantics(
          key: const ValueKey('anuncio-modo'),
          liveRegion: true,
          container: true,
          label: mode.announcement,
          hint: mode.hint,
          child: const SizedBox(width: 1, height: 1),
        ),
        Expanded(
          flex: 5,
          child: PageView.builder(
            controller: controller,
            itemCount: IrisMode.values.length,
            onPageChanged: (i) => onModeChanged(IrisMode.values[i]),
            itemBuilder: (context, i) => pageBuilder(context, IrisMode.values[i]),
          ),
        ),
        if (answer != null)
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              // Pegada al dial: el iris queda centrado en el espacio de arriba.
              child: Align(alignment: Alignment.bottomCenter, child: answer),
            ),
          ),
        ModeDial(controller: controller, mode: mode, onSelected: (m) => _selectTab(context, m)),
      ],
    );
  }
}

/// Dial de modos: el actual grande y al centro, los vecinos chicos y apagados a los lados.
/// Sigue al dedo: lee la posicion del [controller] en cada cuadro.
class ModeDial extends StatelessWidget {
  const ModeDial({super.key, required this.controller, required this.mode, required this.onSelected});

  final PageController controller;
  final IrisMode mode;
  final ValueChanged<IrisMode> onSelected;

  double get _page {
    if (controller.hasClients && controller.position.haveDimensions) return controller.page ?? mode.index.toDouble();
    return mode.index.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    // Con letra muy grande el dial no crece sin limite: el nombre ya es grande.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final height = scaler.scale(30) + 22;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Deslizar sobre el dial tambien cambia de modo (el iris de arriba no: se mantiene presionado).
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 150) return;
        final next = mode.index + (velocity < 0 ? 1 : -1);
        if (next >= 0 && next < IrisMode.values.length) onSelected(IrisMode.values[next]);
      },
      child: _buildDial(context, scaler, height),
    );
  }

  Widget _buildDial(BuildContext context, TextScaler scaler, double height) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final spacing = width * 0.34;
                final slot = width * 0.46;
                return AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) {
                    final page = _page;
                    // El mas cercano al centro se dibuja al final (queda arriba para los toques).
                    final ordered = [...IrisMode.values]
                      ..sort((a, b) => (b.index - page).abs().compareTo((a.index - page).abs()));
                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        for (final m in ordered)
                          _DialLabel(
                            mode: m,
                            distance: m.index - page,
                            selected: m == mode,
                            centerX: width / 2 + (m.index - page) * spacing,
                            slot: slot,
                            scaler: scaler,
                            onTap: () => onSelected(m),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final page = _page;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in IrisMode.values)
                      Builder(builder: (context) {
                        final t = (1 - (m.index - page).abs()).clamp(0.0, 1.0);
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: 6 + 14 * t,
                          height: 4,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: Color.lerp(Colors.white24, AppTheme.accentCyan, t),
                          ),
                        );
                      }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DialLabel extends StatelessWidget {
  const _DialLabel({
    required this.mode,
    required this.distance,
    required this.selected,
    required this.centerX,
    required this.slot,
    required this.scaler,
    required this.onTap,
  });

  final IrisMode mode;

  /// Paginas de distancia al centro (con signo; fraccionario mientras se desliza).
  final double distance;
  final bool selected;
  final double centerX;
  final double slot;
  final TextScaler scaler;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = distance.abs();
    final near = (1 - d).clamp(0.0, 1.0);
    // Los vecinos se ven apagados; mas alla del vecino se desvanecen.
    final opacity = d <= 1 ? 0.42 + 0.58 * near : (0.42 * (1 - (d - 1) / 0.7)).clamp(0.0, 0.42);
    final scale = 0.52 + 0.48 * near;
    return Positioned(
      left: centerX - slot / 2,
      width: slot,
      top: 0,
      bottom: 0,
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: '${mode.spokenName}, pestaña ${mode.index + 1} de ${IrisMode.values.length}',
        onTap: onTap,
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      mode.shortName,
                      maxLines: 1,
                      softWrap: false,
                      textScaler: scaler,
                      style: TextStyle(
                        color: Color.lerp(AppTheme.textOnDarkMuted, AppTheme.textOnDark, near),
                        fontSize: 30,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.6,
                        shadows: const [Shadow(color: Colors.black87, blurRadius: 12)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
