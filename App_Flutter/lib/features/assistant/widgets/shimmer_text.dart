import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Texto con un barrido de luz que lo recorre mientras Iris "piensa"
/// (parecido al indicador de "pensando" de Claude Code).
///
/// - [active] = false: texto estatico en [baseColor].
/// - Si el sistema pide quitar animaciones (MediaQuery.disableAnimations),
///   el texto queda estatico aunque [active] sea true.
/// - La animacion solo repinta el ShaderMask: el texto y su semantica no cambian
///   en cada frame, asi TalkBack no anuncia nada extra.
class ShimmerText extends StatefulWidget {
  const ShimmerText(
    this.text, {
    super.key,
    required this.active,
    this.style,
    this.textAlign = TextAlign.start,
    this.baseColor = AppTheme.textOnDarkMuted,
    this.highlightColor = AppTheme.brightCyan,
    this.period = const Duration(milliseconds: 1600),
  });

  final String text;
  final bool active;
  final TextStyle? style;
  final TextAlign textAlign;
  final Color baseColor;
  final Color highlightColor;
  final Duration period;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.period);

  bool _animate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant ShimmerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) _controller.duration = widget.period;
    _sync();
  }

  void _sync() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldAnimate = widget.active && !reduceMotion;
    if (shouldAnimate == _animate) return;
    _animate = shouldAnimate;
    if (shouldAnimate) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      textAlign: widget.textAlign,
      // Con ShaderMask (srcIn) solo importa la opacidad del texto: va en blanco.
      style: (widget.style ?? const TextStyle()).copyWith(color: Colors.white),
    );

    // Siempre el mismo arbol (animando o no) para que la semantica del texto no se
    // recree al cambiar de estado. En reposo el controller queda en 0: el brillo esta
    // fuera del texto y se ve todo en baseColor.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        child: text,
        builder: (context, child) {
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              colors: [widget.baseColor, widget.highlightColor, widget.baseColor],
              stops: const [0.35, 0.5, 0.65],
              // El brillo entra por la izquierda y sale por la derecha.
              transform: _SlideGradient(_controller.value * 2 - 1),
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}

/// Desplaza el degradado horizontalmente: -1 = fuera a la izquierda, 1 = fuera a la derecha.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.percent);

  final double percent;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * percent, 0, 0);
  }
}
