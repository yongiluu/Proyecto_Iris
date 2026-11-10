import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/glass.dart';
import '../assistant_modes.dart';

/// Contenido de la pantalla de Configuracion: apariencia (oscura o clara), conexion (la placa se
/// detecta sola; el cambio manual Celular/Placa vive aca), placa, Mi cuenta y misiones de datos.
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
    this.lightAppearance = false,
    this.onLightAppearanceChanged,
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

  /// Apariencia clara u oscura. Con el callback en null no se muestra la seccion.
  final bool lightAppearance;
  final ValueChanged<bool>? onLightAppearanceChanged;

  /// null = sin backend (no se muestra "Mi cuenta").
  final VoidCallback? onOpenAccount;

  /// null = misiones ocultas (kShowDataMissions).
  final VoidCallback? onOpenMissions;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  int? _volumeDrag; // valor mientras se arrastra el slider (se manda al soltar)

  /// Tarjeta de una seccion: filas con aire a los lados y una linea fina entre ellas.
  Widget _card(List<Widget> rows) => GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(),
              rows[i],
            ],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isModule = widget.hardwareMode == HardwareMode.esp32;
    // La seccion de la placa se ve tambien en automatico: ahi se elige la placa y se ven los
    // problemas de Bluetooth aunque todavia no haya conectado.
    final showBoard = isModule || widget.autoDetect;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onLightAppearanceChanged != null) ...[
            const SectionLabel('Apariencia'),
            _Segmented<bool>(
              value: widget.lightAppearance,
              onChanged: widget.onLightAppearanceChanged!,
              options: const [
                (value: false, icon: Icons.dark_mode_outlined, label: 'Oscura', spoken: 'Apariencia oscura', hint: null),
                (value: true, icon: Icons.light_mode_outlined, label: 'Clara', spoken: 'Apariencia clara', hint: null),
              ],
            ),
          ],
          const SectionLabel('Conexión'),
          _card([
            _SwitchRow(
              title: 'Detectar la placa sola',
              subtitle: 'Iris usa la placa cuando la encuentra y el celular cuando no',
              value: widget.autoDetect,
              onChanged: widget.busy ? null : widget.onAutoDetectChanged,
            ),
            if (!widget.autoDetect)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: _Segmented<HardwareMode>(
                  value: widget.hardwareMode,
                  enabled: !widget.busy,
                  onChanged: widget.onHardwareModeChanged,
                  options: const [
                    (
                      value: HardwareMode.standalone,
                      icon: Icons.smartphone,
                      label: 'Celular',
                      spoken: 'Modo Celular',
                      hint: 'Usa la cámara y el micrófono del teléfono',
                    ),
                    (
                      value: HardwareMode.esp32,
                      icon: Icons.memory,
                      label: 'Placa',
                      spoken: 'Modo Módulo',
                      hint: 'Usa la cámara y el micrófono de la placa',
                    ),
                  ],
                ),
              ),
          ]),
          if (showBoard) ...[
            const SectionLabel('Placa'),
            _card([
              _buildBoardStatus(),
              _NavRow(icon: Icons.swap_horiz_rounded, label: 'Cambiar placa', onTap: widget.onPickBoard),
              _SwitchRow(
                title: 'Respuestas en el celular',
                subtitle: 'La voz de Iris suena en el celular y no en la placa',
                value: widget.answersOnPhone,
                onChanged: widget.onAnswersOnPhoneChanged,
              ),
              _buildBoardVolume(widget.boardConnected),
            ]),
          ],
          if (widget.onOpenAccount != null || widget.onOpenMissions != null) ...[
            const SectionLabel('Cuenta'),
            _card([
              if (widget.onOpenAccount != null)
                _NavRow(
                  icon: Icons.account_circle_outlined,
                  label: 'Mi cuenta',
                  hint: 'Memoria, acompañantes y privacidad',
                  onTap: widget.onOpenAccount!,
                ),
              if (widget.onOpenMissions != null)
                _NavRow(
                  icon: Icons.assignment_outlined,
                  label: 'Misiones de datos',
                  hint: 'Recoleccion de datos para el equipo',
                  onTap: widget.onOpenMissions!,
                ),
            ]),
          ],
          const SizedBox(height: 28),
          ExcludeSemantics(
            child: Text(
              'Todo se puede pedir por voz:\n"Oye Iris, ¿qué dice aquí?" · "describe en vivo" · "habla más lento"',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textFaint, fontSize: 13, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }

  /// Estado de la conexion: punto de luz, nombre de la placa y, si hay un problema, que hacer.
  Widget _buildBoardStatus() {
    final connected = widget.boardConnected;
    final statusColor = connected ? AppTheme.success : AppTheme.alertAmber;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
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
                      boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.7), blurRadius: 10)],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          connected ? 'CONECTADA' : 'BUSCANDO',
                          style: AppTheme.sectionLabel.copyWith(fontSize: 11, color: statusColor),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          connected ? 'Conectado a ${widget.boardLabel}' : 'Buscando el modulo...',
                          style: TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w500),
                        ),
                      ],
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
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(problem, style: TextStyle(color: AppTheme.alertAmber, fontSize: 15, height: 1.35)),
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
        ],
      ),
    );
  }

  /// Volumen del altavoz de la placa: slider de 5 a 100 (pasos de 5, se manda al soltar) y
  /// botones de -10 / +10.
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
                  iconSize: 22,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  style: IconButton.styleFrom(
                    backgroundColor: AppTheme.subtleFill,
                    foregroundColor: AppTheme.text,
                    disabledForegroundColor: AppTheme.textFaint,
                  ),
                  onPressed: connected ? () => widget.onBoardVolumeChanged(volume + delta) : null,
                  icon: Icon(delta < 0 ? Icons.remove_rounded : Icons.add_rounded),
                ),
              ),
            );
        return Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(child: Text('Volumen de la placa', style: Theme.of(context).textTheme.bodyLarge)),
                    Text(
                      '$shown',
                      style: AppTheme.mono.copyWith(fontSize: 15, letterSpacing: 1, color: AppTheme.accentCyan),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  stepButton(-10),
                  const SizedBox(width: 6),
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
                  const SizedBox(width: 6),
                  stepButton(10),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Fila con titulo, explicacion y un interruptor a la derecha.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.title, required this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        value: value,
        onChanged: onChanged,
        title: Text(title),
        subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle)),
      ),
    );
  }
}

