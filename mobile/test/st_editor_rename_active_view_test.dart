// QA final-review fix (Fix B): after the ST editor's flush applies a program
// RENAME, `_activeViewId` used to keep saying `PROGRAM:<old name>` — a name
// that no longer exists in `_activeProject.programs`. `_buildCenterWorkspace`
// looks the active program up by that name with
// `.firstWhere(..., orElse: () => programs.first)`, so the very next rebuild
// silently swapped the centre pane to an ARBITRARY other program (even one in
// a different language) instead of continuing to show the one just renamed.
//
// This test builds a project where the renamed program is the ONLY
// Structured-Text program and a *different*, first-in-list program is
// LadderLogic — the most visible form of the bug: if `_activeViewId` is left
// stale, `_buildCenterWorkspace`'s language dispatch resolves the stale name
// to `programs.first` (the LadderLogic program) and renders `LdEditorScreen`
// instead of the ST editor entirely.
//
// The rename is applied via the ST editor's real "Save to Project" button
// (the header name field is only applied on a flush, e.g. `applyName: true`)
// while `_activeViewId` is NOT touched by anything else — unlike navigating
// to a different view/program, which always explicitly reassigns
// `_activeViewId` to the user's actual destination and would mask this bug.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

import 'support/responsive_test_utils.dart';

PlcProject _buildProject() {
  final alpha = PlcProgram(name: 'Alpha', language: 'LadderLogic');
  final beta = PlcProgram(
    name: 'Beta',
    language: 'StructuredText',
    description: 'Beta program',
    stSource: 'Beta_Output := TRUE;',
  );
  return PlcProject(
    id: 'proj_rename_active_view_test',
    name: 'Rename Active View Test',
    controllerName: 'TestPLC',
    tags: [],
    structDefs: [],
    // Alpha (LadderLogic) is deliberately FIRST so a stale `_activeViewId`
    // falling back to `programs.first` lands on a different-language program
    // — an unmissable failure signal.
    programs: [alpha, beta],
    tasks: [],
    hmis: [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'renaming the active ST program via Save keeps _activeViewId (and the '
    'centre pane) tracking the new name, not a stale/arbitrary fallback',
    (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final project = _buildProject();
      state.debugAddProject(project);
      state.debugSwitchToProject(project);
      await tester.pumpAndSettle();

      state.debugSetActiveViewId('PROGRAM:Beta');
      await tester.pumpAndSettle();

      const codeFieldKey = Key('stCodeEditorField');
      expect(find.byKey(codeFieldKey), findsOneWidget,
          reason: 'sanity: the ST editor must be showing Beta before the rename');
      expect(find.byType(LdEditorScreen), findsNothing);

      final nameField = find.ancestor(of: find.text('Program Name'), matching: find.byType(TextField));
      await tester.enterText(nameField, 'BetaRenamed');
      await tester.pump();

      // "Save to Project" flushes the pending header edit (applyName: true)
      // without touching `_activeViewId` itself — the shell's `onSaveProgram`
      // callback is the only thing that may correct it.
      await tester.tap(find.byTooltip('Save to Project'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(project.programs.any((p) => p.name == 'BetaRenamed'), isTrue,
          reason: 'the rename must have reached the model');
      expect(project.programs.any((p) => p.name == 'Beta'), isFalse);

      expect(state.debugActiveViewId, 'PROGRAM:BetaRenamed',
          reason: '_activeViewId must track the renamed program, not the stale '
              '"PROGRAM:Beta" id that no longer resolves to anything');

      // The centre pane must still be the ST editor showing the renamed
      // program — NOT `LdEditorScreen` (what `programs.first`/Alpha would
      // render if the stale-id bug swapped the view out from under it).
      expect(find.byType(LdEditorScreen), findsNothing,
          reason: 'the centre pane must not have silently fallen back to '
              'programs.first (Alpha, a different-language program)');
      expect(find.byKey(codeFieldKey), findsOneWidget);
      expect(find.text('BetaRenamed'), findsWidgets,
          reason: 'both the header name field and the left-dock program list should show the new name');
    },
  );
}
