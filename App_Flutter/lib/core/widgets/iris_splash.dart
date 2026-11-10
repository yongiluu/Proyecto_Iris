import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Arranque de Iris: el logo aparece chico en el centro y se abre hasta que sus rayos salen de
/// la pantalla, dejando ver la app por el hueco del medio (como un iris que se dilata).
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
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
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
                child: CustomPaint(painter: _SplashPainter(_controller), size: Size.infinite),
              ),
            ),
          ),
      ],
    );
  }
}

class _SplashPainter extends CustomPainter {
  _SplashPainter(this.progress) : super(repaint: progress);

  final Animation<double> progress;

  static const int _rays = 24;
  static const double _logoRadius = 46;

  static double _segment(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final center = size.center(Offset.zero);
    final diagonal = size.bottomRight(Offset.zero).distance;

    final appear = Curves.easeOutBack.transform(_segment(t, 0.0, 0.26));
    final open = Curves.easeInOutCubic.transform(_segment(t, 0.46, 1.0));
    final fade = Curves.easeIn.transform(_segment(t, 0.58, 0.96));

    // Crece hasta que el hueco del centro es mas grande que la pantalla: solo se ven los rayos
    // saliendo por los bordes, nunca el circulo completo.
    final maxScale = diagonal / (_logoRadius * 0.40) * 1.15;
    final scale = appear * (1 + open * open * (maxScale - 1));
    final radius = _logoRadius * scale;
    final inner = radius * 0.40;

    // Fondo: se abre desde el centro junto con el iris.
    final background = Paint()
      ..shader = RadialGradient(
        colors: [
          AppTheme.ink.withValues(alpha: 0),
          AppTheme.ink.withValues(alpha: 1 - fade),
          AppTheme.ink.withValues(alpha: 1 - fade),
        ],
        stops: [(inner / diagonal).clamp(0.0, 0.98), (inner * 1.6 / diagonal).clamp(0.01, 0.99), 1],
      ).createShader(Rect.fromCircle(center: center, radius: diagonal));
    canvas.drawRect(Offset.zero & size, open == 0 ? (Paint()..color = AppTheme.ink) : background);

    if (radius <= 0) return;
    final halo = Paint()
      ..shader = RadialGradient(
        colors: [AppTheme.accentCyan.withValues(alpha: 0.22 * (1 - fade)), AppTheme.accentCyan.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius * 1.7));
    canvas.drawCircle(center, radius * 1.7, halo);

    final paint = Paint()
      ..isAntiAlias = true
      ..color = Color.lerp(AppTheme.accentCyan, AppTheme.brightCyan, open)!.withValues(alpha: 1 - fade * 0.85);
    final innerHalf = radius * 0.014;
    final outerHalf = radius * 0.062;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.35 * (1 - appear) + 0.5 * open);
    for (int i = 0; i < _rays; i++) {
      final path = Path()
        ..moveTo(-innerHalf, -inner)
        ..lineTo(innerHalf, -inner)
        ..lineTo(outerHalf, -radius)
        ..lineTo(-outerHalf, -radius)
        ..close();
      canvas.drawPath(path, paint);
      canvas.rotate(2 * math.pi / _rays);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SplashPainter oldDelegate) => false;
}
