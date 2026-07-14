// Regression coverage for task 4 of the UI-repaint-decoupling effort: the
// Memory Manager's "Live Value" cells (both the desktop DataTable and the
// compact card list) must repaint on a bare `LiveTick` pulse, not only when
// an ancestor (the shell) setStates. Before this task, each row's value was
// captured once per widget build via `_buildRowData`, so a value mutated
// directly (as the scan loop does) never appeared until something else
// forced a full rebuild.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import '../support/responsive_test_utils.dart';

PlcProject _buildProject() {
  final proj = PlcProject(
    id: 'p',
    name: 'p',
    controllerName: 'c',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  proj.tags.add(
    PlcTag(name: 'Counter', path: 'Counter', dataType: 'INT32', value: 1, ioType: 'Internal'),
  );
  return proj;
}

Widget _harness(PlcProject project, LiveTick tick) {
  return LiveTickScope(
    notifier: tick,
    child: MaterialApp(
      home: MemoryManagerScreen(
        currentProject: project,
        onProjectUpdated: () {},
        historian: TagHistorian(),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'desktop DataTable: a bare LiveTick.pulse() (no ancestor rebuild) repaints the Live Value cell',
      (tester) async {
    await setSurface(tester, desktopSize);
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();
    final tag = project.tags.first;

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('42'), findsNothing);

    // Mutate the tag value directly -- the way the scan loop updates values
    // -- without going through setState on any ancestor.
    tag.value = 42;

    // Without a pulse the stale value must still be showing.
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('42'), findsNothing);

    // A bare pulse (no sentinel ancestor rebuild anywhere in this harness)
    // must repaint the Live Value cell with the new value.
    tick.pulse();
    await tester.pump();

    expect(find.text('42'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });

  testWidgets(
      'compact card list: a bare LiveTick.pulse() (no ancestor rebuild) repaints the Live Value cell',
      (tester) async {
    await setSurface(tester, phoneSize);
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();
    final tag = project.tags.first;

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('42'), findsNothing);

    tag.value = 42;

    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('42'), findsNothing);

    tick.pulse();
    await tester.pump();

    expect(find.text('42'), findsOneWidget);
    expect(find.text('1'), findsNothing);
  });
}
