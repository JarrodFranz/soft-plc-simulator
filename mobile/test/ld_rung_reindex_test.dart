import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';

LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

void main() {
  test('deleteRung renumbers the surviving rung (no stale rungIndex left behind)', () {
    // Exact regression scenario from the finding: 2 rungs [rungIndex 0, 1].
    // Delete list-position 0 -> the survivor (originally rungIndex 1) MUST be
    // renumbered to 0. Before the fix, deleteRung left it at rungIndex 1.
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [contact('A'), coil('Q0')]),
      buildRung(index: 1, main: [contact('B'), coil('Q1')]),
    ]);
    deleteRung(prog, 0);
    expect(prog.rungs.length, 1);
    expect(prog.rungs.single.rungIndex, 0);
  });

  test('delete-then-add never produces duplicate rungIndex values', () {
    // Mirrors _addRung's `index: program.rungs.length` site. Before the fix:
    // delete position 0 leaves the survivor at rungIndex 1; adding a rung
    // with index = length (1) collides -> two rungs share rungIndex 1.
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [contact('A'), coil('Q0')]),
      buildRung(index: 1, main: [contact('B'), coil('Q1')]),
    ]);
    deleteRung(prog, 0);
    prog.rungs.add(buildRung(index: prog.rungs.length, main: [contact('C'), coil('Q2')]));

    final indices = prog.rungs.map((r) => r.rungIndex).toList();
    expect(indices.toSet().length, indices.length, reason: 'rungIndex values must be unique: $indices');
    expect(indices, [0, 1]);
  });

  test('moveRung renumbers so rungIndex always matches list position', () {
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [coil('A')]),
      buildRung(index: 1, main: [coil('B')]),
      buildRung(index: 2, main: [coil('C')]),
    ]);
    moveRung(prog, 0, 2); // A moves to the end: order becomes [B, C, A]
    final indices = prog.rungs.map((r) => r.rungIndex).toList();
    expect(indices, [0, 1, 2]);
    expect(indices.toSet().length, 3);

    final vars = prog.rungs
        .map((r) => r.nodes.firstWhere((n) => n.kind == LdKind.coil).variable)
        .toList();
    expect(vars, ['B', 'C', 'A']);
  });

  test('reindexRungs is a no-op for already-sequential rungs', () {
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [coil('A')]),
      buildRung(index: 1, main: [coil('B')]),
    ]);
    reindexRungs(prog);
    expect(prog.rungs.map((r) => r.rungIndex).toList(), [0, 1]);
  });
}
