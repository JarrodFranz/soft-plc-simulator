// Regression coverage for task 3 of the UI-repaint-decoupling effort: the
// Tag Inspector dock's live-value cells must repaint on a bare `LiveTick`
// pulse, not only when an ancestor (the shell) setStates. Before this task,
// the dock read `tag.value`/`readPath` once per widget build, so a value
// mutated directly (as the scan loop does) never appeared until something
// else forced a full rebuild.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';

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
    PlcTag(name: 'Flag', path: 'Flag', dataType: 'BOOL', value: false, ioType: 'Internal'),
  );
  return proj;
}

Widget _harness(PlcProject project, LiveTick tick) {
  return LiveTickScope(
    notifier: tick,
    child: MaterialApp(
      home: Scaffold(
        body: TagInspectorDock(
          project: project,
          tags: project.tags,
          onTagStateChanged: () {},
          onClose: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'a bare LiveTick.pulse() (no ancestor rebuild) repaints the value cell with the mutated tag value',
      (tester) async {
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();
    final tag = project.tags.first;

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.text('false '), findsOneWidget);
    expect(find.text('true '), findsNothing);

    // Mutate the tag value directly -- the way the scan loop updates values
    // -- without going through setState on any ancestor.
    tag.value = true;

    // Without a pulse the stale value must still be showing.
    await tester.pump();
    expect(find.text('false '), findsOneWidget);
    expect(find.text('true '), findsNothing);

    // A bare pulse (no sentinel ancestor rebuild anywhere in this harness)
    // must repaint the value cell with the new value.
    tick.pulse();
    await tester.pump();

    expect(find.text('true '), findsOneWidget);
    expect(find.text('false '), findsNothing);
  });
}
