import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../assistant_modes.dart';

/// Ajustes que no se usan a cada rato: Celular o Modulo, placa, respuestas en el celular,
/// volumen de la placa, Mi cuenta y misiones de datos. Se abre con el engranaje de arriba.
///
/// No depende de los servicios: recibe el estado y callbacks (la pantalla lo reconstruye cuando
/// algo cambia), asi se puede probar sin Bluetooth.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
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

  static const _sectionStyle = TextStyle(
    color: AppTheme.accentCyan,
    fontSize: 13,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.2,
  );

  @override
  Widget build(BuildContext context) {
    final isModule = widget.hardwareMode == HardwareMode.esp32;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: const Text('Ajustes',
                  style: TextStyle(color: AppTheme.textOnDark, fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 12),
            const ExcludeSemantics(child: Text('CAMARA Y MICROFONO', style: _sectionStyle)),
            const SizedBox(height: 6),
            _HardwareToggle(
              mode: widget.hardwareMode,
              enabled: !widget.busy,
              onChanged: widget.onHardwareModeChanged,
            ),
            if (isModule) ...[
              const SizedBox(height: 16),
              const ExcludeSemantics(child: Text('MODULO', style: _sectionStyle)),
              const SizedBox(height: 4),
              _buildModuleSection(),
            ],
            if (widget.onOpenAccount != null || widget.onOpenMissions != null) ...[
              const SizedBox(height: 12),
              const Divider(color: Colors.white24),
            ],
            if (widget.onOpenAccount != null)
              _SettingsTile(
                icon: Icons.account_circle_outlined,
                label: 'Mi cuenta',
                hint: 'Memoria, acompañantes y privacidad',
                onTap: widget.onOpenAccount!,
              ),
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
    );
  }

  Widget _buildModuleSection() {
    final connected = widget.boardConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: connected ? 'Conectado a ${widget.boardLabel}' : 'Buscando el módulo por Bluetooth',
          child: ExcludeSemantics(
            child: Row(
              children: [
                Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                  color: connected ? AppTheme.accentCyan : AppTheme.alertAmber,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connected ? 'Conectado a ${widget.boardLabel}' : 'Buscando el modulo...',
                    style: const TextStyle(color: AppTheme.textOnDark, fontSize: 16),
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
                          TextButton(
                            onPressed: widget.onRequestPermissions,
                            child: const Text('Dar permiso', style: TextStyle(color: AppTheme.accentCyan)),
                          ),
                          TextButton(
                            onPressed: widget.onOpenAppSettings,
                            child: const Text('Abrir ajustes', style: TextStyle(color: AppTheme.accentCyan)),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        _SettingsTile(
          icon: Icons.swap_horiz,
          label: 'Cambiar placa',
          onTap: widget.onPickBoard,
        ),
        MergeSemantics(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: widget.answersOnPhone,
            onChanged: widget.onAnswersOnPhoneChanged,
            activeThumbColor: Colors.black,
            activeTrackColor: AppTheme.accentCyan,
            inactiveThumbColor: AppTheme.textOnDarkMuted,
            inactiveTrackColor: Colors.white24,
            title: const Text('Respuestas en el celular',
                style: TextStyle(color: AppTheme.textOnDark, fontSize: 16)),
            subtitle: const Text('La voz de Iris suena en el celular y no en la placa',
                style: TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 13)),
          ),
        ),
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
                  iconSize: 28,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  style: IconButton.styleFrom(backgroundColor: Colors.white12),
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
                      activeColor: AppTheme.accentCyan,
                      inactiveColor: Colors.white24,
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

/// Celular / Modulo: dos opciones excluyentes.
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
                    color: selected ? AppTheme.accentCyan.withValues(alpha: 0.28) : Colors.transparent,
                    borderRadius: BorderRadius.circular(28),
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
                                  color: fg,
                                  fontSize: 17,
                                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500)),
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
          option(HardwareMode.esp32, Icons.memory, 'Modulo', 'Modo Módulo', 'Usa la cámara y el micrófono de la placa'),
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
      title: Text(label, style: const TextStyle(color: AppTheme.textOnDark, fontSize: 17)),
      subtitle: hint == null
          ? null
          : Text(hint!, style: const TextStyle(color: AppTheme.textOnDarkMuted, fontSize: 13)),
      trailing: const Icon(Icons.chevron_right, color: AppTheme.textOnDarkMuted),
      onTap: onTap,
    );
  }
}
