import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'support/responsive_test_utils.dart';

// A small project with a couple of scalar tags so the default-value/edit
// flows have something concrete to exercise (mirrors memory_manager_test.dart).
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
  p.tags.add(PlcTag(
    name: 'Counter',
    path: 'Counter',
    dataType: 'INT16',
    value: 1,
    defaultValue: 1,
    ioType: 'Internal',
  ));
  return p;
}

void main() {
  Widget app(PlcProject project, {VoidCallback? onUpdated}) => LiveTickScope(
        notifier: LiveTick(),
        child: MaterialApp(
          home: MemoryManagerScreen(
            currentProject: project,
            onProjectUpdated: onUpdated ?? () {},
            historian: TagHistorian(),
          ),
        ),
      );

  Future<void> openEditDialogFor(WidgetTester tester, String tagName) async {
    final finder = find.byKey(Key('edit_tag_$tagName')).first;
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  // The edit dialog's content column can be taller than the fixed test
  // surface; scroll the target into view within the dialog before
  // interacting with it.
  Future<void> tapInDialog(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('Add Tag dialog — default value', () {
    testWidgets('typing a default of 5 into an INT16 tag sets defaultValue and value', (tester) async {
      final project = _project();
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Tag'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'NewInt');

      // Switch the type dropdown to INT16.
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('INT16').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('add_tag_default_field')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('scalar_value_text_field')), '5');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add Tag').last);
      await tester.pumpAndSettle();

      final tag = project.tags.firstWhere((t) => t.name == 'NewInt');
      expect(tag.defaultValue, equals(5));
      expect(tag.value, equals(5));
    });
  });

  group('Edit Tag Config dialog', () {
    testWidgets('changing default of an existing FLOAT64 tag to 80 saves, name/path unchanged', (tester) async {
      final project = _project();
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openEditDialogFor(tester, 'Speed');

      expect(find.byKey(const Key('edit_tag_dialog')), findsOneWidget);
      final valueField = find.byKey(const Key('scalar_value_text_field'));
      await tester.ensureVisible(valueField);
      await tester.pumpAndSettle();
      await tester.enterText(valueField, '80');
      await tester.pumpAndSettle();

      await tapInDialog(tester, find.byKey(const Key('edit_tag_save_button')));

      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      expect(tag.defaultValue, equals(80.0));
      expect(tag.name, equals('Speed'));
      expect(tag.path, equals('Speed'));
    });

    testWidgets('changing data type from INT16 to BOOL re-coerces the live value', (tester) async {
      final project = _project();
      // Give the live value a distinctive int so the coercion is observable.
      project.tags.firstWhere((t) => t.name == 'Counter').value = 1;
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openEditDialogFor(tester, 'Counter');

      await tapInDialog(tester, find.byKey(const Key('edit_tag_type_dropdown')));
      await tester.tap(find.text('BOOL').last);
      await tester.pumpAndSettle();

      await tapInDialog(tester, find.byKey(const Key('edit_tag_save_button')));

      final tag = project.tags.firstWhere((t) => t.name == 'Counter');
      expect(tag.dataType, equals('BOOL'));
      expect(tag.value, equals(true));
    });

    testWidgets('Reset live value to default clears force and resets value', (tester) async {
      final project = _project();
      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      tag.value = 999.0;
      tag.isForced = true;
      tag.forcedValue = 999.0;
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await openEditDialogFor(tester, 'Speed');

      await tapInDialog(tester, find.byKey(const Key('edit_tag_reset_button')));

      expect(tag.value, equals(tag.effectiveDefault(project)));
      expect(tag.isForced, isFalse);
    });

    testWidgets('the reserved System tag row shows no edit affordance', (tester) async {
      final project = _project();
      ensureSystemTag(project);
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('edit_tag_$kSystemTagName')), findsNothing);
    });

    testWidgets('no overflow at 320/360/1400 with the edit dialog open', (tester) async {
      for (final size in [smallPhoneSize, phoneSize, desktopSize]) {
        await setSurface(tester, size);
        final project = _project();
        await tester.pumpWidget(app(project));
        await tester.pumpAndSettle();

        await openEditDialogFor(tester, 'Speed');

        expect(tester.takeException(), isNull);

        // Dismiss for the next iteration.
        await tapInDialog(tester, find.text('Cancel'));
      }
    });
  });

  group('Live scalar value editing', () {
    // Locates the Live Value text within the tag's card so the tap targets
    // the value field itself, not the tag-name header or other fields.
    Finder liveValueTextFor(String tagName, String text) => find.descendant(
          of: find.ancestor(of: find.text(tagName), matching: find.byType(Card)).first,
          matching: find.text(text),
        );

    testWidgets("tapping a numeric tag's Live Value opens the editor; entering 80 writes value",
        (tester) async {
      final project = _project();
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      await tester.tap(liveValueTextFor('Speed', '12.5'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scalar_value_text_field')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('scalar_value_text_field')), '80');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('scalar_live_edit_ok')));
      await tester.pumpAndSettle();

      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      expect(tag.value, equals(80.0));
    });

    testWidgets("poking a FORCED root scalar writes forcedValue, leaving value unchanged",
        (tester) async {
      final project = _project();
      final tag = project.tags.firstWhere((t) => t.name == 'Speed');
      tag.isForced = true;
      tag.forcedValue = 70.0;
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      // The Memory Manager displays a forced root's live value as its `value`
      // (pre-existing `_liveValueFor` behavior), so the pill still shows 12.5.
      await tester.tap(liveValueTextFor('Speed', '12.5'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scalar_value_text_field')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('scalar_value_text_field')), '80');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('scalar_live_edit_ok')));
      await tester.pumpAndSettle();

      // The poke follows the force rule: forcedValue is updated, value untouched.
      expect(tag.forcedValue, equals(80.0));
      expect(tag.value, equals(12.5));
    });

    testWidgets("the reserved System tag's value is not editable", (tester) async {
      final project = _project();
      ensureSystemTag(project);
      await tester.pumpWidget(app(project));
      await tester.pumpAndSettle();

      final systemValueFinder = liveValueTextFor(kSystemTagName, '{...}');
      await tester.ensureVisible(systemValueFinder);
      await tester.pumpAndSettle();
      await tester.tap(systemValueFinder);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scalar_value_text_field')), findsNothing);
      expect(find.byKey(const Key('scalar_live_edit_ok')), findsNothing);
    });
  });
}
