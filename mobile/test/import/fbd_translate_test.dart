import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fbd_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

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

  FbDefinition scaler() => FbDefinition(name: 'Scaler', vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ], stSource: 'Out := In * Gain;');

  test('FBD custom-FB block routes to instance + struct-typed instance tag', () {
    final body = GraphBody(nodes: [
      _in(1, 'PV'), _in(2, '2.0', y: 40),
      IrGraphNode(localId: 3, elementType: 'block', x: 60,
          attributes: const {'typeName': 'Scaler', 'instanceName': 'S1'}),
      _out(4, 'CV', x: 120),
    ], connections: [
      _c(1, 3, toPin: 'In'), _c(2, 3, toPin: 'Gain'),
      _c(3, 4, fromPin: 'Out'),
    ]);
    final reg = {'Scaler': scaler()};
    final tr = translateFbdBody(body, pouName: 'P', fbRegistry: reg);
    expect(tr.translatedNetworkCount, 1);
    final fb = tr.blocks.firstWhere((b) => b.type == 'Scaler');
    expect(fb.tagBinding, 'S1');
    final inst = tr.instanceTags.firstWhere((t) => t.name == 'S1');
    expect(inst.dataType, 'Scaler');
    expect(defaultValueFor(
        PlcProject(id: 's', name: 's', controllerName: 'P', programs: [],
            tasks: [], hmis: [], structDefs: [], tags: [],
            fbDefinitions: reg.values.toList()),
        'Scaler', 0) is Map, isTrue);
  });

  test('renamed FB routes via rename map', () {
    final body = GraphBody(nodes: [
      _in(1, 'PV'),
      IrGraphNode(localId: 2, elementType: 'block', x: 60,
          attributes: const {'typeName': 'AND', 'instanceName': 'I1'}),
      _out(3, 'CV', x: 120),
    ], connections: [_c(1, 2, toPin: 'In'), _c(2, 3, fromPin: 'Out')]);
    // Source calls it "AND" but it was renamed to "AND_1" on import.
    final reg = {
      'AND_1': FbDefinition(name: 'AND_1', vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ], stSource: 'Out := In;')
    };
    final tr = translateFbdBody(body, pouName: 'P',
        fbRegistry: reg, fbRenameMap: {'AND': 'AND_1'});
    expect(tr.translatedNetworkCount, 1);
    expect(tr.blocks.any((b) => b.type == 'AND_1'), isTrue);
  });

  test('extensible operator IN<n> pin overflow does not throw (never-throws)', () {
    // 20+ digit pin suffix overflows int.parse's 64-bit range; must not escape
    // translateFbdBody as a FormatException.
    final body = GraphBody(nodes: [
      _in(1, 'A'), _blk(2, 'AND', x: 60), _out(3, 'Q', x: 120),
    ], connections: [
      _c(1, 2, toPin: 'IN99999999999999999999'),
      _c(2, 3, fromPin: 'OUT'),
    ]);
    expect(() => translateFbdBody(body, pouName: 'P'), returnsNormally);
  });

  test('two empty-toPin wires colliding on a bare 2-input AND stub as unresolved-pin', () {
    // Neither wire names a pin, so inputCount stays 1 (no IN<n> match) and both
    // wires would collapse onto index 0 in the executor without the guard.
    final body = GraphBody(nodes: [
      _in(1, 'A'), _in(2, 'B', y: 40), _blk(3, 'AND', x: 60), _out(4, 'Q', x: 120),
    ], connections: [
      _c(1, 3), _c(2, 3), _c(3, 4, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unresolved-pin'], 1);
  });

  test('two wires both targeting IN1 on the same block stub as unresolved-pin', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _in(2, 'B', y: 40), _blk(3, 'AND', x: 60), _out(4, 'Q', x: 120),
    ], connections: [
      _c(1, 3, toPin: 'IN1'), _c(2, 3, toPin: 'IN1'), _c(3, 4, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unresolved-pin'], 1);
  });

  test('normal 2-input AND with distinct IN1/IN2 still translates (regression guard)', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _in(2, 'B', y: 40), _blk(3, 'AND', x: 60), _out(4, 'Q', x: 120),
    ], connections: [
      _c(1, 3, toPin: 'IN1'), _c(2, 3, toPin: 'IN2'), _c(3, 4, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);
  });

  test('negated inVariable/outVariable attribute stubs its network', () {
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 1, elementType: 'inVariable',
          attributes: const {'variable': 'A', 'negated': 'true'}),
      _out(2, 'Q', x: 60),
    ], connections: [_c(1, 2)]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['negated-pin'], 1);
  });

  test('malformed (negative) localId stubs its component', () {
    final body = GraphBody(nodes: [
      IrGraphNode(localId: -1, elementType: 'inVariable',
          attributes: const {'variable': 'A'}),
      _out(2, 'Q', x: 60),
    ], connections: [_c(-1, 2)]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, greaterThanOrEqualTo(1));
  });

  test('instance name dedup within a POU', () {
    // Two FB blocks with no instanceName -> deterministic names, deduped.
    final body = GraphBody(nodes: [
      _in(1, 'A'),
      IrGraphNode(localId: 2, elementType: 'block', x: 60,
          attributes: const {'typeName': 'Scaler'}),
      _out(3, 'B', x: 120),
      _in(4, 'C', y: 200),
      IrGraphNode(localId: 5, elementType: 'block', x: 60, y: 200,
          attributes: const {'typeName': 'Scaler'}),
      _out(6, 'D', x: 120, y: 200),
    ], connections: [
      _c(1, 2, toPin: 'In'), _c(2, 3, fromPin: 'Out'),
      _c(4, 5, toPin: 'In'), _c(5, 6, fromPin: 'Out'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P', fbRegistry: {'Scaler': scaler()});
    final names = tr.instanceTags.map((t) => t.name).toSet();
    expect(names, hasLength(2)); // unique
    expect(tr.blocks.where((b) => b.type == 'Scaler'), hasLength(2));
  });
}
