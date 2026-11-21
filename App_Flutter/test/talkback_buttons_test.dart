import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris_app/features/assistant/widgets/mode_action_button.dart';

void main() {
  testWidgets('ModeChipButton se activa con el doble toque de TalkBack', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ModeChipButton(icon: Icons.add, label: 'Agregar persona', onPressed: () => taps++),
        ),
      ),
    ));

    final node = tester.getSemantics(find.byType(ModeChipButton));
    expect(node.label, 'Agregar persona');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue,
        reason: 'sin la accion tap, TalkBack anuncia el boton pero el doble toque no hace nada');

    tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('ModeChipButton deshabilitado no ofrece accion', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: ModeChipButton(icon: Icons.add, label: 'Guardadas', onPressed: null))),
    ));
    final node = tester.getSemantics(find.byType(ModeChipButton));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });
}
