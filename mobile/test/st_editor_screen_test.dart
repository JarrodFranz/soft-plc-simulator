// Bug 3 (QA sweep): "ST Editor silently discards unsaved typed edits on
// navigating away and back — no warning, no autosave."
//
// The real app never disposes StEditorScreen except by rebuilding the
// workspace shell's center pane with a different widget when the active
// view changes (see workspace_shell.dart's `_buildActiveView` — there is no
// IndexedStack keeping the editor alive), so "navigate away" == "dispose",
// and "navigate back" == "mount a fresh StEditorScreen reading whatever is
// currently in the model". These tests reproduce that exact lifecycle with
// a minimal harness that swaps StEditorScreen for a placeholder and back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/st_editor_screen.dart';

PlcProject _buildProject({required PlcProgram program}) {
  return PlcProject(
    id: 'proj_test_st',
    name: 'Test ST Project',
    controllerName: 'TestPLC',
    tags: [],
    structDefs: [],
    programs: [program],
    tasks: [],
    hmis: [],
  );
}

/// Toggles between the real [StEditorScreen] and a placeholder, so tests can
/// force a real dispose/re-mount cycle — the same thing the workspace shell
/// does when the user switches the active view and switches back.
class _NavHarness extends StatefulWidget {
  final PlcProject project;
  final void Function(PlcProgram) onSaveProgram;

  const _NavHarness({super.key, required this.project, required this.onSaveProgram});

  @override
  State<_NavHarness> createState() => _NavHarnessState();
}

class _NavHarnessState extends State<_NavHarness> {
  bool showEditor = true;

  void toggle() => setState(() => showEditor = !showEditor);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: showEditor
          ? StEditorScreen(
              currentProject: widget.project,
              onSaveProgram: widget.onSaveProgram,
            )
          : const Scaffold(body: Text('elsewhere')),
    );
  }
}

void main() {
  const codeFieldKey = Key('stCodeEditorField');

  /// Applies a received `PlcProgram` back into `project.programs` the same
  /// way `workspace_shell.dart`'s real `onSaveProgram` callback does.
  void Function(PlcProgram) applyingSaver(PlcProject project, List<PlcProgram> received) {
    return (updated) {
      received.add(updated);
      final idx = project.programs.indexWhere((p) => p.name == updated.name);
      if (idx != -1) {
        project.programs[idx] = updated;
      }
    };
  }

  testWidgets('typed ST edits persist to the model on a pause in typing, without pressing Save', (tester) async {
    final program = PlcProgram(name: 'Prog1', language: 'StructuredText', description: 'desc', stSource: 'OldCode;');
    final project = _buildProject(program: program);
    final received = <PlcProgram>[];

    await tester.pumpWidget(_NavHarness(project: project, onSaveProgram: applyingSaver(project, received)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(codeFieldKey), 'NewCode := 42;');
    await tester.pump();

    // Before the debounce elapses, the model must not have changed yet.
    expect(project.programs.first.stSource, 'OldCode;');

    // Let the editor's own persist debounce elapse.
    await tester.pump(const Duration(milliseconds: 400));

    expect(project.programs.first.stSource, 'NewCode := 42;');
    expect(received, isNotEmpty);
    expect(received.last.stSource, 'NewCode := 42;');
    // The identity (name) must be preserved — auto-persist must not rename
    // the program out from under the explicit Save workflow.
    expect(received.last.name, 'Prog1');
  });

  testWidgets('typed-but-undebounced edits are flushed on dispose (navigate away) and survive navigating back',
      (tester) async {
    final program = PlcProgram(name: 'Prog1', language: 'StructuredText', description: 'desc', stSource: 'OldCode;');
    final project = _buildProject(program: program);
    final received = <PlcProgram>[];
    final harnessKey = GlobalKey<_NavHarnessState>();

    await tester.pumpWidget(_NavHarness(key: harnessKey, project: project, onSaveProgram: applyingSaver(project, received)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(codeFieldKey), 'NewCode := 42;');
    // Only a single pump — well under the 350ms persist debounce — so the
    // debounce timer has NOT fired yet when we navigate away.
    await tester.pump();
    expect(project.programs.first.stSource, 'OldCode;');

    // Navigate away: dispose the editor before the debounce would have
    // fired on its own.
    harnessKey.currentState!.toggle();
    await tester.pump();

    // dispose() must have flushed the pending edit synchronously.
    expect(project.programs.first.stSource, 'NewCode := 42;');

    // Navigate back: a fresh StEditorScreen is mounted and must load the
    // persisted text, not the stale original.
    harnessKey.currentState!.toggle();
    await tester.pumpAndSettle();

    expect(find.text('NewCode := 42;'), findsOneWidget);
  });

  testWidgets('merely opening the editor does not mark the project dirty (no spurious persist on load)',
      (tester) async {
    final program = PlcProgram(name: 'Prog1', language: 'StructuredText', description: 'desc', stSource: 'OldCode;');
    final project = _buildProject(program: program);
    final received = <PlcProgram>[];

    await tester.pumpWidget(_NavHarness(project: project, onSaveProgram: applyingSaver(project, received)));
    // Let any debounce window that would fire from programmatic load elapse.
    await tester.pump(const Duration(milliseconds: 500));

    expect(received, isEmpty, reason: 'loading a program into the editor must not itself trigger a model write');
  });
}
