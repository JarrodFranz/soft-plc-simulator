import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

void main() {
  test('FbDefinition + FbVar round-trip', () {
    final fb = FbDefinition(name: 'Scaler', stSource: 'Out := In * Gain;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 2.0),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      FbVar(name: 'Count', dataType: 'INT32', direction: FbVarDir.internal),
    ]);
    final rt = FbDefinition.fromJson(fb.toJson());
    expect(rt.name, 'Scaler');
    expect(rt.stSource, 'Out := In * Gain;');
    expect(rt.vars.map((v) => v.name), ['In', 'Gain', 'Out', 'Count']);
    expect(rt.vars[1].direction, FbVarDir.input);
    expect(rt.vars[1].initialValue, 2.0);
    expect(rt.vars.firstWhere((v) => v.name == 'Out').direction, FbVarDir.output);
  });

  test('project carries fbDefinitions; legacy project has none', () {
    final p = PlcProject(id: 'p', name: 'P', controllerName: 'C',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [FbDefinition(name: 'X')]);
    expect(PlcProject.fromJson(p.toJson()).fbDefinitions.single.name, 'X');
    final legacy = PlcProject.fromJson({'id': 'q', 'name': 'Q', 'controller': {}});
    expect(legacy.fbDefinitions, isEmpty);
  });

  test('LdNode.pinBindings is additive and round-trips', () {
    final n = LdNode(id: 'n1', kind: LdKind.block, blockType: 'Scaler', variable: 'S1',
        pinBindings: {'In': 'PV', 'Out': 'CV'});
    expect(LdNode.fromJson(n.toJson()).pinBindings, {'In': 'PV', 'Out': 'CV'});
    expect(LdNode(id: 'n2', kind: LdKind.contact).pinBindings, isEmpty);
  });

  test('ladder-bodied FbDefinition round-trips its rungs', () {
    final fb = FbDefinition(name: 'Latch', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      LdRung(rungIndex: 0, comment: 'XIC(In)OTE(Out)', nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'm0', kind: LdKind.contact, variable: 'In'),
        LdNode(id: 'm1', kind: LdKind.coil, variable: 'Out'),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [
        LdWire(fromId: 'L', toId: 'm0'),
        LdWire(fromId: 'm0', toId: 'm1'),
        LdWire(fromId: 'm1', toId: 'R'),
      ]),
    ]);

    final rt = FbDefinition.fromJson(fb.toJson());
    expect(rt.ladderRungs, hasLength(1));
    expect(rt.ladderRungs.single.rungIndex, 0);
    expect(rt.ladderRungs.single.comment, 'XIC(In)OTE(Out)');
    expect(rt.ladderRungs.single.nodes.map((n) => n.id), ['L', 'm0', 'm1', 'R']);
    expect(rt.ladderRungs.single.nodes[1].variable, 'In');
    expect(rt.ladderRungs.single.wires, hasLength(3));
    expect(rt.stSource, ''); // ladder-bodied FBs carry no ST source
  });

  test('an ST-bodied FbDefinition serializes with NO ladder_rungs key (byte-identical)', () {
    final fb = FbDefinition(name: 'Scaler', stSource: 'Out := In * 2.0;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final json = fb.toJson();
    expect(json.containsKey('ladder_rungs'), isFalse);
    expect(json.keys.toList(), ['name', 'vars', 'st_source']);
    expect(fb.ladderRungs, isEmpty);
  });

  test('legacy JSON without ladder_rungs loads with an empty ladder body', () {
    final rt = FbDefinition.fromJson({
      'name': 'Old',
      'vars': [
        {'name': 'In', 'data_type': 'BOOL', 'direction': 'input', 'initial_value': null},
      ],
      'st_source': 'Out := In;',
    });
    expect(rt.ladderRungs, isEmpty);
    expect(rt.stSource, 'Out := In;');
    expect(rt.vars.single.name, 'In');
  });

  test('renameFbDefinition retargets ladder-body calls and FB-typed vars inside other FBs', () {
    final inner = FbDefinition(name: 'Inner', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'In'),
        LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
      ]),
    ]);
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'Nest', dataType: 'Inner', direction: FbVarDir.internal),
      FbVar(name: 'Drive', dataType: 'BOOL', direction: FbVarDir.input),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.block, blockType: 'Inner', variable: 'Nest',
            pinBindings: {'In': 'Drive'}),
      ]),
    ]);
    final p = PlcProject(
        id: 'p', name: 'p', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);

    renameFbDefinition(p, 'Inner', 'Inner2');

    // The definition itself, the calling FB's ladder-body node, and the
    // FB-typed var all move together. A missed blockType would fall into
    // executeRung's TON/TOF fallback and silently become a timer.
    expect(inner.name, 'Inner2');
    expect(
        outer.ladderRungs.single.nodes
            .firstWhere((n) => n.kind == LdKind.block)
            .blockType,
        'Inner2');
    expect(outer.vars.firstWhere((v) => v.name == 'Nest').dataType, 'Inner2');
    // Unrelated vars/nodes are untouched.
    expect(outer.vars.firstWhere((v) => v.name == 'Drive').dataType, 'BOOL');
    expect(inner.ladderRungs.single.nodes.any((n) => n.kind == LdKind.coil), isTrue);
  });

  test('an FBD-bodied FbDefinition round-trips blocks, wires and networks', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'n0', type: 'TAG_INPUT', title: 'In', tagBinding: 'In', x: 10, y: 20),
      FbdBlock(id: 'n1', type: 'TON', title: 'TON', x: 110, y: 20),
      FbdBlock(id: 'n2', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out', x: 210, y: 20, network: 1),
    ], fbdWires: [
      FbdWire(fromBlockId: 'n0', fromPin: 'OUT', toBlockId: 'n1', toPin: 'IN'),
      FbdWire(fromBlockId: 'n1', fromPin: 'Q', toBlockId: 'n2', toPin: 'IN'),
    ], fbdNetworks: [
      FbdNetwork(comment: 'net one'),
      FbdNetwork(comment: 'net two'),
    ]);

    final rt = FbDefinition.fromJson(fb.toJson());
    expect(rt.fbdBlocks.map((b) => b.id), ['n0', 'n1', 'n2']);
    expect(rt.fbdBlocks[0].tagBinding, 'In');
    expect(rt.fbdBlocks[0].x, 10);
    expect(rt.fbdBlocks[2].network, 1);
    expect(rt.fbdWires, hasLength(2));
    expect(rt.fbdWires[1].fromPin, 'Q');
    expect(rt.fbdWires[1].toPin, 'IN');
    expect(rt.fbdNetworks.map((n) => n.comment), ['net one', 'net two']);
    expect(rt.ladderRungs, isEmpty);
    expect(rt.stSource, ''); // FBD-bodied FBs carry no ST source
  });

  test('ST- and ladder-bodied FbDefinitions serialize with NO fbd_* keys', () {
    final st = FbDefinition(name: 'Scaler', stSource: 'Out := In * 2.0;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
    ]);
    expect(st.toJson().keys.toList(), ['name', 'vars', 'st_source']);

    final ld = FbDefinition(name: 'Latch', ladderRungs: [
      LdRung(rungIndex: 0, nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [LdWire(fromId: 'L', toId: 'R')]),
    ]);
    final ldJson = ld.toJson();
    expect(ldJson.containsKey('fbd_blocks'), isFalse);
    expect(ldJson.containsKey('fbd_wires'), isFalse);
    expect(ldJson.containsKey('fbd_networks'), isFalse);
    expect(ldJson.keys.toList(), ['name', 'vars', 'st_source', 'ladder_rungs']);
  });

  test('legacy JSON without fbd_* keys loads with an empty FBD body', () {
    final rt = FbDefinition.fromJson({
      'name': 'Old',
      'vars': [
        {'name': 'In', 'data_type': 'BOOL', 'direction': 'input', 'initial_value': null},
      ],
      'st_source': 'Out := In;',
    });
    expect(rt.fbdBlocks, isEmpty);
    expect(rt.fbdWires, isEmpty);
    expect(rt.fbdNetworks, isEmpty);
    expect(rt.stSource, 'Out := In;');
  });

  test('renameFbDefinition retargets call blocks inside an FB FBD body (third root)', () {
    final inner = FbDefinition(name: 'B', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final outer = FbDefinition(name: 'A', vars: [
      FbVar(name: 'Nested', dataType: 'B', direction: FbVarDir.internal),
    ], fbdBlocks: [
      FbdBlock(id: 'a0', type: 'B', title: 'B', tagBinding: 'Nested'),
    ]);
    final p = PlcProject(
        id: 'p', name: 'P', controllerName: 'C',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);

    renameFbDefinition(p, 'B', 'B_1');

    expect(outer.fbdBlocks.single.type, 'B_1');
    expect(outer.fbdBlocks.single.tagBinding, 'Nested'); // the var name is untouched
    expect(outer.vars.single.dataType, 'B_1');
    expect(inner.name, 'B_1');
  });
}
