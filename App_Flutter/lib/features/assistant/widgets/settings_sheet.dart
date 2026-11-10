import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/glass.dart';
import '../assistant_modes.dart';

/// Contenido de la pantalla de Configuracion: conexion (la placa se detecta sola; el cambio
/// manual Celular/Placa vive aca), placa, voz, Mi cuenta y misiones de datos.
///
/// No depende de los servicios: recibe el estado y callbacks (la pantalla lo reconstruye cuando
/// algo cambia), asi se puede probar sin Bluetooth.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.autoDetect,
    required this.onAutoDetectChanged,
    required this.hardwareMode,
    required this.onHardwareModeChanged,
    required this.busy,
    required this.boardConnected,
    required this.boardLabel,
    required this.problem,
    required this.needsPermissions,
    required this.onRequestPermissions,
    required this.onOpenAppSettings,
    required this.onPickBoard,
    required this.answersOnPhone,
    required this.onAnswersOnPhoneChanged,
    required this.boardVolume,
    required this.onBoardVolumeChanged,
    this.onOpenAccount,
    this.onOpenMissions,
  });

  /// true = Iris usa la placa cuando la encuentra y el celular cuando no.
  final bool autoDetect;
  final ValueChanged<bool> onAutoDetectChanged;

  final HardwareMode hardwareMode;
  final ValueChanged<HardwareMode> onHardwareModeChanged;

  /// Escuchando o pensando: no se puede cambiar de modo.
  final bool busy;
  final bool boardConnected;
  final String boardLabel;
  final ValueListenable<String?> problem;
  final bool needsPermissions;
  final VoidCallback onRequestPermissions;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onPickBoard;
  final bool answersOnPhone;
  final ValueChanged<bool> onAnswersOnPhoneChanged;
  final ValueListenable<int> boardVolume;
  final ValueChanged<int> onBoardVolumeChanged;

  /// null = sin backend (no se muestra "Mi cuenta").
  final VoidCallback? onOpenAccount;

  /// null = misiones ocultas (kShowDataMissions).
  final VoidCallback? onOpenMissions;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  int? _volumeDrag; // valor mientras se arrastra el slider (se manda al soltar)

  @override
  Widget build(BuildContext context) {
    final isModule = widget.hardwareMode == HardwareMode.esp32;
    // La seccion de la placa se ve tambien en automatico: ahi se elige la placa y se ven los
    // problemas de Bluetooth aunque todavia no haya conectado.
    final showBoard = isModule || widget.autoDetect;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionLabel('Conexión'),
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 6, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MergeSemantics(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: widget.autoDetect,
                    onChanged: widget.busy ? null : widget.onAutoDetectChanged,
                    title: const Text('Detectar la placa sola'),
                    subtitle: const Text('Iris usa la placa cuando la encuentra y el celular cuando no'),
                  ),
                ),
                if (!widget.autoDetect) ...[
                  const SizedBox(height: 6),
                  _HardwareToggle(
                    mode: widget.hardwareMode,
                    enabled: !widget.busy,
                    onChanged: widget.onHardwareModeChanged,
                  ),
                ],
              ],
            ),
          ),
          if (showBoard) ...[
            const SectionLabel('Placa'),
            GlassCard(padding: const EdgeInsets.fromLTRB(16, 14, 12, 10), child: _buildModuleSection()),
          ],
          if (widget.onOpenAccount != null || widget.onOpenMissions != null) ...[
            const SectionLabel('Cuenta'),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  if (widget.onOpenAccount != null)
                    _SettingsTile(
                      icon: Icons.account_circle_outlined,
                      label: 'Mi cuenta',
                      hint: 'Memoria, acompañantes y privacidad',
                      onTap: widget.onOpenAccount!,
                    ),
                  if (widget.onOpenAccount != null && widget.onOpenMissions != null) const Divider(),
                  if (widget.onOpenMissions != null)
                    _SettingsTile(
                      icon: Icons.assignment_outlined,
                      label: 'Misiones de datos',
                      hint: 'Recoleccion de datos para el equipo',
                      onTap: widget.onOpenMissions!,
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          const ExcludeSemantics(
            child: Text(
              'Todo se puede pedir por voz: "Oye Iris, ¿qué dice aquí?", "describe en vivo", "habla más lento".',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textFaint, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleSection() {
    final connected = widget.boardConnected;
    final statusColor = connected ? AppTheme.success : AppTheme.alertAmber;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: connected ? 'Conectado a ${widget.boardLabel}' : 'Buscando el módulo por Bluetooth',
          child: ExcludeSemantics(
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                    boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.8), blurRadius: 10)],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    connected ? 'Conectado a ${widget.boardLabel}' : 'Buscando el modulo...',
                    style: const TextStyle(color: AppTheme.textOnDark, fontSize: 17, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: widget.problem,
          builder: (context, problem, _) {
            if (problem == null || connected) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(problem, style: const TextStyle(color: AppTheme.alertAmber, fontSize: 15, height: 1.3)),
                    if (widget.needsPermissions)
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(onPressed: widget.onRequestPermissions, child: const Text('Dar permiso')),
                          TextButton(onPressed: widget.onOpenAppSettings, child: const Text('Abrir ajustes')),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        _SettingsTile(
          icon: Icons.swap_horiz,
          label: 'Cambiar placa',
          onTap: widget.onPickBoard,
        ),
        const Divider(),
        MergeSemantics(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: widget.answersOnPhone,
            onChanged: widget.onAnswersOnPhoneChanged,
            title: const Text('Respuestas en el celular'),
            subtitle: const Text('La voz de Iris suena en el celular y no en la placa'),
          ),
        ),
        const Divider(),
        const SizedBox(height: 8),
        _buildBoardVolume(connected),
      ],
    );
  }

  /// Volumen del altavoz de la placa: slider de 5 a 100 (pasos de 5, se manda al soltar) y
  /// botones grandes de -10 / +10.
  Widget _buildBoardVolume(bool connected) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.boardVolume,
      builder: (context, volume, _) {
        final shown = _volumeDrag ?? volume;
        Widget stepButton(int delta) => Semantics(
              button: true,
              label: delta < 0 ? 'Bajar volumen de la placa' : 'Subir volumen de la placa',
              value: '$volume por ciento',
              child: ExcludeSemantics(
                child: IconButton(
                  iconSize: 26,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.glassFill,
                    side: const BorderSide(color: AppTheme.glassBorder),
                  ),
                  onPressed: connected ? () => widget.onBoardVolumeChanged(volume + delta) : null,
                  icon: Icon(delta < 0 ? Icons.remove : Icons.add, color: AppTheme.textOnDark),
                ),
              ),
            );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Text('Volumen de la placa: $shown',
                  style: const TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 15)),
            ),
            Row(
              children: [
                stepButton(-10),
                Expanded(
                  child: Semantics(
                    label: 'Volumen de la placa',
                    child: Slider(
                      value: shown.toDouble().clamp(5, 100),
                      min: 5,
                      max: 100,
                      divisions: 19,
                      label: '$shown',
                      onChanged: connected ? (v) => setState(() => _volumeDrag = v.round()) : null,
                      onChangeEnd: connected
                          ? (v) {
                              setState(() => _volumeDrag = null);
                              widget.onBoardVolumeChanged(v.round());
                            }
                          : null,
                    ),
                  ),
                ),
                stepButton(10),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Celular / Placa: dos opciones excluyentes (solo con la deteccion automatica apagada).
class _HardwareToggle extends StatelessWidget {
  const _HardwareToggle({required this.mode, required this.enabled, required this.onChanged});

  final HardwareMode mode;
  final bool enabled;
  final ValueChanged<HardwareMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(HardwareMode value, IconData icon, String label, String spoken, String hint) {
      final selected = mode == value;
      final fg = selected ? AppTheme.textOnDark : AppTheme.textOnDarkMuted;
      return Expanded(
        child: Semantics(
          container: true,
          inMutuallyExclusiveGroup: true,
          checked: selected,
          enabled: enabled,
          label: spoken,
          hint: selected ? null : hint,
          onTap: enabled ? () => onChanged(value) : null,
          child: ExcludeSemantics(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: enabled ? () => onChanged(value) : null,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.accentCyan.withValues(alpha: 0.24) : Colors.transparent,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: selected ? AppTheme.accentCyan : Colors.transparent),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: selected ? AppTheme.brightCyan : fg, size: 22),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(label,
                              maxLines: 1,
                              style: TextStyle(
                                  color: fg, fontSize: 17, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(32)),
      child: Row(
        children: [
          option(HardwareMode.standalone, Icons.smartphone, 'Celular', 'Modo Celular',
              'Usa la cámara y el micrófono del teléfono'),
          const SizedBox(width: 4),
          option(HardwareMode.esp32, Icons.memory, 'Placa', 'Modo Módulo', 'Usa la cámara y el micrófono de la placa'),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({required this.icon, required this.label, required this.onTap, this.hint});

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 52,
      leading: Icon(icon, color: AppTheme.accentCyan),
      title: Text(label),
      subtitle: hint == null ? null : Text(hint!),
      trailing: const Icon(Icons.chevron_right, color: AppTheme.textFaint),
      onTap: onTap,
    );
  }
}
