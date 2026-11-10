// Genera capturas de las pantallas (PNG) con los widgets reales y datos fijos, sin servicios.
// No corre con `flutter test` normal. Para regenerarlas:
//
//   flutter test test/capturas_test.dart --dart-define=IRIS_CAPTURAS=true
//
// Quedan en docs/capturas/. El "fondo de camara" es un degradado de ejemplo (en el celular real
// es la camara en vivo).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_app/core/theme/app_theme.dart';
import 'package:iris_app/core/widgets/aurora_background.dart';
import 'package:iris_app/core/widgets/glass.dart';
import 'package:iris_app/core/widgets/iris_splash.dart';
import 'package:iris_app/features/account/login_screen.dart';
import 'package:iris_app/features/assistant/assistant_modes.dart';
import 'package:iris_app/features/assistant/modes/assistant_mode_page.dart';
import 'package:iris_app/features/assistant/modes/light_mode_page.dart';
import 'package:iris_app/features/assistant/modes/live_mode_page.dart';
import 'package:iris_app/features/assistant/modes/people_mode_page.dart';
import 'package:iris_app/features/assistant/modes/read_text_mode_page.dart';
import 'package:iris_app/features/assistant/widgets/assistant_header.dart';
import 'package:iris_app/features/assistant/widgets/assistant_layout.dart';
import 'package:iris_app/features/assistant/widgets/mode_carousel.dart';
import 'package:iris_app/features/assistant/widgets/settings_sheet.dart';
import 'package:iris_app/features/assistant/widgets/streaming_answer.dart';
import 'package:iris_app/services/ai/tts_service.dart';

const bool _enabled = bool.fromEnvironment('IRIS_CAPTURAS');
final _boundaryKey = GlobalKey();

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    any = true;
  }
  if (any) await loader.load();
}

/// Fuentes reales (en las pruebas la letra por defecto son cuadrados).
Future<void> _loadFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';
  await _loadFont('Roboto', [
    '$fonts/Roboto-Regular.ttf',
    '$fonts/Roboto-Medium.ttf',
    '$fonts/Roboto-Bold.ttf',
    '$fonts/Roboto-Light.ttf',
  ]);
  await _loadFont('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
  await _loadFont('monospace', ['C:/Windows/Fonts/consola.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']);
}

Widget _shell(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: RepaintBoundary(key: _boundaryKey, child: child),
    );

Future<void> _save(WidgetTester tester, String name) async {
  final boundary = _boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('docs/capturas/$name.png')..createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// Fondo de ejemplo que hace de camara: una calle al atardecer, en degradados.
const Widget _fakeCamera = DecoratedBox(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF7C8FA6), Color(0xFFC9A98C), Color(0xFF6B5B4F), Color(0xFF2E2A28)],
      stops: [0, 0.42, 0.62, 1],
    ),
  ),
);

Widget _page(IrisMode mode, {bool listening = false, bool thinking = false, bool speaking = false, bool live = true}) {
  switch (mode) {
    case IrisMode.assistant:
      return AssistantModePage(
        isListening: listening,
        isProcessing: thinking,
        isSpeaking: speaking,
        canTalkHere: true,
        isModule: false,
        moduleConnected: false,
        onPressDown: () {},
        onPressUp: () {},
      );
    case IrisMode.live:
      return LiveModePage(isOn: live, onBoard: true, onToggle: () {});
    case IrisMode.readText:
      return ReadTextModePage(isReading: false, usesBoard: true, onRead: () {});
    case IrisMode.light:
      return LightModePage(isOn: true, level: 72, onToggle: () {});
    case IrisMode.people:
      return PeopleModePage(
        isAvailable: true,
        isBusy: false,
        savedCount: 3,
        onWhoIsHere: () {},
        onAddPerson: () {},
        onShowPeople: () {},
      );
  }
}

