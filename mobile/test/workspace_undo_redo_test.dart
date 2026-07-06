import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

// The default active project ('Basic Motor Start Stop' / proj_motor) has
// 7 tags and 1 struct def; adding a tag via the Memory Manager's "Add Tag"
// dialog (defaults accepted) bumps the tag count by one.
const String _baseLabel = 'Tags & Structs (7 Tags, 1 Structs)';
const String _plusOneLabel = 'Tags & Structs (8 Tags, 1 Structs)';
const String _plusTwoLabel = 'Tags & Structs (9 Tags, 1 Structs)';

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
    await tester.tap(find.text('Tank Level Simulation').last);
    await tester.pumpAndSettle();

    expect(_iconButton(tester, 'Undo').onPressed, isNull);
    expect(_iconButton(tester, 'Redo').onPressed, isNull);
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
}
