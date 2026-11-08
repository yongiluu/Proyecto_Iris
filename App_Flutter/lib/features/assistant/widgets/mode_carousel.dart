import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../assistant_modes.dart';

/// Carrusel horizontal de modos: se desliza con el dedo (o con dos dedos en TalkBack) y arriba
/// tiene pestañas compactas que tambien sirven de indicador de pagina.
///
/// Al cambiar de modo se anuncia con una region viva ("Modo Leer texto, 2 de 4"): en Android es
/// la forma recomendada (los anuncios directos estan obsoletos y cortan a TalkBack).
class ModeCarousel extends StatelessWidget {
  const ModeCarousel({
    super.key,
    required this.controller,
    required this.mode,
    required this.onModeChanged,
    required this.pageBuilder,
    this.onTabSelected,
  });

  final PageController controller;

  /// Modo visible ahora.
  final IrisMode mode;

  /// La pagina cambio (deslizando, por una pestaña o por un comando de voz).
  final ValueChanged<IrisMode> onModeChanged;

  /// Una pestaña fue tocada (si es null, se anima el PageController).
  final ValueChanged<IrisMode>? onTabSelected;
  final Widget Function(BuildContext context, IrisMode mode) pageBuilder;

  void _selectTab(BuildContext context, IrisMode target) {
    if (onTabSelected != null) {
      onTabSelected!(target);
      return;
    }
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      controller.jumpToPage(target.index);
    } else {
      controller.animateToPage(target.index, duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Region viva: solo cambia (y se anuncia) cuando cambia el modo.
        Semantics(
          key: const ValueKey('anuncio-modo'),
          liveRegion: true,
          container: true,
          label: mode.announcement,
          hint: mode.hint,
          child: const SizedBox(width: 1, height: 1),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              children: [
                for (final m in IrisMode.values)
                  Expanded(
                    child: _ModeTab(
                      mode: m,
                      selected: m == mode,
                      onTap: () => _selectTab(context, m),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: controller,
            itemCount: IrisMode.values.length,
            onPageChanged: (i) => onModeChanged(IrisMode.values[i]),
            itemBuilder: (context, i) => pageBuilder(context, IrisMode.values[i]),
          ),
        ),
      ],
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({required this.mode, required this.selected, required this.onTap});

  final IrisMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final fg = selected ? AppTheme.brightCyan : AppTheme.textOnDarkMuted;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '${mode.spokenName}, pestaña ${mode.index + 1} de ${IrisMode.values.length}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: AnimatedContainer(
              duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? AppTheme.accentCyan.withValues(alpha: 0.28) : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(mode.icon, size: 20, color: fg),
                  // Con letra grande solo se achica la etiqueta (el icono queda).
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          mode.shortName,
                          maxLines: 1,
                          style: TextStyle(
                            color: selected ? AppTheme.textOnDark : AppTheme.textOnDarkMuted,
                            fontSize: 14,
                            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                          ),
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
