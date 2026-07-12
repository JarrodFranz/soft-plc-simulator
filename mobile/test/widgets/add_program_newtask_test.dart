import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually resolves
  // inside the test's fake-async zone — see fault_banner_test.dart for the
  // same pattern (an unmocked platform channel call never completes there,
  // hanging every pumpAndSettle() below).
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('adding a program with a new Periodic task files it under that task', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    state.debugAddProgramToNewTask(
      programName: 'Housekeeping',
      language: 'StructuredText',
      taskName: 'HousekeepingTask',
      taskType: 'Periodic',
      periodMs: 1000,
    );

    final proj = state.debugActiveProject;
    expect(proj.programs.any((p) => p.name == 'Housekeeping'), isTrue);
    final task = proj.tasks.firstWhere((t) => t.name == 'HousekeepingTask');
    expect(task.type, 'Periodic');
    expect(task.periodMs, 1000);
    expect(task.programNames, contains('Housekeeping'));
  });
}
