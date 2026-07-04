import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_layout.dart';

LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

void main() {
  test('ldNodeX left-anchors non-coils and right-anchors coils', () {
    final c = LdNode(id: 'x', kind: LdKind.contact, variable: 'A');
    final k = LdNode(id: 'y', kind: LdKind.coil, variable: 'Y');
    expect(ldNodeX(c, 2, 1000), equals(ldColX(2)));
    expect(ldNodeX(k, 4, 1000), equals(1000 - kLdCellW - kLdCoilRailGap));
    // a coil sits to the right of a left-anchored contact on a wide canvas
    expect(ldNodeX(k, 4, 1000) > ldNodeX(c, 2, 1000), isTrue);
  });

  test('ldMinContentWidth leaves room for inputs plus the pinned coil', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final col = colAssignment(r);
    final w = ldMinContentWidth(r, col);
    // at the minimum width, the coil is still right of the last input element
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final k = r.nodes.firstWhere((n) => n.variable == 'Y');
    final bRight = ldColX(col[b.id]!) + kLdCellW;
    expect(ldNodeX(k, col[k.id]!, w) >= bRight, isTrue);
  });

  test('canInsertContactOnWire forbids inserting after a coil', () {
    final r = buildRung(index: 0, main: [contact('A'), coil('Y')]);
    final y = r.nodes.firstWhere((n) => n.variable == 'Y');
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    final beforeCoil = r.wires.firstWhere((w) => w.toId == y.id);   // A -> Y
    final afterCoil = r.wires.firstWhere((w) => w.fromId == y.id);  // Y -> rightRail
    final firstWire = r.wires.firstWhere((w) => w.fromId == left.id); // L -> A
    expect(canInsertContactOnWire(r, firstWire), isTrue);
    expect(canInsertContactOnWire(r, beforeCoil), isTrue);   // before the coil is fine
    expect(canInsertContactOnWire(r, afterCoil), isFalse);   // after the coil is not
  });

  test('canInsertCoilOnWire allows only terminal, non-post-coil segments', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B')]); // no coil yet
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final terminal = r.wires.firstWhere((w) => w.fromId == b.id); // B -> rightRail
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final midWire = r.wires.firstWhere((w) => w.fromId == a.id && w.toId == b.id);
    expect(canInsertCoilOnWire(r, terminal), isTrue);
    expect(canInsertCoilOnWire(r, midWire), isFalse); // not a terminal segment
  });

  test('inserting a coil on the terminal wire keeps it terminal', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B')]);
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    final terminal = r.wires.firstWhere((w) => w.fromId == b.id && w.toId == right.id);
    expect(canInsertCoilOnWire(r, terminal), isTrue);
    final coilNode = LdNode(id: newNodeId(r), kind: LdKind.coil, variable: 'Y');
    insertContactOnWire(r, terminal, coilNode);
    // coil's only outgoing wire is to the right rail; nothing follows it
    final coilOut = r.wires.where((w) => w.fromId == coilNode.id).toList();
    expect(coilOut.length, equals(1));
    expect(coilOut.first.toId, equals(right.id));
    // and no wire now originates from the coil to a non-rail node
    expect(canInsertContactOnWire(r, coilOut.first), isFalse);
  });
}
