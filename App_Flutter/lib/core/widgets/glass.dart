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
    this.tint,
    this.borderColor,
    this.blur = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  /// Relleno; por defecto el vidrio del tema.
  final Color? tint;
  final Color? borderColor;
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
            color: tint ?? AppTheme.glassFill,
            borderRadius: shape,
            border: Border.all(color: borderColor ?? AppTheme.glassBorder),
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
                  padding: const EdgeInsets.fromLTRB(4, 8, 12, 0),
                  child: Row(
                    children: [
                      if (Navigator.of(context).canPop())
                        IconButton(
                          tooltip: 'Volver',
                          iconSize: 26,
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          icon: Icon(Icons.arrow_back_rounded, color: AppTheme.text),
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
                            style: TextStyle(
                              color: AppTheme.text,
                              fontSize: 30,
                              fontWeight: FontWeight.w300,
                              letterSpacing: -0.6,
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

/// Titulo de seccion pequeño, en mayusculas y con aire ("CONEXION", "MEMORIA").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 28, 8, 10),
      child: Semantics(
        header: true,
        label: text,
        child: ExcludeSemantics(
          child: Text(text.toUpperCase(), style: AppTheme.sectionLabel),
        ),
      ),
    );
  }
}
