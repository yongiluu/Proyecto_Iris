import 'package:flutter/material.dart';

import '../widgets/iris_logo.dart';
import '../widgets/mode_action_button.dart';

/// Modo Iris (asistente): mantener presionado el iris para hablar. El iris muestra lo que hace
/// Iris: escucha, piensa (se deshace en puntos) o responde.
class AssistantModePage extends StatelessWidget {
  const AssistantModePage({
    super.key,
    required this.isListening,
    required this.isProcessing,
    required this.canTalkHere,
    required this.isModule,
    required this.moduleConnected,
    required this.onPressDown,
    required this.onPressUp,
    this.isSpeaking = false,
    this.pulseScale = 1,
  });

  final bool isListening;
  final bool isProcessing;

  /// false en modo Modulo: se habla con "Oye Iris" o con el doble toque de volumen.
  final bool canTalkHere;
  final bool isModule;
  final bool moduleConnected;
  final VoidCallback onPressDown;
  final VoidCallback onPressUp;
  /// Iris esta diciendo la respuesta: una ola recorre el iris.
  final bool isSpeaking;
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
      caption: caption,
      action: ModeActionButton(
        icon: isListening ? Icons.graphic_eq : (canTalkHere ? Icons.mic : Icons.memory),
        semanticLabel: label,
        semanticHint: hint,
        enabled: canTalkHere,
        active: isListening,
        irisState: isListening
            ? IrisState.listening
            : (isProcessing ? IrisState.thinking : (isSpeaking ? IrisState.speaking : IrisState.idle)),
        scale: isListening ? pulseScale : 1,
        onPressDown: onPressDown,
        onPressUp: onPressUp,
        // TalkBack: un toque empieza a escuchar y otro envia.
        onSemanticTap: () => isListening ? onPressUp() : onPressDown(),
      ),
    );
  }
}
