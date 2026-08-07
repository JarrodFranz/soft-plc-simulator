// Scoped FBD executor units: an FB's FBD body runs against ONE instance's
// struct (LdScope rewriting) with per-instance stateful-block state
// ('fb:<instancePath>|<blockId>' keys). Never touches same-named globals.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

/// FB interface used by every fixture below: In (BOOL in), Out (BOOL out).
FbDefinition _rampFb() => FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);

/// TAG_INPUT('In') -> TON(PT = CONST 1000) -> TAG_OUTPUT('Out').
List<FbdBlock> _tonBlocks() => [
      FbdBlock(id: 'b_in', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'b_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'b_ton', type: 'TON', title: 'TON'),
      FbdBlock(
          id: 'b_out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ];

List<FbdWire> _tonWires() => [
      FbdWire(
          fromBlockId: 'b_in', fromPin: 'OUT', toBlockId: 'b_ton', toPin: 'IN'),
      FbdWire(
          fromBlockId: 'b_pt', fromPin: 'OUT', toBlockId: 'b_ton', toPin: 'PT'),
      FbdWire(
          fromBlockId: 'b_ton', fromPin: 'Q', toBlockId: 'b_out', toPin: 'IN'),
    ];

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

/// Project with FB `Ramp`, instance tags [instances], and same-named GLOBAL
/// `In`/`Out` BOOLs that a correctly-scoped body must never touch.
PlcProject _proj(FbDefinition fb, List<String> instances) {
  final defaults = PlcProject(
      id: 'd',
      name: 'd',
      controllerName: 'c',
      tags: [],
      structDefs: [],
      programs: [],
      tasks: [],
      hmis: [],
      fbDefinitions: [fb]);
  return PlcProject(
    id: 'p',
    name: 'P',
    controllerName: 'C',
    tags: [
      _tag('In', 'BOOL', false),
      _tag('Out', 'BOOL', false),
      for (final i in instances)
        _tag(i, fb.name, defaultValueFor(defaults, fb.name, 0)),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    fbDefinitions: [fb],
  );
}

void main() {
  test(
      'TAG_INPUT/TAG_OUTPUT bind to <instance>.<var>, never same-named globals',
      () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    final scope = LdScope('R1', {'In', 'Out'});
    writePath(p, 'R1.In', true);

    final rt = FbdRuntime();
    runScopedFbdBody(p, _tonBlocks(), _tonWires(), scope, 500, rt);
    expect(readPath(p, 'R1.Out'), isFalse); // ET 500 < PT 1000
    runScopedFbdBody(p, _tonBlocks(), _tonWires(), scope, 500, rt);
    expect(readPath(p, 'R1.Out'), isTrue); // ET 1000 >= PT 1000

    // The same-named globals were never read (global In stayed false yet the
    // instance timed) and never written.
    expect(readPath(p, 'In'), isFalse);
    expect(readPath(p, 'Out'), isFalse);
  });

  test('a non-var binding still resolves to the global', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    p.tags.add(_tag('Global_Out', 'BOOL', false));
    final blocks = _tonBlocks()
      ..removeWhere((b) => b.id == 'b_out')
      ..add(FbdBlock(
          id: 'b_out',
          type: 'TAG_OUTPUT',
          title: 'G',
          tagBinding: 'Global_Out'));
    writePath(p, 'R1.In', true);

    final rt = FbdRuntime();
    runScopedFbdBody(
        p, blocks, _tonWires(), LdScope('R1', {'In', 'Out'}), 2000, rt);
    expect(readPath(p, 'Global_Out'), isTrue); // not a var name -> global
  });

  test('CONST is NOT rewritten by the scope', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    writePath(p, 'R1.In', true);
    // Deliberately hostile scope: '1000' is listed as a local var name. If the
    // CONST branch rewrote its tagBinding it would become 'R1.1000', parse to
    // null, and the TON would see PT = 0 (Q true on the FIRST scan).
    final scope = LdScope('R1', {'In', 'Out', '1000'});
    runScopedFbdBody(p, _tonBlocks(), _tonWires(), scope, 500, FbdRuntime());
    expect(readPath(p, 'R1.Out'), isFalse);
  });

  test('two instances keep independent stateful-block state', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1', 'R2']);
    final rt = FbdRuntime();
    final blocks = _tonBlocks();
    final wires = _tonWires();
    writePath(p, 'R1.In', true);
    writePath(p, 'R2.In', true);

    // R1 gets two scans, R2 only one: same block ids, disjoint state keys.
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 500, rt);
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 500, rt);
    runScopedFbdBody(p, blocks, wires, LdScope('R2', {'In', 'Out'}), 500, rt);

    expect(readPath(p, 'R1.Out'), isTrue);
    expect(readPath(p, 'R2.Out'), isFalse);
  });

  test('R_TRIG state is per instance too', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1', 'R2']);
    final blocks = [
      FbdBlock(id: 'e_in', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'e_trig', type: 'R_TRIG', title: 'R_TRIG'),
      FbdBlock(
          id: 'e_out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ];
    final wires = [
      FbdWire(
          fromBlockId: 'e_in',
          fromPin: 'OUT',
          toBlockId: 'e_trig',
          toPin: 'CLK'),
      FbdWire(
          fromBlockId: 'e_trig', fromPin: 'Q', toBlockId: 'e_out', toPin: 'IN'),
    ];
    final rt = FbdRuntime();
    writePath(p, 'R1.In', true);
    writePath(p, 'R2.In', true);

    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R1.Out'), isTrue); // first rising edge for R1
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R1.Out'), isFalse); // no second edge for R1
    runScopedFbdBody(p, blocks, wires, LdScope('R2', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R2.Out'), isTrue); // R2's own first edge
  });

  test('CTU counter state is per instance too', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1', 'R2']);
    final blocks = [
      FbdBlock(id: 'c_in', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'c_pv', type: 'CONST', title: 'CONST', tagBinding: '2'),
      FbdBlock(id: 'c_ctu', type: 'CTU', title: 'CTU'),
      FbdBlock(
          id: 'c_out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ];
    final wires = [
      FbdWire(
          fromBlockId: 'c_in', fromPin: 'OUT', toBlockId: 'c_ctu', toPin: 'CU'),
      FbdWire(
          fromBlockId: 'c_pv', fromPin: 'OUT', toBlockId: 'c_ctu', toPin: 'PV'),
      FbdWire(
          fromBlockId: 'c_ctu', fromPin: 'Q', toBlockId: 'c_out', toPin: 'IN'),
    ];
    final rt = FbdRuntime();
    final r1 = LdScope('R1', {'In', 'Out'});
    writePath(p, 'R2.In', true);

    // Two CU rising edges for R1 -> CV 2 >= PV 2. R2 then gets ONE edge, so
    // its own CV is 1 and Q stays false. Were `_counters` keyed by the bare
    // block id, R2 would inherit R1's CV of 2 AND its prev-CU level of 1 (no
    // edge, no count) and read back Q true.
    writePath(p, 'R1.In', true);
    runScopedFbdBody(p, blocks, wires, r1, 100, rt);
    writePath(p, 'R1.In', false);
    runScopedFbdBody(p, blocks, wires, r1, 100, rt);
    writePath(p, 'R1.In', true);
    runScopedFbdBody(p, blocks, wires, r1, 100, rt);
    expect(readPath(p, 'R1.Out'), isTrue);

    runScopedFbdBody(p, blocks, wires, LdScope('R2', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R2.Out'), isFalse);
  });

  test('TP pulse state is per instance too', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1', 'R2']);
    final blocks = [
      FbdBlock(id: 'p_in', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'p_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'p_tp', type: 'TP', title: 'TP'),
      FbdBlock(
          id: 'p_out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ];
    final wires = [
      FbdWire(
          fromBlockId: 'p_in', fromPin: 'OUT', toBlockId: 'p_tp', toPin: 'IN'),
      FbdWire(
          fromBlockId: 'p_pt', fromPin: 'OUT', toBlockId: 'p_tp', toPin: 'PT'),
      FbdWire(
          fromBlockId: 'p_tp', fromPin: 'Q', toBlockId: 'p_out', toPin: 'IN'),
    ];
    final rt = FbdRuntime();
    final r1 = LdScope('R1', {'In', 'Out'});
    writePath(p, 'R1.In', true);
    writePath(p, 'R2.In', true);

    // R1 runs its 1000 ms pulse to completion (400+400+400).
    runScopedFbdBody(p, blocks, wires, r1, 400, rt);
    expect(readPath(p, 'R1.Out'), isTrue);
    runScopedFbdBody(p, blocks, wires, r1, 400, rt);
    runScopedFbdBody(p, blocks, wires, r1, 400, rt);
    expect(readPath(p, 'R1.Out'), isFalse); // ET reached PT, pulse over

    // R2's FIRST scan is its own start edge, so its pulse begins now. Were
    // `_pulse` keyed by the bare block id, R2 would inherit R1's spent state
    // (prevIN 1 -> no start edge, running 0) and never pulse at all.
    runScopedFbdBody(p, blocks, wires, LdScope('R2', {'In', 'Out'}), 400, rt);
    expect(readPath(p, 'R2.Out'), isTrue);
  });

  test('readOnly gates a global body output but never an instance member', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    p.tags.add(_tag('Gen', 'BOOL', false));
    final blocks = [
      FbdBlock(id: 'c1', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
      FbdBlock(
          id: 'o_inst', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
      FbdBlock(
          id: 'o_glob', type: 'TAG_OUTPUT', title: 'Gen', tagBinding: 'Gen'),
    ];
    final wires = [
      FbdWire(
          fromBlockId: 'c1', fromPin: 'OUT', toBlockId: 'o_inst', toPin: 'IN'),
      FbdWire(
          fromBlockId: 'c1', fromPin: 'OUT', toBlockId: 'o_glob', toPin: 'IN'),
    ];

    // 'Out' names a var, so the gate must be evaluated on the REWRITTEN path
    // ('R1.Out'), which no readOnly entry names.
    runScopedFbdBody(
        p, blocks, wires, LdScope('R1', {'In', 'Out'}), 100, FbdRuntime(),
        readOnly: {'Gen', 'Out'});

    expect(readPath(p, 'R1.Out'), isTrue);
    expect(readPath(p, 'Gen'), isFalse); // read-only global untouched
  });

  test('an empty body is a no-op and never throws', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    runScopedFbdBody(
        p, const [], const [], LdScope('R1', {'In', 'Out'}), 100, FbdRuntime());
    expect(readPath(p, 'R1.Out'), isFalse);
  });
}
