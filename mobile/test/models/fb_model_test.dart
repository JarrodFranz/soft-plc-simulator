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
}
