import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Aviso de la vision local (Edge AI) ya separado en partes para mostrarlo.
class VisionAlert {
  const VisionAlert({required this.what, required this.confidence});

  /// Ej. "una puerta".
  final String what;

  /// Porcentaje 0-100, o null si el texto no lo trae.
  final int? confidence;

  static final RegExp _pattern = RegExp(r'^Adelante:\s*(.+?)(?:\s*\((\d+)%\))?\s*$');

  /// Reconoce el texto de estado que arma _onVisionEvent ("Adelante: una puerta (80%)").
  /// Devuelve null si el estado es otra cosa.
  static VisionAlert? tryParse(String status) {
    final match = _pattern.firstMatch(status);
    if (match == null) return null;
    final confidence = match.group(2);
    return VisionAlert(
      what: match.group(1)!,
      confidence: confidence == null ? null : int.tryParse(confidence),
    );
  }

  IconData get icon {
    final w = what.toLowerCase();
    if (w.contains('persona')) return Icons.person;
    if (w.contains('vehiculo')) return Icons.directions_car;
    if (w.contains('escalera')) return Icons.stairs;
    if (w.contains('puerta')) return Icons.door_front_door;
    if (w.contains('cruce')) return Icons.directions_walk;
    return Icons.visibility;
  }
}

/// Tarjeta destacada (amarillo sobre negro, el par de mayor contraste) para el
/// ultimo objeto que la camara detecto adelante.
class VisionAlertBanner extends StatelessWidget {
  const VisionAlertBanner({super.key, required this.alert});

  final VisionAlert alert;

  @override
  Widget build(BuildContext context) {
    final confidence = alert.confidence;
    final spoken = confidence == null
        ? 'Adelante: ${alert.what}'
        : 'Adelante: ${alert.what}, $confidence por ciento de seguridad';

    return Semantics(
      liveRegion: true,
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: AppTheme.alertAmber,
                  shape: BoxShape.circle,
                ),
                child: Icon(alert.icon, color: Colors.black, size: 32),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'ADELANTE',
                      style: TextStyle(
                        color: AppTheme.alertAmber,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _capitalize(alert.what),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              if (confidence != null) ...[
                const SizedBox(width: 10),
                Text(
                  '$confidence%',
                  style: const TextStyle(
                    color: AppTheme.alertAmber,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
