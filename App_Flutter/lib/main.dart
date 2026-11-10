/// ============================================================================
/// IRIS - Visual Assistant PoC
/// ============================================================================
/// Application entry point. Initializes the camera and launches the UI.
/// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/theme/app_theme.dart';
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

  // Apariencia elegida en Configuracion (oscura por defecto).
  try {
    final light = (await SharedPreferences.getInstance()).getBool(AppTheme.prefLightAppearance) ?? false;
    AppTheme.setBrightness(light ? Brightness.light : Brightness.dark);
  } catch (_) {}

  // Hide system bars for immersive full-screen experience
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: AppTheme.isLight ? Brightness.dark : Brightness.light,
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

