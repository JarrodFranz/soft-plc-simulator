import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually resolves
  // inside the test's fake-async zone — see shell_responsive_test.dart for
  // the same pattern (an unmocked platform channel call never completes
  // there, hanging every pumpAndSettle() below).
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('fault banner shows task name and Clear Fault dismisses it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugForceFault('PumpTask');
    await tester.pump();

    expect(find.textContaining('PumpTask'), findsWidgets);
    expect(find.text('Clear Fault'), findsOneWidget);

    await tester.tap(find.text('Clear Fault'));
    await tester.pump();
    expect(find.text('Clear Fault'), findsNothing);
  });

  testWidgets('a fault does not survive switching to a different project', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    // Fault project A (whatever project booted as active) without clearing it.
    state.debugForceFault('PumpTask');
    await tester.pump();
    expect(state.debugFaulted, isTrue);
    expect(find.textContaining('PumpTask'), findsWidgets);

    // Switch to an entirely different project B — same path `_switchActiveProject`
    // takes from the project-switcher UI.
    final projectB = PlcProject(
      id: 'proj_test_b',
      name: 'Project B',
      controllerName: 'PLC_02',
      tags: [],
      structDefs: [],
      // Give B a program so `_switchActiveProject` has a valid view to land
      // on (it only re-keys `_activeViewId` when hmis/programs is non-empty).
      programs: [PlcProgram(name: 'Main', language: 'StructuredText')],
      tasks: [],
      hmis: [],
    );
    state.debugAddProject(projectB);
    state.debugSwitchToProject(projectB);
    await tester.pump();

    // B must not inherit A's latched fault or its banner.
    expect(state.debugFaulted, isFalse);
    expect(find.textContaining('PumpTask'), findsNothing);
    expect(find.text('Clear Fault'), findsNothing);
  });
}
