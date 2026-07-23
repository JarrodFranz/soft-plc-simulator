import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
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

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

bool _b(PlcProject p, String path) => readPath(p, path) == true;

/// One rung: L -- In(contact) -- [block Scaler, variable=S1,
/// pinBindings: In->PV, Out->CV] -- Out(coil) -- R.
LdRung _scalerRung() {
  final block = LdNode(
    id: '',
    kind: LdKind.block,
    blockType: 'Scaler',
    variable: 'S1',
    pinBindings: {'In': 'PV', 'Out': 'CV'},
  );
  return buildRung(index: 0, main: [
    LdNode(id: '', kind: LdKind.contact, variable: 'In'),
    block,
    LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
  ]);
}

void main() {
  final fb = _scalerFb();
  final fbProjForDefaults = PlcProject(
    id: 'p', name: 'p', controllerName: 'c',
    tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb],
  );

  PlcProject buildProj(List<PlcTag> tags, {bool inPower = true}) {
    final prog = PlcProgram(name: 'P1', language: 'LadderLogic', rungs: [_scalerRung()]);
    return PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [
        _tag('In', 'BOOL', inPower),
        _tag('Out', 'BOOL', false),
        ...tags,
      ],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );
  }

  test('LD block whose blockType names an FB reads pin-bound inputs, executes, writes outputs', () {
    final p = buildProj([
      _tag('PV', 'FLOAT64', 5.0),
      _tag('CV', 'FLOAT64', 0.0),
      _tag('S1', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
    ]);

    executeLdPrograms(p, 500, LdExecRuntime());

    expect(readPath(p, 'CV'), equals(10.0)); // PV(5) * Gain(2, unwired default)
  });

  test('power passes through the FB block unchanged (data block, not a break in the rung)', () {
    final p = buildProj([
      _tag('PV', 'FLOAT64', 5.0),
      _tag('CV', 'FLOAT64', 0.0),
      _tag('S1', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
    ]);

    executeLdPrograms(p, 500, LdExecRuntime());

    expect(_b(p, 'Out'), isTrue); // coil energizes through the FB block
  });

  test('input power false: FB does not execute, output tag unchanged, downstream power off', () {
    final p = buildProj([
      _tag('PV', 'FLOAT64', 5.0),
      _tag('CV', 'FLOAT64', 99.0),
      _tag('S1', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
    ], inPower: false);

    executeLdPrograms(p, 500, LdExecRuntime());

    expect(readPath(p, 'CV'), equals(99.0)); // unchanged
    expect(_b(p, 'Out'), isFalse); // no power in -> no power out
  });

  test('a forced output tag is respected (executed logic never overwrites a force)', () {
    final p = buildProj([
      _tag('PV', 'FLOAT64', 5.0),
      _tag('CV', 'FLOAT64', 0.0, forced: true, fv: 42.0),
      _tag('S1', 'Scaler', defaultValueFor(fbProjForDefaults, 'Scaler', 0)),
    ]);

    executeLdPrograms(p, 500, LdExecRuntime());

    expect(readPath(p, 'CV'), equals(42.0)); // force wins over the FB's write
  });

  test('never throws when a pin binding is missing/empty or the instance tag is absent', () {
    final block = LdNode(
      id: '',
      kind: LdKind.block,
      blockType: 'Scaler',
      variable: 'Ghost', // no 'Ghost' instance tag exists
      pinBindings: {'In': 'PV'}, // 'Out' left unbound
    );
    final r = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'In'),
      block,
      LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
    ]);
    final prog = PlcProgram(name: 'P1', language: 'LadderLogic', rungs: [r]);
    final p = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [_tag('In', 'BOOL', true), _tag('PV', 'FLOAT64', 5.0), _tag('Out', 'BOOL', false)],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    expect(() => executeLdPrograms(p, 500, LdExecRuntime()), returnsNormally);
    expect(_b(p, 'Out'), isTrue); // power still passes through
  });
}
