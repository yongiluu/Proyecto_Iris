import 'package:flutter/material.dart';

import '../widgets/mode_action_button.dart';

/// Modo Leer texto: un toque lee lo que tenga al frente la camara (la de la placa si esta
/// conectada; si no, o si la placa no responde, la del celular, sin internet).
class ReadTextModePage extends StatelessWidget {
  const ReadTextModePage({
    super.key,
    required this.isReading,
    required this.usesBoard,
    required this.onRead,
  });

  final bool isReading;

  /// true = lee la camara de la placa; false = la del celular.
  final bool usesBoard;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final source = usesBoard ? 'con la placa' : 'con el celular';
    return ModePage(
      caption: isReading ? 'Leyendo...' : 'Toca para leer ($source)',
      action: ModeActionButton(
        icon: Icons.document_scanner_outlined,
        semanticLabel: isReading ? 'Leyendo texto' : 'Leer texto',
        semanticHint: 'Apunta la cámara al letrero o papel. Lee $source, sin internet',
        enabled: !isReading,
        active: isReading,
        onTap: onRead,
      ),
    );
  }
}
