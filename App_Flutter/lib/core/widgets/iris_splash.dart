import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Marca donde esta el iris grande de la pantalla, para que el del arranque nazca exactamente
/// encima (mismo centro y mismo tamaño) y no se vean dos iris desalineados.
class IrisSplashAnchor extends StatelessWidget {
  const IrisSplashAnchor({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Arranque de Iris: el logo aparece sobre el iris de la pantalla y se abre hasta que sus rayos
/// salen por los bordes, dejando ver la app por el hueco del medio (como un iris que se dilata).
/// Debajo queda el iris real, en el mismo lugar.
///
/// [child] se construye desde el primer cuadro (los servicios arrancan mientras tanto). Con
/// "quitar animaciones" del sistema no se muestra.
class IrisSplash extends StatefulWidget {
  const IrisSplash({super.key, required this.child});

  final Widget child;

  @override
  State<IrisSplash> createState() => _IrisSplashState();
}

class _IrisSplashState extends State<IrisSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2300));

  /// Centro y diametro del iris de la pantalla (null = centro de la pantalla).
  final ValueNotifier<Rect?> _anchor = ValueNotifier(null);
  bool _done = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _done = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _findAnchor());
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  /// Busca el iris grande ya dibujado debajo. Solo al principio, mientras el logo esta chico:
  /// despues no se mueve aunque la pantalla de abajo cambie.
  void _findAnchor() {
    if (!mounted || _done) return;
    final origin = context.findRenderObject();
    Rect? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget is IrisSplashAnchor) {
        final box = element.findRenderObject();
        if (box is RenderBox && box.hasSize && box.attached && origin is RenderBox) {
          found = box.localToGlobal(Offset.zero, ancestor: origin) & box.size;
          return;
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    if (found != null) {
      _anchor.value = found;
    } else if (_controller.value < 0.2) {
      // La pantalla de abajo todavia no puso su iris: probar en el cuadro siguiente.
      WidgetsBinding.instance.addPostFrameCallback((_) => _findAnchor());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _anchor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_done)
          // Absorbe los toques hasta que la app queda a la vista.
          AbsorbPointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: CustomPaint(painter: _SplashPainter(_controller, _anchor), size: Size.infinite),
              ),
            ),
          ),
      ],
    );
  }
}

class _SplashPainter extends CustomPainter {
  _SplashPainter(this.progress, this.anchor) : super(repaint: Listenable.merge([progress, anchor]));

  final Animation<double> progress;
  final ValueNotifier<Rect?> anchor;

  // Misma geometria que el iris de la pantalla (IrisPainter).
  static const int _rays = 24;
  static const double _step = 2 * math.pi / _rays;
  static const double _fill = 0.84;
  static const double _innerRatio = 0.40;
  static const double _defaultSize = 150;

  static double _segment(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final target = anchor.value;
    final center = target?.center ?? size.center(Offset.zero);
    final logoRadius = (target?.shortestSide ?? _defaultSize) / 2 * _fill;
    // Hasta la esquina mas lejana: el hueco tiene que cubrir toda la pantalla.
    final reach = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((corner) => (corner - center).distance).reduce(math.max);

    final appear = Curves.easeOutCubic.transform(_segment(t, 0.0, 0.26));
    final open = Curves.easeInOutCubic.transform(_segment(t, 0.46, 1.0));
    final fade = Curves.easeIn.transform(_segment(t, 0.62, 0.98));

    // Crece hasta que el hueco del centro es mas grande que la pantalla: solo se ven los rayos
    // saliendo por los bordes, nunca el circulo completo.
    final maxScale = reach / (logoRadius * _innerRatio) * 1.2;
    final scale = appear * (1 + open * open * (maxScale - 1));
    final radius = logoRadius * scale;
    final inner = radius * _innerRatio;

    // Fondo: tapa la app y se abre desde el centro junto con el iris. El iris real queda oculto
    // hasta que el hueco lo supera.
    if (open == 0) {
      canvas.drawRect(Offset.zero & size, Paint()..color = AppTheme.ink);
    } else {
      final edge = (inner / reach).clamp(0.0, 0.97);
      final background = Paint()
        ..shader = RadialGradient(
          colors: [
            AppTheme.ink.withValues(alpha: 0),
            AppTheme.ink.withValues(alpha: 1 - fade),
            AppTheme.ink.withValues(alpha: 1 - fade),
          ],
          stops: [edge, (edge + 0.02).clamp(0.0, 0.99), 1],
        ).createShader(Rect.fromCircle(center: center, radius: reach));
      canvas.drawRect(Offset.zero & size, background);
    }

    if (radius <= 0) return;
    final halo = Paint()
      ..shader = RadialGradient(
        colors: [AppTheme.accentCyan.withValues(alpha: 0.22 * (1 - fade)), AppTheme.accentCyan.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 1.7));
    canvas.drawCircle(center, radius * 1.7, halo);

    final paint = Paint()
      ..isAntiAlias = true
      ..color = AppTheme.accentCyan.withValues(alpha: 1 - fade * 0.9);
    final innerHalf = radius * 0.014;
    final outerHalf = radius * 0.062;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    // Gira dos pasos al aparecer y queda con los rayos en el mismo angulo que el iris real; al
    // abrirse gira pasos enteros, asi los rayos siempre coinciden con los de abajo.
    canvas.rotate(-2 * _step * (1 - appear) + 2 * _step * open);
    for (int i = 0; i < _rays; i++) {
      final path = Path()
        ..moveTo(-innerHalf, -inner)
        ..lineTo(innerHalf, -inner)
        ..lineTo(outerHalf, -radius)
        ..lineTo(-outerHalf, -radius)
        ..close();
      canvas.drawPath(path, paint);
      canvas.rotate(_step);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SplashPainter oldDelegate) => false;
}
