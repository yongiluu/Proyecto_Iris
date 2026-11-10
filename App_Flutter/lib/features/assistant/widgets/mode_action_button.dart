import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'iris_logo.dart';

/// Boton grande del centro: es el iris de Iris, con el icono del modo en la pupila. Hace la
/// accion del modo visible.
///
/// - Toque normal: [onTap].
/// - Mantener presionado (modo Iris): [onPressDown] / [onPressUp] con un Listener (no compite en
///   la arena de gestos, asi que soltar el dedo siempre llega).
/// - TalkBack: un toque doble llega como "tap"; [onSemanticTap] decide que hacer (en Iris: un
///   toque empieza a escuchar y otro envia).
/// - Los arrastres horizontales que empiezan sobre el boton no cambian de pagina: asi no se
///   cambia de modo sin querer al mantenerlo presionado.
class ModeActionButton extends StatelessWidget {
  const ModeActionButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.semanticHint,
    this.onTap,
    this.onPressDown,
    this.onPressUp,
    this.onSemanticTap,
    this.enabled = true,
    this.active = false,
    this.activeColor = AppTheme.listeningRed,
    this.irisState,
    this.scale = 1,
    this.size,
    this.toggled,
  });

  final IconData icon;
  final String semanticLabel;
  final String? semanticHint;
  final VoidCallback? onTap;
  final VoidCallback? onPressDown;
  final VoidCallback? onPressUp;
  final VoidCallback? onSemanticTap;
  final bool enabled;

  /// Escuchando / encendido: se pinta con [activeColor].
  final bool active;
  final Color activeColor;

  /// Como se mueve el iris. Si es null: ola mientras esta [active], reposo si no.
  final IrisState? irisState;

  /// Pulso mientras escucha (lo anima la pantalla).
  final double scale;

  /// Diametro. Si es null se ajusta al ancho de la pantalla (el iris es el protagonista).
  final double? size;

  /// Para botones que prenden/apagan (Luz): TalkBack dice "activado/desactivado".
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final usable = enabled || active;
    final Color color = active ? activeColor : (enabled ? AppTheme.accentCyan : AppTheme.textFaint);
    final state = irisState ?? (active ? IrisState.speaking : IrisState.idle);
    final semanticTap = onSemanticTap ?? onTap;
    final size = this.size ?? (MediaQuery.sizeOf(context).width * 0.50).clamp(132.0, 208.0);
    final pupil = size * 0.30;

    // El boton es el propio iris: los rayos alrededor y, en la pupila, el icono del modo.
    Widget iris = SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IrisLogo(size: size, color: color, state: state, glow: usable),
          AnimatedContainer(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
            width: pupil,
            height: pupil,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: active ? 0.30 : 0.14),
              border: Border.all(color: color.withValues(alpha: usable ? 0.75 : 0.35), width: 1.2),
            ),
            child: Icon(icon, color: usable ? AppTheme.textOnDark : AppTheme.textFaint, size: pupil * 0.56),
          ),
        ],
      ),
    );
    if (!reduceMotion && scale != 1) iris = Transform.scale(scale: scale, child: iris);

    return Semantics(
      container: true,
      button: true,
      enabled: usable,
      toggled: toggled,
      label: semanticLabel,
      hint: semanticHint,
      onTap: usable ? semanticTap : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          // Reclama los arrastres horizontales para que el carrusel no cambie de pagina.
          onHorizontalDragStart: (_) {},
          onTap: usable ? onTap : null,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: onPressDown == null ? null : (_) => onPressDown!(),
            onPointerUp: onPressUp == null ? null : (_) => onPressUp!(),
            onPointerCancel: onPressUp == null ? null : (_) => onPressUp!(),
            child: iris,
          ),
        ),
      ),
    );
  }
}

/// Esqueleto comun de una pagina de modo: [extra] arriba (opcional), el boton grande y una
/// linea corta debajo. Si no cabe (letra muy grande) se desplaza en vez de desbordar.
class ModePage extends StatelessWidget {
  const ModePage({
    super.key,
    required this.action,
    required this.caption,
    this.extra,
  });

  final Widget action;
  final String caption;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        // Si no cabe, parte mostrando lo de abajo: el boton grande siempre a la vista.
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (extra != null) ...[
                extra!,
                const SizedBox(height: 10),
              ],
              action,
              const SizedBox(height: 2),
              ExcludeSemantics(
                child: Text(
                  caption,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textOnDarkMuted,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Boton secundario compacto (pastilla) para acciones de la pagina: "Agregar persona", etc.
class ModeChipButton extends StatelessWidget {
  const ModeChipButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: ExcludeSemantics(
        child: OutlinedButton.icon(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            backgroundColor: highlighted ? AppTheme.accentCyan.withValues(alpha: 0.22) : AppTheme.cardDark,
            foregroundColor: AppTheme.textOnDark,
            side: BorderSide(color: highlighted ? AppTheme.accentCyan : AppTheme.glassBorder),
            shape: const StadiumBorder(),
          ),
          icon: Icon(icon, size: 20, color: highlighted ? AppTheme.brightCyan : AppTheme.textOnDarkMuted),
          label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
