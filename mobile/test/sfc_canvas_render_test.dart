import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/tag_autocomplete_field.dart';

/// A chart exercising BOTH an alternative divergence (s0 -> {s1, s2} that
/// reconverges at s3) AND a parallel fork/join (s3 forks to s4 & s5 which join
/// into s6). Built via the model directly so the region parser + 2D layout are
/// driven end-to-end by the canvas editor.
PlcProgram _complexProg() {
  final p = PlcProgram(name: 'CX', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'START', isInitial: true),
    SfcStep(id: 's1', name: 'BRANCH_A'),
    SfcStep(id: 's2', name: 'BRANCH_B'),
    SfcStep(id: 's3', name: 'MERGE'),
    SfcStep(id: 's4', name: 'PAR_A'),
    SfcStep(id: 's5', name: 'PAR_B'),
    SfcStep(id: 's6', name: 'DONE'),
  ]);
  p.sfcTransitions.addAll([
    // Alternative divergence out of s0 (two single guards).
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'GuardA'),
    SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'GuardB'),
    // Both branches reconverge at s3.
    SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's3', conditionSt: 'A_Done'),
    SfcTransition(id: 't3', fromStepId: 's2', toStepId: 's3', conditionSt: 'B_Done'),
    // Parallel fork s3 -> {s4, s5}.
    SfcTransition(
      id: 't4',
      fromStepId: 's3',
      toStepId: 's4',
      conditionSt: 'Fork',
      kind: 'parallelFork',
      toStepIds: ['s4', 's5'],
    ),
    // Parallel join {s4, s5} -> s6.
    SfcTransition(
      id: 't5',
      fromStepId: 's4',
      toStepId: 's6',
      conditionSt: 'Join',
      kind: 'parallelJoin',
      fromStepIds: ['s4', 's5'],
    ),
  ]);
  return p;
}

PlcProject _projectFor(PlcProgram prog) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

/// A minimal linear chart A(init) -> B -> C, used to exercise structured
/// authoring from the canvas.
PlcProgram _linearProg() {
  final p = PlcProgram(name: 'LN', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'A_START', isInitial: true),
    SfcStep(id: 's1', name: 'B_MID'),
    SfcStep(id: 's2', name: 'C_END'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go1'),
    SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Go2'),
  ]);
  return p;
}

Future<void> _tapAddParallel(WidgetTester tester, PlcProgram prog) async {
  await tester.pumpWidget(MaterialApp(
    home: SfcEditorScreen(
      currentProject: _projectFor(prog),
      program: prog,
      onProgramUpdated: () {},
      sfcRuntime: SfcRuntime(),
      scanRunning: false,
    ),
  ));
  await tester.pumpAndSettle();

  // Open the mid-step editor and add a parallel branch around it.
  await tester.tap(find.text('B_MID'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('＋Add parallel branch'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('2D canvas renders steps, transition blocks, branches at 1400', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _complexProg();
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(
        currentProject: _projectFor(prog),
        program: prog,
        onProgramUpdated: () {},
        sfcRuntime: SfcRuntime(),
        scanRunning: false,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // (a) step names render as boxes on the canvas. The alt-divergence head
    // 'START' is placed once by the enclosing sequence's step — the Alt
    // fragment must NOT redraw it (that previously produced a duplicate box).
    expect(find.text('START'), findsOneWidget);
    expect(find.text('BRANCH_A'), findsOneWidget);
    expect(find.text('BRANCH_B'), findsOneWidget);
    expect(find.text('MERGE'), findsWidgets);
    expect(find.text('DONE'), findsWidgets);
    // Parallel-branch step boxes render too.
    expect(find.text('PAR_A'), findsWidgets);
    expect(find.text('PAR_B'), findsWidgets);

    // (b) transition condition text renders inside bordered transition blocks
    // (each condition lives in an editable autocomplete field within the block).
    expect(find.text('GuardA'), findsOneWidget);
    expect(find.text('GuardB'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('GuardA'), matching: find.byType(TagAutocompleteField)),
      findsOneWidget,
    );

    // (c) the body is a pan/zoom canvas.
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // (d) the two alternative branch step boxes are laid out at DIFFERENT x.
    final ax = tester.getTopLeft(find.text('BRANCH_A')).dx;
    final bx = tester.getTopLeft(find.text('BRANCH_B')).dx;
    expect(ax == bx, isFalse);
  });

  testWidgets('2D canvas: no overflow / no exception at 360 width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _complexProg();
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(
        currentProject: _projectFor(prog),
        program: prog,
        onProgramUpdated: () {},
        sfcRuntime: SfcRuntime(),
        scanRunning: false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    // Steps still render on the (pannable) canvas at a narrow width.
    expect(find.text('START'), findsWidgets);
  });

  testWidgets('tapping ＋Add parallel branch adds fork/join + side-by-side branches at 1400', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _linearProg();
    await _tapAddParallel(tester, prog);

    expect(tester.takeException(), isNull);

    // The model gained a matching parallelFork + parallelJoin pair.
    final fork = prog.sfcTransitions.firstWhere((t) => t.kind == 'parallelFork');
    expect(prog.sfcTransitions.any((t) => t.kind == 'parallelJoin'), isTrue);
    expect(fork.toStepIds.length, 2);

    // The canvas renders the double-line fork + join bars.
    expect(find.byKey(const ValueKey('sfc_forkBar')), findsOneWidget);
    expect(find.byKey(const ValueKey('sfc_joinBar')), findsOneWidget);

    // The two branch step boxes are laid out at DIFFERENT x (side-by-side).
    final names = fork.toStepIds
        .map((id) => prog.sfcSteps.firstWhere((s) => s.id == id).name)
        .toList();
    final x0 = tester.getTopLeft(find.text(names[0])).dx;
    final x1 = tester.getTopLeft(find.text(names[1])).dx;
    expect(x0 == x1, isFalse);
  });

  testWidgets('＋Add parallel branch: no overflow / no exception at 360 width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _linearProg();
    await _tapAddParallel(tester, prog);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('sfc_forkBar')), findsOneWidget);
    expect(find.byKey(const ValueKey('sfc_joinBar')), findsOneWidget);
  });
}
