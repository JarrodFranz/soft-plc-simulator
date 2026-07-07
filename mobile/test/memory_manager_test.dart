import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';

// A small project with one in-use DUT (PumpStatusDUT, referenced by tag P1)
// and one unused DUT (SpareDUT) so both delete-guard branches are exercised.
PlcProject _project() {
  final structDefs = [
    PlcStructDef(name: 'PumpStatusDUT', fields: [
      StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
    ]),
    PlcStructDef(name: 'SpareDUT', fields: [
      StructFieldDef(name: 'Value', dataType: 'INT32', defaultValue: 0),
    ]),
  ];
  final p = PlcProject(
    id: 'p1',
    name: 'Test Project',
    controllerName: 'c',
    tags: [],
    structDefs: structDefs,
    programs: [],
    tasks: [],
    hmis: [],
  );
  p.tags.add(PlcTag(
    name: 'P1',
    path: 'P1',
    dataType: 'PumpStatusDUT',
    value: defaultValueFor(p, 'PumpStatusDUT', 0),
    ioType: 'Internal',
  ));
  return p;
}

void main() {
  Widget app(PlcProject project, {VoidCallback? onUpdated}) => MaterialApp(
        home: MemoryManagerScreen(
          currentProject: project,
          onProjectUpdated: onUpdated ?? () {},
        ),
      );

  Future<void> goToStructTab(WidgetTester tester) async {
    await tester.tap(find.text('Struct Definitions (DUT)'));
    await tester.pumpAndSettle();
  }

  group('Struct Definitions (DUT) tab', () {
    testWidgets('Add DUT FAB appends a new struct definition', (tester) async {
      final project = _project();
      int updates = 0;
      await tester.pumpWidget(app(project, onUpdated: () => updates++));
      await goToStructTab(tester);

      expect(find.text('Add DUT'), findsOneWidget);
      await tester.tap(find.text('Add DUT'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'NewDUT');
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();

      expect(project.structDefs.any((s) => s.name == 'NewDUT'), isTrue);
      expect(updates, greaterThan(0));
      expect(find.text('NewDUT'), findsOneWidget);
    });

    testWidgets('delete of an in-use DUT is blocked with a message', (tester) async {
      final project = _project();
      await tester.pumpWidget(app(project));
      await goToStructTab(tester);

      final pumpCard = find.ancestor(
        of: find.text('PumpStatusDUT'),
        matching: find.byType(Card),
      );
      final deleteIcon = find.descendant(of: pumpCard, matching: find.byIcon(Icons.delete));
      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      expect(find.textContaining('use', findRichText: false), findsWidgets);
      expect(project.structDefs.any((s) => s.name == 'PumpStatusDUT'), isTrue);

      // Dismiss the blocking dialog.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    });

    testWidgets('delete of an unused DUT removes it', (tester) async {
      final project = _project();
      int updates = 0;
      await tester.pumpWidget(app(project, onUpdated: () => updates++));
      await goToStructTab(tester);

      final spareCard = find.ancestor(
        of: find.text('SpareDUT'),
        matching: find.byType(Card),
      );
      final deleteIcon = find.descendant(of: spareCard, matching: find.byIcon(Icons.delete));
      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      // Confirm the delete dialog.
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(project.structDefs.any((s) => s.name == 'SpareDUT'), isFalse);
      expect(updates, greaterThan(0));
    });

    testWidgets('edit dialog renames the DUT and can add/remove a field', (tester) async {
      final project = _project();
      await tester.pumpWidget(app(project));
      await goToStructTab(tester);

      final spareCard = find.ancestor(
        of: find.text('SpareDUT'),
        matching: find.byType(Card),
      );
      final editIcon = find.descendant(of: spareCard, matching: find.byIcon(Icons.edit));
      await tester.tap(editIcon);
      await tester.pumpAndSettle();

      // Rename via the name field (first TextField in the dialog).
      final nameField = find.byType(TextField).first;
      await tester.enterText(nameField, 'RenamedDUT');
      await tester.pumpAndSettle();

      // Add a field.
      final fieldsBefore = project.structDefs.firstWhere((s) => s.name == 'SpareDUT').fields.length;
      await tester.tap(find.text('Add Field'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final renamed = project.structDefs.firstWhere((s) => s.name == 'RenamedDUT');
      expect(renamed.fields.length, equals(fieldsBefore + 1));
      expect(project.structDefs.any((s) => s.name == 'SpareDUT'), isFalse);
    });

    testWidgets('edit dialog remove field decreases the field count', (tester) async {
      final project = _project();
      project.structDefs.add(PlcStructDef(name: 'TwoFieldDUT', fields: [
        StructFieldDef(name: 'A', dataType: 'BOOL', defaultValue: false),
        StructFieldDef(name: 'B', dataType: 'INT32', defaultValue: 0),
      ]));
      await tester.pumpWidget(app(project));
      await goToStructTab(tester);

      final card = find.ancestor(
        of: find.text('TwoFieldDUT'),
        matching: find.byType(Card),
      );
      final editIcon = find.descendant(of: card, matching: find.byIcon(Icons.edit));
      await tester.tap(editIcon);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.remove_circle), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.remove_circle).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = project.structDefs.firstWhere((s) => s.name == 'TwoFieldDUT');
      expect(saved.fields.length, equals(1));
    });

    testWidgets('retyping a field resets its stale default value', (tester) async {
      final project = _project();
      project.structDefs.add(PlcStructDef(name: 'RetypeDUT', fields: [
        StructFieldDef(name: 'Flag', dataType: 'BOOL', defaultValue: false),
      ]));
      await tester.pumpWidget(app(project));
      await goToStructTab(tester);

      final card = find.ancestor(
        of: find.text('RetypeDUT'),
        matching: find.byType(Card),
      );
      final editIcon = find.descendant(of: card, matching: find.byIcon(Icons.edit));
      await tester.tap(editIcon);
      await tester.pumpAndSettle();

      // Change the field's data type dropdown from BOOL to INT32.
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('INT32').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = project.structDefs.firstWhere((s) => s.name == 'RetypeDUT');
      final field = saved.fields.first;
      expect(field.dataType, equals('INT32'));
      // The instantiated default for the retyped field must match its new
      // type (int 0), not the stale BOOL default (false).
      final resolved = field.defaultValue ?? defaultValueFor(project, field.dataType, field.arrayLength);
      expect(resolved, isA<int>());
      expect(resolved, equals(0));
    });

    testWidgets('edit dialog excludes the struct being edited from its own field-type options', (tester) async {
      final project = _project();
      await tester.pumpWidget(app(project));
      await goToStructTab(tester);

      final card = find.ancestor(
        of: find.text('SpareDUT'),
        matching: find.byType(Card),
      );
      final editIcon = find.descendant(of: card, matching: find.byIcon(Icons.edit));
      await tester.tap(editIcon);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();

      // 'SpareDUT' (the struct currently being edited) must not be offered
      // as a field type for its own fields, to prevent a self-referencing
      // (infinitely recursive) DUT. The only legitimate remaining
      // occurrences are the struct-list card label behind the dialog and
      // the dialog's own "DUT Name" field content — not a dropdown option.
      expect(find.text('SpareDUT'), findsNWidgets(2));
      // Other DUTs remain available.
      expect(find.text('PumpStatusDUT'), findsWidgets);
    });
  });
}
