import 'package:flutter/material.dart';

import '../widgets/iris_logo.dart';
import '../widgets/mode_action_button.dart';

/// Modo En vivo: al entrar, Iris describe sola lo que va apareciendo adelante; al salir de la
/// pagina se apaga. El iris lo muestra con una ola continua. Un toque lo pausa o lo retoma.
/// Por voz: "describe en vivo" / "deja de describir".
class LiveModePage extends StatelessWidget {
  const LiveModePage({
    super.key,
    required this.isOn,
    required this.onBoard,
    required this.onToggle,
  });

  final bool isOn;

  /// true = lo hace la placa sola (sin internet); false = el celular con la nube.
  final bool onBoard;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return ModePage(
      caption: isOn
          ? (onBoard ? 'La placa te avisa lo que aparece. Toca para pausar' : 'Describiendo en vivo. Toca para pausar')
          : 'En pausa. Toca para describir en vivo',
      action: ModeActionButton(
        icon: isOn ? Icons.sensors : Icons.sensors_off,
        semanticLabel: 'Descripción en vivo',
        semanticHint: isOn ? 'Toca dos veces para pausar' : 'Toca dos veces para que Iris describa sola lo que ve',
        toggled: isOn,
        active: isOn,
        activeColor: const Color(0xFF5EF2B0),
        irisState: isOn ? IrisState.speaking : IrisState.idle,
        onTap: onToggle,
      ),
    );
  }
}
