import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

// Migrated from the old vertical-list renderer to the 2D canvas (SFC-v2).
// Intent preserved: a branched chart renders every branch's condition, renders
// a loop-back as a GOTO chip, and does not overflow.

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
  testWidgets('a branched SFC renders both branch conditions + a GOTO chip on the canvas', (tester) async {
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
        sfcRuntime: SfcRuntime(),
        scanRunning: false,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The body is a pan/zoom canvas.
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // Both branch conditions render (inside the bordered transition blocks).
    expect(find.text('Bottle_Present'), findsOneWidget);
    expect(find.text('Abort_Cmd'), findsOneWidget);

    // The s1 -> s0 loop-back renders as a GOTO chip back to IDLE.
    expect(find.textContaining('GOTO'), findsWidgets);
    expect(find.textContaining('IDLE'), findsWidgets);
  });

  testWidgets('branch step boxes are laid out side-by-side (different x)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // s0 alternately diverges to s1 (FILLING) and s2 (ABORTED); both reconverge.
    final prog = PlcProgram(name: 'ALT', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true),
      SfcStep(id: 's1', name: 'FILLING'),
      SfcStep(id: 's2', name: 'ABORTED'),
      SfcStep(id: 's3', name: 'MERGE'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go_Fill'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Go_Abort'),
      SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's3', conditionSt: 'Fill_Done'),
      SfcTransition(id: 't3', fromStepId: 's2', toStepId: 's3', conditionSt: 'Abort_Done'),
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
        sfcRuntime: SfcRuntime(),
        scanRunning: false,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final fx = tester.getTopLeft(find.text('FILLING')).dx;
    final ax = tester.getTopLeft(find.text('ABORTED')).dx;
    expect(fx == ax, isFalse);
  });

  testWidgets('GOTO chip with a long target name does not overflow at 320 width', (tester) async {
    tester.view.physicalSize = const Size(320, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // s1 -> s0 is a loop-back GOTO chip; s0 has a very long name so the chip's
    // Text would overflow the fixed-width chip container without ellipsis.
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
        sfcRuntime: SfcRuntime(),
        scanRunning: false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The loop-back is drawn as a GOTO chip (canvas), not an inline connector.
    expect(find.textContaining('GOTO'), findsWidgets);
  });
}
