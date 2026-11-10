import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'iris_logo.dart';
import 'shimmer_text.dart';

enum AssistantPhase { starting, listening, thinking, ready }

/// Con que esta trabajando Iris. La app lo decide sola: usa la placa cuando la encuentra.
enum IrisLink {
  /// Camara y microfono del celular.
  phone,

  /// Modo placa elegido a mano y todavia no conecta.
  searching,

  /// Placa conectada.
  board,
}

/// Barra de arriba, una sola linea: el logo vivo con la fase ("LISTA", "PENSANDO"), un indicador
/// discreto de conexion (no es un boton) y el acceso a Configuracion.
class AssistantTopBar extends StatelessWidget {
  const AssistantTopBar({
    super.key,
    required this.phase,
    required this.link,
    required this.onOpenSettings,
  });

  final AssistantPhase phase;
  final IrisLink link;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final (String label, String spoken, Color accent, IrisState iris) = switch (phase) {
      AssistantPhase.starting => ('INICIANDO', 'Iniciando', AppTheme.textOnDarkMuted, IrisState.thinking),
      AssistantPhase.listening => ('ESCUCHANDO', 'Escuchando', AppTheme.listeningRed, IrisState.listening),
      AssistantPhase.thinking => ('PENSANDO', 'Pensando', AppTheme.violet, IrisState.thinking),
      AssistantPhase.ready => ('LISTA', 'Iris lista', AppTheme.accentCyan, IrisState.idle),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: spoken,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    IrisLogo(size: 26, color: accent, state: iris),
                    const SizedBox(width: 10),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: AppTheme.mono.copyWith(
                            fontSize: 13,
                            color: phase == AssistantPhase.ready ? AppTheme.textOnDark : accent,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          LinkIndicator(link: link),
          IconButton(
            tooltip: 'Configuración',
            iconSize: 24,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.tune_rounded, color: AppTheme.textOnDarkMuted),
            onPressed: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

/// Indicador de conexion: un punto de luz y una palabra. Verde con la placa, apagado con el
/// celular, ambar si se pidio la placa y aun no aparece.
class LinkIndicator extends StatelessWidget {
  const LinkIndicator({super.key, required this.link});

  final IrisLink link;

  @override
  Widget build(BuildContext context) {
    final (String label, String spoken, Color color) = switch (link) {
      IrisLink.board => ('PLACA', 'Placa conectada', AppTheme.success),
      IrisLink.searching => ('BUSCANDO', 'Buscando la placa', AppTheme.alertAmber),
      IrisLink.phone => ('CELULAR', 'Usando el celular', AppTheme.textFaint),
    };
    final lit = link != IrisLink.phone;
    return Semantics(
      label: spoken,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: lit ? [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 8)] : null,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                maxLines: 1,
                textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
                style: AppTheme.mono.copyWith(fontSize: 11, color: lit ? color : AppTheme.textOnDarkMuted),
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
      child: Semantics(
        liveRegion: announce,
        label: text,
        child: ExcludeSemantics(
          child: ShimmerText(
            text,
            active: active,
            highlightColor: AppTheme.violet,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.3),
          ),
        ),
      ),
    );
  }
}
