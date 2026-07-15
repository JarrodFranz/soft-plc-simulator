import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

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
  testWidgets('add branch appends an outgoing transition to the step', (tester) async {
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
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // s0 starts with 1 outgoing.
    expect(prog.sfcTransitions.where((t) => t.fromStepId == 's0').length, 1);

    // Tap the first "add branch" affordance (tooltip 'Add branch').
    await tester.tap(find.byTooltip('Add branch').first);
    await tester.pumpAndSettle();

    expect(prog.sfcTransitions.where((t) => t.fromStepId == 's0').length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete step removes the step and its transitions', (tester) async {
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
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // Delete RUN (s1): the s0->s1 transition must go too.
    // The RUN card's delete button is the 2nd delete icon.
    final deletes = find.byIcon(Icons.delete);
    await tester.tap(deletes.at(1));
    await tester.pumpAndSettle();

    expect(prog.sfcSteps.any((s) => s.id == 's1'), isFalse);
    expect(prog.sfcTransitions.any((t) => t.toStepId == 's1'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unsubmitted condition edit survives a sibling setState (add branch)',
      (tester) async {
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
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // TextField order: s0's action field (0), t0's condition field (1,
    // since t0 is s0's inline outgoing), s1's action field (2).
    final conditionField = find.byType(TextField).at(1);

    // Type into the condition field WITHOUT submitting (no Enter/onSubmitted).
    await tester.enterText(conditionField, 'New_Unsubmitted_Condition');
    // Do not pump a settle here beyond what enterText already does; the
    // edit is committed via onChanged on every keystroke, so it should
    // already be on the model, but exercise a further partial edit that
    // relies purely on onChanged without any explicit submit action.
    await tester.pump();

    // A sibling authoring control (Add branch) triggers setState, which
    // rebuilds the tree and recreates TextEditingControllers.
    await tester.tap(find.byTooltip('Add branch').first);
    await tester.pumpAndSettle();

    expect(
      prog.sfcTransitions.firstWhere((t) => t.id == 't0').conditionSt,
      'New_Unsubmitted_Condition',
    );
    expect(tester.takeException(), isNull);
  });
}
