import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_app/core/widgets/aurora_background.dart';
import 'package:iris_app/core/widgets/iris_splash.dart';
import 'package:iris_app/features/assistant/assistant_modes.dart';
import 'package:iris_app/features/assistant/modes/assistant_mode_page.dart';
import 'package:iris_app/features/assistant/modes/light_mode_page.dart';
import 'package:iris_app/features/assistant/modes/live_mode_page.dart';
import 'package:iris_app/features/assistant/modes/people_mode_page.dart';
import 'package:iris_app/features/assistant/modes/read_text_mode_page.dart';
import 'package:iris_app/features/assistant/widgets/assistant_header.dart';
import 'package:iris_app/features/assistant/widgets/assistant_layout.dart';
import 'package:iris_app/features/assistant/widgets/iris_logo.dart';
import 'package:iris_app/features/assistant/widgets/mode_carousel.dart';
import 'package:iris_app/features/assistant/widgets/settings_sheet.dart';
import 'package:iris_app/features/assistant/widgets/streaming_answer.dart';
import 'package:iris_app/features/assistant/widgets/vision_alert_banner.dart';
import 'package:iris_app/services/ai/tts_service.dart';

/// Pantalla de telefono chico (360x640 dp).
void _phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Widget _app(Widget child, {double textScale = 1, bool reduceMotion = false}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: Scaffold(backgroundColor: Colors.black, body: child),
      ),
    ),
  );
}

/// Las paginas reales con valores fijos (sin servicios).
Widget _realPage(BuildContext context, IrisMode mode) {
  switch (mode) {
    case IrisMode.assistant:
      return AssistantModePage(
        isListening: false,
        isProcessing: false,
        canTalkHere: true,
        isModule: false,
        moduleConnected: false,
        onPressDown: () {},
        onPressUp: () {},
      );
    case IrisMode.live:
      return LiveModePage(isOn: true, onBoard: false, onToggle: () {});
    case IrisMode.readText:
      return ReadTextModePage(isReading: false, usesBoard: false, onRead: () {});
    case IrisMode.light:
      return LightModePage(isOn: true, level: 72, onToggle: () {});
    case IrisMode.people:
      return PeopleModePage(
        isAvailable: true,
        isBusy: true,
        savedCount: 3,
        onWhoIsHere: () {},
        onAddPerson: () {},
        onShowPeople: () {},
        enrollStatus: 'Raul: foto 2 de 5',
        onCancelEnroll: () {},
      );
  }
}

/// Carrusel con su propio estado, como lo usa la pantalla.
class _CarouselHost extends StatefulWidget {
  const _CarouselHost({required this.onChanged});

  final ValueChanged<IrisMode> onChanged;

  @override
  State<_CarouselHost> createState() => _CarouselHostState();
}

class _CarouselHostState extends State<_CarouselHost> {
  final PageController controller = PageController();
  IrisMode mode = IrisMode.assistant;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ModeCarousel(
      controller: controller,
      mode: mode,
      onModeChanged: (m) {
        setState(() => mode = m);
        widget.onChanged(m);
      },
      pageBuilder: _realPage,
    );
  }
}

String _answerText(WidgetTester tester) {
  final rich = tester.widget<RichText>(
    find.descendant(of: find.byKey(const ValueKey('respuesta-texto')), matching: find.byType(RichText)),
  );
  return rich.text.toPlainText();
}

