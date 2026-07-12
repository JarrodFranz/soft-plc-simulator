import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
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

  testWidgets('scalar tag row shows the Force control', (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    // 'Flag' is a scalar BOOL tag; its row should offer a Force toggle.
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Flag'),
          matching: find.byType(Card),
        ),
        matching: find.text('Force'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('composite tag row does not show the Force control', (tester) async {
    final project = _buildProject();
    await tester.pumpWidget(_harness(project));
    await tester.pumpAndSettle();

    // 'T1' is a TIMER (struct) tag whose value is a Map; forcing a composite
    // is ill-defined (readPath's force overlay ignores composites), so the
    // Force control must not be offerable for it.
    expect(project.tags.firstWhere((t) => t.name == 'T1').value, isA<Map>());
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('T1'),
          matching: find.byType(Card),
        ),
        matching: find.text('Force'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('T1'),
          matching: find.byType(Card),
        ),
        matching: find.text('Unforce'),
      ),
      findsNothing,
    );
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

  group('Reserved System tag protection', () {
    PlcProject buildSystemProject() {
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
      ensureSystemTag(proj);
      return proj;
    }

    testWidgets('System root row does not show the Force control', (tester) async {
      final project = buildSystemProject();
      await tester.pumpWidget(_harness(project));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.ancestor(of: find.text(kSystemTagName), matching: find.byType(Card)),
          matching: find.text('Force'),
        ),
        findsNothing,
      );
    });

    testWidgets('AlarmReset has a writable control; other System status fields do not', (tester) async {
      final project = buildSystemProject();
      await tester.pumpWidget(_harness(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('inspector-expand-$kSystemTagName')));
      await tester.pumpAndSettle();

      // AlarmReset gets a dedicated writable control...
      final writeKey = find.byKey(const ValueKey('inspector-write-System.AlarmReset'));
      expect(writeKey, findsOneWidget);

      // ...tapping it flips the underlying tag value. Scroll it into view
      // first: the SYSTEM composite has ~19 fields, so AlarmReset's row can
      // land below the dock's visible viewport once expanded.
      await tester.ensureVisible(writeKey);
      await tester.pumpAndSettle();
      expect(readPath(project, 'System.AlarmReset'), isFalse);
      await tester.tap(writeKey);
      await tester.pumpAndSettle();
      expect(readPath(project, 'System.AlarmReset'), isTrue);

      // A different BOOL status field has no writable control of its own.
      expect(find.text('.Running'), findsOneWidget);
      expect(find.byKey(const ValueKey('inspector-write-System.Running')), findsNothing);
    });
  });
}
