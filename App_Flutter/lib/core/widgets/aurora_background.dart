import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

/// Animo del fondo: en calma queda quieto; al escuchar, pensar o responder los colores fluyen.
enum AuroraMood { calm, listening, thinking, speaking }

/// Fondo de Iris: una aurora de manchas de color sobre negro azulado.
///
/// - Quieto en [AuroraMood.calm] (no gasta bateria); se mueve en los demas animos y cambia de
///   paleta: cian al escuchar, violeta y magenta al pensar, cian y violeta al responder.
/// - Con [overlay] no pinta el fondo oscuro: sirve para tenir la camara mientras Iris trabaja.
/// - Si el sistema pide reducir animaciones, cambia de color pero no se mueve.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, this.mood = AuroraMood.calm, this.overlay = false});

  final AuroraMood mood;
  final bool overlay;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with TickerProviderStateMixin {
  static const Map<AuroraMood, List<Color>> _palettes = {
    AuroraMood.calm: [Color(0xFF0891B2), Color(0xFF6D28D9), Color(0xFF1D4ED8), Color(0xFFBE185D)],
    AuroraMood.listening: [Color(0xFF22D3EE), Color(0xFF0EA5E9), Color(0xFF2563EB), Color(0xFF7C3AED)],
    AuroraMood.thinking: [Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF6366F1), Color(0xFF22D3EE)],
    AuroraMood.speaking: [Color(0xFF22D3EE), Color(0xFF8B5CF6), Color(0xFF06B6D4), Color(0xFFF472B6)],
  };
  /// Apariencia clara: los mismos tonos en pastel, sobre blanco frio.
  static const Map<AuroraMood, List<Color>> _lightPalettes = {
    AuroraMood.calm: [Color(0xFF7DD3FC), Color(0xFFC4B5FD), Color(0xFFA5B4FC), Color(0xFFF9A8D4)],
    AuroraMood.listening: [Color(0xFF22D3EE), Color(0xFF38BDF8), Color(0xFF60A5FA), Color(0xFFA78BFA)],
    AuroraMood.thinking: [Color(0xFFA78BFA), Color(0xFFF472B6), Color(0xFF818CF8), Color(0xFF22D3EE)],
    AuroraMood.speaking: [Color(0xFF22D3EE), Color(0xFFA78BFA), Color(0xFF2DD4BF), Color(0xFFF472B6)],
  };
  static const Map<AuroraMood, double> _speeds = {
    AuroraMood.calm: 0,
    AuroraMood.listening: 0.55,
    AuroraMood.thinking: 1.0,
    AuroraMood.speaking: 0.7,
  };
  static const Map<AuroraMood, double> _intensities = {
    AuroraMood.calm: 0.58,
    AuroraMood.listening: 0.62,
    AuroraMood.thinking: 0.78,
    AuroraMood.speaking: 0.70,
  };

  late final AnimationController _blend =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900), value: 1);
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _phase = ValueNotifier(0);
  Duration _lastTick = Duration.zero;
  late AuroraMood _from = widget.mood;
  bool _reduceMotion = false;

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    final from = _speeds[_from]!;
    final speed = from + (_speeds[widget.mood]! - from) * _blend.value;
    _phase.value += dt * speed;
    // En calma y con la mezcla terminada no hay nada que mover.
    if (widget.mood == AuroraMood.calm && !_blend.isAnimating) _ticker.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
  }

  @override
  void didUpdateWidget(AuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mood != widget.mood) {
      _from = oldWidget.mood;
      if (_reduceMotion) {
        _blend.value = 1;
      } else {
        _blend.forward(from: 0);
      }
      _syncTicker();
    }
  }

  void _syncTicker() {
    final shouldRun = !_reduceMotion && (widget.mood != AuroraMood.calm || _blend.isAnimating);
    if (shouldRun && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _blend.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _AuroraPainter(
            phase: _phase,
            blend: _blend,
            from: (AppTheme.isLight ? _lightPalettes : _palettes)[_from]!,
            to: (AppTheme.isLight ? _lightPalettes : _palettes)[widget.mood]!,
            light: AppTheme.isLight,
            fromIntensity: _intensities[_from]!,
            toIntensity: _intensities[widget.mood]!,
            overlay: widget.overlay,
          ),
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.phase,
    required this.blend,
    required this.from,
    required this.to,
    required this.fromIntensity,
    required this.toIntensity,
    required this.overlay,
    required this.light,
  }) : super(repaint: Listenable.merge([phase, blend]));

  final ValueListenable<double> phase;
  final Animation<double> blend;
  final List<Color> from;
  final List<Color> to;
  final double fromIntensity;
  final double toIntensity;
  final bool overlay;
  final bool light;

  // Centro (en fracciones de la pantalla), radio y desfase de cada mancha.
  static const _blobs = [
    (x: 0.18, y: 0.20, r: 0.85, o: 0.0),
    (x: 0.88, y: 0.42, r: 0.95, o: 1.9),
    (x: 0.30, y: 0.92, r: 0.90, o: 3.7),
    (x: 0.80, y: 0.02, r: 0.60, o: 5.1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (!overlay) canvas.drawRect(rect, Paint()..color = AppTheme.ink);
    final p = phase.value;
    final b = Curves.easeInOut.transform(blend.value);
    // En claro la luz no se suma (quemaria a blanco): se pinta encima, un poco mas suave.
    final intensity = (fromIntensity + (toIntensity - fromIntensity) * b) * (light ? 0.85 : 1);
    final unit = size.shortestSide;

    for (int i = 0; i < _blobs.length; i++) {
      final blob = _blobs[i];
      final color = Color.lerp(from[i], to[i], b)!;
      final center = Offset(
        size.width * (blob.x + 0.16 * math.sin(p * 0.9 + blob.o)),
        size.height * (blob.y + 0.11 * math.cos(p * 0.7 + blob.o * 1.3)),
      );
      final radius = unit * blob.r * (1 + 0.12 * math.sin(p * 1.1 + blob.o * 0.7));
      final paint = Paint()
        ..blendMode = light ? BlendMode.srcOver : BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: intensity),
            color.withValues(alpha: intensity * 0.35),
            color.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, paint);
    }

    if (!overlay && !light) {
      // Viñeta: bordes mas oscuros para que el texto y el iris destaquen.
      final vignette = Paint()
        ..shader = RadialGradient(
          radius: 1.05,
          colors: [AppTheme.ink.withValues(alpha: 0.0), AppTheme.ink.withValues(alpha: 0.55)],
        ).createShader(rect);
      canvas.drawRect(rect, vignette);
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.from != from ||
      old.to != to ||
      old.overlay != overlay ||
      old.light != light ||
      old.toIntensity != toIntensity;
}

/// Fondo de la pantalla principal: la imagen (camara del celular o foto de la placa) si la hay,
/// y si no la aurora. Con imagen, la aurora la tiñe solo mientras Iris escucha, piensa o responde.
class IrisBackdrop extends StatelessWidget {
  const IrisBackdrop({super.key, required this.mood, this.image});

  final AuroraMood mood;
  final Widget? image;

  @override
  Widget build(BuildContext context) {
    final image = this.image;
    if (image == null) return AuroraBackground(mood: mood);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: AppTheme.ink),
        image,
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: mood == AuroraMood.calm ? 0 : 0.55,
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 700),
            child: AuroraBackground(mood: mood, overlay: true),
          ),
        ),
      ],
    );
  }
}
