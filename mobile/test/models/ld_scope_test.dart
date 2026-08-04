// Scoped ladder execution: LdScope's path rewriting, executeRung's optional
// `scope`, and runScopedLdBody. The null-scope regression test is the
// backward-compat guard — every existing caller passes no scope.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal',
        isForced: forced, forcedValue: fv);

/// Builds the structural default Map for [fbName] from [fb] alone.
Map<String, dynamic> _instanceValue(FbDefinition fb) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
  return Map<String, dynamic>.from(
      defaultValueFor(defaults, fb.name, 0) as Map);
}

/// BOOL-in / BOOL-out FB, used for its var NAMES + instance struct shape.
FbDefinition _gateFb() => FbDefinition(name: 'Gate', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);

/// One rung: L -- In(contact) -- Out(coil) -- R.
LdRung _gateRung() => buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'In'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
    ]);

void main() {
  test('LdScope.rewrite maps FB-var roots (bare, dotted, indexed) and leaves globals', () {
    final s = LdScope('A1', {'In', 'T', 'Buf'});
    expect(s.rewrite('In'), 'A1.In');
    expect(s.rewrite('T.ACC'), 'A1.T.ACC');
    expect(s.rewrite('Buf[2]'), 'A1.Buf[2]');
    expect(s.rewrite('Buf[2].X'), 'A1.Buf[2].X');
    expect(s.rewrite('GlobalTag'), 'GlobalTag');
    expect(s.rewrite('Other.In'), 'Other.In'); // the ROOT segment decides
    expect(LdScope('A1.Inner', {'In'}).rewrite('In'), 'A1.Inner.In'); // nested
  });

  test('a scoped rung reads/writes the instance struct, never the same-named globals', () {
    final fb = _gateFb();
    final inst = _instanceValue(fb)..['In'] = true;
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('In', 'BOOL', false), _tag('Out', 'BOOL', false), _tag('A1', 'Gate', inst)],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    executeRung(p, 'fb:A1', _gateRung(), 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('A1', {'In', 'Out'}));

    expect(readPath(p, 'A1.Out'), isTrue); // instance In(true) drove instance Out
    expect(readPath(p, 'Out'), isFalse);   // same-named global untouched
  });

  test('scope == null is byte-identical to today: the SAME rung hits globals only', () {
    final fb = _gateFb();
    final inst = _instanceValue(fb)..['In'] = false;
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('In', 'BOOL', true), _tag('Out', 'BOOL', false), _tag('A1', 'Gate', inst)],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    executeRung(p, 'P1', _gateRung(), 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v));

    expect(readPath(p, 'Out'), isTrue);     // global In(true) drove global Out
    expect(readPath(p, 'A1.Out'), isFalse); // instance untouched
  });

  test('a compare operand that names an FB var is scoped; a numeric literal is not', () {
    final fb = FbDefinition(name: 'Cmp', vars: [
      FbVar(name: 'Level', dataType: 'FLOAT64', direction: FbVarDir.internal, initialValue: 7.0),
      FbVar(name: 'Hi', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Level', 'FLOAT64', 0.0), // global decoy: would make 'Level > 5' false
          _tag('Hi', 'BOOL', false),
          _tag('C1', 'Cmp', _instanceValue(fb)),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'GT', operandA: 'Level', operandB: '5'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Hi'),
    ]);
    executeRung(p, 'fb:C1', rung, 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('C1', {'Level', 'Hi'}));

    expect(readPath(p, 'C1.Hi'), isTrue); // C1.Level(7) > literal 5
    expect(readPath(p, 'Hi'), isFalse);   // global untouched
  });

  test('a scoped timer accumulates inside the instance, not in a same-named global', () {
    final fb = FbDefinition(name: 'Del', vars: [
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Q', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final base = PlcProject(id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('T', 'TIMER', defaultValueFor(base, 'TIMER', 0)), // global decoy
          _tag('Q', 'BOOL', false),
          _tag('D1', 'Del', _instanceValue(fb)),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
      LdNode(id: '', kind: LdKind.coil, variable: 'Q'),
    ]);
    final rt = LdExecRuntime();
    final scope = LdScope('D1', {'T', 'Q'});
    executeRung(p, 'fb:D1', rung, 100, rt, (path, v) => writePath(p, path, v), scope: scope);
    executeRung(p, 'fb:D1', rung, 100, rt, (path, v) => writePath(p, path, v), scope: scope);

    expect(readPath(p, 'D1.T.ACC'), 200);
    expect(readPath(p, 'D1.T.PRE'), 300);
    expect(readPath(p, 'D1.Q'), isFalse);  // 200 < 300
    expect(readPath(p, 'T.ACC'), 0);       // global timer never touched
  });

  test('runScopedLdBody runs every rung scoped and keeps writes force-aware', () {
    final fb = FbDefinition(name: 'Sig', vars: [
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('S1', 'Sig', _instanceValue(fb)),
          _tag('Lamp', 'BOOL', false),                            // plain global
          _tag('Locked', 'BOOL', false, forced: true, fv: false), // forced global
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    // Rung 0: L -- Out(coil) -- R   (scoped -> S1.Out)
    // Rung 1: L -- Lamp(coil) -- R  (not an FB var -> global)
    // Rung 2: L -- Locked(coil) -- R (global, forced false: force must win)
    final rungs = [
      buildRung(index: 0, main: [LdNode(id: '', kind: LdKind.coil, variable: 'Out')]),
      buildRung(index: 1, main: [LdNode(id: '', kind: LdKind.coil, variable: 'Lamp')]),
      buildRung(index: 2, main: [LdNode(id: '', kind: LdKind.coil, variable: 'Locked')]),
    ];

    runScopedLdBody(p, rungs, LdScope('S1', {'Out'}), 100, LdExecRuntime());

    expect(readPath(p, 'S1.Out'), isTrue); // scoped write landed in the instance
    expect(readPath(p, 'Lamp'), isTrue);   // non-var reference fell through global
    expect(readPath(p, 'Locked'), isFalse); // force wins over executed logic
  });
}
