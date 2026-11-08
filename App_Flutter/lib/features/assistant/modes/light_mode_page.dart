import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../widgets/mode_action_button.dart';

/// Modo Buscar luz: un toque prende o apaga el detector. Suena un tono mas agudo con mas luz
/// (la placa o el celular, segun cual mida). En pantalla, el nivel grande con un brillo.
class LightModePage extends StatelessWidget {
  const LightModePage({
    super.key,
    required this.isOn,
    required this.level,
    required this.onToggle,
  });

  final bool isOn;

  /// 0-100, o null si todavia no hay medicion.
  final int? level;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return ModePage(
      extra: isOn ? LightLevelMeter(level: level) : null,
      caption: isOn ? 'Toca para apagar' : 'Toca para encender. Mas agudo = mas luz',
      action: ModeActionButton(
        icon: isOn ? Icons.light_mode : Icons.light_mode_outlined,
        semanticLabel: 'Detector de luz',
        semanticHint: isOn ? 'Toca dos veces para apagar' : 'Toca dos veces para encender',
        toggled: isOn,
        active: isOn,
        activeColor: AppTheme.alertAmber,
        onTap: onToggle,
      ),
    );
  }
}

/// Barra horizontal con el nivel de luz y un brillo ambar proporcional. Sin liveRegion: el tono
/// ya avisa y anunciar cada cambio saturaria a TalkBack.
class LightLevelMeter extends StatelessWidget {
  const LightLevelMeter({super.key, required this.level});

  final int? level;

  @override
  Widget build(BuildContext context) {
    final value = level;
    final fraction = (value ?? 0) / 100;
    return Semantics(
      label: 'Nivel de luz',
      value: value == null ? 'midiendo' : '$value por ciento',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            boxShadow: [
              BoxShadow(
                color: AppTheme.alertAmber.withValues(alpha: 0.15 + 0.55 * fraction),
                blurRadius: 10 + 30 * fraction,
                spreadRadius: 2 * fraction,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                value == null ? 'Midiendo...' : '$value %',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.alertAmber, fontSize: 34, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: value == null ? null : fraction,
                  minHeight: 14,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation(AppTheme.alertAmber),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
