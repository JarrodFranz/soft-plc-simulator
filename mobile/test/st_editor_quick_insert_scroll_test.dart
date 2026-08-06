// QA sweep item A3 (#8): the ST Editor's "QUICK INSERT" tag-chip row clipped
// at the right edge with no scroll affordance — chips beyond the visible
// width were reachable only by an undiscoverable drag. The row is now a
// SingleChildScrollView with an always-visible Scrollbar thumb.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/st_editor_screen.dart';

PlcProject _project() => DefaultProjects.all().first;

void main() {
  Widget app(PlcProject project) => MaterialApp(
        home: StEditorScreen(
          currentProject: project,
          onSaveProgram: (_, {bool notifyHost = true, String? previousName}) {},
        ),
      );

  testWidgets('QUICK INSERT row is a horizontally-scrollable SingleChildScrollView '
      'with an always-visible Scrollbar', (tester) async {
    await tester.pumpWidget(app(_project()));
    await tester.pumpAndSettle();

    final scrollViewFinder = find.ancestor(
      of: find.text('QUICK INSERT: '),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollViewFinder, findsOneWidget);
    final scrollView = tester.widget<SingleChildScrollView>(scrollViewFinder);
    expect(scrollView.scrollDirection, Axis.horizontal);

    final scrollbarFinder = find.ancestor(
      of: scrollViewFinder,
      matching: find.byType(Scrollbar),
    );
    expect(scrollbarFinder, findsOneWidget);
    final scrollbar = tester.widget<Scrollbar>(scrollbarFinder);
    expect(scrollbar.thumbVisibility, isTrue);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a quick-insert chip is still tappable and inserts into the code', (tester) async {
    await tester.pumpWidget(app(_project()));
    await tester.pumpAndSettle();

    final chipFinder = find.byType(ActionChip).first;
    expect(chipFinder, findsOneWidget);
    await tester.tap(chipFinder);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
