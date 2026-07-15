import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

PlcProgram _branchedProg() {
  final p = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'IDLE', isInitial: true),
    SfcStep(id: 's1', name: 'FILLING'),
    SfcStep(id: 's2', name: 'ABORTED'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Bottle_Present'),
    SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Abort_Cmd'),
    SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's0', conditionSt: 'TRUE'),
  ]);
  return p;
}

void main() {
  testWidgets('a branched SFC renders both branches + a GOTO chip, no overflow', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _branchedProg();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(
        currentProject: proj,
        program: prog,
        onProgramUpdated: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Both branch conditions render.
    expect(find.textContaining('Bottle_Present'), findsOneWidget);
    expect(find.textContaining('Abort_Cmd'), findsOneWidget);
    // The s1->s0 loop-back renders as a GOTO chip to IDLE.
    expect(find.textContaining('GOTO'), findsWidgets);
    expect(find.textContaining('IDLE'), findsWidgets);
  });
}
