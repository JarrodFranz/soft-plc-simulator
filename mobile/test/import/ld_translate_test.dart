import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

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
}
