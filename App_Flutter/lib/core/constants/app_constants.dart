/// ============================================================================
/// IRIS - Configuration Constants
/// ============================================================================
/// ALL configurable project variables are centralized here.
/// ============================================================================

class AppConstants {
  AppConstants._(); // Prevent instantiation

  // ─────────────────────────────────────────────────────────────
  // FRAME SAMPLING AND TTS
  // ─────────────────────────────────────────────────────────────

  static const int frameCaptureIntervalMs = 1800;
  static const int imageQuality = 70;

  static const String ttsLanguage = 'es-CL';
  static const double ttsSpeechRate = 0.55;
  static const double ttsPitch = 1.0;
  static const double ttsVolume = 1.0;
}
