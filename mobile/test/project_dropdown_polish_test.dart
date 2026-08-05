// QA sweep item A7 (#10): the project-select dropdown's header visually
// blended into the scan-speed toolbar row beside it, and a long project
// name truncated in the dropdown's list rows with no way to read it in
// full. (A true modal scrim behind the popup itself is not implemented —
// DropdownButton's popup route hardcodes barrierColor to null with no
// public override, and adding one without forking the widget or a NEW
// PopupRoute app-wide would mean replacing DropdownButton entirely, which
// several other tests key off via find.byType(DropdownButton<String>); see
// the report for the full rationale.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the SELECT PROJECT header has a top border separating it from the '
      'scan-speed toolbar', (tester) async {
    // Desktop width so the left dock renders inline instead of inside the
    // (initially-closed) Drawer.
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final headerFinder = find.ancestor(
      of: find.text('SELECT PROJECT'),
      matching: find.byType(Container),
    );
    expect(headerFinder, findsWidgets);
    final header = tester.widget<Container>(headerFinder.first);
    final decoration = header.decoration as BoxDecoration?;
    expect(decoration, isNotNull);
    expect(decoration!.border, isNotNull);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a project name in the dropdown list is wrapped in a Tooltip', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final dropdown = find.byType(DropdownButton<String>).first;
    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    // The active project's row renders both in the closed-button display and
    // again inside the open popup list, so this legitimately matches twice.
    expect(find.byTooltip('Basic Motor Start Stop'), findsWidgets);

    // Close the menu so addTearDown's surface reset doesn't race an open
    // overlay.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
