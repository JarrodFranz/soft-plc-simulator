import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'support/responsive_test_utils.dart';

// The "All Languages — Water Treatment Plant" project has a TIMER tag
// (BackwashTimer), a DUT-typed tag (Pump1_Status), and an array tag
// (Recipe_Steps) — good coverage of the struct/array/bit hierarchy.
PlcProject _project() => DefaultProjects.all().firstWhere((p) => p.id == 'proj_all_water');

void main() {
  Widget app(PlcProject project) => LiveTickScope(
        notifier: LiveTick(),
        child: MaterialApp(
          home: MemoryManagerScreen(
            currentProject: project,
            onProjectUpdated: () {},
            historian: TagHistorian(),
          ),
        ),
      );

  group('MemoryManagerScreen responsive Global Tags tab', () {
    testWidgets('desktop: shows DataTable', (tester) async {
      await setSurface(tester, desktopSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: no DataTable, renders cards instead', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(Card), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: expanding a struct row reveals its children', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      // Before expansion, a child field label like '.Running' should not exist.
      expect(find.textContaining('.Running'), findsNothing);

      // Scroll the Pump1_Status card into view, then tap its expand icon.
      await tester.scrollUntilVisible(
        find.text('Pump1_Status').first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final expandIcon = find.descendant(
        of: find.ancestor(
          of: find.text('Pump1_Status').first,
          matching: find.byType(Card),
        ).first,
        matching: find.byIcon(Icons.play_arrow),
      );
      expect(expandIcon, findsOneWidget);
      await tester.tap(expandIcon);
      await tester.pumpAndSettle();

      expect(find.textContaining('.Running'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320x568): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('small desktop window (1300x709): edit/delete actions visible on-screen',
        (tester) async {
      // Regression: at moderate desktop widths the 7-column table used to push
      // the Actions column past the right edge of an invisible horizontal
      // scroll region, hiding edit/delete entirely. With priority columns the
      // actions must be laid out inside the visible viewport.
      await setSurface(tester, const Size(1300, 709));
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);

      // An edit button for a root tag exists and sits within the screen bounds.
      final edit = find.byKey(const Key('edit_tag_Start_PB'));
      expect(edit, findsOneWidget);
      final rect = tester.getRect(edit);
      expect(rect.right, lessThanOrEqualTo(1300));
      expect(rect.left, greaterThanOrEqualTo(0));

      // Its sibling delete button is present too.
      final actionsRow = find.ancestor(of: edit, matching: find.byType(Row)).first;
      expect(
        find.descendant(of: actionsRow, matching: find.byIcon(Icons.delete)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide desktop (1600x900): all informational columns present', (tester) async {
      await setSurface(tester, const Size(1600, 900));
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      expect(find.text('Browse Path'), findsOneWidget);
      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('I/O Classification'), findsOneWidget);
      // Actions remain visible alongside the full column set.
      expect(find.byKey(const Key('edit_tag_Start_PB')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow desktop (900x709): low-priority columns drop, actions stay',
        (tester) async {
      await setSurface(tester, const Size(900, 709));
      await tester.pumpWidget(app(_project()));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      // Browse Path and Quality are dropped at this width; actions remain.
      expect(find.text('Browse Path'), findsNothing);
      expect(find.text('Quality'), findsNothing);
      final edit = find.byKey(const Key('edit_tag_Start_PB'));
      expect(edit, findsOneWidget);
      expect(tester.getRect(edit).right, lessThanOrEqualTo(900));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fit is content-measured: columns reappear as the pane grows',
        (tester) async {
      // (The test font renders every glyph a full em wide, so absolute widths
      // here are ~1.7x real rendering — assert the BEHAVIOR, not exact
      // breakpoints: mid width already readmits I/O Classification, and a
      // clearly-wide pane shows the full column set with actions intact.)
      final mimo = DefaultProjects.all().firstWhere((p) => p.id == 'proj_mimo_two_zone');
      await setSurface(tester, const Size(1300, 709));
      await tester.pumpWidget(app(mimo));
      await tester.pumpAndSettle();
      expect(find.text('I/O Classification'), findsOneWidget);
      expect(find.byKey(const Key('edit_tag_Heater_A')), findsOneWidget);

      await setSurface(tester, const Size(1800, 709));
      await tester.pumpWidget(app(mimo));
      await tester.pumpAndSettle();
      expect(find.text('Browse Path'), findsOneWidget);
      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('I/O Classification'), findsOneWidget);
      expect(find.byKey(const Key('edit_tag_Heater_A')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('table stretches to fill the pane (no dead space beside it)',
        (tester) async {
      final mimo = DefaultProjects.all().firstWhere((p) => p.id == 'proj_mimo_two_zone');
      await setSurface(tester, const Size(1300, 709));
      await tester.pumpWidget(app(mimo));
      await tester.pumpAndSettle();

      // Pane = window − 16px padding either side.
      final table = tester.getSize(find.byType(DataTable).first);
      expect(table.width, greaterThanOrEqualTo(1300 - 32 - 1));
      expect(tester.takeException(), isNull);
    });
  });
}
