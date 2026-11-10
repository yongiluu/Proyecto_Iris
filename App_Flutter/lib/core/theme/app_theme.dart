// ============================================================================
// IRIS - Tema visual ("Iris viva")
// ============================================================================
//
// Oscuro, con una aurora de color que se mueve cuando Iris piensa o responde. El cian del logo
// es el color de la marca; el violeta aparece mientras piensa y el ambar solo en los avisos.

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ─── Marca ───
  static const Color ink = Color(0xFF060913); // fondo: negro azulado
  static const Color inkRaised = Color(0xFF0D1322); // hojas y dialogos
  static const Color accentCyan = Color(0xFF22D3EE); // cian del logo
  static const Color primaryCyan = accentCyan;
  static const Color brightCyan = Color(0xFF8DEBFF); // brillos y palabra que suena
  static const Color violet = Color(0xFFA78BFA); // "pensando"
  static const Color magenta = Color(0xFFF472B6);
  static const Color listeningRed = Color(0xFFFF6B8B);
  static const Color alertAmber = Color(0xFFFFB74D);
  static const Color dangerRed = Color(0xFFFF5C7A);
  static const Color success = Color(0xFF5EF2B0);

  // ─── Texto ───
  static const Color textOnDark = Color(0xFFF4F8FF);
  static const Color textOnDarkMuted = Color(0xFFB6C2D6); // >9:1 sobre ink
  static const Color textFaint = Color(0xFF7B879C);

  // ─── Superficies ───
  /// Tarjeta sobre la camara: oscura y casi opaca para que el texto se lea con cualquier fondo.
  static const Color cardDark = Color(0xC70A0F1C);
  /// Vidrio: relleno y borde de las tarjetas sobre la aurora.
  static const Color glassFill = Color(0x17FFFFFF);
  static const Color glassBorder = Color(0x2EFFFFFF);
  static const double cardRadius = 22;

  /// Etiquetas tecnicas ("PENSANDO", "PLACA"): monoespaciada, en mayusculas y con aire.
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.4,
    color: textOnDarkMuted,
  );

  static ThemeData get darkTheme {
    const scheme = ColorScheme.dark(
      primary: accentCyan,
      onPrimary: Color(0xFF00222A),
      secondary: violet,
      surface: inkRaised,
      onSurface: textOnDark,
      onSurfaceVariant: textOnDarkMuted,
      error: dangerRed,
      outline: glassBorder,
    );
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: ink,
      splashFactory: InkSparkle.splashFactory,
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 52, fontWeight: FontWeight.w300, letterSpacing: -1.5, color: textOnDark),
        headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.4, color: textOnDark),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: textOnDark),
        titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: textOnDark),
        bodyLarge: TextStyle(fontSize: 17, height: 1.45, color: textOnDark),
        bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: textOnDarkMuted),
        labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: textOnDark,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: accentCyan,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? const Color(0xFF00222A) : textOnDarkMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentCyan : Colors.white12,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      sliderTheme: const SliderThemeData(activeTrackColor: accentCyan, thumbColor: brightCyan, inactiveTrackColor: Colors.white24),
      dividerTheme: const DividerThemeData(color: Colors.white12, space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: inkRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: const BorderSide(color: glassBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: inkRaised,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: Colors.white30,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF16203A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accentCyan)),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accentCyan),
    );
  }
}
