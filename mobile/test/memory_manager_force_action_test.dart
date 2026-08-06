import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

// QA sweep item #4: Force/Unforce used to be reachable only from the Tag
// Inspector dock. These tests cover the two new surfaces added in this
// batch: the Tags & Structs table/card row action, and the Edit Tag dialog
// -- both delegating to the same `PlcTag.toggleForce()` the inspector uses.

PlcProject _project() {
  final p = PlcProject(
    id: 'p1',
    name: 'Test Project',
    controllerName: 'c',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  p.tags.add(PlcTag(
    name: 'Speed',
    path: 'Speed',
    dataType: 'FLOAT64',
    value: 12.5,
    defaultValue: 12.5,
    ioType: 'Internal',
  ));
  return p;
}

Widget _app(PlcProject project, {VoidCallback? onUpdated}) => LiveTickScope(
      notifier: LiveTick(),
      child: MaterialApp(
        home: MemoryManagerScreen(
          currentProject: project,
          onProjectUpdated: onUpdated ?? () {},
          historian: TagHistorian(),
        ),
      ),
    );

void main() {
  group('Tags & Structs table row — Force action (desktop width)', () {
    testWidgets('tapping the force icon toggles isForced on and off',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _project();
      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      var updates = 0;
      await tester.pumpWidget(_app(project, onUpdated: () => updates++));
      await tester.pumpAndSettle();

      final forceKey = find.byKey(const Key('force_tag_Speed'));
      expect(forceKey, findsOneWidget);
      expect(tag.isForced, isFalse);

      await tester.tap(forceKey);
      await tester.pumpAndSettle();

      expect(tag.isForced, isTrue);
      expect(updates, greaterThan(0));
      // Forced indicator now shown on the row.
      expect(find.byTooltip('Forced'), findsOneWidget);

      await tester.tap(find.byKey(const Key('force_tag_Speed')));
      await tester.pumpAndSettle();

      expect(tag.isForced, isFalse);
      expect(find.byTooltip('Forced'), findsNothing);
    });

    testWidgets('forcing seeds forcedValue from the current value',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _project();
      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      await tester.pumpWidget(_app(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('force_tag_Speed')));
      await tester.pumpAndSettle();

      expect(tag.isForced, isTrue);
      expect(tag.forcedValue, equals(12.5));
    });
  });

  group('Tags & Structs card row — Force action (compact width)', () {
    testWidgets('tapping the force icon toggles isForced on the mobile card',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _project();
      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      await tester.pumpWidget(_app(project));
      await tester.pumpAndSettle();

      final forceKey = find.byKey(const Key('force_tag_Speed'));
      expect(forceKey, findsOneWidget);

      await tester.tap(forceKey);
      await tester.pumpAndSettle();

      expect(tag.isForced, isTrue);
      expect(find.byTooltip('Forced'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  });

  group('Edit Tag dialog — Force/Unforce', () {
    testWidgets('the Force button toggles isForced and its own label',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _project();
      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      var updates = 0;
      await tester.pumpWidget(_app(project, onUpdated: () => updates++));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('edit_tag_Speed')).first);
      await tester.pumpAndSettle();

      final forceButton = find.byKey(const Key('edit_tag_force_button'));
      expect(forceButton, findsOneWidget);
      expect(find.descendant(of: forceButton, matching: find.text('Force')),
          findsOneWidget);

      await tester.tap(forceButton);
      await tester.pumpAndSettle();

      expect(tag.isForced, isTrue);
      expect(tag.forcedValue, equals(12.5));
      expect(updates, greaterThan(0));
      expect(find.descendant(of: forceButton, matching: find.text('Unforce')),
          findsOneWidget);

      await tester.tap(forceButton);
      await tester.pumpAndSettle();

      expect(tag.isForced, isFalse);
      expect(find.descendant(of: forceButton, matching: find.text('Force')),
          findsOneWidget);
    });

    testWidgets('no Force button for a composite (struct) tag', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final project = _project();
      project.tags.add(PlcTag(
        name: 'Timer1',
        path: 'Timer1',
        dataType: 'TIMER',
        value: {'PT': 1000, 'ET': 0, 'Q': false, 'EN': false},
        ioType: 'Internal',
      ));
      await tester.pumpWidget(_app(project));
      await tester.pumpAndSettle();

      // The table/card row itself must not offer Force for a composite tag.
      expect(find.byKey(const Key('force_tag_Timer1')), findsNothing);

      await tester.tap(find.byKey(const Key('edit_tag_Timer1')).first);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('edit_tag_force_button')), findsNothing);
    });
  });
}
