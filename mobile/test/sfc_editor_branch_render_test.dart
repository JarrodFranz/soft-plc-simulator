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

  testWidgets(
      'a step with both a forward branch and a loop-back renders distinct GOTO icons',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // s0 -IDLE(initial)-> s1 -RUN-> s2 -CHECK-, which then:
    //   - continues the main line into s3 (inline connector, drawn below),
    //   - loops back up to s1 (a genuine loop-back: s1 is placed above s2),
    //   - branches forward to s4 (a forward branch: s4 is placed below s2,
    //     and is not the immediately-following card).
    final prog = PlcProgram(name: 'MIX', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true),
      SfcStep(id: 's1', name: 'RUN'),
      SfcStep(id: 's2', name: 'CHECK'),
      SfcStep(id: 's3', name: 'NEXT'),
      SfcStep(id: 's4', name: 'SKIP_TARGET'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Start'),
      SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Running'),
      SfcTransition(id: 't2', fromStepId: 's2', toStepId: 's3', conditionSt: 'Done'),
      SfcTransition(id: 't3', fromStepId: 's2', toStepId: 's1', conditionSt: 'Retry_Loop'),
      SfcTransition(id: 't4', fromStepId: 's2', toStepId: 's4', conditionSt: 'Skip_Ahead'),
    ]);

    final proj = PlcProject(
      id: 'p2', name: 'P2', controllerName: 'C',
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

    // Both non-inline GOTO chips render, with distinct icons: the loop-back
    // (s2 -> s1, s1 placed above s2) uses the loop icon, and the forward
    // branch (s2 -> s4, s4 placed below s2) uses a different, forward icon.
    expect(find.byIcon(Icons.subdirectory_arrow_left), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
  });

  testWidgets(
      'GOTO chip with a long target name does not overflow at 320 width',
      (tester) async {
    tester.view.physicalSize = const Size(320, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // s1 -> s0 is a loop-back GOTO chip; s0 has a very long name so the
    // chip's Text would overflow the fixed-width chip container without
    // Flexible/ellipsis.
    final prog = PlcProgram(name: 'LONG', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'Waiting_For_Bottle_At_Station_Number_Three', isInitial: true),
      SfcStep(id: 's1', name: 'RUN'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Start'),
      SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's0', conditionSt: 'Done'),
    ]);

    final proj = PlcProject(
      id: 'p3', name: 'P3', controllerName: 'C',
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
  });
}
