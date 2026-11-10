import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'aurora_background.dart';

/// Tarjeta de vidrio: desenfoca lo que hay detras, con un borde fino de luz.
/// Con un [tint] mas oscuro sirve para texto sobre la camara.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppTheme.cardRadius,
    this.tint = AppTheme.glassFill,
    this.borderColor = AppTheme.glassBorder,
    this.blur = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color tint;
  final Color borderColor;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: shape,
            border: Border.all(color: borderColor),
          ),
          // Material propio: las filas (ListTile, interruptores) pintan aqui su onda al tocar.
          child: Material(
            type: MaterialType.transparency,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Pagina secundaria (configuracion, cuenta, historial): aurora quieta de fondo, flecha para
/// volver y un titulo grande.
class IrisPage extends StatelessWidget {
  const IrisPage({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackground(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  child: Row(
                    children: [
                      if (Navigator.of(context).canPop())
                        IconButton(
                          tooltip: 'Volver',
                          iconSize: 26,
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.textOnDark),
                          onPressed: () => Navigator.of(context).maybePop(),
                        )
                      else
                        const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textOnDark,
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Titulo de seccion en mayusculas monoespaciadas ("CONEXION", "MEMORIA").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
      child: Semantics(
        header: true,
        label: text,
        child: ExcludeSemantics(
          child: Text(text.toUpperCase(), style: AppTheme.mono.copyWith(color: AppTheme.accentCyan)),
        ),
      ),
    );
  }
}
