import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'support/responsive_test_utils.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _buildProject() {
  return PlcProject(
    id: 'proj_test_fbd_config_dialog',
    name: 'Test FBD Config Dialog',
    controllerName: 'TestPLC',
    tags: [
      _tag('Motor_Run', 'BOOL', false),
      _tag('Start_PB', 'BOOL', false),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
}

/// A single-network program with one EXTENSIBLE block (ADD, has the
/// "Inputs:" +/- row) — the block type that overflows at 320px.
PlcProgram _extensibleBlockProgram() {
  return PlcProgram(
    name: 'FBD_EXT',
    language: 'FunctionBlockDiagram',
    fbdBlocks: [
      FbdBlock(id: 'add1', type: 'ADD', title: 'Adder', x: 100, y: 100, network: 0),
    ],
    fbdNetworks: [FbdNetwork(comment: '')],
  );
}

/// A single-network program with one NON-extensible block (GT, no
/// "Inputs:" row) — the control case that must keep passing.
PlcProgram _nonExtensibleBlockProgram() {
  return PlcProgram(
    name: 'FBD_NONEXT',
    language: 'FunctionBlockDiagram',
    fbdBlocks: [
      FbdBlock(id: 'gt1', type: 'GT', title: 'Comparator', x: 100, y: 100, network: 0),
    ],
    fbdNetworks: [FbdNetwork(comment: '')],
  );
}

Widget _app(PlcProject project, PlcProgram program) {
  return MaterialApp(
    home: FbdEditorScreen(
      currentProject: project,
      program: program,
      onProgramUpdated: () {},
    ),
  );
}

void main() {
  group('FbdEditorScreen config dialog — 320px width, no overflow', () {
    testWidgets('EXTENSIBLE block (ADD, has Inputs: +/- row): config dialog opens with no overflow',
        (tester) async {
      await setSurface(tester, smallPhoneSize);
      final program = _extensibleBlockProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      // Not expanded at 320px, so tapping the block card itself (not an
      // Icons.edit affordance) opens the configure dialog.
      await tester.tap(find.text('Adder'));
      await tester.pumpAndSettle();

      expect(find.text('Configure: Adder'), findsOneWidget);
      expect(find.text('Inputs:'), findsOneWidget);

      // The layout fix must not break the +/- input-count control itself.
      // The block card behind the dialog has its own always-present (smaller)
      // Inputs +/- row, so scope the finder to the dialog's copy specifically.
      final before = program.fbdBlocks.first.inputCount;
      final dialogAddIcon = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byIcon(Icons.add_circle_outline),
      );
      expect(dialogAddIcon, findsOneWidget);
      await tester.tap(dialogAddIcon);
      await tester.pumpAndSettle();
      expect(program.fbdBlocks.first.inputCount, before + 1);

      expect(tester.takeException(), isNull);
    });

    testWidgets('NON-extensible block (GT, no Inputs: row): config dialog opens with no overflow',
        (tester) async {
      await setSurface(tester, smallPhoneSize);
      final program = _nonExtensibleBlockProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Comparator'));
      await tester.pumpAndSettle();

      expect(find.text('Configure: Comparator'), findsOneWidget);
      expect(find.text('Inputs:'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
