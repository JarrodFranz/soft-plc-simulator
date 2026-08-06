import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/ui/delete_feedback.dart';

import 'support/responsive_test_utils.dart';

/// QA #1 — the app-wide delete-confirmation policy (see
/// `lib/ui/delete_feedback.dart`):
///
///  * a delete the shell's undo history CAN reverse -> no blocking dialog,
///    a "Deleted <thing>" SnackBar with a working UNDO action;
///  * a delete it CANNOT reverse -> an explicit blocking confirmation.
Widget _app() => const MaterialApp(home: WorkspaceShell());

// Boot-active project (all()[0]). The shell injects the reserved System tag at
// load, so the rendered count is tags.length + 1.
final String _baseLabel = () {
  final p = DefaultProjects.all().first;
  return 'Tags & Structs (${p.tags.length + 1} Tags, ${p.structDefs.length} Structs)';
}();

Future<void> _goToMemoryView(WidgetTester tester) async {
  await tester.tap(find.text(_baseLabel).hitTestable());
  await tester.pumpAndSettle();
}

WorkspaceShellState _shell(WidgetTester tester) =>
    tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('undoable delete: no dialog, SnackBar + UNDO', () {
    testWidgets('deleting a tag shows "Deleted …" with UNDO and no confirmation dialog',
        (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _goToMemoryView(tester);

      expect(_shell(tester).debugActiveProject.tags.any((t) => t.name == 'Start_PB'), isTrue);

      await tester.tap(find.byKey(const Key('delete_tag_Start_PB')));
      await tester.pump();

      // No blocking dialog — the delete already happened.
      expect(find.byType(AlertDialog), findsNothing);
      expect(_shell(tester).debugActiveProject.tags.any((t) => t.name == 'Start_PB'), isFalse);

      // …and it is announced with an undo affordance.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Deleted tag "Start_PB"'), findsOneWidget);
      expect(find.byKey(kDeleteUndoActionKey), findsOneWidget);
    });

    testWidgets('tapping UNDO on the SnackBar restores the deleted tag', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _goToMemoryView(tester);

      await tester.tap(find.byKey(const Key('delete_tag_Start_PB')));
      await tester.pump();
      expect(_shell(tester).debugActiveProject.tags.any((t) => t.name == 'Start_PB'), isFalse);

      // Let the SnackBar finish sliding in so its action is hit-testable.
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.byKey(kDeleteUndoActionKey));
      await tester.pumpAndSettle();

      expect(_shell(tester).debugActiveProject.tags.any((t) => t.name == 'Start_PB'), isTrue,
          reason: 'the SnackBar UNDO action must run the shell undo');
      expect(tester.takeException(), isNull);
    });

    testWidgets('deleting a struct definition no longer blocks on a confirmation dialog',
        (tester) async {
      // Struct defs live inside PlcProject, so undo restores them — they fall
      // on the "no dialog" side of the policy like every other project edit.
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // The stock DUT is referenced by a tag (deletion is refused for that
      // reason, which is a separate guard), so seed a spare, unused one before
      // opening the view.
      _shell(tester).debugActiveProject.structDefs.add(
        PlcStructDef(name: 'SpareDUT', fields: [
          StructFieldDef(name: 'Val', dataType: 'BOOL', defaultValue: false),
        ]),
      );
      _shell(tester).debugResetHistory();
      await _goToMemoryView(tester);
      await tester.tap(find.text('Struct Definitions (DUT)'));
      await tester.pumpAndSettle();

      final before = _shell(tester).debugActiveProject.structDefs.length;
      expect(_shell(tester).debugActiveProject.structDefs.any((d) => d.name == 'SpareDUT'), isTrue);

      final spareCard = find.ancestor(of: find.text('SpareDUT'), matching: find.byType(Card));
      await tester.tap(find.descendant(of: spareCard, matching: find.byTooltip('Delete DUT')));
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(_shell(tester).debugActiveProject.structDefs.length, before - 1);
      expect(find.byKey(kDeleteUndoActionKey), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.byKey(kDeleteUndoActionKey));
      await tester.pumpAndSettle();
      expect(_shell(tester).debugActiveProject.structDefs.length, before);
    });
  });

  group('non-undoable delete: explicit confirmation', () {
    testWidgets('Delete Project still confirms before deleting', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final before = _shell(tester).debugAllProjects.length;

      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Project'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      // Nothing deleted while the dialog is still up.
      expect(_shell(tester).debugAllProjects.length, before);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(_shell(tester).debugAllProjects.length, before);
    });

    testWidgets('Clearing the log gains a confirmation (the logger buffer is outside history)',
        (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      _shell(tester).debugSetActiveViewId('LOGS');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('logs_clear_button')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('QA F3: stale UNDO snackbar is cleared on project switch', () {
    testWidgets('switching projects while a delete-UNDO snackbar is showing dismisses it',
        (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await _goToMemoryView(tester);

      // Trigger the "Deleted …" SnackBar with its UNDO action still live.
      await tester.tap(find.byKey(const Key('delete_tag_Start_PB')));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byKey(kDeleteUndoActionKey), findsOneWidget);

      // Switch to a different project before the snackbar times out — its
      // UNDO action, if it survived, would resolve against the NEW project's
      // history and revert an unrelated edit there.
      final other = PlcProject(
        id: 'proj_qa_f3_other',
        name: 'QA F3 Other Project',
        controllerName: 'PLC_02',
        tags: [],
        structDefs: [],
        programs: [PlcProgram(name: 'Main', language: 'StructuredText')],
        tasks: [],
        hmis: [],
      );
      _shell(tester).debugAddProject(other);
      _shell(tester).debugSwitchToProject(other);
      await tester.pump();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(kDeleteUndoActionKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
