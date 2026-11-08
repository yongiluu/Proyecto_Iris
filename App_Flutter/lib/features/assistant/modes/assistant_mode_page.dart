import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../widgets/mode_action_button.dart';

/// Modo Iris (asistente): mantener presionado para hablar. La descripcion continua vive aca
/// como un interruptor secundario.
class AssistantModePage extends StatelessWidget {
  const AssistantModePage({
    super.key,
    required this.isListening,
    required this.isProcessing,
    required this.canTalkHere,
    required this.isModule,
    required this.moduleConnected,
    required this.continuousMode,
    required this.onContinuousChanged,
    required this.onPressDown,
    required this.onPressUp,
    this.pulseScale = 1,
  });

  final bool isListening;
  final bool isProcessing;

  /// false en modo Modulo: se habla con "Oye Iris" o con el doble toque de volumen.
  final bool canTalkHere;
  final bool isModule;
  final bool moduleConnected;
  final bool continuousMode;
  final ValueChanged<bool> onContinuousChanged;
  final VoidCallback onPressDown;
  final VoidCallback onPressUp;
  final double pulseScale;

  @override
  Widget build(BuildContext context) {
    final String caption;
    if (isListening) {
      caption = canTalkHere ? 'Suelta para enviar' : 'Escuchando...';
    } else if (!isModule) {
      caption = 'Manten presionado para hablar';
    } else if (canTalkHere) {
      caption = 'Manten presionado: habla al modulo';
    } else {
      caption = moduleConnected ? 'Di "Oye Iris" para hablar' : 'Conecta el modulo para hablar';
    }

    final String label;
    final String hint;
    if (!canTalkHere) {
      label = isListening ? 'Escuchando' : 'Hablar con Iris';
      hint = 'En modo Módulo, di Oye Iris, o presiona dos veces el botón de subir volumen';
    } else if (isListening) {
      label = 'Escuchando';
      hint = 'Toca dos veces para enviar tu pregunta';
    } else {
      label = isProcessing ? 'Iris está pensando. Hablar con Iris' : 'Hablar con Iris';
      hint = 'Toca dos veces para empezar a escuchar y otra vez para enviar. '
          'Sin lector de pantalla: mantén presionado mientras hablas';
    }

    return ModePage(
      extra: _ContinuousToggle(value: continuousMode, onChanged: onContinuousChanged),
      caption: caption,
      action: ModeActionButton(
        icon: isListening ? Icons.graphic_eq : (canTalkHere ? Icons.mic : Icons.memory),
        semanticLabel: label,
        semanticHint: hint,
        enabled: canTalkHere,
        active: isListening,
        scale: isListening ? pulseScale : 1,
        onPressDown: onPressDown,
        onPressUp: onPressUp,
        // TalkBack: un toque empieza a escuchar y otro envia.
        onSemanticTap: () => isListening ? onPressUp() : onPressDown(),
      ),
    );
  }
}

class _ContinuousToggle extends StatelessWidget {
  const _ContinuousToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      toggled: value,
      label: 'Descripción continua',
      hint: 'Describe lo que ve la cámara de forma automática',
      onTap: () => onChanged(!value),
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => onChanged(!value),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.only(left: 14, right: 4),
              decoration: ShapeDecoration(
                color: value ? AppTheme.accentCyan.withValues(alpha: 0.25) : AppTheme.cardDark,
                shape: StadiumBorder(side: BorderSide(color: value ? AppTheme.accentCyan : Colors.white24)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.autorenew, size: 20, color: value ? AppTheme.brightCyan : AppTheme.textOnDarkMuted),
                  const SizedBox(width: 8),
                  const Flexible(
                    child: Text('Descripcion continua',
                        style: TextStyle(color: AppTheme.textOnDark, fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  Switch(
                    value: value,
                    onChanged: onChanged,
                    activeThumbColor: Colors.black,
                    activeTrackColor: AppTheme.accentCyan,
                    inactiveThumbColor: AppTheme.textOnDarkMuted,
                    inactiveTrackColor: Colors.white24,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
