import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_app/features/assistant/assistant_modes.dart';
import 'package:iris_app/features/assistant/modes/assistant_mode_page.dart';
import 'package:iris_app/features/assistant/modes/light_mode_page.dart';
import 'package:iris_app/features/assistant/modes/people_mode_page.dart';
import 'package:iris_app/features/assistant/modes/read_text_mode_page.dart';
import 'package:iris_app/features/assistant/widgets/assistant_header.dart';
import 'package:iris_app/features/assistant/widgets/assistant_layout.dart';
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
        continuousMode: false,
        onContinuousChanged: (_) {},
        onPressDown: () {},
        onPressUp: () {},
      );
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
    testWidgets('muestra los 4 modos y deslizar cambia el modo anunciado', (tester) async {
      _phoneSize(tester);
      final semantics = tester.ensureSemantics();
      final changes = <IrisMode>[];
      await tester.pumpWidget(_app(_CarouselHost(onChanged: changes.add)));

      for (final m in IrisMode.values) {
        expect(find.text(m.shortName), findsOneWidget, reason: m.name);
        expect(find.bySemanticsLabel('${m.spokenName}, pestaña ${m.index + 1} de 4'), findsOneWidget);
      }
      SemanticsNode announcer() => tester.getSemantics(find.byKey(const ValueKey('anuncio-modo')));
      expect(announcer().label, 'Modo Iris, asistente, 1 de 4');
      expect(announcer().flagsCollection.isLiveRegion, isTrue);

      // Deslizar a la izquierda: siguiente modo.
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(changes, [IrisMode.readText]);
      expect(announcer().label, 'Modo Leer texto, 2 de 4');
      expect(find.bySemanticsLabel('Leer texto'), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.light);
      expect(announcer().label, 'Modo Buscar luz, 3 de 4');

      // Una pestaña tambien lleva al modo.
      await tester.tap(find.text('Personas'));
      await tester.pumpAndSettle();
      expect(changes.last, IrisMode.people);
      expect(announcer().label, 'Modo Personas, 4 de 4');
      semantics.dispose();
    });

    testWidgets('mantener el boton grande y arrastrar no cambia de modo', (tester) async {
      _phoneSize(tester);
      final changes = <IrisMode>[];
      await tester.pumpWidget(_app(_CarouselHost(onChanged: changes.add)));
      await tester.drag(find.bySemanticsLabel('Hablar con Iris'), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
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
      await tester.pumpAndSettle();
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
              hardwareLabel: 'Modulo conectado',
              hardwareIcon: Icons.bluetooth_connected,
              onOpenSettings: () {},
            ),
            status: const StatusLine(text: 'La placa no respondio. Leo con el celular...', active: false),
            alert: const VisionAlertBanner(alert: VisionAlert(what: 'un cruce peatonal', confidence: 81)),
            answer: withAnswer
                ? StreamingAnswer(
                    text: List.filled(30, 'Hay una mesa con un vaso y una puerta al fondo.').join(' '),
                    progress: progress,
                  )
                : null,
            carousel: ModeCarousel(
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

    testWidgets('hoja de ajustes en modo Modulo', (tester) async {
      _phoneSize(tester);
      await tester.pumpWidget(_app(
        SettingsSheet(
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
      expect(find.text('Cambiar placa'), findsOneWidget);
      expect(find.text('Mi cuenta'), findsOneWidget);
    });
  });
}
