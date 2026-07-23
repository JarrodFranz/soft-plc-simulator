import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'support/responsive_test_utils.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _buildProject() {
  return PlcProject(
    id: 'proj_test_fbd_naming',
    name: 'Test FBD Naming',
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

/// A single-network program with one operator (ADD) block — no TAG_*/CONST
/// blocks, so the only pre-existing pencil affordance (gated to those two
/// types) never applies here.
PlcProgram _operatorBlockProgram() {
  return PlcProgram(
    name: 'FBD_OP',
    language: 'FunctionBlockDiagram',
    fbdBlocks: [
      FbdBlock(id: 'add1', type: 'ADD', title: 'Adder', x: 100, y: 100, network: 0),
    ],
    fbdNetworks: [FbdNetwork(comment: '')],
  );
}

/// A two-network program with one block in network 0, used to exercise the
/// "Network" reassignment dropdown in the config dialog.
PlcProgram _twoNetworkProgram() {
  return PlcProgram(
    name: 'FBD_NET2',
    language: 'FunctionBlockDiagram',
    fbdBlocks: [
      FbdBlock(id: 'add1', type: 'ADD', title: 'Adder', x: 100, y: 100, network: 0),
    ],
    fbdNetworks: [FbdNetwork(comment: ''), FbdNetwork(comment: '')],
  );
}

Widget _app(PlcProject project, PlcProgram program, {VoidCallback? onUpdated}) {
  return MaterialApp(
    home: FbdEditorScreen(
      currentProject: project,
      program: program,
      onProgramUpdated: onUpdated ?? () {},
    ),
  );
}

void main() {
  group('FbdEditorScreen block naming — all types, desktop', () {
    testWidgets(
        'an operator (ADD) block is nameable on desktop: config dialog opens '
        'and Save renames the block face', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _operatorBlockProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      // No TAG_*/CONST pencil exists on an ADD block, so the only affordance
      // must be a generic edit affordance present for every block type.
      expect(find.byIcon(Icons.edit), findsOneWidget);

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      expect(find.text('Configure: Adder'), findsOneWidget);
      final nameField = find.widgetWithText(TextFormField, 'Block name');
      expect(nameField, findsOneWidget);

      await tester.enterText(nameField, 'My Adder');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      final block = program.fbdBlocks.firstWhere((b) => b.id == 'add1');
      expect(block.title, 'My Adder');
      expect(find.text('My Adder'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen block config — Network dropdown', () {
    testWidgets(
        'changing the Network dropdown reassigns the block via setBlockNetwork',
        (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      expect(program.fbdBlocks.first.network, 0);

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      final dropdownFinder = find.byKey(const Key('fbd_block_network_dropdown'));
      expect(dropdownFinder, findsOneWidget);

      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Network 2').last);
      await tester.pumpAndSettle();

      expect(program.fbdBlocks.first.network, 1);
      expect(tester.takeException(), isNull);
    });
  });
}
