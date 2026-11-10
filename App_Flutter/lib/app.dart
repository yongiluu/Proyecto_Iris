/// ============================================================================
/// IRIS - App Configuration (MaterialApp)
/// ============================================================================

import 'package:flutter/material.dart';

import 'features/account/auth_gate.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/iris_splash.dart';

/// Root widget of the Iris application.
class IrisApp extends StatelessWidget {
  const IrisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Brightness>(
      valueListenable: AppTheme.brightnessNotifier,
      builder: (context, brightness, _) => MaterialApp(
        title: 'Iris - Visual Assistant',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        // Los colores de AppTheme no pasan por Theme.of: al cambiar de apariencia hay que
        // reconstruir todas las pantallas abiertas (sin perder su estado).
        builder: (context, child) => _RebuildOnAppearance(brightness: brightness, child: child!),
        // Arranque animado (el iris se abre) y despues: iniciar sesion si hay backend configurado.
        home: const IrisSplash(child: AuthGate()),
      ),
    );
  }
}

class _RebuildOnAppearance extends StatefulWidget {
  const _RebuildOnAppearance({required this.brightness, required this.child});

  final Brightness brightness;
  final Widget child;

  @override
  State<_RebuildOnAppearance> createState() => _RebuildOnAppearanceState();
}

class _RebuildOnAppearanceState extends State<_RebuildOnAppearance> {
  @override
  void didUpdateWidget(_RebuildOnAppearance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.brightness == widget.brightness) return;
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.visitChildElements(rebuild);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
