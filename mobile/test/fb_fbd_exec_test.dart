import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

FbDefinition _scalerFb() => FbDefinition(
      name: 'Scaler',
      stSource: 'Out := In * Gain;',
      vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 2.0),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ],
    );

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

void main() {
  test('FBD block whose type names an FB resolves pins from the FB interface and executes it', () {
    final fb = _scalerFb();
    final fbProjForDefaults = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'PV'),
      FbdBlock(id: 's1', type: 'Scaler', title: 'S1', tagBinding: 'S1'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'CV'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 's1', toPin: 'In'),
      FbdWire(fromBlockId: 's1', fromPin: 'Out', toBlockId: 'to', toPin: 'IN'),
    ]);

    final p = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [
        _tag('PV', 'FLOAT64', 5.0),
        _tag('CV', 'FLOAT64', 0.0),
        _tag('S1', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
      ],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    executeFbdPrograms(p, 500, FbdRuntime());

    expect(readPath(p, 'CV'), equals(10.0)); // PV(5) * Gain(2, unwired default)
  });

  test('two FB instances in one program stay independent', () {
    final fb = _scalerFb();
    final fbProjForDefaults = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti1', type: 'TAG_INPUT', title: '', tagBinding: 'PV1'),
      FbdBlock(id: 'ti2', type: 'TAG_INPUT', title: '', tagBinding: 'PV2'),
      FbdBlock(id: 's1', type: 'Scaler', title: '', tagBinding: 'S1'),
      FbdBlock(id: 's2', type: 'Scaler', title: '', tagBinding: 'S2'),
      FbdBlock(id: 'to1', type: 'TAG_OUTPUT', title: '', tagBinding: 'CV1'),
      FbdBlock(id: 'to2', type: 'TAG_OUTPUT', title: '', tagBinding: 'CV2'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'ti1', fromPin: 'OUT', toBlockId: 's1', toPin: 'In'),
      FbdWire(fromBlockId: 's1', fromPin: 'Out', toBlockId: 'to1', toPin: 'IN'),
      FbdWire(fromBlockId: 'ti2', fromPin: 'OUT', toBlockId: 's2', toPin: 'In'),
      FbdWire(fromBlockId: 's2', fromPin: 'Out', toBlockId: 'to2', toPin: 'IN'),
    ]);

    final p = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [
        _tag('PV1', 'FLOAT64', 3.0),
        _tag('PV2', 'FLOAT64', 7.0),
        _tag('CV1', 'FLOAT64', 0.0),
        _tag('CV2', 'FLOAT64', 0.0),
        _tag('S1', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
        _tag('S2', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
      ],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    executeFbdPrograms(p, 500, FbdRuntime());

    expect(readPath(p, 'CV1'), equals(6.0)); // 3 * 2
    expect(readPath(p, 'CV2'), equals(14.0)); // 7 * 2
  });
}
