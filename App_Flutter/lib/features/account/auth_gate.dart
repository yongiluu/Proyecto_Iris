import 'package:flutter/material.dart';

import '../../services/backend/backend_service.dart';
import '../assistant/screens/assistant_screen.dart';
import 'login_screen.dart';

/// Con backend configurado, pide iniciar sesion antes de la pantalla principal (las llaves de IA estan
/// en el servidor y se usan con la sesion). Sin backend, la app funciona como siempre, sin cuentas.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final backend = BackendService.instance;
    if (!backend.enabled) return const AssistantScreen();
    return StreamBuilder(
      stream: backend.authChanges,
      builder: (context, _) => backend.signedIn ? const AssistantScreen() : const LoginScreen(),
    );
  }
}
