import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/screens/simulated_io_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

// QA sweep item #2: at compact widths (mobile/tablet), the "Generate Test
// Set" + "Add Tag" floating action buttons on the Global Tags tab (and "Add
// DUT" on the Struct Definitions tab) float over the scrollable tag/DUT
// list. The screen already reserves bottom padding on the scroll view sized
// to clear the FAB cluster (see the "floating action" comments in
// memory_manager_screen.dart) so a card scrolled to the end of the list is
// never left permanently stuck behind the FABs. These tests lock that
// invariant in so it can't silently regress — computed from the FABs'
// actual rendered sizes rather than a hardcoded pixel count, so the
// assertion stays correct if the FAB styling ever changes.
//
// Confirmed live in a headless Playwright pass against the built web app at
// 390x844 and 768x1024 (scrolling the Global Tags tab to its end): the last
// card ("System") fully clears both FABs. Mid-scroll/initial-view transient
// overlap of non-terminal cards is inherent to any floating-button-over-
// scrollable-list pattern (the same as e.g. a chat app's compose FAB) and
// is not something trailing padding can address; eliminating it entirely
// would mean replacing the floating FABs with a pinned, non-overlapping
// surface, which is a larger UX change than this item's scope.

PlcProject _project() {
  final p = PlcProject(
    id: 'p1',
    name: 'Test Project',
    controllerName: 'c',
    tags: [
      PlcTag(name: 'Start_PB', path: 'Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
      PlcTag(name: 'Stop_PB', path: 'Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
    ],
    structDefs: [
      PlcStructDef(name: 'MyDut', fields: [
        StructFieldDef(name: 'f1', dataType: 'BOOL', defaultValue: false),
      ]),
    ],
    programs: [],
    tasks: [],
    hmis: [],
  );
  return p;
}

Widget _app(PlcProject project) => LiveTickScope(
      notifier: LiveTick(),
      child: MaterialApp(
        home: MemoryManagerScreen(
          currentProject: project,
          onProjectUpdated: () {},
          historian: TagHistorian(),
        ),
      ),
    );

void main() {
  const double fabGap = 12; // gap between the two stacked FABs (see build())
  const double fabMargin = 16; // Scaffold's default FAB-to-edge margin

  testWidgets(
      'Global Tags tab: bottom padding clears the two stacked FABs at compact width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(_project()));
    await tester.pumpAndSettle();

    final scrollView = tester.widget<SingleChildScrollView>(
      find.ancestor(
        of: find.text('HIERARCHICAL TAG DATABASE (TIMERS, STRUCTS & BITS)'),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    final bottomPadding = scrollView.padding!.resolve(TextDirection.ltr).bottom;

    final testSetFabHeight =
        tester.getSize(find.widgetWithText(FloatingActionButton, 'Generate Test Set')).height;
    final addTagFabHeight =
        tester.getSize(find.widgetWithText(FloatingActionButton, 'Add Tag')).height;
    final requiredClearance = testSetFabHeight + fabGap + addTagFabHeight + fabMargin;

    expect(bottomPadding, greaterThanOrEqualTo(requiredClearance),
        reason: 'Bottom padding ($bottomPadding) must reserve at least the '
            'FAB cluster\'s rendered height + gap + margin ($requiredClearance) '
            'so the last card can scroll clear of both FABs.');
  });

  testWidgets(
      'Struct Definitions tab: bottom padding clears the single Add DUT FAB at compact width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(_project()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Struct Definitions (DUT)'));
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    final bottomPadding = (listView.padding as EdgeInsets?)!.bottom;

    final addDutFabHeight =
        tester.getSize(find.widgetWithText(FloatingActionButton, 'Add DUT')).height;
    final requiredClearance = addDutFabHeight + fabMargin;

    expect(bottomPadding, greaterThanOrEqualTo(requiredClearance),
        reason: 'Bottom padding ($bottomPadding) must reserve at least the '
            'Add DUT FAB\'s rendered height + margin ($requiredClearance).');
  });

  testWidgets('the last tag card fully clears the FAB cluster once scrolled to the end',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Enough tags to force real scrolling on a compact viewport.
    final project = _project();
    for (var i = 0; i < 15; i++) {
      project.tags.add(PlcTag(
          name: 'Extra_$i', path: 'Extra_$i', dataType: 'BOOL', value: false, ioType: 'Internal'));
    }

    await tester.pumpWidget(_app(project));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(Key('edit_tag_${project.tags.last.name}')).first,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    final lastCardBottom = tester.getBottomLeft(find.byKey(Key('edit_tag_${project.tags.last.name}')).first).dy;
    final fabTop = tester.getTopLeft(find.widgetWithText(FloatingActionButton, 'Add Tag')).dy;

    expect(lastCardBottom, lessThanOrEqualTo(fabTop),
        reason: 'The last tag row must be fully above the FAB cluster once scrolled into view.');
  });

  testWidgets(
      'Simulated I/O has no floating action button over its rule list (no FAB-overlap pattern to fix here)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final project = _project();
    project.simRules.add(SimRule(
      id: 'sim0',
      name: 'Rule 1',
      targetPath: 'Start_PB',
      behavior: 'pulse',
      condition: const [],
    ));

    await tester.pumpWidget(MaterialApp(
      home: SimulatedIoScreen(currentProject: project, onProjectUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // "Add Rule" is an AppBar action, not a floating action button — so
    // there's no floating-over-scrollable-content pattern to reserve
    // padding for on this screen (QA #2's suggested sibling-screen check).
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
