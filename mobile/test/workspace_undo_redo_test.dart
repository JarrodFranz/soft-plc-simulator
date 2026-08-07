import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

// The boot-active project (`all()[0]`, 'Ladder — Conveyor Line') ships its
// declared tags plus the reserved `System` status tag the shell injects on
// boot (`ensureSystemTag`) -> tags.length + 1 baseline. Adding a tag via the
// Memory Manager's "Add Tag" dialog (defaults accepted) bumps the tag count
// by one from there.
String _tagsLabel(PlcProject p, {int extra = 0}) =>
    'Tags & Structs (${p.tags.length + 1 + extra} Tags, ${p.structDefs.length} Structs)';

final PlcProject _boot = DefaultProjects.all()[0];   // Ladder — Conveyor Line
final PlcProject _second = DefaultProjects.all()[1]; // FBD — HVAC Zone Controller

final String _baseLabel = _tagsLabel(_boot);
final String _plusOneLabel = _tagsLabel(_boot, extra: 1);
final String _plusTwoLabel = _tagsLabel(_boot, extra: 2);

/// Navigates to the Memory Manager view via the left dock nav tree. On
/// compact widths the dock lives in a Drawer that must be opened first.
Future<void> _goToMemoryView(WidgetTester tester, {required bool compact}) async {
  if (compact) {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(_baseLabel).hitTestable());
  await tester.pumpAndSettle();
}

/// Drives one real mutation through the shell: opens the Memory Manager's
/// "Add Tag" dialog and confirms it with the default field values, which
/// appends a new tag ("New_Tag") to the active project. This exercises the
/// real `onProjectUpdated` -> `_markDirtyAndAutosave` callback path.
///
/// Deliberately uses a couple of fixed `pump()` calls rather than
/// `pumpAndSettle()`: the dialog's autofocused `TextField` has a blinking
/// text cursor, an indefinitely-repeating animation, so `pumpAndSettle`
/// keeps pumping (and therefore keeps advancing the fake clock) until its
/// own internal timeout - easily blowing past the 800ms autosave/history
/// debounce even for "instantaneous" taps. That would make it impossible to
/// exercise the coalescing behavior (two edits inside one debounce window).
Future<void> _addTagViaUi(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FloatingActionButton, 'Add Tag'));
  await tester.pump();
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Add Tag'));
  await tester.pump();
  await tester.pump();
}

