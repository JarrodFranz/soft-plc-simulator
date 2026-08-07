import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

import 'support/responsive_test_utils.dart';

/// QA #6 — on a phone the app used to open three different panels from
/// identical-looking glyphs, and two detail screens stacked a second
/// hamburger directly under the shell's.
///
/// The contract locked in here:
///  * the hamburger (`'Open navigation menu'`) belongs to the MAIN nav drawer
///    and nothing else — never two of them on one screen;
///  * a per-editor list drawer (ST programs, Function Blocks) opens from its
///    own tree glyph with its own tooltip;
///  * the Tag Inspector keeps its own distinct `Icons.table_chart` toggle.
Widget _app() => const MaterialApp(home: WorkspaceShell());

WorkspaceShellState _shell(WidgetTester tester) =>
    tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

Future<void> _openStEditor(WidgetTester tester) async {
  final state = _shell(tester);
  state.debugSwitchToProject(
      state.debugAllProjects.firstWhere((p) => p.id == 'proj_st_reactor_control'));
  await tester.pumpAndSettle();
  state.debugSetActiveViewId('PROGRAM:ReactorTemp_ST');
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ST editor at phone width: one hamburger, plus a distinct program-list icon',
      (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openStEditor(tester);

    // Exactly one hamburger on screen — the shell's.
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);

    // The editor's own drawer opens from its own glyph.
    expect(find.byTooltip('Open program list'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('Open program list'),
        matching: find.byIcon(Icons.account_tree),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the program-list icon opens the ST program drawer', (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openStEditor(tester);

    expect(find.text('PROJECT ST PROGRAMS'), findsNothing);
    await tester.tap(find.byTooltip('Open program list'));
    await tester.pumpAndSettle();
    expect(find.text('PROJECT ST PROGRAMS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Function Blocks at phone width: one hamburger, plus a distinct FB-list icon',
      (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    _shell(tester).debugSetActiveViewId('FB');
    await tester.pumpAndSettle();

    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    expect(find.byTooltip('Open function block list'), findsOneWidget);

    await tester.tap(find.byTooltip('Open function block list'));
    await tester.pumpAndSettle();
    expect(find.text('FUNCTION BLOCKS'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Tag Inspector keeps its own non-hamburger toggle at phone width',
      (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final toggle = find.byTooltip('Toggle Tag Inspector Side Dock');
    expect(toggle, findsOneWidget);
    expect(
      find.descendant(of: toggle, matching: find.byIcon(Icons.table_chart)),
      findsOneWidget,
    );
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop width shows neither drawer glyph on the ST editor', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openStEditor(tester);

    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.byTooltip('Open program list'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
