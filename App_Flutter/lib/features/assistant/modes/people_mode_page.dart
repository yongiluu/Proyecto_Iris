import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../widgets/mode_action_button.dart';

/// Modo Personas: un toque dice quien esta al frente ("Aqui esta Raul al frente"). Debajo,
/// "Agregar persona" (guarda su cara con ~5 fotos guiadas por voz) y la lista para borrar.
class PeopleModePage extends StatelessWidget {
  const PeopleModePage({
    super.key,
    required this.isAvailable,
    required this.isBusy,
    required this.savedCount,
    required this.onWhoIsHere,
    required this.onAddPerson,
    required this.onShowPeople,
    this.enrollStatus,
    this.onCancelEnroll,
  });

  /// false hasta que este instalado el modelo de caras.
  final bool isAvailable;
  final bool isBusy;
  final int savedCount;
  final VoidCallback onWhoIsHere;
  final VoidCallback onAddPerson;
  final VoidCallback onShowPeople;

  /// "Agregando a Raul: foto 2 de 5" mientras guarda una cara.
  final String? enrollStatus;
  final VoidCallback? onCancelEnroll;

  @override
  Widget build(BuildContext context) {
    final enrolling = enrollStatus != null;
    final Widget extra;
    if (enrolling) {
      extra = Row(
        children: [
          Expanded(
            child: Text(
              enrollStatus!,
              style: TextStyle(color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          ModeChipButton(icon: Icons.close, label: 'Cancelar', onPressed: onCancelEnroll),
        ],
      );
    } else {
      extra = Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          ModeChipButton(
            icon: Icons.person_add_alt_1,
            label: 'Agregar persona',
            onPressed: isBusy ? null : onAddPerson,
          ),
          ModeChipButton(
            icon: Icons.list,
            label: 'Guardadas ($savedCount)',
            semanticLabel: 'Personas guardadas, $savedCount',
            onPressed: isBusy ? null : onShowPeople,
          ),
        ],
      );
    }

    return ModePage(
      extra: extra,
      caption: !isAvailable
          ? 'Reconocimiento de personas aun no instalado'
          : (isBusy
              ? 'Mirando...'
              : (savedCount > 0 ? 'Te aviso solo a quien conozco' : 'Toca: ¿quien esta aqui?')),
      action: ModeActionButton(
        icon: Icons.face_retouching_natural,
        semanticLabel: '¿Quién está aquí?',
        semanticHint: 'Apunta la cámara a las personas. En esta página te aviso solo cuando veo a alguien que conozco',
        enabled: !isBusy,
        active: isBusy,
        onTap: onWhoIsHere,
      ),
    );
  }
}
