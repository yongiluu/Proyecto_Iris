import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/iris_splash.dart';

/// Lo que esta haciendo Iris: cada estado mueve el logo de otra forma.
enum IrisState {
  /// Reposo: respira despacio.
  idle,

  /// Escuchando: los rayos se alargan y encogen como una onda de voz.
  listening,

  /// Pensando: los rayos se deshacen en puntos que giran en anillos.
  thinking,

  /// Respondiendo o describiendo: los rayos se levantan y bajan, alternados, sin perder el circulo.
  speaking,
}

/// Logo de Iris (sol de 24 rayos) dibujado en codigo y vivo: respira, escucha, piensa y habla.
/// Si el sistema pide reducir animaciones queda quieto, mostrando la forma de cada estado.
class IrisLogo extends StatefulWidget {
  const IrisLogo({
    super.key,
    this.size = 24,
    this.color,
    this.thinkingColor,
    this.state = IrisState.idle,
    this.glow = false,
  });

  final double size;

  /// Por defecto, el cian de la marca.
  final Color? color;

  /// Color hacia el que viran los puntos de afuera mientras piensa (por defecto, violeta).
  final Color? thinkingColor;
  final IrisState state;

  /// Halo de luz detras (para el logo grande).
  final bool glow;

  @override
  State<IrisLogo> createState() => _IrisLogoState();
}

class _IrisLogoState extends State<IrisLogo> with TickerProviderStateMixin {
  static const _blend = Duration(milliseconds: 520);

  late final AnimationController _think = AnimationController(vsync: this, duration: _blend);
  late final AnimationController _listen = AnimationController(vsync: this, duration: _blend);
  late final AnimationController _speak = AnimationController(vsync: this, duration: _blend);
  late final Ticker _ticker = createTicker(_onTick);

  /// Segundos de animacion acumulados (lo unico que cambia en cada cuadro).
  final ValueNotifier<double> _time = ValueNotifier(0);
  Duration _lastTick = Duration.zero;
  bool _reduceMotion = false;

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _time.value += dt.clamp(0, 0.1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync(jump: true);
  }

  @override
  void didUpdateWidget(IrisLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _sync();
  }

  void _sync({bool jump = false}) {
    void drive(AnimationController c, bool on) {
      final target = on ? 1.0 : 0.0;
      if (_reduceMotion || jump) {
        c.value = target;
      } else if (c.value != target) {
        c.animateTo(target, curve: Curves.easeInOutCubic);
      }
    }

    drive(_think, widget.state == IrisState.thinking);
    drive(_listen, widget.state == IrisState.listening);
    drive(_speak, widget.state == IrisState.speaking);

    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _think.dispose();
    _listen.dispose();
    _speak.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = _buildLogo();
    // El iris grande es donde nace la animacion de arranque.
    return widget.glow ? IrisSplashAnchor(child: logo) : logo;
  }

  Widget _buildLogo() {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: IrisPainter(
            time: _time,
            think: _think,
            listen: _listen,
            speak: _speak,
            color: widget.color ?? AppTheme.accentCyan,
            thinkingColor: widget.thinkingColor ?? AppTheme.violet,
            glow: widget.glow,
          ),
        ),
      ),
    );
  }
}

/// Pinta el iris. Publico para reutilizarlo en la animacion de arranque.
class IrisPainter extends CustomPainter {
  IrisPainter({
    required this.time,
    required this.think,
    required this.listen,
    required this.speak,
    required this.color,
    required this.thinkingColor,
    this.glow = false,
  }) : super(repaint: Listenable.merge([time, think, listen, speak]));

  final ValueListenable<double> time;
  final Animation<double> think;
  final Animation<double> listen;
  final Animation<double> speak;
  final Color color;
  final Color thinkingColor;
  final bool glow;

  static const int rays = 24;
  static const int _rings = 5;
  static const double _step = 2 * math.pi / rays;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final k = think.value;
    final l = listen.value;
    final s = speak.value;
    final full = size.shortestSide / 2;
    final center = size.center(Offset.zero);

