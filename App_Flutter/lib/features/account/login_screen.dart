import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/backend/backend_service.dart';

/// Inicio de sesion accesible: un solo boton grande ("Continuar con Google"), sin escribir contraseñas.
/// Todo se anuncia con el lector de pantalla (TalkBack).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await BackendService.instance.signInWithGoogle();
    // Si funciono, AuthGate cambia a la pantalla principal solo.
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text('Iris', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displayLarge),
              ),
              const SizedBox(height: 12),
              Text(
                'Inicia sesión para que Iris recuerde tus conversaciones, guarde tus preferencias '
                'y puedas vincular a un familiar o acompañante.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppTheme.textDark),
              ),
              const SizedBox(height: 40),
              SizedBox(
                height: 72,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _signIn,
                  icon: _busy
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
                      : const Icon(Icons.login, size: 30),
                  label: Text(_busy ? 'Iniciando sesión...' : 'Continuar con Google', style: const TextStyle(fontSize: 22)),
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.textDark, foregroundColor: Colors.white),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 20),
                Semantics(
                  liveRegion: true,
                  child: Text(_error!, textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.dangerRed, fontSize: 18, fontWeight: FontWeight.w600)),
                ),
              ],
              const SizedBox(height: 32),
              Text(
                'Usamos tu cuenta de Google solo para identificarte. Tus conversaciones son privadas: '
                'solo tú puedes verlas y borrarlas.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