void main() {
  group('Carrusel de modos', () {
    // Sin animaciones: el iris respira siempre y pumpAndSettle no terminaria nunca.
    testWidgets('muestra los 5 modos y deslizar cambia el modo anunciado', (tester) async {
      _phoneSize(tester);
      final semantics = tester.ensureSemantics();
      final changes = <IrisMode>[];
      await tester.pumpWidget(_app(_CarouselHost(onChanged: changes.add), reduceMotion: true));

      expect(IrisMode.values.map((m) => m.shortName), ['Iris', 'En vivo', 'Leer', 'Luz', 'Personas']);
      for (final m in IrisMode.values) {
        expect(find.text(m.shortName), findsOneWidget, reason: m.name);
      }
      // El dial muestra el modo actual y sus vecinos.
      expect(find.bySemanticsLabel('Iris, asistente, pestaña 1 de 5'), findsOneWidget);
      expect(find.bySemanticsLabel('En vivo, pestaña 2 de 5'), findsOneWidget);
      SemanticsNode announcer() => tester.getSemantics(find.byKey(const ValueKey('anuncio-modo')));
      expect(announcer().label, 'Modo Iris, asistente, 1 de 5');
      expect(announcer().flagsCollection.isLiveRegion, isTrue);

      // Deslizar a la izquierda (fuera del iris, que no cambia de pagina): siguiente modo.
      Offset beside() => tester.getTopRight(find.byType(PageView)) + const Offset(-30, 30);
      await tester.flingFrom(beside(), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(changes, [IrisMode.live]);
      expect(announcer().label, 'Modo En vivo, 2 de 5');
      expect(find.bySemanticsLabel('Descripción en vivo'), findsOneWidget);

      await tester.flingFrom(beside(), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.readText);
      expect(announcer().label, 'Modo Leer texto, 3 de 5');
      expect(find.bySemanticsLabel('Leer texto'), findsOneWidget);

      // Tocar un nombre del dial tambien lleva al modo.
      await tester.tap(find.text('Luz'));
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.light);
      expect(announcer().label, 'Modo Buscar luz, 4 de 5');
      // Y deslizar sobre el dial: hacia la derecha vuelve al anterior.
      await tester.fling(find.byType(ModeDial), const Offset(200, 0), 1000);
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.readText);
      await tester.fling(find.byType(ModeDial), const Offset(-200, 0), 1000);
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.light);
      await tester.tap(find.text('Personas'));
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.people);
      expect(announcer().label, 'Modo Personas, 5 de 5');
      semantics.dispose();
    });

    testWidgets('mantener el boton grande y arrastrar no cambia de modo', (tester) async {
      _phoneSize(tester);
      final changes = <IrisMode>[];
      await tester.pumpWidget(_app(_CarouselHost(onChanged: changes.add), reduceMotion: true));
      await tester.drag(find.bySemanticsLabel('Hablar con Iris'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
    });

    testWidgets('la respuesta va entre el iris y el dial', (tester) async {
      _phoneSize(tester);
      final controller = PageController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(
        ModeCarousel(
          controller: controller,
          mode: IrisMode.assistant,
          onModeChanged: (_) {},
          pageBuilder: _realPage,
          answer: StreamingAnswer(
            text: 'Hay una silla adelante.',
            progress: ValueNotifier(const SpeechProgress('Hay una silla adelante.', 23, done: true)),
          ),
        ),
        reduceMotion: true,
      ));
      final iris = tester.getRect(find.bySemanticsLabel('Hablar con Iris'));
      final answer = tester.getRect(find.byType(StreamingAnswer));
      final dial = tester.getRect(find.byType(ModeDial));
      expect(iris.bottom, lessThanOrEqualTo(answer.top));
      expect(answer.bottom, lessThanOrEqualTo(dial.top));
    });
  });

  group('Iris vivo, fondo y arranque', () {
    testWidgets('el iris cambia de estado sin errores y queda quieto sin animaciones', (tester) async {
      for (final state in IrisState.values) {
        await tester.pumpWidget(_app(Center(child: IrisLogo(size: 140, state: state, glow: true))));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.takeException(), isNull, reason: state.name);
      }
      await tester.pumpWidget(
        _app(const Center(child: IrisLogo(size: 140, state: IrisState.thinking)), reduceMotion: true),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('la aurora queda quieta en calma y se mueve al pensar', (tester) async {
      await tester.pumpWidget(_app(const AuroraBackground()));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'en calma no anima');

      await tester.pumpWidget(_app(const AuroraBackground(mood: AuroraMood.thinking)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue, reason: 'pensando, los colores fluyen');

      await tester.pumpWidget(_app(const AuroraBackground()));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('con imagen de fondo (camara o foto de la placa) se ve la imagen', (tester) async {
      const image = ColoredBox(key: ValueKey('imagen'), color: Colors.green);
      await tester.pumpWidget(_app(const IrisBackdrop(mood: AuroraMood.calm, image: image)));
      expect(find.byKey(const ValueKey('imagen')), findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0);

      // Pensando: la aurora tiñe la imagen.
      await tester.pumpWidget(_app(const IrisBackdrop(mood: AuroraMood.thinking, image: image)));
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, greaterThan(0));

      // Sin imagen (placa conectada que aun no manda foto): solo la aurora.
      await tester.pumpWidget(_app(const IrisBackdrop(mood: AuroraMood.calm)));
      expect(find.byType(AuroraBackground), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('el arranque animado termina y deja la app usable', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: IrisSplash(
          child: Scaffold(body: Center(child: TextButton(onPressed: () => taps++, child: const Text('Entrar')))),
        ),
      ));
      // Durante la animacion la app ya esta construida, pero no recibe toques.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Entrar'), findsOneWidget);
      await tester.tap(find.text('Entrar'), warnIfMissed: false);
      expect(taps, 0);

      await tester.pumpAndSettle();
      expect(find.byType(CustomPaint, skipOffstage: false).evaluate().where((e) {
        return (e.widget as CustomPaint).painter.runtimeType.toString() == '_SplashPainter';
      }), isEmpty);
      await tester.tap(find.text('Entrar'));
      expect(taps, 1);
    });

    testWidgets('el indicador de conexion dice con que trabaja Iris y no es un boton', (tester) async {
      final semantics = tester.ensureSemantics();
      for (final (link, spoken) in [
        (IrisLink.phone, 'Usando el celular'),
        (IrisLink.board, 'Placa conectada'),
        (IrisLink.searching, 'Buscando la placa'),
      ]) {
        await tester.pumpWidget(_app(
          AssistantTopBar(phase: AssistantPhase.ready, link: link, onOpenSettings: () {}),
          reduceMotion: true,
        ));
        final node = tester.getSemantics(find.bySemanticsLabel(spoken));
        expect(node.flagsCollection.isButton, isFalse, reason: spoken);
      }
      expect(find.byTooltip('Configuración'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('Respuesta que se escribe con la voz', () {
    final longText = List.generate(
      40,
      (i) => 'Frase $i: hay una mesa con un vaso a la derecha y una puerta al fondo.',
    ).join(' ');

    Widget answer(ValueNotifier<SpeechProgress> progress, {String? text, bool reduceMotion = false}) => _app(
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: 220,
              child: StreamingAnswer(text: text ?? longText, progress: progress),
            ),
          ),
          reduceMotion: reduceMotion,
        );

    testWidgets('revela el texto al ritmo de la voz', (tester) async {
      _phoneSize(tester);
      final progress = ValueNotifier(SpeechProgress(longText, 0));
      await tester.pumpWidget(answer(progress));
      expect(_answerText(tester), isEmpty);

      final end = TtsService.wordEndAt(longText, 20);
      progress.value = SpeechProgress(longText, end);
      await tester.pump();
      expect(_answerText(tester), longText.substring(0, end));

      progress.value = SpeechProgress(longText, 200);
      await tester.pump();
      expect(_answerText(tester).length, 200);

      progress.value = progress.value.finished();
      await tester.pump();
      expect(_answerText(tester), longText);
    });

    testWidgets('si la voz habla de otro texto, o sin animaciones, se ve completo', (tester) async {
      _phoneSize(tester);
      final progress = ValueNotifier(const SpeechProgress('Bluetooth conectado', 3));
      await tester.pumpWidget(answer(progress, text: 'Dice: salida de emergencia'));
      expect(_answerText(tester), 'Dice: salida de emergencia');

      final p2 = ValueNotifier(SpeechProgress(longText, 0));
      await tester.pumpWidget(answer(p2, reduceMotion: true));
      expect(_answerText(tester), longText);
    });

    testWidgets('se puede desplazar y sigue a la voz hasta que el usuario desplaza', (tester) async {
      _phoneSize(tester);
      final progress = ValueNotifier(SpeechProgress(longText, 0));
      await tester.pumpWidget(answer(progress));
      final state = tester.state<StreamingAnswerState>(find.byType(StreamingAnswer));

      progress.value = SpeechProgress(longText, TtsService.wordEndAt(longText, 1500));
      await tester.pump();
      await tester.pump();
      final position = state.scrollController.position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'el texto largo debe desplazarse');
      expect(position.pixels, position.maxScrollExtent, reason: 'sigue a la palabra que suena');

      // El usuario sube para releer: deja de seguir.
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 150));
      // (sin pumpAndSettle: el iris de la tarjeta se mueve mientras suena la voz)
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.isFollowing, isFalse);
      final readingAt = position.pixels;
      expect(readingAt, lessThan(position.maxScrollExtent));

      progress.value = SpeechProgress(longText, TtsService.wordEndAt(longText, 2000));
      await tester.pump();
      await tester.pump();
      expect(position.pixels, readingAt, reason: 'no lo mueve mientras lee');

      // "Seguir la voz" vuelve a seguirla.
      await tester.tap(find.byKey(const ValueKey('seguir-voz')));
      await tester.pump();
      await tester.pump();
      expect(state.isFollowing, isTrue);
      expect(position.pixels, position.maxScrollExtent);
    });

    testWidgets('TalkBack lee el texto completo, no la parte escrita', (tester) async {
      _phoneSize(tester);
      final semantics = tester.ensureSemantics();
      final progress = ValueNotifier(const SpeechProgress('Hay una silla adelante.', 4));
      await tester.pumpWidget(answer(progress, text: 'Hay una silla adelante.'));
      expect(find.bySemanticsLabel('Respuesta: Hay una silla adelante.'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('Letra grande (2x) en 360x640', () {
    Future<void> pumpScreen(WidgetTester tester, {required bool withAnswer}) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      final progress = ValueNotifier(SpeechProgress('x' * 10, 0, done: true));
      var mode = IrisMode.assistant;
      await tester.pumpWidget(_app(
        StatefulBuilder(
          builder: (context, setState) => AssistantLayout(
            background: const ColoredBox(color: Colors.black),
            topBar: AssistantTopBar(
              phase: AssistantPhase.ready,
              link: IrisLink.board,
              onOpenSettings: () {},
            ),
            status: const StatusLine(text: 'La placa no respondio. Leo con el celular...', active: false),
            alert: const VisionAlertBanner(alert: VisionAlert(what: 'un cruce peatonal', confidence: 81)),
            carousel: ModeCarousel(
              answer: withAnswer
                  ? StreamingAnswer(
                      text: List.filled(30, 'Hay una mesa con un vaso y una puerta al fondo.').join(' '),
                      progress: progress,
                    )
                  : null,
              controller: controller,
              mode: mode,
              onModeChanged: (m) => setState(() => mode = m),
              pageBuilder: _realPage,
            ),
          ),
        ),
        textScale: 2,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // El boton grande se ve entero sin desplazar.
      final button = tester.getRect(find.bySemanticsLabel('Hablar con Iris'));
      expect(button.top, greaterThanOrEqualTo(0));
      expect(button.bottom, lessThanOrEqualTo(640));
      for (final m in IrisMode.values.skip(1)) {
        controller.jumpToPage(m.index);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: m.name);
      }
    }

    testWidgets('pantalla con respuesta, aviso y todas las paginas', (tester) async {
      _phoneSize(tester);
      await pumpScreen(tester, withAnswer: true);
    });

    testWidgets('pantalla sin respuesta', (tester) async {
      _phoneSize(tester);
      await pumpScreen(tester, withAnswer: false);
    });

    testWidgets('configuracion: en automatico no hay selector Celular/Placa', (tester) async {
      _phoneSize(tester);
      bool? changedTo;
      await tester.pumpWidget(_app(
        SettingsSheet(
          autoDetect: true,
          onAutoDetectChanged: (v) => changedTo = v,
          hardwareMode: HardwareMode.standalone,
          onHardwareModeChanged: (_) {},
          busy: false,
          boardConnected: false,
          boardLabel: 'Iris 1',
          problem: ValueNotifier(null),
          needsPermissions: false,
          onRequestPermissions: () {},
          onOpenAppSettings: () {},
          onPickBoard: () {},
          answersOnPhone: true,
          onAnswersOnPhoneChanged: (_) {},
          boardVolume: ValueNotifier(50),
          onBoardVolumeChanged: (_) {},
        ),
      ));
      expect(find.text('Detectar la placa sola'), findsOneWidget);
      expect(find.text('Celular'), findsNothing);
      // La placa se puede elegir aunque todavia no haya conectado.
      expect(find.text('Cambiar placa'), findsOneWidget);
      await tester.tap(find.text('Detectar la placa sola'));
      expect(changedTo, isFalse);
    });

    testWidgets('configuracion en modo Modulo manual', (tester) async {
      _phoneSize(tester);
      await tester.pumpWidget(_app(
        SettingsSheet(
          autoDetect: false,
          onAutoDetectChanged: (_) {},
          hardwareMode: HardwareMode.esp32,
          onHardwareModeChanged: (_) {},
          busy: false,
          boardConnected: false,
          boardLabel: 'Iris 1',
          problem: ValueNotifier('Falta el permiso de Bluetooth.'),
          needsPermissions: true,
          onRequestPermissions: () {},
          onOpenAppSettings: () {},
          onPickBoard: () {},
          answersOnPhone: true,
          onAnswersOnPhoneChanged: (_) {},
          boardVolume: ValueNotifier(50),
          onBoardVolumeChanged: (_) {},
          onOpenAccount: () {},
        ),
        textScale: 2,
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Celular'), findsOneWidget);
      expect(find.text('Cambiar placa'), findsOneWidget);
      expect(find.text('Mi cuenta'), findsOneWidget);
    });
  });
}
