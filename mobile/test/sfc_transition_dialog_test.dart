import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

/// QA #5 — a transition used to have two partial editing surfaces: the inline
/// condition field on the canvas (condition only) and the kebab "Transition"
/// dialog (routing only). The dialog is now the complete surface: ONE place
/// edits both the condition and the target step. The inline field keeps
/// working for anyone who already knows about it.
PlcProgram _prog() {
  final p = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'IDLE', isInitial: true),
    SfcStep(id: 's1', name: 'RUN'),
    SfcStep(id: 's2', name: 'HOLD'),
  ]);
  p.sfcTransitions.add(
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
  );
  return p;
}

Future<PlcProgram> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final prog = _prog();
  final proj = PlcProject(
    id: 'p',
    name: 'P',
    controllerName: 'C',
    tags: [],
    structDefs: [],
    programs: [prog],
    tasks: [],
    hmis: [],
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
  return prog;
}

Future<void> _openTransitionDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('sfctransmenu_t0')));
  await tester.pumpAndSettle();
  expect(find.text('Transition'), findsOneWidget);
}

SfcTransition _t0(PlcProgram p) => p.sfcTransitions.firstWhere((t) => t.id == 't0');

void main() {
  testWidgets('the Transition dialog carries the condition, pre-filled', (tester) async {
    final prog = await _pump(tester);
    await _openTransitionDialog(tester);

    expect(find.text('CONDITION:'), findsOneWidget);
    expect(find.text('TARGET STEP:'), findsOneWidget);

    final field = find.byKey(const ValueKey('sfcconddlg_t0'));
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(
        find.descendant(of: field, matching: find.byType(TextField)),
      ).controller!.text,
      'Go',
    );
    expect(_t0(prog).conditionSt, 'Go');
  });

  testWidgets('the dialog edits condition AND target in one sitting', (tester) async {
    final prog = await _pump(tester);
    await _openTransitionDialog(tester);

    // 1. Condition — same write-through-on-keystroke semantics as inline.
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('sfcconddlg_t0')),
        matching: find.byType(TextField),
      ),
      'Tank_Full',
    );
    await tester.pump();
    expect(_t0(prog).conditionSt, 'Tank_Full');

    // 2. Routing — without having to reopen anything: the dialog stays up.
    await tester.tap(find.byKey(const ValueKey('sfctarget_t0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HOLD').last);
    await tester.pumpAndSettle();

    expect(_t0(prog).toStepId, 's2');
    expect(find.text('Transition'), findsOneWidget,
        reason: 'retargeting must not dismiss the one dialog that edits both');
    expect(_t0(prog).conditionSt, 'Tank_Full',
        reason: 'the condition edit must survive the routing edit');

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a condition edited in the dialog shows on the canvas after closing',
      (tester) async {
    final prog = await _pump(tester);
    await _openTransitionDialog(tester);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('sfcconddlg_t0')),
        matching: find.byType(TextField),
      ),
      'Edited_In_Dialog',
    );
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Back on the bare canvas: exactly one condition field, showing the new text.
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Edited_In_Dialog',
    );
    expect(_t0(prog).conditionSt, 'Edited_In_Dialog');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the inline canvas field still edits the condition', (tester) async {
    final prog = await _pump(tester);

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Inline_Still_Works');
    await tester.pump();

    expect(_t0(prog).conditionSt, 'Inline_Still_Works');
    expect(tester.takeException(), isNull);
  });
}
