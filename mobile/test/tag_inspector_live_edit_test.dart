import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';

// A small project with scalar (non-BOOL) tags so live scalar-value editing in
// the Tag Inspector has something concrete to exercise, plus the reserved
// System tag to confirm it stays un-editable.
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
    PlcTag(
      name: 'Speed',
      path: 'Speed',
      dataType: 'FLOAT64',
      value: 12.5,
      defaultValue: 12.5,
      ioType: 'Internal',
    ),
    PlcTag(
      name: 'ForcedSpeed',
      path: 'ForcedSpeed',
      dataType: 'FLOAT64',
      value: 10.0,
      defaultValue: 10.0,
      ioType: 'Internal',
      isForced: true,
      forcedValue: 50.0,
    ),
  ]);
  ensureSystemTag(proj);
  return proj;
}

Widget _harness(PlcProject project) {
  return LiveTickScope(
    notifier: LiveTick(),
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
  testWidgets('tapping a numeric tag value pill opens an editor; confirming 80 sets value (unforced)',
      (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('inspector-value-Speed')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scalar_value_text_field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('scalar_value_text_field')), '80');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scalar_live_edit_ok')));
    await tester.pumpAndSettle();

    final tag = project.tags.firstWhere((t) => t.name == 'Speed');
    expect(tag.value, equals(80.0));
  });

  testWidgets('when the tag isForced, the same flow writes forcedValue, leaving value unchanged',
      (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('inspector-value-ForcedSpeed')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scalar_value_text_field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('scalar_value_text_field')), '80');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scalar_live_edit_ok')));
    await tester.pumpAndSettle();

    final tag = project.tags.firstWhere((t) => t.name == 'ForcedSpeed');
    expect(tag.forcedValue, equals(80.0));
    expect(tag.value, equals(10.0));
  });

  testWidgets('the reserved System tag pill does not open an editor', (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('inspector-value-$kSystemTagName')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scalar_value_text_field')), findsNothing);
    expect(find.byKey(const Key('scalar_live_edit_ok')), findsNothing);
  });
}
