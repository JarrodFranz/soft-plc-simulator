// QA final-review fix (Fix A): `_createNewProject` was the one
// project-replacing CRUD path with no `_flushPendingAutosave()` call.
// `_duplicateActiveProject`, `_switchActiveProject`, and `_applyImportedProject`
// all flush before swapping `_activeProject` away, so an edit still sitting
// inside the shell's 800ms autosave debounce window survives the swap. Without
// the flush, an edit made shortly before "New Project" is silently lost: the
// debounce timer that would have saved it fires (if ever) AFTER
// `_activeProject` has already been replaced by the new blank project, so it
// re-saves the WRONG (blank) project and the previous project's edit never
// reaches disk.
//
// This test drives the real shell exactly like a user would: flips a tag via
// the Tag Inspector (marking the project dirty, arming the debounce, but
// deliberately not letting it elapse), then immediately creates a new project
// via the real "Project actions" (kebab) menu, and asserts the PREVIOUS
// project's copy in the backing store reflects the flipped tag.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/project_repository.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';

import 'support/responsive_test_utils.dart';

Widget _app(ProjectRepository repo) => MaterialApp(home: WorkspaceShell(repository: repo));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an edit still inside the autosave debounce window survives "New Project" '
    "(the previous project's stored copy reflects it)",
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = ProjectRepository(prefs);

      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app(repo));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final previousId = state.debugActiveProject.id;

      // Flip the first tag (Start_PB) via the Tag Inspector, exactly like a
      // user would. This marks the project dirty and arms the shell's 800ms
      // autosave debounce (`_markDirtyAndAutosave`) — a single `pump()` (zero
      // elapsed time) registers the tap without letting any of that debounce
      // elapse.
      expect(find.byType(TagInspectorDock), findsOneWidget);
      final startPbCard = find.ancestor(of: find.text('Start_PB'), matching: find.byType(Card)).first;
      final valuePill = find.descendant(of: startPbCard, matching: find.text('false ')).first;
      await tester.tap(valuePill);
      await tester.pump();
      expect(tester.takeException(), isNull);

      // Immediately (well inside the 800ms debounce window) create a new
      // project via the real ⋮ "Project actions" menu, the same path a user
      // would take. `pumpAndSettle()` is deliberately avoided here: the
      // shell's continuously-repainting scan loop means it never really
      // "settles", so it silently burns well over 800ms of fake time before
      // returning — which would let the natural autosave debounce fire on
      // its own and mask the very bug this test exists to catch (see
      // `workspace_undo_redo_test.dart`'s `_addTagViaUi` for the same
      // concern). A handful of small, fixed pumps lets the popup menu's
      // route settle into a hit-testable position without burning anywhere
      // near that much fake time.
      await tester.tap(find.byTooltip('Project actions'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.tap(find.text('New Project'));
      await tester.pump();
      await tester.pump();

      // The name dialog opens pre-filled with 'New Project'; accept it as-is.
      // From here on, elapsed time no longer matters: `_createNewProject`
      // already flushed (or failed to) synchronously the moment "New
      // Project" was tapped above, before this `await _promptForName(...)`
      // dialog even opened.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // A brand-new blank project is now active...
      expect(state.debugActiveProject.id, isNot(previousId));

      // ...but the PREVIOUS project's copy in the backing store must reflect
      // the flipped tag: `_createNewProject` must flush the pending autosave
      // before swapping `_activeProject`, exactly like every other
      // project-replacing CRUD path.
      final persistedPrevious = await repo.loadProject(previousId);
      expect(persistedPrevious, isNotNull);
      expect(persistedPrevious!.tags.first.name, 'Start_PB');
      expect(
        persistedPrevious.tags.first.value,
        true,
        reason: '_createNewProject must flush the pending autosave before swapping '
            'the active project away, like every other project-replacing CRUD path '
            '(_duplicateActiveProject, _switchActiveProject, _applyImportedProject)',
      );
    },
  );
}
