/// ============================================================================
/// IRIS - Haptic Service (Vibration Feedback)
/// ============================================================================
/// Adapted for vibration ^3.1.8.
/// In v3.0.0+, hasVibrator() is no longer necessary — the plugin handles
/// devices without a vibrator internally.
/// ============================================================================

import 'package:vibration/vibration.dart';

class HapticService {
  /// Initializes the service (no-op in v3.x, kept for consistency).
  Future<void> initialize() async {
    // In vibration 3.x, hasVibrator() is no longer necessary.
    // The plugin internally handles if the device has no vibrator.
  }

  /// Vibration pattern for STARTING assistance.
  /// Two short ascending pulses (like "ready").
  Future<void> vibrateStart() async {
    await Vibration.vibrate(
      pattern: [0, 100, 80, 200],
      intensities: [0, 128, 0, 255],
    );
  }

  /// Vibration pattern for STOPPING assistance.
  /// One long descending pulse (like "powering down").
  Future<void> vibrateStop() async {
    await Vibration.vibrate(duration: 400);
  }

  /// Brief confirmation vibration.
  Future<void> vibrateTick() async {
    await Vibration.vibrate(duration: 50);
  }
}
