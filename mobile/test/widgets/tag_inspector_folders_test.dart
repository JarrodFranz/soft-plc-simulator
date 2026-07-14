// Task 8 of the UI-repaint-decoupling effort: the Tag Inspector dock groups
// its tag rows by `PlcTag.folder`, matching the Memory Manager / protocol-map
// folder-grouping pattern (root tags first with no header, then each
// non-root folder alphabetically under a collapsible header). Live values
// inside an expanded folder must keep repainting on a bare `LiveTick.pulse()`
// (task 3's requirement), not just on an ancestor rebuild.
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
  proj.tags.addAll([
    PlcTag(name: 'RootFlag', path: 'RootFlag', dataType: 'BOOL', value: false, ioType: 'Internal'),
    PlcTag(
      name: 'Ramp1Speed',
      path: 'Ramp1Speed',
      dataType: 'BOOL',
      value: false,
      ioType: 'Internal',
      folder: 'ramp1',
    ),
    PlcTag(
      name: 'Ramp1Enable',
      path: 'Ramp1Enable',
      dataType: 'BOOL',
      value: false,
      ioType: 'Internal',
      folder: 'ramp1',
    ),
  ]);
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
  testWidgets('root tags render with no folder header', (tester) async {
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.text('RootFlag'), findsOneWidget);
    // Root ('') never gets a header widget: the folder-header key is scoped
    // by folder name, so an empty-string key would never be built anyway --
    // this just double-checks no stray header text renders for the root.
    expect(find.byKey(const ValueKey('inspector-folder-header-')), findsNothing);
  });

  testWidgets('non-root folder shows a collapsible header with its name', (tester) async {
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('inspector-folder-header-ramp1')), findsOneWidget);
    expect(find.text('ramp1'), findsOneWidget);
    expect(find.text('(2)'), findsOneWidget);
    // Default-expanded: both folder rows show.
    expect(find.text('Ramp1Speed'), findsOneWidget);
    expect(find.text('Ramp1Enable'), findsOneWidget);
  });

  testWidgets('tapping a folder header hides then re-shows its rows', (tester) async {
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.text('Ramp1Speed'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('inspector-folder-header-ramp1')));
    await tester.pumpAndSettle();

    expect(find.text('Ramp1Speed'), findsNothing);
    expect(find.text('Ramp1Enable'), findsNothing);
    // Header itself, root tags and count stay visible while collapsed.
    expect(find.byKey(const ValueKey('inspector-folder-header-ramp1')), findsOneWidget);
    expect(find.text('RootFlag'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('inspector-folder-header-ramp1')));
    await tester.pumpAndSettle();

    expect(find.text('Ramp1Speed'), findsOneWidget);
    expect(find.text('Ramp1Enable'), findsOneWidget);
  });

  testWidgets('a live value inside an expanded folder still updates on tick.pulse()', (tester) async {
    final tick = LiveTick();
    addTearDown(tick.dispose);
    final project = _buildProject();
    final foldered = project.tags.firstWhere((t) => t.name == 'Ramp1Speed');

    await tester.pumpWidget(_harness(project, tick));
    await tester.pumpAndSettle();

    expect(find.text('false '), findsNWidgets(3));

    // Mutate the foldered tag's value directly (as the scan loop does),
    // bypassing any ancestor setState.
    foldered.value = true;

    await tester.pump();
    expect(find.text('true '), findsNothing);

    tick.pulse();
    await tester.pump();

    expect(find.text('true '), findsOneWidget);
    expect(find.text('false '), findsNWidgets(2));
  });
}