IconButton _iconButton(WidgetTester tester, String tooltip) {
  return tester.widget<IconButton>(
    find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)).first,
  );
}

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually resolves
  // inside the test's FakeAsync zone (see shell_responsive_test.dart).
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Undo/Redo disabled on a freshly loaded project', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(_iconButton(tester, 'Undo').onPressed, isNull);
    expect(_iconButton(tester, 'Redo').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit + debounce enables Undo; Undo reverts; Redo re-applies', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _goToMemoryView(tester, compact: false);
    expect(find.text(_baseLabel), findsOneWidget);

    await _addTagViaUi(tester);
    // Tag count bumps immediately (setState in MemoryManagerScreen); the
    // shell's own dock label reflects the same underlying project object.
    expect(find.text(_plusOneLabel), findsOneWidget);

    // Before the debounce fires, Undo is still disabled (nothing captured
    // into history yet).
    expect(_iconButton(tester, 'Undo').onPressed, isNull);

    // Let the autosave/history debounce (800ms) elapse.
    await tester.pump(const Duration(seconds: 1));

    expect(_iconButton(tester, 'Undo').onPressed, isNotNull);
    expect(_iconButton(tester, 'Redo').onPressed, isNull);

    // Tap Undo -> reverts the tag addition.
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();

    expect(find.text(_baseLabel), findsOneWidget);
    expect(_iconButton(tester, 'Redo').onPressed, isNotNull);
    expect(tester.takeException(), isNull);

    // Tap Redo -> re-applies the addition.
    await tester.tap(find.byTooltip('Redo'));
    await tester.pumpAndSettle();

    expect(find.text(_plusOneLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two mutations within one debounce window coalesce into one undo step', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _goToMemoryView(tester, compact: false);
    expect(find.text(_baseLabel), findsOneWidget);

    // First mutation, then quickly a second one before the debounce fires.
    await _addTagViaUi(tester);
    expect(find.text(_plusOneLabel), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));

    await _addTagViaUi(tester);
    expect(find.text(_plusTwoLabel), findsOneWidget);

    // Now let the debounce elapse fully.
    await tester.pump(const Duration(seconds: 1));

    expect(_iconButton(tester, 'Undo').onPressed, isNotNull);

    // A single Undo should return all the way to the pre-both-edits state.
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();

    expect(find.text(_baseLabel), findsOneWidget);
    // No further undo available - it was a single coalesced step.
    expect(_iconButton(tester, 'Undo').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching project clears history (Undo disabled again)', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _goToMemoryView(tester, compact: false);
    await _addTagViaUi(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(_iconButton(tester, 'Undo').onPressed, isNotNull);

    // Switch active project via the dropdown in the left dock.
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_second.name).last);
    await tester.pumpAndSettle();

    expect(_iconButton(tester, 'Undo').onPressed, isNull);
    expect(_iconButton(tester, 'Redo').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Undo reverts a structural edit while the scan loop churns live tag values', (tester) async {
    // Regression: the history snapshot serializes every tag's LIVE value
    // (`PlcTag.toJson` writes the current `value` as `initial_value`), so on a
    // project whose scan loop actually moves values (the HVAC zone controller
    // integrates its room/tank levels via sim rules) the snapshot changes on every
    // tick with no user edit at all. Undo must still step back to the
    // pre-edit STRUCTURE rather than to a snapshot that merely differs by
    // that live-value drift (which would leave the edit in place).
    expect(_second.simRules.where((r) => r.enabled), isNotEmpty,
        reason: 'this test needs a project whose scan loop moves live values');
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Switch to the churning project (this also resets history).
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_second.name).last);
    await tester.pumpAndSettle();

    final secondBase = _tagsLabel(_second);
    final secondPlusOne = _tagsLabel(_second, extra: 1);
    await tester.tap(find.text(secondBase).hitTestable());
    await tester.pumpAndSettle();

    await _addTagViaUi(tester);
    expect(find.text(secondPlusOne), findsOneWidget);

    // Let the 800ms autosave/history debounce fire (captures the edit)...
    await tester.pump(const Duration(seconds: 1));
    expect(_iconButton(tester, 'Undo').onPressed, isNotNull);
    // ...then let the scan loop run on, drifting live tag values away from
    // the captured snapshot without any further user edit.
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();

    expect(find.text(secondBase), findsOneWidget,
        reason: 'Undo must revert the added tag, not just the live-value drift');
    expect(tester.takeException(), isNull);

    // The restore's own debounced autosave (plus further drift) must not
    // record a bogus entry that wipes redo...
    await tester.pump(const Duration(seconds: 2));
    expect(_iconButton(tester, 'Redo').onPressed, isNotNull);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pumpAndSettle();
    expect(find.text(secondPlusOne), findsOneWidget);

    // ...and undo must not get stuck oscillating between two drift states:
    // a second Undo (after more drift) still returns to the pre-edit state.
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect(find.text(secondBase), findsOneWidget);
    expect(_iconButton(tester, 'Undo').onPressed, isNull,
        reason: 'drift must not have manufactured extra undo steps');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no exception on undo across surfaces 320 and 1400', (tester) async {
    for (final size in const [smallPhoneSize, desktopSize]) {
      await setSurface(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final compact = size.width < 600;
      await _goToMemoryView(tester, compact: compact);
      await _addTagViaUi(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(_iconButton(tester, 'Undo').onPressed, isNotNull);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    }
  });

  // ── ST editor x undo (final-review F1/F2/F3) ───────────────────────────
  //
  // The ST editor persists typed source through a 350ms debounce and flushes
  // whatever is still pending from `dispose()`. The centre pane is re-keyed
  // (and the editor therefore disposed) by every view/project switch AND by
  // every undo/redo restore, so that flush used to fire from inside the
  // framework's tree-lock window — calling the shell's `setState` (a throw in
  // assert-enabled builds), writing into whatever project was active by then,
  // and re-arming `_pendingHistoryCapture` right after `_applySnapshot` had
  // cleared it (which wiped the redo stack on the next autosave).
  //
  // The contract: the shell flushes the editor BEFORE it swaps anything, so
  // typing then hitting Undo behaves exactly like any other editor's edit.
  group('ST editor + undo/redo', () {
    const codeField = Key('stCodeEditorField');

    /// Boots the shell onto the built-in Structured Text demo project with
    /// its ST program open in the centre pane.
    Future<PlcProgram> openStProgram(WidgetTester tester) async {
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final st = state.debugAllProjects.firstWhere((p) => p.id == 'proj_st_reactor_control');
      state.debugSwitchToProject(st);
      await tester.pumpAndSettle();
      state.debugSetActiveViewId('PROGRAM:ReactorTemp_ST');
      await tester.pumpAndSettle();
      expect(find.byKey(codeField), findsOneWidget);
      return state.debugActiveProject.programs.firstWhere((p) => p.name == 'ReactorTemp_ST');
    }

    String stSourceOf(WidgetTester tester) => tester
        .state<WorkspaceShellState>(find.byType(WorkspaceShell))
        .debugActiveProject
        .programs
        .firstWhere((p) => p.name == 'ReactorTemp_ST')
        .stSource;

    testWidgets('typing then Undo: no tree-lock throw, the undone text stays undone, Redo still works',
        (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      await openStProgram(tester);

      // Edit 1, fully debounced + captured as an undo step.
      await tester.enterText(find.byKey(codeField), 'FIRST_EDIT;');
      await tester.pump(const Duration(milliseconds: 400)); // editor persist debounce
      await tester.pump(const Duration(seconds: 1)); // shell autosave/history debounce
      expect(stSourceOf(tester), 'FIRST_EDIT;');

      // Edit 2, still INSIDE the editor's persist debounce when Undo is hit —
      // this is what used to reach the shell from `dispose()`.
      await tester.enterText(find.byKey(codeField), 'SECOND_EDIT;');
      await tester.pump();

      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull,
          reason: 'the dispose-time flush must not call setState during the tree lock');

      // Let any deferred/debounced work settle, then assert the undo held.
      await tester.pump(const Duration(seconds: 1));
      expect(stSourceOf(tester), isNot('SECOND_EDIT;'),
          reason: 'the undone text must not be resurrected by a dispose-time flush');
      expect(tester.takeException(), isNull);

      expect(_iconButton(tester, 'Redo').onPressed, isNotNull,
          reason: 'a dispose-time flush must not wipe the redo stack');
      await tester.tap(find.byTooltip('Redo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(stSourceOf(tester), 'SECOND_EDIT;');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typed ST lands in the project it was typed into, not the one switched to',
        (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      final stProject = await openStProgram(tester);
      final otherProject =
          state.debugAllProjects.firstWhere((p) => p.id == 'proj_fbd_hvac_zone');

      // Type, then switch projects before the persist debounce elapses.
      await tester.enterText(find.byKey(codeField), 'TYPED_INTO_ST_PROJECT;');
      await tester.pump();
      state.debugSwitchToProject(otherProject);
      await tester.pumpAndSettle();

      expect(stProject.stSource, 'TYPED_INTO_ST_PROJECT;',
          reason: 'the text must land in the project that was active while typing');
      expect(otherProject.programs.every((p) => p.stSource != 'TYPED_INTO_ST_PROJECT;'), isTrue,
          reason: 'and never in the project switched to');
      expect(tester.takeException(), isNull);
    });
  });
}
