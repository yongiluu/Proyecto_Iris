import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Boton grande y redondo del centro: hace la accion del modo visible.
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
    this.scale = 1,
    this.size = 96,
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

  /// Pulso mientras escucha (lo anima la pantalla).
  final double scale;
  final double size;

  /// Para botones que prenden/apagan (Luz): TalkBack dice "activado/desactivado".
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Color fill = active ? activeColor : (enabled ? AppTheme.primaryCyan : AppTheme.cardDark);
    final Color iconColor = (active || enabled) ? const Color(0xFF00161A) : AppTheme.brightCyan;
    final semanticTap = onSemanticTap ?? onTap;

    Widget circle = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 250),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(
          color: enabled || active ? Colors.white.withValues(alpha: 0.6) : Colors.white24,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: (active ? activeColor : AppTheme.primaryCyan).withValues(alpha: enabled || active ? 0.4 : 0.15),
            blurRadius: 26,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Center(child: Icon(icon, color: iconColor, size: size * 0.5)),
    );
    if (!reduceMotion && scale != 1) circle = Transform.scale(scale: scale, child: circle);

    return Semantics(
      container: true,
      button: true,
      enabled: enabled || active,
      toggled: toggled,
      label: semanticLabel,
      hint: semanticHint,
      onTap: (enabled || active) ? semanticTap : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          // Reclama los arrastres horizontales para que el carrusel no cambie de pagina.
          onHorizontalDragStart: (_) {},
          onTap: (enabled || active) ? onTap : null,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: onPressDown == null ? null : (_) => onPressDown!(),
            onPointerUp: onPressUp == null ? null : (_) => onPressUp!(),
            onPointerCancel: onPressUp == null ? null : (_) => onPressUp!(),
            child: circle,
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
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (extra != null) ...[
                extra!,
                const SizedBox(height: 10),
              ],
              action,
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: Text(
                  caption,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textOnDark,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
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
            backgroundColor: highlighted ? AppTheme.accentCyan.withValues(alpha: 0.25) : AppTheme.cardDark,
            foregroundColor: AppTheme.textOnDark,
            side: BorderSide(color: highlighted ? AppTheme.accentCyan : Colors.white24),
            shape: const StadiumBorder(),
          ),
          icon: Icon(icon, size: 20, color: highlighted ? AppTheme.brightCyan : AppTheme.textOnDarkMuted),
          label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
