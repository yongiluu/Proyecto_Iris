import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'iris_logo.dart';
import 'shimmer_text.dart';

enum AssistantPhase { starting, listening, thinking, ready }

/// Barra de arriba, una sola linea: logo + fase ("Iris lista"), el chip del hardware
/// ("Celular" / "Modulo conectado") y el engranaje de ajustes.
class AssistantTopBar extends StatelessWidget {
  const AssistantTopBar({
    super.key,
    required this.phase,
    required this.hardwareLabel,
    required this.hardwareIcon,
    required this.onOpenSettings,
    this.hardwareWarning = false,
  });

  final AssistantPhase phase;

  /// "Celular", "Modulo conectado", "Buscando modulo".
  final String hardwareLabel;
  final IconData hardwareIcon;

  /// Ambar: el modulo no esta conectado o falta un permiso.
  final bool hardwareWarning;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final (String label, String spoken, Color accent) = switch (phase) {
      AssistantPhase.starting => ('INICIANDO', 'Iniciando', AppTheme.textOnDarkMuted),
      AssistantPhase.listening => ('ESCUCHANDO', 'Escuchando', AppTheme.listeningRed),
      AssistantPhase.thinking => ('PENSANDO', 'Pensando', AppTheme.brightCyan),
      AssistantPhase.ready => ('IRIS LISTA', 'Iris lista', AppTheme.accentCyan),
    };
    final busy = phase == AssistantPhase.listening || phase == AssistantPhase.thinking;
    final chipColor = hardwareWarning ? AppTheme.alertAmber : AppTheme.textOnDarkMuted;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: spoken,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    if (phase == AssistantPhase.listening)
                      Icon(Icons.mic, color: accent, size: 24)
                    else
                      // Logo de Iris: quieto en reposo, girando mientras piensa o arranca.
                      IrisLogo(
                        size: 24,
                        color: accent,
                        spinning: phase == AssistantPhase.thinking || phase == AssistantPhase.starting,
                        turnDuration: Duration(milliseconds: phase == AssistantPhase.thinking ? 1600 : 4000),
                      ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: TextStyle(
                            color: busy ? accent : AppTheme.textOnDark,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Chip del hardware: tambien abre los ajustes.
          Flexible(
            child: Semantics(
              button: true,
              label: '$hardwareLabel. Ajustes de conexión',
              child: ExcludeSemantics(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: onOpenSettings,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: ShapeDecoration(
                          color: AppTheme.cardDark,
                          shape: StadiumBorder(side: BorderSide(color: chipColor.withValues(alpha: 0.6))),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(hardwareIcon, size: 16, color: chipColor),
                            const SizedBox(width: 5),
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(hardwareLabel,
                                    maxLines: 1, style: TextStyle(color: chipColor, fontSize: 13)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Ajustes',
            iconSize: 26,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.settings_outlined, color: AppTheme.textOnDarkMuted),
            onPressed: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

/// Linea de estado corta ("Leyendo texto...", "Modulo conectado"). Region viva: TalkBack la
/// anuncia solo cuando cambia. El brillo no cambia la semantica.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.text, required this.active, this.announce = true});

  final String text;
  final bool active;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Semantics(
        liveRegion: announce,
        label: text,
        child: ExcludeSemantics(
          child: ShimmerText(
            text,
            active: active,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.3),
          ),
        ),
      ),
    );
  }
}
