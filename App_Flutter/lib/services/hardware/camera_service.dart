/// ============================================================================
/// IRIS - Camera Service (Frame Sampling)
/// ============================================================================
/// Handles camera initialization and periodic frame capture.
/// ============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../../main.dart';

/// Callback that receives the JPEG bytes of the captured frame.
typedef FrameCapturedCallback = void Function(Uint8List imageBytes);

class CameraService {
  CameraController? _controller;

  /// Indicates if the camera controller is initialized and ready.
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  /// Exposes the controller for the preview widget (optional).
  CameraController? get controller => _controller;

  /// Initializes the back-facing camera with medium resolution (720p).
  Future<void> initialize() async {
    if (cameras.isEmpty) {
      throw CameraException('NO_CAMERA', 'No available cameras found.');
    }

    // Search for the back-facing camera
    final CameraDescription backCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      backCamera,
      ResolutionPreset.medium, // ~720p for lightweight payload
      enableAudio: false, // We do not need audio
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _controller!.initialize();

    // Set flash off by default
    await _controller!.setFlashMode(FlashMode.off);
  }

  /// Captures a single frame and returns its JPEG bytes.
  Future<Uint8List?> captureSingleFrame() async {
    if (!isInitialized) return null;

    // Avoid attempting to capture if the controller is already busy
    if (_controller!.value.isTakingPicture) return null;

    try {
      final XFile imageFile = await _controller!.takePicture();
      final Uint8List bytes = await imageFile.readAsBytes();

      // Delete the temporary file to free up storage
      try {
        await File(imageFile.path).delete();
      } catch (_) {}

      return bytes;
    } on CameraException catch (e) {
      debugPrint('⚠️ Error capturing frame: ${e.code} - ${e.description}');
      return null;
    } catch (e) {
      debugPrint('⚠️ Unexpected capture error: $e');
      return null;
    }
  }

  /// Releases all camera resources.
  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }
}
