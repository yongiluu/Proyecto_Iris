import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../../core/theme/app_theme.dart';
import '../../../services/ai/tts_service.dart';

/// Respuesta de Iris que se va escribiendo al ritmo de la voz (tipo karaoke) y que se puede
/// desplazar. Mientras la voz avanza, la vista la sigue sola; si la persona desplaza con el dedo,
/// deja de seguirla hasta que vuelva al final (o toque "Seguir la voz").
///
/// - Solo se sincroniza si [progress] habla de este mismo [text]; si no (otra frase lo corto, o
///   nunca se dijo), se muestra completo.
/// - Con "quitar animaciones" del sistema se muestra completo de inmediato.
/// - TalkBack: la tarjeta tiene el texto completo como etiqueta y no anuncia cada palabra (la
///   voz de Iris ya la esta diciendo).
class StreamingAnswer extends StatefulWidget {
  const StreamingAnswer({
    super.key,
    required this.text,
    required this.progress,
    this.title = 'Respuesta',
  });

  /// Texto ya limpio (ver [TtsService.displayText]).
  final String text;
  final ValueListenable<SpeechProgress> progress;
  final String title;

  @override
  State<StreamingAnswer> createState() => StreamingAnswerState();
}

@visibleForTesting
class StreamingAnswerState extends State<StreamingAnswer> {
  final ScrollController _scroll = ScrollController();
  bool _follow = true;

  /// true mientras la vista sigue sola a la voz.
  bool get isFollowing => _follow;

  ScrollController get scrollController => _scroll;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onProgress);
  }

  @override
  void didUpdateWidget(covariant StreamingAnswer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_onProgress);
      widget.progress.addListener(_onProgress);
    }
    if (oldWidget.text != widget.text) {
      // Respuesta nueva: arriba y siguiendo otra vez.
      _follow = true;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgress);
    _scroll.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  int get _visibleEnd {
    final p = widget.progress.value;
    if (_reduceMotion || p.text != widget.text) return widget.text.length;
    return p.visibleEnd;
  }

  bool get _streaming {
    final p = widget.progress.value;
    return !_reduceMotion && p.text == widget.text && !p.done;
  }

  void _onProgress() {
    if (!mounted) return;
    setState(() {});
    if (_follow) _scheduleFollow();
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if ((_scroll.offset - target).abs() < 1) return;
      _scroll.jumpTo(target);
    });
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is UserScrollNotification && n.direction != ScrollDirection.idle) {
      if (_follow) setState(() => _follow = false);
    } else if (n is ScrollEndNotification) {
      // Volvio al final con el dedo: seguir otra vez.
      final atEnd = n.metrics.pixels >= n.metrics.maxScrollExtent - 4;
      if (atEnd && !_follow && _streaming) setState(() => _follow = true);
    }
    return false;
  }

  void _resumeFollow() {
    setState(() => _follow = true);
    _scheduleFollow();
  }

  @override
  Widget build(BuildContext context) {
    final end = _visibleEnd;
    final text = widget.text;
    final spoken = text.substring(0, end);
    // La palabra que esta sonando, resaltada en cian.
    final lastSpace = spoken.trimRight().lastIndexOf(RegExp(r'\s'));
    final streaming = _streaming;
    final before = streaming && lastSpace > 0 ? spoken.substring(0, lastSpace + 1) : spoken;
    final current = streaming && lastSpace > 0 ? spoken.substring(lastSpace + 1) : '';

    const bodyStyle = TextStyle(color: AppTheme.textOnDark, fontSize: 19, height: 1.45);

    return Semantics(
      container: true,
      label: '${widget.title}: $text',
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.cardDark,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.spatial_audio_off, color: AppTheme.accentCyan, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.accentCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  if (streaming && !_follow)
                    TextButton.icon(
                      key: const ValueKey('seguir-voz'),
                      onPressed: _resumeFollow,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 40),
                        foregroundColor: AppTheme.brightCyan,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      label: const Text('Seguir la voz', style: TextStyle(fontSize: 13)),
                    )
                  else
                    const SizedBox(height: 40),
                ],
              ),
              Flexible(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.only(right: 12, bottom: 4),
                      // Alineado a la izquierda: el texto justificado deja huecos que cuestan con baja vision.
                      child: Text.rich(
                        key: const ValueKey('respuesta-texto'),
                        TextSpan(
                          style: bodyStyle,
                          children: [
                            TextSpan(text: before),
                            if (current.isNotEmpty)
                              TextSpan(
                                text: current,
                                style: const TextStyle(color: AppTheme.brightCyan, fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
