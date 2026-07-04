import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';

LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

void main() {
  test('buildRung wires a series main line rail-to-rail', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    // left rail feeds first element; coil feeds right rail
    expect(r.wires.any((w) => w.fromId == left.id), isTrue);
    expect(r.wires.any((w) => w.toId == right.id), isTrue);
    // every non-rail node has an inbound and outbound wire
    for (final n in r.nodes.where((n) =>
        n.kind != LdKind.leftRail && n.kind != LdKind.rightRail)) {
      expect(r.wires.any((w) => w.toId == n.id), isTrue);
      expect(r.wires.any((w) => w.fromId == n.id), isTrue);
    }
  });

  test('colAssignment increments along a series chain', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final col = colAssignment(r);
    final ids = r.nodes.where((n) => n.kind == LdKind.contact || n.kind == LdKind.coil).toList();
    final a = ids.firstWhere((n) => n.variable == 'A');
    final b = ids.firstWhere((n) => n.variable == 'B');
    final y = ids.firstWhere((n) => n.variable == 'Y');
    expect(col[a.id]! < col[b.id]!, isTrue);
    expect(col[b.id]! < col[y.id]!, isTrue);
    // right rail sits at the last column
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    expect(col[right.id], equals(col.values.reduce((x, z) => x > z ? x : z)));
  });

  test('buildRung branch parallels a span on a new lane', () {
    final r = buildRung(
      index: 0,
      main: [contact('Start'), contact('Stop'), coil('Motor')],
      branches: [BranchSpec(startIndex: 0, endIndex: 0, nodes: [contact('Seal')])],
    );
    final seal = r.nodes.firstWhere((n) => n.variable == 'Seal');
    expect(seal.row, equals(1));
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    // seal taps off the left rail (predecessor of Start) and merges into Stop
    final stop = r.nodes.firstWhere((n) => n.variable == 'Stop');
    expect(r.wires.any((w) => w.fromId == left.id && w.toId == seal.id), isTrue);
    expect(r.wires.any((w) => w.fromId == seal.id && w.toId == stop.id), isTrue);
  });

  test('addParallelBranch adds a lane and OR-converges', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final before = maxLane(r);
    final br = addParallelBranch(r, a, a);
    expect(maxLane(r), equals(before + 1));
    expect(br.lane, equals(before + 1));
    // new branch node exists on the new lane
    expect(r.nodes.any((n) => n.row == br.lane), isTrue);
  });

  test('moveBranchMerge re-points the branch end', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final y = r.nodes.firstWhere((n) => n.variable == 'Y');
    final br = addParallelBranch(r, a, a); // merges into B initially
    moveBranchMerge(r, br, y);
    final last = br.lastNodeId;
    expect(r.wires.any((w) => w.fromId == last && w.toId == y.id), isTrue);
    expect(r.wires.any((w) => w.fromId == last && w.toId == b.id), isFalse);
  });

  test('insertContactOnWire splits the wire in series', () {
    final r = buildRung(index: 0, main: [contact('A'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final wire = r.wires.firstWhere((w) => w.fromId == a.id);
    final destBefore = wire.toId;
    final n = LdNode(id: newNodeId(r), kind: LdKind.contact, variable: 'C');
    insertContactOnWire(r, wire, n);
    expect(wire.toId, equals(n.id));                 // A -> C
    expect(r.wires.any((w) => w.fromId == n.id && w.toId == destBefore), isTrue); // C -> Y
  });

  test('deleteNode heals the series wires', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final y = r.nodes.firstWhere((n) => n.variable == 'Y');
    deleteNode(r, b);
    expect(r.nodes.contains(b), isFalse);
    expect(r.wires.any((w) => w.fromId == a.id && w.toId == y.id), isTrue);
  });

  test('deleteNode drops a sole-node branch without creating a bypass jumper', () {
    final r = buildRung(
      index: 0,
      main: [contact('Start'), contact('Stop'), coil('Y')],
      branches: [BranchSpec(startIndex: 0, endIndex: 0, nodes: [contact('Seal')])],
    );
    final seal = r.nodes.firstWhere((n) => n.variable == 'Seal');
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    final stop = r.nodes.firstWhere((n) => n.variable == 'Stop');
    deleteNode(r, seal);
    expect(r.wires.any((w) => w.fromId == left.id && w.toId == stop.id), isFalse);
    expect(r.nodes.any((n) => n.row == 1), isFalse);
  });

  test('moveBranchTap re-points the branch start wire', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final br = addParallelBranch(r, a, a); // taps at left rail initially
    moveBranchTap(r, br, a);
    expect(r.wires.any((w) => w.fromId == a.id && w.toId == br.firstNodeId), isTrue);
  });

  test('findBranches reports each branch lane once', () {
    final r = buildRung(
      index: 0,
      main: [contact('A'), coil('Y')],
      branches: [BranchSpec(startIndex: 0, endIndex: 0, nodes: [contact('Seal')])],
    );
    final branches = findBranches(r);
    expect(branches.length, equals(1));
    expect(branches.first.lane, equals(1));
  });

  test('moveBranchTap is a no-op (no throw) when no matching wire exists', () {
    final r = buildRung(index: 0, main: [contact('A'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final fake = LdBranchView(lane: 9, firstNodeId: 'missing', lastNodeId: 'missing');
    moveBranchTap(r, fake, a); // must not throw
    expect(r.nodes.contains(a), isTrue);
  });
}
