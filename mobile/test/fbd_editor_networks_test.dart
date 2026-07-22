import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'support/responsive_test_utils.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _buildProject() {
  return PlcProject(
    id: 'proj_test_fbd_nets',
    name: 'Test FBD Networks',
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

/// A program with two distinct networks, two blocks each.
PlcProgram _twoNetworkProgram() {
  return PlcProgram(
    name: 'FBD2',
    language: 'FunctionBlockDiagram',
    fbdBlocks: [
      FbdBlock(id: 'n0a', type: 'TAG_INPUT', title: 'In A', tagBinding: 'Start_PB', x: 40, y: 40, network: 0),
      FbdBlock(id: 'n0b', type: 'TAG_OUTPUT', title: 'Out A', tagBinding: 'Motor_Run', x: 320, y: 40, network: 0),
      FbdBlock(id: 'n1a', type: 'TAG_INPUT', title: 'In B', tagBinding: 'Start_PB', x: 40, y: 40, network: 1),
      FbdBlock(id: 'n1b', type: 'TAG_OUTPUT', title: 'Out B', tagBinding: 'Motor_Run', x: 320, y: 40, network: 1),
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
  group('FbdEditorScreen network lanes', () {
    testWidgets('renders one lane header per network with 1-based labels', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fbd_network_header_0')), findsOneWidget);
      expect(find.byKey(const Key('fbd_network_header_1')), findsOneWidget);
      expect(find.text('Network 1'), findsOneWidget);
      expect(find.text('Network 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('+ Network button appends a third network lane', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      var notified = false;
      await tester.pumpWidget(_app(_buildProject(), program, onUpdated: () => notified = true));
      await tester.pumpAndSettle();

      expect(program.fbdNetworks.length, 2);
      await tester.tap(find.byKey(const Key('fbd_add_network')));
      await tester.pumpAndSettle();

      expect(program.fbdNetworks.length, 3);
      expect(find.text('Network 3'), findsOneWidget);
      expect(notified, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('delete (confirmed) removes the lane, its blocks, and renumbers', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fbd_net_del_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fbd_net_del_confirm')));
      await tester.pumpAndSettle();

      expect(program.fbdNetworks.length, 1);
      expect(find.text('Network 2'), findsNothing);
      expect(find.text('Network 1'), findsOneWidget);
      // The deleted network's blocks are gone; the survivors stay in network 0.
      expect(program.fbdBlocks.any((b) => b.id == 'n1a'), isFalse);
      expect(program.fbdBlocks.any((b) => b.id == 'n1b'), isFalse);
      expect(program.fbdBlocks.every((b) => b.network == 0), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing a network comment persists to the model', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('fbd_network_comment_0')), 'Interlock rung');
      await tester.pumpAndSettle();

      expect(program.fbdNetworks[0].comment, 'Interlock rung');
      expect(tester.takeException(), isNull);
    });

    testWidgets('move-up reorders networks and rewrites block network indices', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fbd_net_up_1')));
      await tester.pumpAndSettle();

      // The old network-1 blocks are now network 0, old network-0 blocks are 1.
      expect(program.fbdBlocks.firstWhere((b) => b.id == 'n1a').network, 0);
      expect(program.fbdBlocks.firstWhere((b) => b.id == 'n0a').network, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adding a block from a lane assigns it that lane network', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      final before = program.fbdBlocks.length;
      // Open lane 1's add-block palette and add the first palette item.
      await tester.tap(find.byKey(const Key('fbd_net_addblock_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();

      expect(program.fbdBlocks.length, before + 1);
      expect(program.fbdBlocks.last.network, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone (320): stacked lanes render without overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fbd_network_header_0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'tapping an output pin in network 0 then an input pin in network 1 '
        'creates NO wire (cross-network wiring is blocked at the tap path)',
        (tester) async {
      await setSurface(tester, desktopSize);
      final program = _twoNetworkProgram();
      await tester.pumpWidget(_app(_buildProject(), program));
      await tester.pumpAndSettle();

      expect(program.fbdWires, isEmpty);

      // Arm network 0's TAG_INPUT output pin (n0a -> OUT) via the real
      // _onOutputTap path, exactly like the same-network wiring tests in
      // fbd_editor_test.dart.
      await tester.tap(find.byKey(const Key('fbdpin_n0a_out_OUT')));
      await tester.pumpAndSettle();

      // Then tap network 1's TAG_OUTPUT input pin (n1b -> IN) via the real
      // _onInputTap -> _completeWire path. n0a and n1b live in different
      // networks, so the guard at fbd_editor_screen.dart's _completeWire
      // (fromBlock.network != toBlock.network) must reject this — the same
      // choke point that keeps runtime cross-network wires from ever being
      // drawable in the first place.
      await tester.tap(find.byKey(const Key('fbdpin_n1b_in_IN')));
      await tester.pumpAndSettle();

      expect(program.fbdWires, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
