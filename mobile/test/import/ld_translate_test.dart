import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

IrGraphNode _n(int id, String type, {double x = 0, double y = 0, Map<String, String>? a}) =>
    IrGraphNode(localId: id, elementType: type, x: x, y: y, attributes: a ?? const {});
IrConnection _c(int to, int from, {String? toPin}) =>
    IrConnection(toLocalId: to, fromLocalId: from, toPin: toPin);

void mainTask2() {
  group('segmentRungs', () {
    test('two independent rungs -> two components, ordered by y', () {
      // Rung A (y=10): L -> contact1 -> coil2 -> R ; Rung B (y=50): L -> contact3 -> coil4 -> R
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(3, 'contact', y: 50, a: {'variable': 'B'}), _n(4, 'coil', y: 50, a: {'variable': 'D'}),
        _n(1, 'contact', y: 10, a: {'variable': 'A'}), _n(2, 'coil', y: 10, a: {'variable': 'C'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(200, 2),
        _c(3, 100), _c(4, 3), _c(200, 4),
      ]);
      final comps = segmentRungs(body);
      expect(comps, hasLength(2));
      // Ordered by min y: the A/C rung (y=10) first.
      expect(comps[0].nodes.map((n) => n.localId).toSet(), {1, 2});
      expect(comps[1].nodes.map((n) => n.localId).toSet(), {3, 4});
      expect(comps[0].leftRailNodeIds, contains(1));
      expect(comps[0].rightRailNodeIds, contains(2));
    });

    test('shared series path feeding two coils -> one component', () {
      // L -> A -> B -> {C, D}
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}), _n(2, 'contact', a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'C'}), _n(4, 'coil', a: {'variable': 'D'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(3, 2), _c(4, 2), _c(200, 3), _c(200, 4),
      ]);
      final comps = segmentRungs(body);
      expect(comps, hasLength(1));
      expect(comps[0].nodes.map((n) => n.localId).toSet(), {1, 2, 3, 4});
    });
  });
}

void mainTask3() {
  LdTranslation t(GraphBody b) => translateLdBody(b, pouName: 'P');

  group('translateLdBody boolean', () {
    test('single series rung: L-[A]-[B]-(C)-R', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'contact', a: {'variable': 'B', 'negated': 'true'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      final rung = r.rungs.single;
      // main line has A, B, C (plus rails L/R added by buildRung).
      final contacts = rung.nodes.where((n) => n.kind == LdKind.contact).toList();
      expect(contacts.map((n) => n.variable), containsAll(['A', 'B']));
      expect(contacts.firstWhere((n) => n.variable == 'B').modifier, 'negated');
      expect(rung.nodes.where((n) => n.kind == LdKind.coil).single.variable, 'C');
      expect(rung.nodes.any((n) => n.kind == LdKind.leftRail), isTrue);
    });

    test('parallel contacts A||B feeding one coil -> one branch lane', () {
      // L->A->C(coil); L->B->C : A and B are parallel into the coil.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', y: 0, a: {'variable': 'A'}),
        _n(2, 'contact', y: 20, a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 100), _c(3, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final rung = r.rungs.single;
      // One node on a branch lane (row > 0).
      expect(rung.nodes.where((n) => n.row > 0).length, 1);
      expect(rung.nodes.where((n) => n.kind == LdKind.contact).map((n) => n.variable),
          containsAll(['A', 'B']));
    });

    test('a component with a block stubs (Task 3 has no block support yet)', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'block', a: {'typeName': 'TON'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.rungs.single.comment, contains('not translated'));
      expect(r.warnings, isNotEmpty);
    });

    test('component with no coil stubs', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
      ], connections: [_c(1, 100)]);
      final r = t(body);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['no-coil'], 1);
    });

    test('unsupported negated+edge modifier combo stubs', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A', 'negated': 'true', 'edge': 'rising'}),
        _n(2, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(200, 2)]);
      final r = t(body);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['unsupported-modifier-combo'], 1);
    });
  });
}

void main() {
  group('parseIecDuration', () {
    test('parses seconds, ms, minutes, compound, and TIME# prefix', () {
      expect(parseIecDuration('T#5s'), 5000);
      expect(parseIecDuration('T#500ms'), 500);
      expect(parseIecDuration('T#2m'), 120000);
      expect(parseIecDuration('T#1m30s'), 90000);
      expect(parseIecDuration('T#1.5s'), 1500);
      expect(parseIecDuration('TIME#250ms'), 250);
      expect(parseIecDuration('t#3h'), 10800000);
    });
    test('returns null for non-durations', () {
      expect(parseIecDuration('hello'), isNull);
      expect(parseIecDuration('5'), isNull);
      expect(parseIecDuration(''), isNull);
    });
  });

  mainTask2();
  mainTask3();
}
