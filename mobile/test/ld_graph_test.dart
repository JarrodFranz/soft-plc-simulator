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

  test('moveBranchMerge keeps a branch coil terminal (refuses non-rail dest)', () {
    final r = buildRung(
      index: 0,
      main: [contact('A'), coil('Y')],
      branches: [BranchSpec(startIndex: 0, endIndex: 1, nodes: [contact('C'), coil('D')])],
    );
    final br = findBranches(r).first;
    final d = r.nodes.firstWhere((n) => n.variable == 'D');
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    expect(br.lastNodeId, equals(d.id));
    moveBranchMerge(r, br, a); // attempt to point coil D -> A (non-rail)
    final dOut = r.wires.firstWhere((w) => w.fromId == d.id);
    expect(dOut.toId, equals(right.id)); // still terminal at the rail
  });

  test('deleteRung removes the rung and is a no-op out of range', () {
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [contact('A'), coil('Q')]),
      buildRung(index: 1, main: [contact('B'), coil('R')]),
    ]);
    deleteRung(prog, 0);
    expect(prog.rungs.length, 1);
    expect(prog.rungs.first.nodes.any((n) => n.variable == 'B'), isTrue);
    deleteRung(prog, 5); // out of range
    expect(prog.rungs.length, 1);
    deleteRung(prog, 0);
    expect(prog.rungs, isEmpty); // may go to zero
  });

  test('moveRung reorders and clamps', () {
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [coil('A')]),
      buildRung(index: 1, main: [coil('B')]),
      buildRung(index: 2, main: [coil('C')]),
    ]);
    moveRung(prog, 0, 2); // A to the end
    expect(prog.rungs.map((r) => r.nodes.firstWhere((n) => n.kind == LdKind.coil).variable).toList(), ['B', 'C', 'A']);
    moveRung(prog, 2, 2); // no-op
    expect(prog.rungs.first.nodes.firstWhere((n) => n.kind == LdKind.coil).variable, 'B'); // unchanged order
    // `to == length` is the append case (honors the [0, length] contract).
    moveRung(prog, 0, 3); // B (now first) to past-the-end -> last
    expect(prog.rungs.map((r) => r.nodes.firstWhere((n) => n.kind == LdKind.coil).variable).toList(), ['C', 'A', 'B']);
    moveRung(prog, 0, 4); // to > length -> rejected no-op
    expect(prog.rungs.first.nodes.firstWhere((n) => n.kind == LdKind.coil).variable, 'C');
  });

  test('addEmptyBranch creates an open link lane wired source->link->dest', () {
    final rung = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Q')]);
    final before = maxLane(rung);
    // parallel element B: source = the node before B (m0='A'), dest = right of B (m2='Q')
    final link = addEmptyBranch(rung, 'm0', 'm2');
    expect(link.kind, LdKind.link);
    expect(link.row, before + 1);
    expect(rung.wires.any((w) => w.fromId == 'm0' && w.toId == link.id), isTrue);
    expect(rung.wires.any((w) => w.fromId == link.id && w.toId == 'm2'), isTrue);
  });

  test('fillLink swaps kind in place, preserving id/row/wires', () {
    final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
    final link = addEmptyBranch(rung, kLeftRailId, 'm1'); // parallels A
    final wiresBefore = rung.wires.length;
    final filled = fillLink(rung, link, LdNode(id: 'IGNORED', kind: LdKind.contact, variable: 'Seal'));
    expect(filled.id, link.id); // id preserved so wires stay valid
    expect(filled.row, link.row);
    expect(rung.nodes.any((n) => n.kind == LdKind.link), isFalse);
    expect(rung.nodes.firstWhere((n) => n.id == link.id).variable, 'Seal');
    expect(rung.wires.length, wiresBefore); // no wires added/removed
  });

  test('emptyBranch reverts a real node to a link (same id/row)', () {
    final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
    final link = addEmptyBranch(rung, kLeftRailId, 'm1');
    final filled = fillLink(rung, link, LdNode(id: 'x', kind: LdKind.contact, variable: 'Seal'));
    final back = emptyBranch(rung, filled);
    expect(back.kind, LdKind.link);
    expect(back.id, filled.id);
    expect(back.row, filled.row);
  });

  test('collapseLink removes the link and its two branch wires', () {
    final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
    final link = addEmptyBranch(rung, kLeftRailId, 'm1');
    final n0 = rung.nodes.length, w0 = rung.wires.length;
    collapseLink(rung, link);
    expect(rung.nodes.length, n0 - 1);
    expect(rung.wires.length, w0 - 2);
    expect(rung.wires.any((w) => w.fromId == link.id || w.toId == link.id), isFalse);
  });

  test('addOutputCoil adds a new terminal coil lane', () {
    final rung = buildRung(index: 0, main: [
      contact('A'),
      coil('Q1'),
    ]);
    final before = maxLane(rung);
    final newCoil = addOutputCoil(rung);
    expect(newCoil.kind, LdKind.coil);
    expect(newCoil.row, before + 1);
    // the new coil feeds the right rail (terminal) and is fed from the left rail
    expect(rung.wires.any((w) => w.fromId == newCoil.id && w.toId == kRightRailId), isTrue);
    expect(rung.wires.any((w) => w.toId == newCoil.id), isTrue);
  });
}