Widget _home({
  required IrisMode mode,
  required AuroraMood mood,
  required IrisLink link,
  AssistantPhase phase = AssistantPhase.ready,
  Widget? image,
  String status = '',
  Widget? answer,
}) {
  return Scaffold(
    key: UniqueKey(), // cada captura parte de cero (el carrusel no recuerda la pagina anterior)
    backgroundColor: AppTheme.ink,
    body: AssistantLayout(
      background: IrisBackdrop(mood: mood, image: image),
      topBar: AssistantTopBar(phase: phase, link: link, onOpenSettings: () {}),
      status: StatusLine(text: status, active: phase == AssistantPhase.thinking),
      carousel: ModeCarousel(
        controller: PageController(initialPage: mode.index),
        mode: mode,
        onModeChanged: (_) {},
        answer: answer,
        pageBuilder: (context, m) => _page(
          m,
          listening: phase == AssistantPhase.listening,
          thinking: phase == AssistantPhase.thinking,
          speaking: mood == AuroraMood.speaking,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(_loadFonts);

  Future<void> shot(WidgetTester tester, String name, Widget child, {int frames = 12}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(child));
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await _save(tester, name);
  }

  testWidgets('capturas de las pantallas', (tester) async {
    await shot(
      tester,
      '01_inicio_placa',
      _home(mode: IrisMode.assistant, mood: AuroraMood.calm, link: IrisLink.board),
    );
    await shot(
      tester,
      '02_escuchando',
      _home(
        mode: IrisMode.assistant,
        mood: AuroraMood.listening,
        link: IrisLink.board,
        phase: AssistantPhase.listening,
        status: 'Te escucho',
      ),
    );
    await shot(
      tester,
      '03_pensando',
      _home(
        mode: IrisMode.assistant,
        mood: AuroraMood.thinking,
        link: IrisLink.board,
        phase: AssistantPhase.thinking,
        status: 'Mirando lo que hay adelante...',
      ),
    );
    const answer = 'Frente a ti hay una puerta de vidrio y un letrero que dice Farmacia, abierto hasta las nueve. '
        'A tu derecha hay un escalón.';
    await shot(
      tester,
      '04_respondiendo_placa',
      _home(
        mode: IrisMode.assistant,
        mood: AuroraMood.speaking,
        link: IrisLink.board,
        answer: StreamingAnswer(text: answer, progress: ValueNotifier(const SpeechProgress(answer, 58))),
      ),
    );
    await shot(
      tester,
      '05_respondiendo_celular_camara',
      _home(
        mode: IrisMode.assistant,
        mood: AuroraMood.speaking,
        link: IrisLink.phone,
        image: _fakeCamera,
        answer: StreamingAnswer(text: answer, progress: ValueNotifier(const SpeechProgress(answer, 58))),
      ),
    );
    await shot(tester, '06_modo_en_vivo', _home(mode: IrisMode.live, mood: AuroraMood.speaking, link: IrisLink.board));
    await shot(tester, '07_modo_luz', _home(mode: IrisMode.light, mood: AuroraMood.calm, link: IrisLink.board));
    await shot(tester, '08_modo_personas', _home(mode: IrisMode.people, mood: AuroraMood.calm, link: IrisLink.phone, image: _fakeCamera));
    await shot(tester, '09_login', const LoginScreen());
    await shot(
      tester,
      '10_configuracion',
      IrisPage(
        title: 'Configuración',
        child: SettingsSheet(
          autoDetect: true,
          onAutoDetectChanged: (_) {},
          hardwareMode: HardwareMode.esp32,
          onHardwareModeChanged: (_) {},
          busy: false,
          boardConnected: true,
          boardLabel: 'Iris de Diego',
          problem: ValueNotifier(null),
          needsPermissions: false,
          onRequestPermissions: () {},
          onOpenAppSettings: () {},
          onPickBoard: () {},
          answersOnPhone: true,
          onAnswersOnPhoneChanged: (_) {},
          boardVolume: ValueNotifier(60),
          onBoardVolumeChanged: (_) {},
          onOpenAccount: () {},
        ),
      ),
    );

    // Arranque: tres momentos de la animacion (logo chico, abriendose, rayos saliendo).
    Widget splash() => IrisSplash(
          key: UniqueKey(),
          child: _home(mode: IrisMode.assistant, mood: AuroraMood.calm, link: IrisLink.board),
        );
    await shot(tester, '11_arranque_a', splash(), frames: 5);
    await shot(tester, '11_arranque_b', splash(), frames: 11);
    await shot(tester, '11_arranque_c', splash(), frames: 13);
  }, skip: !_enabled);
}
