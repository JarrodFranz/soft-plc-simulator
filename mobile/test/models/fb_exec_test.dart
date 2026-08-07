import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/models/fb_exec.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';

FbDefinition _accumFb() => FbDefinition(name: 'Accum', stSource: 'Sum := Sum + In; Out := Sum;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Sum', dataType: 'FLOAT64', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);

PlcProject _proj(FbDefinition fb, {List<PlcTag>? tags}) => PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: tags ?? [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

void main() {
  test('executeFbInstance runs scoped body; internal state persists across calls', () {
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      PlcTag(name: 'A1', path: 'A1', dataType: 'Accum', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Accum', 0)),
    ]);
    var out = executeFbInstance(p, fb, 'A1', {'In': 3.0});
    expect(out['Out'], 3.0);
    out = executeFbInstance(p, fb, 'A1', {'In': 4.0});
    expect(out['Out'], 7.0); // Sum persisted in the A1 struct
    expect(readPath(p, 'A1.Sum'), 7.0);
  });

  test('two instances keep independent state', () {
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      PlcTag(name: 'A1', path: 'A1', dataType: 'Accum', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Accum', 0)),
      PlcTag(name: 'A2', path: 'A2', dataType: 'Accum', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Accum', 0)),
    ]);
    executeFbInstance(p, fb, 'A1', {'In': 5.0});
    final o2 = executeFbInstance(p, fb, 'A2', {'In': 9.0});
    expect(o2['Out'], 9.0);
    expect(readPath(p, 'A1.Sum'), 5.0);
  });

  test('an empty instance name refuses to run and does not touch same-named globals', () {
    // A dangling/unbound FB block would call with instanceName == '' — paths like
    // '.In' strip to bare 'In' and would otherwise alias onto globals. Guard it.
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      // Same-named globals the aliasing bug would have clobbered / read.
      PlcTag(name: 'In', path: 'In', dataType: 'FLOAT64', ioType: 'Internal', value: 5.0),
      PlcTag(name: 'Sum', path: 'Sum', dataType: 'FLOAT64', ioType: 'Internal', value: 42.0),
      PlcTag(name: 'Out', path: 'Out', dataType: 'FLOAT64', ioType: 'Internal', value: 7.0),
    ]);
    final out = executeFbInstance(p, fb, '', {'In': 3.0});
    expect(out, isEmpty); // no outputs produced
    // Globals untouched — inputs not written, body not run.
    expect(readPath(p, 'In'), 5.0);
    expect(readPath(p, 'Sum'), 42.0);
    expect(readPath(p, 'Out'), 7.0);
  });

  test('a body reference not in the FB vars falls through to a global tag', () {
    final fb = FbDefinition(name: 'Gue', stSource: 'Out := In + Bias;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final p = _proj(fb, tags: [
      PlcTag(name: 'G1', path: 'G1', dataType: 'Gue', ioType: 'Internal', value: defaultValueFor(_proj(fb), 'Gue', 0)),
      PlcTag(name: 'Bias', path: 'Bias', dataType: 'FLOAT64', ioType: 'Internal', value: 100.0),
    ]);
    final out = executeFbInstance(p, fb, 'G1', {'In': 1.0});
    expect(out['Out'], 101.0); // Bias read from the global tag
  });

  // ---- three-way body precedence + FBD dispatch (L5X FBD import) ----

  PlcProject projFor(List<FbDefinition> fbs, List<String> instances,
      {List<PlcTag> extra = const []}) {
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: fbs);
    return PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        ...extra,
        for (final i in instances)
          PlcTag(name: i, path: i, dataType: fbs.first.name,
              value: defaultValueFor(defaults, fbs.first.name, 0),
              ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: fbs,
    );
  }

  test('body precedence: ladder wins over FBD, FBD wins over ST', () {
    final both = FbDefinition(
      name: 'Both',
      stSource: 'StMark := TRUE;',
      vars: [
        FbVar(name: 'LdMark', dataType: 'BOOL', direction: FbVarDir.output),
        FbVar(name: 'FbdMark', dataType: 'BOOL', direction: FbVarDir.output),
        FbVar(name: 'StMark', dataType: 'BOOL', direction: FbVarDir.output),
      ],
      ladderRungs: [
        LdRung(rungIndex: 0, nodes: [
          LdNode(id: 'L', kind: LdKind.leftRail),
          LdNode(id: 'c', kind: LdKind.coil, variable: 'LdMark'),
          LdNode(id: 'R', kind: LdKind.rightRail),
        ], wires: [
          LdWire(fromId: 'L', toId: 'c'),
          LdWire(fromId: 'c', toId: 'R'),
        ]),
      ],
      fbdBlocks: [
        FbdBlock(id: 'k', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
        FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: 'FbdMark', tagBinding: 'FbdMark'),
      ],
      fbdWires: [
        FbdWire(fromBlockId: 'k', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
      ],
    );
    final p = projFor([both], ['A1']);
    executeFbInstance(p, both, 'A1', {}, dtMs: 100, fbdRt: FbdRuntime());
    expect(readPath(p, 'A1.LdMark'), isTrue);
    expect(readPath(p, 'A1.FbdMark'), isFalse); // ladder wins
    expect(readPath(p, 'A1.StMark'), isFalse);

    // Same definition minus the ladder body: now FBD wins over ST.
    both.ladderRungs.clear();
    final p2 = projFor([both], ['A2']);
    executeFbInstance(p2, both, 'A2', {}, dtMs: 100, fbdRt: FbdRuntime());
    expect(readPath(p2, 'A2.FbdMark'), isTrue);
    expect(readPath(p2, 'A2.StMark'), isFalse);
  });

  test('EnableIn is re-asserted true before every FBD-body call', () {
    final fb = FbDefinition(name: 'Gated', vars: [
      FbVar(name: 'EnableIn', dataType: 'BOOL', direction: FbVarDir.internal,
          initialValue: true),
      FbVar(name: 'Seen', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      // Read EnableIn -> Seen, then deliberately clear EnableIn (the FBD
      // analog of an OTU(EnableIn) rung). List order fixes the evaluation
      // order: the read is resolved before the clear is written.
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'EnableIn', tagBinding: 'EnableIn'),
      FbdBlock(id: 'seen', type: 'TAG_OUTPUT', title: 'Seen', tagBinding: 'Seen'),
      FbdBlock(id: 'kf', type: 'CONST', title: 'CONST', tagBinding: 'FALSE'),
      FbdBlock(id: 'clr', type: 'TAG_OUTPUT', title: 'EnableIn', tagBinding: 'EnableIn'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'seen', toPin: 'IN'),
      FbdWire(fromBlockId: 'kf', fromPin: 'OUT', toBlockId: 'clr', toPin: 'IN'),
    ]);
    final p = projFor([fb], ['G1']);
    final rt = FbdRuntime();

    executeFbInstance(p, fb, 'G1', {}, dtMs: 100, fbdRt: rt);
    expect(readPath(p, 'G1.Seen'), isTrue);
    expect(readPath(p, 'G1.EnableIn'), isFalse); // body cleared it

    executeFbInstance(p, fb, 'G1', {}, dtMs: 100, fbdRt: rt);
    expect(readPath(p, 'G1.Seen'), isTrue); // re-asserted, not self-disabled
  });

  test('no fbdRt degrades ONLY stateful blocks (ephemeral fallback)', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Alive', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
      FbdBlock(id: 'kt', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
      FbdBlock(id: 'al', type: 'TAG_OUTPUT', title: 'Alive', tagBinding: 'Alive'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'pt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'to', toPin: 'IN'),
      FbdWire(fromBlockId: 'kt', fromPin: 'OUT', toBlockId: 'al', toPin: 'IN'),
    ]);
    final p = projFor([fb], ['R1']);

    for (var i = 0; i < 4; i++) {
      executeFbInstance(p, fb, 'R1', {'In': true}, dtMs: 500);
    }
    expect(readPath(p, 'R1.Alive'), isTrue); // combinational still correct
    expect(readPath(p, 'R1.Out'), isFalse); // timer state lost every call
  });

  test('nested FBD AOI keeps per-instancePath state (Outer.Inner)', () {
    final inner = FbDefinition(name: 'Inner', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'i_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'i_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'i_ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'i_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'i_ti', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'i_pt', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'i_ton', fromPin: 'Q', toBlockId: 'i_to', toPin: 'IN'),
    ]);
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Nested', dataType: 'Inner', direction: FbVarDir.internal),
    ], fbdBlocks: [
      FbdBlock(id: 'o_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'o_fb', type: 'Inner', title: 'Inner', tagBinding: 'Nested'),
      FbdBlock(id: 'o_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'o_ti', fromPin: 'OUT', toBlockId: 'o_fb', toPin: 'In'),
      FbdWire(fromBlockId: 'o_fb', fromPin: 'Out', toBlockId: 'o_to', toPin: 'IN'),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        for (final i in ['O1', 'O2'])
          PlcTag(name: i, path: i, dataType: 'Outer',
              value: defaultValueFor(defaults, 'Outer', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
      fbDefinitions: [inner, outer],
    );
    final rt = FbdRuntime();

    // O1 runs twice (ET 1000 >= PT), O2 once.
    executeFbInstance(p, outer, 'O1', {'In': true}, dtMs: 500, fbdRt: rt);
    executeFbInstance(p, outer, 'O1', {'In': true}, dtMs: 500, fbdRt: rt);
    executeFbInstance(p, outer, 'O2', {'In': true}, dtMs: 500, fbdRt: rt);

    expect(readPath(p, 'O1.Nested.Out'), isTrue);
    expect(readPath(p, 'O1.Out'), isTrue);
    expect(readPath(p, 'O2.Nested.Out'), isFalse);
    expect(readPath(p, 'O2.Out'), isFalse);
  });

  test('a ladder-bodied AOI calling an FBD-bodied AOI keeps the inner timer state', () {
    final inner = FbDefinition(name: 'Inner', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'i_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'i_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'i_ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'i_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'i_ti', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'i_pt', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'i_ton', fromPin: 'Q', toBlockId: 'i_to', toPin: 'IN'),
    ]);
    // LADDER body: left rail -> FB call block (type 'Inner', instance var
    // 'Nested') -> right rail.
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Nested', dataType: 'Inner', direction: FbVarDir.internal),
    ], ladderRungs: [
      LdRung(rungIndex: 0, nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'b', kind: LdKind.block, blockType: 'Inner', variable: 'Nested',
            pinBindings: {'In': 'In', 'Out': 'Out'}),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [
        LdWire(fromId: 'L', toId: 'b'),
        LdWire(fromId: 'b', toId: 'R'),
      ]),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'O1', path: 'O1', dataType: 'Outer',
            value: defaultValueFor(defaults, 'Outer', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
      fbDefinitions: [inner, outer],
    );

    final ldRt = LdExecRuntime();
    final fbdRt = FbdRuntime();
    executeFbInstance(p, outer, 'O1', {'In': true},
        dtMs: 500, ldRt: ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'O1.Out'), isFalse); // ET 500 < PT 1000
    executeFbInstance(p, outer, 'O1', {'In': true},
        dtMs: 500, ldRt: ldRt, fbdRt: fbdRt);
    // Only true if runScopedLdBody -> executeRung -> executeFbInstance carried
    // fbdRt all the way down; with a dropped fbdRt the inner TON restarts.
    expect(readPath(p, 'O1.Out'), isTrue);
  });

  test('an FBD-bodied AOI calling a ladder-bodied AOI keeps the inner edge state', () {
    // The MIRROR of the test above, covering `executeFbInstance`'s FBD arm
    // forwarding `ldRt: ldRt` into `runScopedFbdBody`.
    //
    // NOTE the inner body uses a RISING-EDGE CONTACT, not a TON: a ladder
    // timer's accumulator lives in the instance TAG (`<base>.ACC`), so it
    // survives regardless of the runtime and would not detect a dropped
    // forward. `LdExecRuntime.prevBool` — edge contacts and pulse coils — is
    // the only ladder state a dropped `ldRt` actually loses.
    final inner = FbDefinition(name: 'Inner', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      LdRung(rungIndex: 0, nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'c', kind: LdKind.contact, variable: 'In', modifier: 'rising'),
        LdNode(id: 'o', kind: LdKind.coil, variable: 'Out', modifier: 'set'),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [
        LdWire(fromId: 'L', toId: 'c'),
        LdWire(fromId: 'c', toId: 'o'),
        LdWire(fromId: 'o', toId: 'R'),
      ]),
    ]);
    // FBD body: In -> nested ladder-bodied AOI -> Out.
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Nested', dataType: 'Inner', direction: FbVarDir.internal),
    ], fbdBlocks: [
      FbdBlock(id: 'o_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'o_fb', type: 'Inner', title: 'Inner', tagBinding: 'Nested'),
      FbdBlock(id: 'o_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'o_ti', fromPin: 'OUT', toBlockId: 'o_fb', toPin: 'In'),
      FbdWire(fromBlockId: 'o_fb', fromPin: 'Out', toBlockId: 'o_to', toPin: 'IN'),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'O1', path: 'O1', dataType: 'Outer',
            value: defaultValueFor(defaults, 'Outer', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
      fbDefinitions: [inner, outer],
    );

    final ldRt = LdExecRuntime();
    final fbdRt = FbdRuntime();
    // Call 1 with In=false records prev=false for the inner edge contact.
    executeFbInstance(p, outer, 'O1', {'In': false},
        dtMs: 100, ldRt: ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'O1.Out'), isFalse);
    // Call 2 with In=true is a RISING EDGE only if that prev survived — i.e.
    // only if executeFbInstance -> runScopedFbdBody -> _evalBlock ->
    // executeFbInstance -> runScopedLdBody carried ldRt all the way down.
    // With a dropped ldRt the ephemeral runtime seeds prev := true, no edge
    // fires, and the set-coil never latches.
    executeFbInstance(p, outer, 'O1', {'In': true},
        dtMs: 100, ldRt: ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'O1.Out'), isTrue);
  });

  test('a self-calling FBD FB is depth-capped instead of overflowing the stack', () {
    // The FBD analog of fb_ladder_exec_test.dart's ladder depth-cap test: both
    // bodies share the one `_fbCallDepth` guard in fb_exec.dart. Not reachable
    // via import (the FB registry only holds FBs defined EARLIER in the file),
    // but reachable from hand-edited/legacy JSON. Never-throws.
    //
    // `Self` is declared BOOL (not 'Loop') so building the instance's default
    // value does not itself recurse — the self-reference lives in the block's
    // `type`, which is what the executor dispatches on.
    final loop = FbDefinition(name: 'Loop', vars: [
      FbVar(name: 'X', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Self', dataType: 'BOOL', direction: FbVarDir.internal),
    ], fbdBlocks: [
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: 'X', tagBinding: 'X'),
      FbdBlock(id: 'self', type: 'Loop', title: 'Loop', tagBinding: 'Self'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'self', toPin: 'X'),
    ]);
    final p = projFor([loop], ['L1']);
    // Repeated well past the cap: the depth counter must BALANCE back to 0
    // after EVERY capped call, because the cap is a re-armable guard, not a
    // one-shot fuse. An unbalanced ++/-- would let the counter creep past the
    // cap and silently no-op every later FB call in the session.
    for (var i = 0; i < 20; i++) { // > fb_exec's private cap of 16
      expect(
          () => executeFbInstance(p, loop, 'L1', {'X': true},
              dtMs: 100, fbdRt: FbdRuntime()),
          returnsNormally);
    }
    // The guard re-armed: an ordinary FBD-bodied FB still executes afterwards.
    final ok = FbDefinition(name: 'Ok', vars: [
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'k', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'k', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
    ]);
    final p2 = projFor([ok], ['K1']);
    expect(
        executeFbInstance(p2, ok, 'K1', {}, dtMs: 100, fbdRt: FbdRuntime())['Out'],
        isTrue);
  });
}
