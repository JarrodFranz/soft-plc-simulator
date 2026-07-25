import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fbd_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

IrGraphNode _in(int id, String v, {double x = 0, double y = 0}) => IrGraphNode(
    localId: id, elementType: 'inVariable', x: x, y: y,
    attributes: {'variable': v});
IrGraphNode _out(int id, String v, {double x = 0, double y = 0}) => IrGraphNode(
    localId: id, elementType: 'outVariable', x: x, y: y,
    attributes: {'variable': v});
IrGraphNode _blk(int id, String type,
        {double x = 0, double y = 0, Map<String, String>? attrs}) =>
    IrGraphNode(localId: id, elementType: 'block', x: x, y: y,
        attributes: {'typeName': type, ...?attrs});
IrConnection _c(int from, int to, {String? toPin, String? fromPin}) =>
    IrConnection(fromLocalId: from, toLocalId: to, toPin: toPin, fromPin: fromPin);

void main() {
  test('inVariable literal -> CONST, identifier -> TAG_INPUT; outVariable -> TAG_OUTPUT', () {
    // Component: TAG_INPUT(A) & CONST(5) -> AND -> TAG_OUTPUT(Q)
    final body = GraphBody(nodes: [
      _in(1, 'A', y: 0),
      _in(2, '5', y: 40),
      _blk(3, 'AND', x: 60),
      _out(4, 'Q', x: 120),
    ], connections: [
      _c(1, 3, toPin: 'IN1'),
      _c(2, 3, toPin: 'IN2'),
      _c(3, 4, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);
    expect(tr.networks, hasLength(1));
    final types = {for (final b in tr.blocks) b.type};
    expect(types, containsAll(['TAG_INPUT', 'CONST', 'AND', 'TAG_OUTPUT']));
    final tagIn = tr.blocks.firstWhere((b) => b.type == 'TAG_INPUT');
    expect(tagIn.tagBinding, 'A');
    final constB = tr.blocks.firstWhere((b) => b.type == 'CONST');
    expect(constB.tagBinding, '5');
    final tagOut = tr.blocks.firstWhere((b) => b.type == 'TAG_OUTPUT');
    expect(tagOut.tagBinding, 'Q');
    // All blocks in network 0; three wires carried through.
    expect(tr.blocks.every((b) => b.network == 0), isTrue);
    expect(tr.wires, hasLength(3));
  });

  test('two components -> two layout-ordered networks', () {
    final body = GraphBody(nodes: [
      _in(1, 'A', y: 0), _out(2, 'B', x: 60, y: 0),      // top component
      _in(3, 'C', y: 100), _out(4, 'D', x: 60, y: 100),  // bottom component
    ], connections: [
      _c(1, 2), _c(3, 4),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 2);
    expect(tr.networks, hasLength(2));
    // Top component (y=0) is network 0.
    final net0Bindings = {
      for (final b in tr.blocks) if (b.network == 0) b.tagBinding
    };
    expect(net0Bindings, containsAll(['A', 'B']));
  });

  test('extensible AND inputCount follows the highest wired IN pin', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _in(2, 'B', y: 40), _in(3, 'C', y: 80),
      _blk(4, 'AND', x: 60), _out(5, 'Q', x: 120),
    ], connections: [
      _c(1, 4, toPin: 'IN1'), _c(2, 4, toPin: 'IN2'), _c(3, 4, toPin: 'IN3'),
      _c(4, 5, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 1);
    final and = tr.blocks.firstWhere((b) => b.type == 'AND');
    expect(and.inputCount, 3);
  });

  test('unsupported element (inOutVariable) stubs its network', () {
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 1, elementType: 'inOutVariable',
          attributes: const {'variable': 'X'}),
      _out(2, 'Y', x: 60),
    ], connections: [_c(1, 2)]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unsupported-element'], 1);
    expect(tr.networks.single.comment, contains('not translated'));
    expect(tr.blocks, isEmpty);
    expect(tr.warnings.any((w) => w.severity == WarningSeverity.warning), isTrue);
  });

  test('negated pin stubs its network', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'),
      _blk(2, 'NOT', x: 60, attrs: {'hasNegatedPin': 'true'}),
      _out(3, 'Q', x: 120),
    ], connections: [_c(1, 2, toPin: 'IN'), _c(2, 3, fromPin: 'OUT')]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['negated-pin'], 1);
  });

  test('unknown block type stubs + records inventory', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _blk(2, 'MYSTERY', x: 60), _out(3, 'Q', x: 120),
    ], connections: [_c(1, 2, toPin: 'IN1'), _c(2, 3, fromPin: 'OUT')]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unsupported-block'], 1);
    expect(tr.unsupportedBlockTypes, contains('MYSTERY'));
  });

  test('compound expression operand stubs its network', () {
    final body = GraphBody(nodes: [
      _in(1, 'A + B'), _out(2, 'Q', x: 60),
    ], connections: [_c(1, 2)]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['complex-expression'], 1);
  });

  test('wire to a pin not on the block stubs its network', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _blk(2, 'NOT', x: 60), _out(3, 'Q', x: 120),
    ], connections: [
      _c(1, 2, toPin: 'BOGUS'), // NOT has only IN
      _c(2, 3, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unresolved-pin'], 1);
  });
}
