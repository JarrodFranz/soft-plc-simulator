import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/graph_segment.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

IrGraphNode _n(int id, {double x = 0, double y = 0}) =>
    IrGraphNode(localId: id, elementType: 'block', x: x, y: y);
IrConnection _e(int from, int to) =>
    IrConnection(fromLocalId: from, toLocalId: to);

void main() {
  test('splits into weakly-connected components, layout-ordered', () {
    // Component X: nodes 1-2 (top, y=0). Component Y: node 3 (below, y=100).
    final nodes = [_n(1, y: 0), _n(2, x: 50, y: 0), _n(3, y: 100)];
    final conns = [_e(1, 2)];
    final comps = weaklyConnectedComponents(nodes, conns);
    expect(comps.length, 2);
    expect(comps[0].map((n) => n.localId).toSet(), {1, 2}); // top first
    expect(comps[1].map((n) => n.localId).toSet(), {3});
  });

  test('excludeIds drops nodes and edges touching them', () {
    // 1 - 99(rail) - 2 : with 99 excluded, 1 and 2 are separate components.
    final nodes = [_n(1, y: 0), _n(99, y: 0), _n(2, y: 0, x: 100)];
    final conns = [_e(1, 99), _e(99, 2)];
    final comps = weaklyConnectedComponents(nodes, conns, excludeIds: {99});
    expect(comps.length, 2);
    expect(comps.expand((c) => c).map((n) => n.localId), isNot(contains(99)));
  });

  test('empty input yields no components', () {
    expect(weaklyConnectedComponents(const [], const []), isEmpty);
  });
}
