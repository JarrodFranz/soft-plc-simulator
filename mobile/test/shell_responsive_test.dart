import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

void main() {
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
}
