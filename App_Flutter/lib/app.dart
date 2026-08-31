/// ============================================================================
/// IRIS - App Configuration (MaterialApp)
/// ============================================================================

import 'package:flutter/material.dart';

import 'features/assistant/screens/assistant_screen.dart';
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
      home: const AssistantScreen(),
    );
  }
}
