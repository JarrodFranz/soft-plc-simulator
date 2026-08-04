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

/// Builds the structural default Map for [typeName] with [fbs] in scope — the
/// list form is needed when one FB has a var typed as ANOTHER FB (nesting).
Map<String, dynamic> _instanceValueOf(List<FbDefinition> fbs, String typeName) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: fbs);
  return Map<String, dynamic>.from(
      defaultValueFor(defaults, typeName, 0) as Map);
}

/// Builds the structural default Map for [fb]'s own type from [fb] alone.
Map<String, dynamic> _instanceValue(FbDefinition fb) =>
    _instanceValueOf([fb], fb.name);

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
    // rewrite() is purely lexical: it has no idea what a numeric literal is,
    // so a var named '5' WOULD be rewritten. This is the falsifiable half of
    // "_operandValue parses literals BEFORE it rewrites" (asserted at the
    // executeRung level below) — if that order ever flipped, '5' would resolve
    // to the missing path 'C1.5' (0) instead of the number five.
    expect(LdScope('C1', {'5'}).rewrite('5'), 'C1.5');
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

  test('a compare operand that names an FB var is scoped', () {
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

  test('a numeric literal operand is parsed BEFORE any rewrite is considered', () {
    // The scope deliberately declares a var literally named '5'. If
    // `_operandValue` rewrote before parsing, operandA would become the
    // missing path 'L1.5' -> 0, and `0 > 0` would be FALSE. Parsing first
    // keeps it the number five, so `5 > 0` is TRUE.
    final fb = FbDefinition(name: 'Lit', vars: [
      FbVar(name: 'Zero', dataType: 'FLOAT64', direction: FbVarDir.internal, initialValue: 0.0),
      FbVar(name: 'Hi', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('L1', 'Lit', _instanceValue(fb))],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'GT', operandA: '5', operandB: 'Zero'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Hi'),
    ]);
    executeRung(p, 'fb:L1', rung, 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('L1', {'Zero', 'Hi', '5'}));

    expect(readPath(p, 'L1.Hi'), isTrue);
  });

  test('a scoped math block scopes BOTH its operands and its destination', () {
    final fb = FbDefinition(name: 'Adder', vars: [
      FbVar(name: 'A', dataType: 'INT32', direction: FbVarDir.internal, initialValue: 4),
      FbVar(name: 'Sum', dataType: 'INT32', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('A', 'INT32', 100), // global decoy: unscoped operand -> 103
          _tag('Sum', 'INT32', 0), // global decoy: unscoped destination
          _tag('M1', 'Adder', _instanceValue(fb)),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'ADD',
          operandA: 'A', operandB: '3', variable: 'Sum'),
    ]);
    executeRung(p, 'fb:M1', rung, 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('M1', {'A', 'Sum'}));

    expect((readPath(p, 'M1.Sum') as num).toDouble(), 7.0); // M1.A(4) + 3
    expect(readPath(p, 'Sum'), 0); // global destination untouched
  });

  test('a scoped CTUD reads its down-input operand from the instance', () {
    final fb = FbDefinition(name: 'Cnt', vars: [
      FbVar(name: 'Dn', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'C', dataType: 'COUNTER', direction: FbVarDir.internal),
      FbVar(name: 'Q', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final base = PlcProject(id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Dn', 'BOOL', false), // global decoy: never goes true
          _tag('C', 'COUNTER', defaultValueFor(base, 'COUNTER', 0)), // global decoy
          _tag('X1', 'Cnt', _instanceValue(fb)),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
    writePath(p, 'X1.C.CV', 3);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'CTUD',
          variable: 'C', operandA: 'Dn', presetMs: 5),
    ]);
    final rt = LdExecRuntime();
    final scope = LdScope('X1', {'Dn', 'C', 'Q'});
    // Scan 1 establishes the down-input's prev state (false), scan 2 supplies
    // the rising edge that decrements. An UNSCOPED operandA would read the
    // global 'Dn', which stays false, so CV would never move off 3.
    executeRung(p, 'fb:X1', rung, 100, rt, (path, v) => writePath(p, path, v), scope: scope);
    writePath(p, 'X1.Dn', true);
    executeRung(p, 'fb:X1', rung, 100, rt, (path, v) => writePath(p, path, v), scope: scope);

    expect(readPath(p, 'X1.C.CD'), isTrue); // CD mirrors the scoped down input
    expect(readPath(p, 'X1.C.CV'), 2);      // 3 - 1 on the scoped down edge
    expect(readPath(p, 'C.CV'), 0);         // global counter never touched
    expect(readPath(p, 'C.CD'), isFalse);
  });

  test('a scoped custom-FB call scopes its pin bindings AND its instance name', () {
    // Deviation (b): inside an FB body, a nested call's instance var lives in
    // the OUTER instance ('Inner' -> 'A1.Inner'), and its pin bindings name
    // the OUTER FB's own vars ('Src' -> 'A1.Src', 'Res' -> 'A1.Res').
    final relay = FbDefinition(name: 'Relay', stSource: 'Out := In;', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'Src', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Res', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Inner', dataType: 'Relay', direction: FbVarDir.internal),
    ]);
    final inst = _instanceValueOf([relay, outer], 'Outer')..['Src'] = true;
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Src', 'BOOL', false), // global decoys, all same-named
          _tag('Res', 'BOOL', false),
          _tag('Inner', 'Relay', _instanceValue(relay)),
          _tag('A1', 'Outer', inst),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [relay, outer]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'Relay', variable: 'Inner',
          pinBindings: {'In': 'Src', 'Out': 'Res'}),
    ]);
    executeRung(p, 'fb:A1', rung, 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('A1', {'Src', 'Res', 'Inner'}));

    expect(readPath(p, 'A1.Inner.In'), isTrue);  // pin input read A1.Src
    expect(readPath(p, 'A1.Inner.Out'), isTrue); // nested body ran in A1.Inner
    expect(readPath(p, 'A1.Res'), isTrue);       // output landed in the outer instance
    expect(readPath(p, 'Inner.In'), isFalse);    // same-named globals all untouched
    expect(readPath(p, 'Inner.Out'), isFalse);
    expect(readPath(p, 'Res'), isFalse);
  });

  test('two instances of one FB keep disjoint edge state on a shared runtime', () {
    final fb = FbDefinition(name: 'Pulse', vars: [
      FbVar(name: 'Trig', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'P', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('S1', 'Pulse', _instanceValue(fb)..['Trig'] = true),
          _tag('S2', 'Pulse', _instanceValue(fb)), // Trig starts false
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    // Rung 0: L -- Trig(rising contact) -- P(coil) -- R. IDENTICAL rungs for
    // both instances, ONE shared LdExecRuntime: only the 'fb:<instance>'
    // program key keeps their prevBool entries apart.
    final rungs = [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Trig', modifier: 'rising'),
        LdNode(id: '', kind: LdKind.coil, variable: 'P'),
      ]),
    ];
    final rt = LdExecRuntime();
    final s1 = LdScope('S1', {'Trig', 'P'});
    final s2 = LdScope('S2', {'Trig', 'P'});

    runScopedLdBody(p, rungs, s1, 100, rt); // S1.Trig true (no edge: first scan)
    runScopedLdBody(p, rungs, s2, 100, rt); // S2.Trig false
    writePath(p, 'S2.Trig', true);
    runScopedLdBody(p, rungs, s1, 100, rt); // S1.Trig still true -> no edge
    runScopedLdBody(p, rungs, s2, 100, rt); // S2.Trig false->true -> EDGE

    // Aliased keys would invert this exactly (S1 true / S2 false), because
    // each instance would overwrite the other's remembered previous value.
    expect(readPath(p, 'S1.P'), isFalse);
    expect(readPath(p, 'S2.P'), isTrue);
  });
}
