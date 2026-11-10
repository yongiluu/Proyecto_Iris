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
    return MaterialApp(
      title: 'Iris - Visual Assistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      // Arranque animado (el iris se abre) y despues: iniciar sesion si hay backend configurado.
      home: const IrisSplash(child: AuthGate()),
    );
  }
}
