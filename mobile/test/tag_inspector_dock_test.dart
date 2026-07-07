import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';
import 'support/responsive_test_utils.dart';

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
      name: 'T1',
      path: 'T1',
      dataType: 'TIMER',
      value: defaultValueFor(proj, 'TIMER', 0),
      ioType: 'Internal',
    ),
    PlcTag(name: 'Flag', path: 'Flag', dataType: 'BOOL', value: false, ioType: 'Internal'),
  ]);
  return proj;
}

Widget _harness(PlcProject project) {
  return MaterialApp(
    home: Scaffold(
      body: TagInspectorDock(
        project: project,
        tags: project.tags,
        onTagStateChanged: () {},
        onClose: () {},
      ),
    ),
  );
}

void main() {
  testWidgets('composite tag shows an expand chevron; scalar tag does not', (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('inspector-expand-T1')), findsOneWidget);
    expect(find.byKey(const ValueKey('inspector-expand-Flag')), findsNothing);
  });

  testWidgets('tapping the chevron reveals live child values', (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    expect(find.text('.EN'), findsNothing);
    expect(find.text('.DN'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('inspector-expand-T1')));
    await tester.pumpAndSettle();

    expect(find.text('.EN'), findsOneWidget);
    expect(find.text('.DN'), findsOneWidget);
    expect(find.text('false'), findsWidgets);
  });

  for (final size in const [smallPhoneSize, phoneSize, desktopSize]) {
    testWidgets('no overflow at ${size.width.toInt()}px with an expanded composite tag',
        (tester) async {
      await setSurface(tester, size);
      final project = _buildProject();
      await tester.pumpWidget(_harness(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('inspector-expand-T1')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
