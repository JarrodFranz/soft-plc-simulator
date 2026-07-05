import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually
  // resolves inside the test's FakeAsync zone — an unmocked platform
  // channel invocation never completes there at all (neither resolving
  // nor throwing), so without this the boot Future would hang forever
  // and every pumpAndSettle() below would time out.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('phone: shell exposes a Drawer and no overflow', (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    // A hamburger opens the project drawer.
    final hamburger = find.byTooltip('Open navigation menu');
    expect(hamburger, findsOneWidget);
    // Opening it reveals the Drawer (Scaffold only builds the Drawer's
    // child into the tree once it starts opening).
    await tester.tap(hamburger);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsWidgets); // drawer(s) registered
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop: inline docks, no hamburger, no overflow', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone (320x568): no overflow', (tester) async {
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // The Tag Inspector moves to an end-drawer on compact. Exercise that actual
  // content path (not just the closed-drawer registration) at the two smallest
  // supported widths and assert its content renders without overflow.
  for (final size in const [phoneSize, smallPhoneSize]) {
    testWidgets('phone ${size.width.toInt()}: end-drawer tag inspector opens '
        'without overflow', (tester) async {
      await setSurface(tester, size);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      // Open the end-drawer directly via the shell's (outermost) Scaffold,
      // independent of which AppBar control triggers it. The center workspace
      // screens nest their own Scaffolds, so target the first (root) one.
      final scaffoldState =
          tester.state<ScaffoldState>(find.byType(Scaffold).first);
      scaffoldState.openEndDrawer();
      await tester.pumpAndSettle();
      expect(find.byType(TagInspectorDock), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
