// Ladder-bodied FB dispatch: executeFbInstance runs `ladderRungs` scoped to
// the instance, with per-instance edge state ('fb:<instance>' keys) and
// per-instance timer accumulators. ST-bodied FBs are unaffected.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fb_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

Map<String, dynamic> _instanceValue(FbDefinition fb) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
  return Map<String, dynamic>.from(defaultValueFor(defaults, fb.name, 0) as Map);
}

PlcProject _proj(FbDefinition fb, List<String> instanceNames) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [for (final n in instanceNames) _tag(n, fb.name, _instanceValue(fb))],
      structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

/// Ladder-bodied threshold FB: `Out := In > 10`.
FbDefinition _threshFb() => FbDefinition(name: 'Thresh', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.block, blockType: 'GT', operandA: 'In', operandB: '10'),
        LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
      ]),
    ]);

/// Ladder-bodied edge detector: `Out` pulses for one call per rising `Trig`.
FbDefinition _edgeFb() => FbDefinition(name: 'Edge', vars: [
      FbVar(name: 'Trig', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Trig', modifier: 'rising'),
        LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
      ]),
    ]);

/// Ladder-bodied on-delay: an FB-local TIMER var accumulates per instance.
FbDefinition _delayFb() => FbDefinition(name: 'Delay', vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Done', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Run'),
        LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
        LdNode(id: '', kind: LdKind.coil, variable: 'Done'),
      ]),
    ]);

void main() {
  test('a ladder-bodied FB takes inputs, runs its rungs, and returns outputs', () {
    final fb = _threshFb();
    final p = _proj(fb, ['A1']);

    expect(executeFbInstance(p, fb, 'A1', {'In': 12.0})['Out'], isTrue);
    expect(readPath(p, 'A1.In'), 12.0);
    expect(executeFbInstance(p, fb, 'A1', {'In': 5.0})['Out'], isFalse);
  });

  test('two instances have independent edge state (disjoint "fb:<instance>" keys)', () {
    final fb = _edgeFb();
    final p = _proj(fb, ['A1', 'A2']);
    final rt = LdExecRuntime();

    // Scan 1: A1 already true (no spurious first-scan edge), A2 false.
    executeFbInstance(p, fb, 'A1', {'Trig': true}, ldRt: rt);
    executeFbInstance(p, fb, 'A2', {'Trig': false}, ldRt: rt);
    expect(readPath(p, 'A1.Out'), isFalse);
    expect(readPath(p, 'A2.Out'), isFalse);

    // Scan 2: both true. A1 has no edge (already true); A2 rises.
    // Had the two instances SHARED an edge key, this would be inverted.
    final o1 = executeFbInstance(p, fb, 'A1', {'Trig': true}, ldRt: rt);
    final o2 = executeFbInstance(p, fb, 'A2', {'Trig': true}, ldRt: rt);
    expect(o1['Out'], isFalse);
    expect(o2['Out'], isTrue);
  });

  test('a scoped TON accumulates per instance across calls using dtMs', () {
    final fb = _delayFb();
    final p = _proj(fb, ['D1', 'D2']);
    final rt = LdExecRuntime();

    for (var i = 0; i < 3; i++) {
      executeFbInstance(p, fb, 'D1', {'Run': true}, dtMs: 100, ldRt: rt);
    }
    executeFbInstance(p, fb, 'D2', {'Run': true}, dtMs: 100, ldRt: rt);

    expect(readPath(p, 'D1.T.ACC'), 300);
    expect(readPath(p, 'D1.Done'), isTrue);
    expect(readPath(p, 'D2.T.ACC'), 100);
    expect(readPath(p, 'D2.Done'), isFalse);
  });

  test('no ldRt still runs (ephemeral fallback) — only edge detection degrades', () {
    final fb = _delayFb();
    final p = _proj(fb, ['D1']);
    expect(() => executeFbInstance(p, fb, 'D1', {'Run': true}, dtMs: 100),
        returnsNormally);
    expect(readPath(p, 'D1.T.ACC'), 100);
  });

  test('an ST-bodied FB is unaffected by the new dispatch (regression)', () {
    final fb = FbDefinition(name: 'Accum', stSource: 'Sum := Sum + In; Out := Sum;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Sum', dataType: 'FLOAT64', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final p = _proj(fb, ['S1']);
    expect(executeFbInstance(p, fb, 'S1', {'In': 3.0})['Out'], 3.0);
    expect(executeFbInstance(p, fb, 'S1', {'In': 4.0})['Out'], 7.0);
  });

  test('an empty instance name still refuses to run (unchanged)', () {
    final fb = _threshFb();
    final p = _proj(fb, ['A1']);
    expect(executeFbInstance(p, fb, '', {'In': 12.0}), isEmpty);
  });

  test('a self-calling ladder FB is depth-capped instead of overflowing the stack', () {
    // Not reachable via import (the FB registry only holds FBs defined EARLIER
    // in the file), but reachable from hand-edited/legacy JSON. Never-throws.
    final fb = FbDefinition(name: 'Loop', vars: [
      FbVar(name: 'X', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Self', dataType: 'BOOL', direction: FbVarDir.internal),
    ]);
    fb.ladderRungs.add(buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'Loop', variable: 'Self',
          pinBindings: {'X': 'X'}),
    ]));
    final p = _proj(fb, ['L1']);
    expect(() => executeFbInstance(p, fb, 'L1', {'X': true}), returnsNormally);
  });
}
