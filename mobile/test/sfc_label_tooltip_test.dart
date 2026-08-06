// QA sweep item A6 (#16): SFC step/action labels truncate mid-word at
// narrow canvas widths ("OPEN_BACK...") with no way to see the full text.
// Wrap the truncating Text widgets in Tooltip(message: fullText) so
// hover (desktop) / long-press (touch) reveals it. Cosmetic only — no
// change to editing behavior.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

PlcProgram _prog() {
  final p = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(
      id: 's0',
      name: 'OPEN_BACKWASH_VALVE_AND_WAIT_FOR_CONFIRM',
      isInitial: true,
      actionSt: 'BackwashValve := TRUE; Pump_Run := TRUE;',
    ),
    SfcStep(id: 's1', name: 'RUN'),
  ]);
  p.sfcTransitions.add(
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
  );
  return p;
}

void main() {
  Future<void> pumpEditor(WidgetTester tester, PlcProgram prog) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}, sfcRuntime: SfcRuntime(), scanRunning: false),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a long step name is wrapped in a Tooltip carrying the full text', (tester) async {
    final prog = _prog();
    await pumpEditor(tester, prog);

    expect(find.byTooltip(prog.sfcSteps[0].name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the step action preview is wrapped in a Tooltip carrying the full text',
      (tester) async {
    final prog = _prog();
    await pumpEditor(tester, prog);

    expect(find.byTooltip(prog.sfcSteps[0].actionSt), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
