import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/theme/app_theme.dart';
import '../../../services/hardware/esp32_speech_service.dart';

/// Lista de placas Iris cercanas: elegir a cual conectarse y ponerles apodo ("Iris 1", "Iris 2").
class BoardPicker extends StatelessWidget {
  const BoardPicker({super.key, required this.service});

  final Esp32SpeechService service;

  Future<void> _rename(BuildContext context, IrisBoard board) async {
    final controller = TextEditingController(text: board.nickname ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apodo de la placa'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'Ej. Iris 1', helperText: board.id),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null) await service.setNickname(board.id, name);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: ValueListenableBuilder<List<IrisBoard>>(
          valueListenable: service.boardsFound,
          builder: (context, boards, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Elige tu placa Iris',
                          style: TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      tooltip: 'Buscar de nuevo',
                      onPressed: service.refreshBoards,
                      icon: Icon(Icons.refresh, color: AppTheme.accentCyan),
                    ),
                  ],
                ),
                if (boards.isEmpty)
                  ValueListenableBuilder<String?>(
                    valueListenable: service.problem,
                    builder: (context, problem, _) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          service.isScanning || problem == null
                              ? 'Buscando placas... Enciende la placa y acercala al celular.'
                              : problem,
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 16),
                        ),
                      ),
                    ),
                  ),
                if (service.needsPermissions)
                  TextButton(
                    onPressed: openAppSettings,
                    child: Text('Abrir ajustes de la app', style: TextStyle(color: AppTheme.accentCyan)),
                  ),
                for (final board in boards)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      board.id == service.connectedBoardId ? Icons.bluetooth_connected : Icons.memory,
                      color: board.id == service.preferredBoardId ? AppTheme.accentCyan : AppTheme.textMuted,
                    ),
                    title: Text(board.label, style: TextStyle(color: AppTheme.text, fontSize: 18)),
                    subtitle: Text(
                      '${board.id}  ·  ${board.id == service.connectedBoardId ? 'conectada' : 'senal ${board.rssi} dBm'}',
                      style: TextStyle(color: AppTheme.textMuted),
                    ),
                    trailing: IconButton(
                      tooltip: 'Poner apodo',
                      onPressed: () => _rename(context, board),
                      icon: Icon(Icons.edit, color: AppTheme.textMuted),
                    ),
                    onTap: () {
                      service.selectBoard(board.id);
                      Navigator.pop(context);
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
