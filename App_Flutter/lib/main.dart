/// ============================================================================
/// IRIS - Visual Assistant PoC
/// ============================================================================
/// Application entry point. Initializes the camera and launches the UI.
/// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

import 'app.dart';
import 'core/constants/env_config.dart';
import 'features/data_collection/training_upload_queue.dart';
import 'services/backend/backend_service.dart';

/// Global list of available cameras on the device.
late List<CameraDescription> cameras;

Future<void> main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load environment variables
  await EnvConfig.init();

  // Cuentas y agente en el servidor (si el .env tiene SUPABASE_URL; si no, la app funciona sin cuentas).
  await BackendService.instance.init();
  // Retoma en segundo plano las subidas de Misiones de datos que quedaron pendientes.
  unawaited(TrainingUploadQueue.instance.init());

  // Force portrait orientation for consistent accessibility
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Hide system bars for immersive full-screen experience
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  // Get available cameras
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Error getting cameras: ${e.code} - ${e.description}');
    cameras = [];
  }

  runApp(const IrisApp());
}

