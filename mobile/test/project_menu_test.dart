// WS7 Task 2: the 7 inline project CRUD icon buttons (New, Duplicate,
// Rename, Delete, Reset to Defaults, Export, Import) were collapsed into a
// single PopupMenuButton (⋮) beside the SELECT PROJECT dropdown to save
// space in the narrow left dock. Assert the old inline buttons are gone,
// the ⋮ menu exists, and all actions are reachable through it — at both
// phone and desktop widths, with no overflow.
//
// Task 5 of the PLCopen-XML import feature added an 8th action, 'Import PLC
// Program (XML)', beside 'Import Project' in the same menu.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final size in const [phoneSize, desktopSize]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$label: old inline CRUD buttons are gone, ⋮ menu present', (tester) async {
      await setSurface(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // On phone, the project switcher (and its PopupMenuButton) lives
      // inside the Drawer — open it first so it's actually in the tree.
      // On desktop the dock is already inline; there's no hamburger there.
      final hamburger = find.byTooltip('Open navigation menu');
      if (hamburger.evaluate().isNotEmpty) {
        await tester.tap(hamburger);
        await tester.pumpAndSettle();
      }

      // The old per-action icon buttons carried these tooltips directly on
      // an IconButton in a Wrap. They must no longer be present.
      expect(find.byTooltip('New Project'), findsNothing);
      expect(find.byTooltip('Duplicate Project'), findsNothing);
      expect(find.byTooltip('Rename Project'), findsNothing);
      expect(find.byTooltip('Delete Project'), findsNothing);
      expect(find.byTooltip('Reset to Defaults'), findsNothing);
      expect(find.byTooltip('Export Project (.splc.json)'), findsNothing);
      expect(find.byTooltip('Import Project (.splc.json)'), findsNothing);

      // The new overflow menu trigger exists in the project switcher area.
      // (Scoped by its own tooltip: the compact AppBar has an unrelated
      // "More actions" PopupMenuButton<String> too.)
      expect(find.byTooltip('Project actions'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('$label: opening the ⋮ menu reveals all 8 project actions', (tester) async {
      await setSurface(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      // On phone, the project switcher (and its PopupMenuButton) lives
      // inside the Drawer — open it first so the trigger is actually in
      // the tree and hit-testable.
      final hamburger = find.byTooltip('Open navigation menu');
      if (hamburger.evaluate().isNotEmpty) {
        await tester.tap(hamburger);
        await tester.pumpAndSettle();
      }

      final menuButton = find.byTooltip('Project actions');
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      expect(find.text('New Project'), findsOneWidget);
      expect(find.text('Duplicate Project'), findsOneWidget);
      expect(find.text('Rename Project'), findsOneWidget);
      expect(find.text('Delete Project'), findsOneWidget);
      expect(find.text('Reset to Defaults'), findsOneWidget);
      expect(find.text('Export Project'), findsOneWidget);
      expect(find.text('Import Project'), findsOneWidget);
      expect(find.text('Import PLC Program (XML)'), findsOneWidget);

      expect(tester.takeException(), isNull);

      // Dismiss the menu so addTearDown's surface reset doesn't race an
      // open overlay.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('small phone (320x568): no overflow with the new ⋮ menu', (tester) async {
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
