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
  });
}
