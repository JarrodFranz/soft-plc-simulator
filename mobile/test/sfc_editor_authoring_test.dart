import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

// Migrated from the old vertical-list authoring controls to the 2D canvas
// (SFC-v2). Intent preserved: a step can be deleted (with its transitions), and
// an in-flight condition edit is committed to the model and survives a sibling
// rebuild. (Branch add/reorder authoring returns in a later task.)

PlcProgram _prog() {
  final p = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'IDLE', isInitial: true),
    SfcStep(id: 's1', name: 'RUN'),
  ]);
  p.sfcTransitions.add(
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
  );
  return p;
}

void main() {
  testWidgets('delete step (via the step editor) removes the step and its transitions', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _prog();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}, sfcRuntime: SfcRuntime(), scanRunning: false),
    ));
    await tester.pumpAndSettle();

    // Tap the RUN step box to open its editor, then Delete.
    await tester.tap(find.text('RUN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(prog.sfcSteps.any((s) => s.id == 's1'), isFalse);
    expect(prog.sfcTransitions.any((t) => t.toStepId == 's1'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a transition condition in its block commits to the model', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _prog();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}, sfcRuntime: SfcRuntime(), scanRunning: false),
    ));
    await tester.pumpAndSettle();

    // The only TextField on the canvas is t0's condition block (step boxes show
    // their action as static text).
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'New_Condition');
    await tester.pump();

    expect(prog.sfcTransitions.firstWhere((t) => t.id == 't0').conditionSt, 'New_Condition');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsubmitted condition edit survives a sibling setState (add step)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _prog();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}, sfcRuntime: SfcRuntime(), scanRunning: false),
    ));
    await tester.pumpAndSettle();

    // Type into the condition field without submitting (committed via onChanged).
    await tester.enterText(find.byType(TextField), 'Unsubmitted_Condition');
    await tester.pump();

    // A sibling authoring control (Add SFC Step) triggers setState, rebuilding
    // the canvas.
    await tester.tap(find.byTooltip('Add SFC Step'));
    await tester.pumpAndSettle();

    expect(
      prog.sfcTransitions.firstWhere((t) => t.id == 't0').conditionSt,
      'Unsubmitted_Condition',
    );
    expect(tester.takeException(), isNull);
  });
}
