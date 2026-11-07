/// ============================================================================
/// IRIS - App Configuration (MaterialApp)
/// ============================================================================

import 'package:flutter/material.dart';

import 'features/account/auth_gate.dart';
import 'core/theme/app_theme.dart';

/// Root widget of the Iris application.
class IrisApp extends StatelessWidget {
  const IrisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Iris - Visual Assistant',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const AuthGate(),  // pide iniciar sesion si hay backend configurado
    );
  }
}
