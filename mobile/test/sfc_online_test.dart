import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

/// A chart with a parallel fork s0 -> {p1, q1} joining into s3, so BOTH p1 and
/// q1 render as step boxes and can be simultaneously active (parallel).
PlcProgram _parallelProg() {
  final p = PlcProgram(name: 'PP', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'START', isInitial: true),
    SfcStep(id: 'p1', name: 'PARALLEL_P'),
    SfcStep(id: 'q1', name: 'PARALLEL_Q'),
    SfcStep(id: 's3', name: 'DONE'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(
      id: 't0',
      fromStepId: 's0',
      toStepId: 'p1',
      conditionSt: 'Fork',
      kind: 'parallelFork',
      toStepIds: ['p1', 'q1'],
    ),
    SfcTransition(
      id: 't1',
      fromStepId: 'p1',
      toStepId: 's3',
      conditionSt: 'Join',
      kind: 'parallelJoin',
      fromStepIds: ['p1', 'q1'],
    ),
  ]);
  return p;
}

PlcProject _projectFor(PlcProgram prog) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

void main() {
  testWidgets('Go-Online highlights the parallel active-step set with STEP_T', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _parallelProg();
    final rt = SfcRuntime();
    // Two parallel steps lit at once.
    rt.active['PP'] = {'p1', 'q1'};
    rt.stepElapsedMs['PP|p1'] = 2500;
    rt.stepElapsedMs['PP|q1'] = 800;

    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(
        currentProject: _projectFor(prog),
        program: prog,
        onProgramUpdated: () {},
        sfcRuntime: rt,
        scanRunning: true,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Offline: no LIVE badge, no STEP_T readout.
    expect(find.text('LIVE'), findsNothing);
    expect(find.textContaining('STEP_T'), findsNothing);

    // Go Online.
    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // LIVE badge shows (scanRunning == true).
    expect(find.text('LIVE'), findsOneWidget);

    // Both parallel active step boxes still render.
    expect(find.text('PARALLEL_P'), findsOneWidget);
    expect(find.text('PARALLEL_Q'), findsOneWidget);

    // Each active step shows its live STEP_T (two readouts, one per active box).
    expect(find.textContaining('STEP_T'), findsNWidgets(2));
    // The formatted elapsed values render.
    expect(find.textContaining('2.5s'), findsOneWidget);
    expect(find.textContaining('800ms'), findsOneWidget);
  });
}
