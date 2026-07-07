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
  });
}
