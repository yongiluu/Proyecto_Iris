// ============================================================================
// IRIS - Tema visual ("Iris viva")
// ============================================================================
//
// Una aurora de color que se mueve cuando Iris escucha, piensa o responde. El cian del logo es
// el color de la marca; el violeta aparece mientras piensa y el ambar solo en los avisos.
//
// Hay dos apariencias, oscura (por defecto) y clara. Los colores son getters que dependen de
// [AppTheme.brightness]: al cambiarla con [AppTheme.setBrightness] la app se reconstruye entera.

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  /// Apariencia actual. Se escucha en la raiz de la app para redibujar todo.
  static final ValueNotifier<Brightness> brightnessNotifier = ValueNotifier(Brightness.dark);

  static Brightness get brightness => brightnessNotifier.value;
  static bool get isLight => brightness == Brightness.light;

  static void setBrightness(Brightness value) => brightnessNotifier.value = value;

  /// Preferencia guardada: true = apariencia clara.
  static const String prefLightAppearance = 'iris_light_appearance';

  static Color _pick(int dark, int light) => Color(isLight ? light : dark);

  // ─── Marca ───
  /// Fondo: negro azulado (oscuro) o blanco frio (claro).
  static Color get ink => _pick(0xFF060913, 0xFFF4F7FC);

  /// Hojas y dialogos.
  static Color get inkRaised => _pick(0xFF0D1322, 0xFFFFFFFF);

  /// Cian del logo (mas profundo en claro, para que se lea sobre blanco).
  static Color get accentCyan => _pick(0xFF22D3EE, 0xFF0891B2);
  static Color get primaryCyan => accentCyan;

  /// Brillos y letras que se estan diciendo.
  static Color get brightCyan => _pick(0xFF8DEBFF, 0xFF06B6D4);

  /// "Pensando".
  static Color get violet => _pick(0xFFA78BFA, 0xFF7C3AED);
  static Color get magenta => _pick(0xFFF472B6, 0xFFDB2777);
  static Color get listeningRed => _pick(0xFFFF6B8B, 0xFFE11D48);
  static Color get alertAmber => _pick(0xFFFFB74D, 0xFFB45309);
  static Color get dangerRed => _pick(0xFFFF5C7A, 0xFFDC2626);
  static Color get success => _pick(0xFF5EF2B0, 0xFF059669);

  /// Texto sobre un boton relleno de cian.
  static Color get onAccent => _pick(0xFF00222A, 0xFFFFFFFF);

  // ─── Texto ───
  static Color get text => _pick(0xFFF4F8FF, 0xFF0B1220);
  static Color get textMuted => _pick(0xFFB6C2D6, 0xFF475569);
  static Color get textFaint => _pick(0xFF7B879C, 0xFF64748B);

  /// Halo detras del texto que va directo sobre la camara o la aurora.
  static Color get textHalo => _pick(0xDD000000, 0xE6FFFFFF);

  // ─── Superficies ───
  /// Tarjeta sobre la camara: casi opaca para que el texto se lea con cualquier fondo.
  static Color get card => _pick(0xC70A0F1C, 0xE0FFFFFF);

  /// Vidrio: relleno y borde de las tarjetas sobre la aurora.
  static Color get glassFill => _pick(0x17FFFFFF, 0x99FFFFFF);
  static Color get glassBorder => _pick(0x2EFFFFFF, 0x1F0B1220);

  /// Relleno tenue (pistas de controles, botones secundarios).
  static Color get subtleFill => _pick(0x1AFFFFFF, 0x120B1220);
  static const double cardRadius = 22;

  /// Etiquetas tecnicas ("PENSANDO", "PLACA"): monoespaciada, en mayusculas y con aire.
  static TextStyle get mono => TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 2.4,
        color: textMuted,
      );

  /// Titulos de seccion en las pantallas de lectura (configuracion, cuenta): pequeños, en
  /// mayusculas y con aire.
  static TextStyle get sectionLabel => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.8,
        color: textFaint,
      );

  static ThemeData get theme {
    final light = isLight;
    final scheme = (light ? const ColorScheme.light() : const ColorScheme.dark()).copyWith(
      primary: accentCyan,
      onPrimary: onAccent,
      secondary: violet,
      surface: inkRaised,
      onSurface: text,
      onSurfaceVariant: textMuted,
      error: dangerRed,
      outline: glassBorder,
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: ink,
      splashFactory: InkSparkle.splashFactory,
      textTheme: TextTheme(
        displayLarge: TextStyle(fontSize: 52, fontWeight: FontWeight.w300, letterSpacing: -1.5, color: text),
        headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: -0.4, color: text),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: text),
        titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: text),
        bodyLarge: TextStyle(fontSize: 16.5, height: 1.4, letterSpacing: 0.1, color: text),
        bodyMedium: TextStyle(fontSize: 14, height: 1.4, letterSpacing: 0.1, color: textMuted),
        labelLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: text,
      ),
      listTileTheme: ListTileThemeData(iconColor: accentCyan),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : textFaint,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accentCyan : subtleFill,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.transparent : glassBorder,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accentCyan,
        thumbColor: light ? accentCyan : brightCyan,
        inactiveTrackColor: subtleFill,
        trackHeight: 3,
        tickMarkShape: SliderTickMarkShape.noTickMark,
        overlayColor: accentCyan.withValues(alpha: 0.14),
      ),
      dividerTheme: DividerThemeData(color: glassBorder, space: 1, thickness: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: inkRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: glassBorder),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: inkRaised,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: textFaint,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: light ? const Color(0xFF0B1220) : const Color(0xFF16203A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accentCyan)),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accentCyan),
    );
  }
}
