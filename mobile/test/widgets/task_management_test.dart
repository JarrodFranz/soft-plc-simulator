import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
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

  testWidgets('addTask appends a task; deleteTask blocked if it would orphan', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    final before = state.debugActiveProject.tasks.length;
    state.debugAddTask(PlcTask(name: 'PollTask', type: 'Periodic', periodMs: 500, programNames: []));
    expect(state.debugActiveProject.tasks.length, before + 1);

    // A program that is ONLY in PollTask cannot be orphaned by deleting PollTask.
    final proj = state.debugActiveProject;
    proj.programs.add(PlcProgram(name: 'Lonely', language: 'StructuredText', stSource: ''));
    proj.tasks.firstWhere((t) => t.name == 'PollTask').programNames.add('Lonely');
    final blocked = state.debugDeleteTask(proj.tasks.firstWhere((t) => t.name == 'PollTask'));
    expect(blocked, isFalse); // delete refused
    expect(proj.tasks.any((t) => t.name == 'PollTask'), isTrue); // still there
  });

  testWidgets('deleteTask succeeds when its programs are also owned by another task', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    final proj = state.debugActiveProject;
    proj.programs.add(PlcProgram(name: 'Shared', language: 'StructuredText', stSource: ''));
    state.debugAddTask(PlcTask(name: 'Main', type: 'Continuous', programNames: ['Shared']));
    state.debugAddTask(PlcTask(name: 'Extra', type: 'Periodic', periodMs: 500, programNames: ['Shared']));

    final removed = state.debugDeleteTask(proj.tasks.firstWhere((t) => t.name == 'Extra'));
    expect(removed, isTrue); // delete succeeds; 'Shared' remains owned by 'Main'
    expect(state.debugActiveProject.tasks.any((t) => t.name == 'Extra'), isFalse);
    expect(state.debugActiveProject.programs.any((p) => p.name == 'Shared'), isTrue);
  });

  testWidgets('add-program "new task" path rejects a duplicate task name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    state.debugAddTask(PlcTask(name: 'Dupe', type: 'Continuous', programNames: []));
    final taskCount = state.debugActiveProject.tasks.length;
    final progCount = state.debugActiveProject.programs.length;

    // Case-insensitive collision with the existing 'Dupe' task must be rejected.
    final added = state.debugAddProgramToNewTask(
      programName: 'Prog1',
      language: 'StructuredText',
      taskName: 'dupe',
      taskType: 'Periodic',
      periodMs: 250,
    );
    expect(added, isFalse); // rejected
    expect(state.debugActiveProject.tasks.length, taskCount); // no task added
    expect(state.debugActiveProject.programs.length, progCount); // no program added

    // A unique name still succeeds.
    final ok = state.debugAddProgramToNewTask(
      programName: 'Prog2',
      language: 'StructuredText',
      taskName: 'FreshTask',
      taskType: 'Continuous',
    );
    expect(ok, isTrue);
    expect(state.debugActiveProject.tasks.any((t) => t.name == 'FreshTask'), isTrue);
    expect(state.debugActiveProject.programs.any((p) => p.name == 'Prog2'), isTrue);
  });
}
