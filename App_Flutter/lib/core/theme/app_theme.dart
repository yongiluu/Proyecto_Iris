/// ============================================================================
/// IRIS - Visual Theme (High Contrast / Accessibility)
/// ============================================================================

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ─── High Contrast Color Palette (Light Theme) ───
  static const Color background = Color(0xFFE0F7FA); // Soft pastel cyan
  static const Color surface = Color(0xFFFFFFFF);    // White
  static const Color primaryCyan = Color(0xFF00B8D4); // Deeper cyan for readability
  static const Color accentCyan = Color(0xFF00BCD4);
  static const Color dangerRed = Color(0xFFD50000);
  static const Color textDark = Color(0xFF121212);   // Dark text
  static const Color textMuted = Color(0xFF455A64);  // Muted dark text

  // ─── Gradients ───
  static const LinearGradient activeGradient = LinearGradient(
    colors: [Color(0xFF00E5FF), Color(0xFF00B8D4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient idleGradient = LinearGradient(
    colors: [Color(0xFF00B8D4), Color(0xFF00838F)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient pulseGradient = LinearGradient(
    colors: [Color(0xFF84FFFF), Color(0xFF00E5FF)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ─── Material Theme ───
  static ThemeData get lightTheme => ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.light(
          primary: primaryCyan,
          secondary: accentCyan,
          surface: surface,
          error: dangerRed,
        ),
        fontFamily: 'Roboto',
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w900,
            color: textDark,
            letterSpacing: -1.5,
          ),
          displayMedium: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w700,
            color: textDark,
          ),
          headlineLarge: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: primaryCyan,
          ),
          bodyLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            color: textDark,
            height: 1.4,
          ),
          bodyMedium: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w400,
            color: textMuted,
          ),
          labelLarge: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: background,
            letterSpacing: 1.2,
          ),
        ),
      );
}