/// Fila que lleva a otra pantalla.
class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap, this.hint});

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      minTileHeight: 60,
      horizontalTitleGap: 14,
      leading: Icon(icon, color: AppTheme.accentCyan, size: 24),
      title: Text(label),
      subtitle: hint == null ? null : Padding(padding: const EdgeInsets.only(top: 4), child: Text(hint!)),
      trailing: Icon(Icons.chevron_right_rounded, color: AppTheme.textFaint),
      onTap: onTap,
    );
  }
}

typedef _SegmentOption<T> = ({T value, IconData icon, String label, String spoken, String? hint});

/// Opciones excluyentes en una pastilla: Oscura / Clara, Celular / Placa.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({required this.value, required this.onChanged, required this.options, this.enabled = true});

  final T value;
  final bool enabled;
  final ValueChanged<T> onChanged;
  final List<_SegmentOption<T>> options;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppTheme.subtleFill,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: AppTheme.glassBorder),
      ),
      child: Row(
        children: [
          for (final option in options)
            Expanded(child: _buildOption(option, option.value == value, reduceMotion)),
        ],
      ),
    );
  }

  Widget _buildOption(_SegmentOption<T> option, bool selected, bool reduceMotion) {
    return Semantics(
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: option.spoken,
      hint: selected ? null : option.hint,
      onTap: enabled ? () => onChanged(option.value) : null,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: enabled ? () => onChanged(option.value) : null,
            child: AnimatedContainer(
              duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
              constraints: const BoxConstraints(minHeight: 50),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? AppTheme.accentCyan.withValues(alpha: 0.20) : Colors.transparent,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: selected ? AppTheme.accentCyan.withValues(alpha: 0.8) : Colors.transparent),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(option.icon, size: 20, color: selected ? AppTheme.accentCyan : AppTheme.textFaint),
                  const SizedBox(width: 10),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        option.label,
                        maxLines: 1,
                        style: TextStyle(
                          color: selected ? AppTheme.text : AppTheme.textMuted,
                          fontSize: 16,
                          fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                    ),
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
