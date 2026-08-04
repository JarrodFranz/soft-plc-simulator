import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

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
}
