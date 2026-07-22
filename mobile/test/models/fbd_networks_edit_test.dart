import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_networks.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

/// Returns the (fromBlockId, toBlockId) pairs present in [p.fbdWires], in
/// list order, for easy set/list assertions without needing FbdWire `==`.
List<List<String>> _wirePairs(PlcProgram p) =>
    p.fbdWires.map((w) => [w.fromBlockId, w.toBlockId]).toList();

void main() {
  group('fbdBlocksInNetwork / addFbdNetwork', () {
    test('addFbdNetwork appends and returns the new index', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      expect(p.fbdNetworks, isEmpty);

      final idx0 = addFbdNetwork(p, comment: 'first');
      expect(idx0, 0);
      final idx1 = addFbdNetwork(p, comment: 'second');
      expect(idx1, 1);

      expect(p.fbdNetworks.length, 2);
      expect(p.fbdNetworks[0].comment, 'first');
      expect(p.fbdNetworks[1].comment, 'second');
    });

    test('fbdBlocksInNetwork filters by network index in list order', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p);
      addFbdNetwork(p);
      p.fbdBlocks.addAll([
        FbdBlock(id: 'a', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'b', type: 'OR', title: '', network: 1),
        FbdBlock(id: 'c', type: 'NOT', title: '', network: 0),
      ]);

      expect(fbdBlocksInNetwork(p, 0).map((b) => b.id).toList(), ['a', 'c']);
      expect(fbdBlocksInNetwork(p, 1).map((b) => b.id).toList(), ['b']);
      // Out-of-range net is a no-op / empty result, never throws.
      expect(fbdBlocksInNetwork(p, 5), isEmpty);
      expect(fbdBlocksInNetwork(p, -1), isEmpty);
    });
  });

  group('deleteFbdNetwork', () {
    PlcProgram buildThreeNetworkProgram() {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      addFbdNetwork(p, comment: 'N1');
      addFbdNetwork(p, comment: 'N2');
      p.fbdBlocks.addAll([
        FbdBlock(id: 'a1', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'a2', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'b1', type: 'OR', title: '', network: 1),
        FbdBlock(id: 'b2', type: 'OR', title: '', network: 1),
        FbdBlock(id: 'c1', type: 'NOT', title: '', network: 2),
        FbdBlock(id: 'c2', type: 'NOT', title: '', network: 2),
      ]);
      p.fbdWires.addAll([
        FbdWire(fromBlockId: 'a1', toBlockId: 'a2'),
        FbdWire(fromBlockId: 'b1', toBlockId: 'b2'),
        FbdWire(fromBlockId: 'c1', toBlockId: 'c2'),
      ]);
      return p;
    }

    test('deleteFbdNetwork(1) removes its blocks+wires and renumbers net 2 -> 1', () {
      final p = buildThreeNetworkProgram();

      deleteFbdNetwork(p, 1);

      // Header: 2 networks left, contiguous; old N2 is now at index 1.
      expect(p.fbdNetworks.length, 2);
      expect(p.fbdNetworks[0].comment, 'N0');
      expect(p.fbdNetworks[1].comment, 'N2');

      // Blocks: b1/b2 gone; a1/a2 stay at network 0; c1/c2 renumbered to 1.
      expect(p.fbdBlocks.length, 4);
      expect(p.fbdBlocks.map((b) => b.id).toSet(), {'a1', 'a2', 'c1', 'c2'});
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'a1').network, 0);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'a2').network, 0);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'c1').network, 1);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'c2').network, 1);

      // Wires: the b1->b2 wire is gone with its blocks; the others remain.
      expect(p.fbdWires.length, 2);
      expect(_wirePairs(p), [
        ['a1', 'a2'],
        ['c1', 'c2'],
      ]);
    });

    test('deleteFbdNetwork with out-of-range index is a no-op', () {
      final p = buildThreeNetworkProgram();
      final blocksBefore = p.fbdBlocks.length;
      final wiresBefore = p.fbdWires.length;
      final networksBefore = p.fbdNetworks.length;

      deleteFbdNetwork(p, 5);
      deleteFbdNetwork(p, -1);

      expect(p.fbdBlocks.length, blocksBefore);
      expect(p.fbdWires.length, wiresBefore);
      expect(p.fbdNetworks.length, networksBefore);
    });
  });

  group('moveFbdNetwork', () {
    test('moveFbdNetwork(2, 0) moves header to front and rewrites block network indices', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      addFbdNetwork(p, comment: 'N1');
      addFbdNetwork(p, comment: 'N2');
      p.fbdBlocks.addAll([
        FbdBlock(id: 'a1', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'a2', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'b1', type: 'OR', title: '', network: 1),
        FbdBlock(id: 'b2', type: 'OR', title: '', network: 1),
        FbdBlock(id: 'c1', type: 'NOT', title: '', network: 2),
        FbdBlock(id: 'c2', type: 'NOT', title: '', network: 2),
      ]);
      p.fbdWires.addAll([
        FbdWire(fromBlockId: 'a1', toBlockId: 'a2'),
        FbdWire(fromBlockId: 'b1', toBlockId: 'b2'),
        FbdWire(fromBlockId: 'c1', toBlockId: 'c2'),
      ]);

      moveFbdNetwork(p, 2, 0);

      // Header reordered: old N2, N0, N1.
      expect(p.fbdNetworks.map((n) => n.comment).toList(), ['N2', 'N0', 'N1']);

      // Moved network's blocks (c1/c2) are now network 0; others shift down.
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'c1').network, 0);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'c2').network, 0);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'a1').network, 1);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'a2').network, 1);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'b1').network, 2);
      expect(p.fbdBlocks.firstWhere((b) => b.id == 'b2').network, 2);

      // Wires travel with their (whole-network) blocks: still 3, all intact,
      // since a whole network always moves together (no cross-network wire
      // is ever created by a move).
      expect(p.fbdWires.length, 3);
      expect(_wirePairs(p), [
        ['a1', 'a2'],
        ['b1', 'b2'],
        ['c1', 'c2'],
      ]);
    });

    test('moveFbdNetwork with out-of-range from/to is a no-op', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      addFbdNetwork(p, comment: 'N1');
      p.fbdBlocks.add(FbdBlock(id: 'a', type: 'AND', title: '', network: 0));

      moveFbdNetwork(p, 5, 0);
      moveFbdNetwork(p, 0, -1);

      expect(p.fbdNetworks.map((n) => n.comment).toList(), ['N0', 'N1']);
      expect(p.fbdBlocks.first.network, 0);
    });

    test('moveFbdNetwork(from, from) is a no-op', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      addFbdNetwork(p, comment: 'N1');
      p.fbdBlocks.add(FbdBlock(id: 'a', type: 'AND', title: '', network: 1));

      moveFbdNetwork(p, 1, 1);

      expect(p.fbdNetworks.map((n) => n.comment).toList(), ['N0', 'N1']);
      expect(p.fbdBlocks.first.network, 1);
    });
  });

  group('setBlockNetwork', () {
    test('reassigning one block prunes the wire it had to a block left behind, '
        'but leaves other blocks/wires already together untouched', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      addFbdNetwork(p, comment: 'N1');
      p.fbdBlocks.addAll([
        FbdBlock(id: 'a', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'b', type: 'OR', title: '', network: 0),
        FbdBlock(id: 'd', type: 'NOT', title: '', network: 1),
        FbdBlock(id: 'e', type: 'NOT', title: '', network: 1),
      ]);
      p.fbdWires.addAll([
        FbdWire(fromBlockId: 'a', toBlockId: 'b'), // intra net 0 (for now)
        FbdWire(fromBlockId: 'd', toBlockId: 'e'), // intra net 1, untouched
      ]);

      setBlockNetwork(p, 'b', 1);

      expect(p.fbdBlocks.firstWhere((b) => b.id == 'b').network, 1);
      // a-b is now cross-network (a stays in net 0) -> pruned.
      // d-e was never touched by this reassignment -> stays.
      expect(_wirePairs(p), [
        ['d', 'e'],
      ]);
    });

    test('setBlockNetwork with unknown blockId is a no-op', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      p.fbdBlocks.add(FbdBlock(id: 'a', type: 'AND', title: '', network: 0));

      setBlockNetwork(p, 'nope', 0);

      expect(p.fbdBlocks.first.network, 0);
    });

    test('setBlockNetwork with out-of-range net is a no-op', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      p.fbdBlocks.add(FbdBlock(id: 'a', type: 'AND', title: '', network: 0));

      setBlockNetwork(p, 'a', 7);

      expect(p.fbdBlocks.first.network, 0);
    });
  });

  group('pruneCrossNetworkWires', () {
    test('removes only cross-network wires, keeps intra-network ones; idempotent', () {
      final p = PlcProgram(name: 'P', language: 'FunctionBlockDiagram');
      addFbdNetwork(p, comment: 'N0');
      addFbdNetwork(p, comment: 'N1');
      p.fbdBlocks.addAll([
        FbdBlock(id: 'a', type: 'AND', title: '', network: 0),
        FbdBlock(id: 'b', type: 'OR', title: '', network: 0),
        FbdBlock(id: 'c', type: 'NOT', title: '', network: 1),
        FbdBlock(id: 'd', type: 'NOT', title: '', network: 1),
      ]);
      p.fbdWires.addAll([
        FbdWire(fromBlockId: 'a', toBlockId: 'b'), // intra net 0
        FbdWire(fromBlockId: 'c', toBlockId: 'd'), // intra net 1
        FbdWire(fromBlockId: 'a', toBlockId: 'c'), // cross
        FbdWire(fromBlockId: 'b', toBlockId: 'd'), // cross
      ]);

      pruneCrossNetworkWires(p);

      expect(_wirePairs(p), [
        ['a', 'b'],
        ['c', 'd'],
      ]);

      // Idempotent: running it again changes nothing further.
      pruneCrossNetworkWires(p);
      expect(_wirePairs(p), [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });
  });
}
