import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Logo de Iris (sol de 24 rayos) dibujado en codigo: nitido a cualquier tamano y de cualquier color.
/// Con `spinning` gira, para mostrar que Iris esta escuchando o pensando. Si el sistema pide
/// reducir animaciones, queda quieto.
class IrisLogo extends StatefulWidget {
  const IrisLogo({
    super.key,
    this.size = 24,
    this.color = AppTheme.accentCyan,
    this.spinning = false,
    this.turnDuration = const Duration(milliseconds: 2400),
  });

  final double size;
  final Color color;
  final bool spinning;

  /// Tiempo de una vuelta completa.
  final Duration turnDuration;

  @override
  State<IrisLogo> createState() => _IrisLogoState();
}

class _IrisLogoState extends State<IrisLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.turnDuration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(IrisLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turnDuration != widget.turnDuration) _controller.duration = widget.turnDuration;
    _sync();
  }

  void _sync() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.spinning && !reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RotationTransition(
        turns: _controller,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _SunburstPainter(widget.color),
        ),
      ),
    );
  }
}

class _SunburstPainter extends CustomPainter {
  _SunburstPainter(this.color);

  final Color color;
  static const int _rays = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final center = size.center(Offset.zero);
    final inner = radius * 0.38;
    final innerHalf = radius * 0.012; // rayos finos por dentro...
    final outerHalf = radius * 0.06; // ...y anchos por fuera
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    canvas.save();
    canvas.translate(center.dx, center.dy);
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
  bool shouldRepaint(_SunburstPainter oldDelegate) => oldDelegate.color != color;
}
