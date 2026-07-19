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

  // The five sibling CRUD paths below all contain the exact same
  // unconditional `_activeViewId` re-key that `_switchActiveProject` used to
  // have, and are all reachable from the always-present AppBar project ⋮
  // menu regardless of the active view — so a user reading LOGS who taps
  // New/Duplicate/Delete/Reset/Import is silently bounced off it, same bug,
  // different trigger. Desktop surface so the ⋮ menu is inline (no drawer).

  testWidgets('creating a new project while LOGS is active does not reset the view', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSetActiveViewId('LOGS');
    expect(state.debugActiveViewId, 'LOGS');

    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Project'));
    await tester.pumpAndSettle();

    // The name dialog opens pre-filled with 'New Project'; accept it as-is.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
    await tester.pumpAndSettle();

    expect(state.debugActiveViewId, 'LOGS',
        reason: 'LOGS must survive _createNewProject exactly like it survives a project switch');
  });

  testWidgets('duplicating the active project while LOGS is active does not reset the view',
      (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSetActiveViewId('LOGS');
    expect(state.debugActiveViewId, 'LOGS');

    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate Project'));
    await tester.pumpAndSettle();

    expect(state.debugActiveViewId, 'LOGS',
        reason: 'LOGS must survive _duplicateActiveProject exactly like it survives a project switch');
  });

  testWidgets('deleting the active project while LOGS is active does not reset the view',
      (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSetActiveViewId('LOGS');
    expect(state.debugActiveViewId, 'LOGS');

    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Project'));
    await tester.pumpAndSettle();

    // Confirm dialog: default projects catalog has many entries, so
    // deleting the active one always leaves a valid next project to land on.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(state.debugActiveViewId, 'LOGS',
        reason: 'LOGS must survive _deleteActiveProject exactly like it survives a project switch');
  });

  testWidgets('resetting to defaults while LOGS is active does not reset the view', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSetActiveViewId('LOGS');
    expect(state.debugActiveViewId, 'LOGS');

    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to Defaults'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Reset'));
    await tester.pumpAndSettle();

    expect(state.debugActiveViewId, 'LOGS',
        reason: 'LOGS must survive _resetToDefaults exactly like it survives a project switch');
  });

  testWidgets('importing a project while LOGS is active does not reset the view', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSetActiveViewId('LOGS');
    expect(state.debugActiveViewId, 'LOGS');

    // `_importProject`'s file-picker/decode steps go through the real
    // `file_picker` plugin platform channel, which can't be faithfully
    // mocked in a widget test (see `debugImportProject`'s doc comment) —
    // so drive its state-mutation tail directly, the same way
    // `debugSwitchToProject` drives `_switchActiveProject` directly.
    final importedProject =
        _project('proj_shell_logging_test_import', 'Shell Logging Test Import');
    await state.debugImportProject(importedProject);
    await tester.pump();

    expect(state.debugActiveViewId, 'LOGS',
        reason: 'LOGS must survive _importProject exactly like it survives a project switch');
  });
}