    // En reposo el dibujo ocupa ~84% del espacio: el resto es margen para crecer al escuchar.
    final breath = 1 + 0.025 * math.sin(t * 1.3);
    final radius = full * 0.84 * breath * (1 - 0.05 * s);
    final inner = radius * 0.40;

    if (glow) {
      final strength = 0.20 + 0.16 * math.max(k, math.max(l, s));
      final halo = Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(color, thinkingColor, k)!.withValues(alpha: strength),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: full * 1.5));
      canvas.drawCircle(center, full * 1.5, halo);
    }

    final rayPaint = Paint()..isAntiAlias = true;
    final dotPaint = Paint()..isAntiAlias = true;
    final rayAlpha = (1 - k * 1.25).clamp(0.0, 1.0);

    for (int i = 0; i < rays; i++) {
      final angle = i * _step - math.pi / 2;

      // Escuchando: cada rayo se alarga como una onda de voz (irregular).
      final voice = 0.5 + 0.5 * math.sin(t * 7.3 + i * 1.7) * math.sin(t * 3.1 + i * 0.9);
      // Hablando: el rayo entero se levanta y baja, sin estirarse. Los pares suben cuando los
      // impares bajan, asi la silueta sigue siendo un circulo.
      final wave = 0.5 + 0.5 * math.sin(t * 4.6 + (i.isEven ? 0 : math.pi));
      final lift = radius * s * 0.085 * (wave * 2 - 1);
      final outer = radius * (1 + l * (0.02 + 0.17 * voice)) + lift;
      final innerR = inner * (1 - 0.18 * l * voice) + lift;

      if (rayAlpha > 0) {
        final innerHalf = radius * 0.014;
        final outerHalf = radius * 0.062;
        final dir = Offset(math.cos(angle), math.sin(angle));
        final normal = Offset(-dir.dy, dir.dx);
        final a = center + dir * innerR;
        final b = center + dir * outer;
        final path = Path()
          ..moveTo(a.dx - normal.dx * innerHalf, a.dy - normal.dy * innerHalf)
          ..lineTo(a.dx + normal.dx * innerHalf, a.dy + normal.dy * innerHalf)
          ..lineTo(b.dx + normal.dx * outerHalf, b.dy + normal.dy * outerHalf)
          ..lineTo(b.dx - normal.dx * outerHalf, b.dy - normal.dy * outerHalf)
          ..close();
        final lit = 0.78 + 0.22 * (l * voice + s * wave);
        rayPaint.color = color.withValues(alpha: rayAlpha * (l + s > 0 ? lit.clamp(0.0, 1.0) : 1));
        canvas.drawPath(path, rayPaint);
      }

      if (k > 0) {
        // Cada rayo se parte en puntos; cada anillo gira a su velocidad (y los pares al reves).
        for (int j = 0; j < _rings; j++) {
          final f = j / (_rings - 1);
          final r = inner + (radius - inner) * (0.06 + 0.94 * f);
          final speed = (0.35 + 0.22 * j) * (j.isEven ? 1 : -1);
          // Los 24 puntos de un anillo son iguales: basta el giro dentro de un paso, asi al
          // volver a ser rayos no "desenrolla" vueltas enteras.
          final drift = ((t * speed) % _step) * k;
          final a = angle + drift;
          final pulse = 0.55 + 0.45 * math.sin(t * 3.4 - j * 1.1 + i * 0.26);
          dotPaint.color = Color.lerp(color, thinkingColor, f * k)!.withValues(alpha: k * pulse);
          final dotR = radius * (0.016 + 0.040 * f) * (0.75 + 0.25 * pulse);
          canvas.drawCircle(center + Offset(math.cos(a), math.sin(a)) * r, dotR, dotPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(IrisPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.thinkingColor != thinkingColor || oldDelegate.glow != glow;
}
