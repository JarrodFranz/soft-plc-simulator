// Task 4 of the in-app log feature: the shell owns the `AppLogger` (threaded
// into the six protocol hosts instrumented in Task 3), instruments its own
// subsystems (scan engine, project CRUD, sim/historian/scheduler), and adds
// a 'LOGS' left-dock nav entry + a (Task-5-owned) placeholder screen.
//
// These three tests are exactly the ones called out in the brief:
//  1. switching projects logs a kLogSourceProject entry AND preserves the
//     entries logged before the switch (the deliberate divergence from
//     TagHistorian, which DOES clear on switch).
//  2. selecting the Logs nav entry activates the 'LOGS' view.
//  3. a project switch while 'LOGS' is active does not reset the view —
//     the easily-missed `_ensureValidView`-adjacent bug the brief warns
//     about: `_switchActiveProject` used to unconditionally re-key
//     `_activeViewId` to the new project's first HMI/program whenever one
//     existed, silently bouncing the user off ANY non-HMI/PROGRAM view.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

import 'support/responsive_test_utils.dart';

PlcProject _project(String id, String name) => PlcProject(
      id: id,
      name: name,
      controllerName: 'PLC_02',
      tags: [],
      structDefs: [],
      // Give the project a program so `_switchActiveProject` has a valid
      // HMI/program view to (potentially) land on — it only re-keys
      // `_activeViewId` when hmis/programs is non-empty.
      programs: [PlcProgram(name: 'Main', language: 'StructuredText')],
      tasks: [],
      hmis: [],
    );

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually resolves
  // inside the test's fake-async zone — see shell_responsive_test.dart for
  // the same pattern.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'switching projects logs a Project entry and preserves entries logged before the switch',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    final entriesBefore = state.debugLogger.entries;
    expect(entriesBefore, isNotEmpty,
        reason: 'boot itself already logs at least the initial project load');

    final projectB = _project('proj_shell_logging_test_b', 'Shell Logging Test B');
    state.debugAddProject(projectB);
    state.debugSwitchToProject(projectB);
    await tester.pump();

    final entriesAfter = state.debugLogger.entries;

    // Divergence-from-historian half: nothing logged before the switch was
    // discarded. AppLogger.clear() is never called implicitly, so every
    // pre-switch entry (by identity — same seq) must still be present.
    final beforeSeqs = entriesBefore.map((e) => e.seq).toSet();
    final afterSeqs = entriesAfter.map((e) => e.seq).toSet();
    expect(afterSeqs.containsAll(beforeSeqs), isTrue,
        reason: 'entries logged before a project switch must survive it — '
            'the logger is never cleared on switch, unlike TagHistorian');

    // The switch itself half: a new kLogSourceProject entry names the
    // project switched to.
    expect(
      entriesAfter.any((e) =>
          e.source == kLogSourceProject &&
          e.level == LogLevel.info &&
          e.message.contains('Shell Logging Test B')),
      isTrue,
      reason: 'the switch must record a kLogSourceProject entry naming the new project',
    );
  });

  testWidgets('selecting the Logs nav entry activates the Logs view', (tester) async {
    // Desktop-sized surface so the left dock renders inline (no drawer to
    // open first) — mirrors shell_responsive_test.dart's desktop case.
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    expect(state.debugActiveViewId, isNot('LOGS'));

    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();

    expect(state.debugActiveViewId, 'LOGS');
    // The Task-5 screen doesn't exist yet — this is the placeholder Task 4
    // wires up so Task 5 has somewhere to land its real screen.
    expect(find.text('Logs (coming soon)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a project switch while LOGS is active does not reset the view', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSetActiveViewId('LOGS');
    expect(state.debugActiveViewId, 'LOGS');

    // Switch to an entirely different project that DOES have hmis/programs
    // — the exact condition that used to unconditionally re-key
    // `_activeViewId` regardless of what view was active.
    final projectC = _project('proj_shell_logging_test_c', 'Shell Logging Test C');
    state.debugAddProject(projectC);
    state.debugSwitchToProject(projectC);
    await tester.pump();

    expect(state.debugActiveViewId, 'LOGS',
        reason: 'LOGS is an always-valid view (like MEMORY/SIMIO:rules/GATEWAY) — '
            'a project switch must not silently bounce the user off it');
  });
}
