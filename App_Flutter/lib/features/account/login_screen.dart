import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/aurora_background.dart';
import '../../services/backend/backend_service.dart';
import '../assistant/widgets/iris_logo.dart';

/// Inicio de sesion: el iris vivo sobre la aurora y un solo boton grande ("Continuar con
/// Google"), sin escribir contraseñas. Todo se anuncia con el lector de pantalla (TalkBack).
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
      backgroundColor: AppTheme.ink,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Mientras inicia sesion, la aurora y el iris "piensan".
          AuroraBackground(mood: _busy ? AuroraMood.thinking : AuroraMood.calm),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Center(
                        child: IrisLogo(
                          size: 148,
                          glow: true,
                          state: _busy ? IrisState.thinking : IrisState.idle,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Semantics(
                        header: true,
                        child: Text('Iris', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displayLarge),
                      ),
                      const SizedBox(height: 6),
                      ExcludeSemantics(
                        child: Text(
                          'TU ASISTENTE VISUAL',
                          textAlign: TextAlign.center,
                          style: AppTheme.mono.copyWith(color: AppTheme.accentCyan),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        'Inicia sesión para que Iris recuerde tus conversaciones, guarde tus preferencias '
                        'y puedas vincular a un familiar o acompañante.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 17, height: 1.45),
                      ),
                      const SizedBox(height: 32),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 64),
                        child: FilledButton(
                          onPressed: _busy ? null : _signIn,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.text,
                            foregroundColor: AppTheme.ink,
                            disabledBackgroundColor: AppTheme.subtleFill,
                            disabledForegroundColor: AppTheme.text,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (!_busy) ...[
                                const ExcludeSemantics(
                                  child: Text('G', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Flexible(
                                child: Text(
                                  _busy ? 'Iniciando sesión...' : 'Continuar con Google',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 18),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.dangerRed, fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      Text(
                        'Usamos tu cuenta de Google solo para identificarte. Tus conversaciones son privadas: '
                        'solo tú puedes verlas y borrarlas.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textFaint, fontSize: 14, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
