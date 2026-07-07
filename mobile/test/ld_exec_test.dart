import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProject _proj(List<PlcTag> tags, List<PlcProgram> programs, {List<PlcStructDef>? structDefs}) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: structDefs ?? [], programs: programs, tasks: [], hmis: [],
    );

/// A minimal counter DUT with the fields every CTU/CTD/CTUD test needs;
/// unused fields for a given block are simply ignored by the engine.
final PlcStructDef _counterDef = PlcStructDef(name: 'COUNTER', fields: [
  StructFieldDef(name: 'CU', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'CD', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'PV', dataType: 'INT32', defaultValue: 0),
  StructFieldDef(name: 'CV', dataType: 'INT32', defaultValue: 0),
  StructFieldDef(name: 'QU', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'QD', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'R', dataType: 'BOOL', defaultValue: false),
]);

PlcTag _counterTag(String n) => PlcTag(
      name: n, path: n, dataType: 'COUNTER',
      value: defaultValueFor(_proj([], [], structDefs: [_counterDef]), 'COUNTER', 0),
      ioType: 'Internal',
    );

/// A counter tag with `.CV` absent (as if never yet written) so CTD's
/// "load PV when absent" branch (`readPath(...) == null`) is exercised.
PlcTag _counterTagNoCv(String n) {
  final v = defaultValueFor(_proj([], [], structDefs: [_counterDef]), 'COUNTER', 0) as Map;
  final m = Map<String, dynamic>.from(v)..remove('CV');
  return PlcTag(name: n, path: n, dataType: 'COUNTER', value: m, ioType: 'Internal');
}

LdNode _no(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode _nc(String v) => LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'negated');
LdNode _coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

PlcProgram _ldProg(List<LdRung> rungs) =>
    PlcProgram(name: 'P1', language: 'LadderLogic', rungs: rungs);

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('series contacts AND to the coil', () {
    final r = buildRung(index: 0, main: [_no('A'), _no('B'), _coil('Y')]);
    final p = _proj([_tag('A', 'BOOL', true), _tag('B', 'BOOL', false), _tag('Y', 'BOOL', false)],
        [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Y'), isFalse);
    writePath(p, 'B', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Y'), isTrue);
  });

  test('parallel branch ORs (seal-in holds, Stop NC drops it)', () {
    final r = buildRung(
      index: 0,
      main: [_no('Start'), _nc('Stop'), _coil('Motor')],
      branches: [BranchSpec(startIndex: 0, endIndex: 0, nodes: [_no('Motor')])],
    );
    final p = _proj(
        [_tag('Start', 'BOOL', false), _tag('Stop', 'BOOL', false), _tag('Motor', 'BOOL', false)],
        [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isFalse);
    writePath(p, 'Start', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isTrue);
    writePath(p, 'Start', false); // seal-in must hold via the Motor branch
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isTrue);
    writePath(p, 'Stop', true); // NC contact opens
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isFalse);
  });

  test('set/reset coils latch and unlatch', () {
    final r0 = buildRung(index: 0, main: [
      _no('SetBtn'),
      LdNode(id: '', kind: LdKind.coil, variable: 'L', modifier: 'set'),
    ]);
    final r1 = buildRung(index: 1, main: [
      _no('RstBtn'),
      LdNode(id: '', kind: LdKind.coil, variable: 'L', modifier: 'reset'),
    ]);
    final p = _proj(
        [_tag('SetBtn', 'BOOL', true), _tag('RstBtn', 'BOOL', false), _tag('L', 'BOOL', false)],
        [_ldProg([r0, r1])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'L'), isTrue);
    writePath(p, 'SetBtn', false); // latch holds without power
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'L'), isTrue);
    writePath(p, 'RstBtn', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'L'), isFalse);
  });

  test('rising-edge contact fires for exactly one scan', () {
    final r = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'In', modifier: 'rising'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Out', modifier: 'set'),
    ]);
    final p = _proj([_tag('In', 'BOOL', false), _tag('Out', 'BOOL', false)], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // establishes prev=false, no edge on first scan
    expect(_b(p, 'Out'), isFalse);
    writePath(p, 'In', true);
    executeLdPrograms(p, 100, rt); // edge -> latch Out
    expect(_b(p, 'Out'), isTrue);
  });

  test('TON accumulates by dt, DN at PRE, resets when IN drops', () {
    final r = buildRung(index: 0, main: [
      _no('Run'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
      _coil('Done'),
    ]);
    final p = _proj([
      _tag('Run', 'BOOL', true),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Done', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // ACC=100
    expect(_b(p, 'T.DN'), isFalse);
    expect(_b(p, 'Done'), isFalse);
    executeLdPrograms(p, 100, rt); // 200
    executeLdPrograms(p, 100, rt); // 300 -> DN
    expect(_b(p, 'T.DN'), isTrue);
    expect(_b(p, 'Done'), isTrue); // block output power = DN drives the coil
    expect((readPath(p, 'T.PRE') as num).toInt(), equals(300)); // PRE synced from block
    writePath(p, 'Run', false);
    executeLdPrograms(p, 100, rt); // IN drops -> reset
    expect(_b(p, 'T.DN'), isFalse);
    expect((readPath(p, 'T.ACC') as num).toInt(), equals(0));
  });

  test('TOF holds Q for PRE after IN drops', () {
    final r = buildRung(index: 0, main: [
      _no('Run'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TOF', variable: 'T', presetMs: 200),
      _coil('Q'),
    ]);
    final p = _proj([
      _tag('Run', 'BOOL', true),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Q', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Q'), isTrue); // Q while IN
    writePath(p, 'Run', false);
    executeLdPrograms(p, 100, rt); // 100 elapsed of 200 hold
    expect(_b(p, 'Q'), isTrue);
    executeLdPrograms(p, 100, rt); // 200 -> hold expires
    expect(_b(p, 'Q'), isFalse);
  });

  test('writes are visible to later rungs in the same scan', () {
    final r0 = buildRung(index: 0, main: [_no('A'), _coil('Mid')]);
    final r1 = buildRung(index: 1, main: [_no('Mid'), _coil('Out')]);
    final p = _proj(
        [_tag('A', 'BOOL', true), _tag('Mid', 'BOOL', false), _tag('Out', 'BOOL', false)],
        [_ldProg([r0, r1])]);
    executeLdPrograms(p, 100, LdExecRuntime());
    expect(_b(p, 'Out'), isTrue); // rung 1 saw rung 0's write this scan
  });

  test('a forced root tag is not overwritten by a coil', () {
    final r = buildRung(index: 0, main: [_no('A'), _coil('Y')]);
    final p = _proj(
        [_tag('A', 'BOOL', true), _tag('Y', 'BOOL', false, forced: true, fv: false)],
        [_ldProg([r])]);
    executeLdPrograms(p, 100, LdExecRuntime());
    expect(readPath(p, 'Y'), isFalse); // untouched (forced)
  });

  test('unknown contact tag reads as false, no throw', () {
    final r = buildRung(index: 0, main: [_no('Ghost'), _coil('Y')]);
    final p = _proj([_tag('Y', 'BOOL', true)], [_ldProg([r])]);
    executeLdPrograms(p, 100, LdExecRuntime());
    expect(_b(p, 'Y'), isFalse); // Ghost=false -> coil de-energized
  });

  test('non-LD programs are skipped', () {
    final p = _proj([_tag('Y', 'BOOL', false)],
        [PlcProgram(name: 'S', language: 'StructuredText')]);
    executeLdPrograms(p, 100, LdExecRuntime()); // must not throw
    expect(_b(p, 'Y'), isFalse);
  });

  test('negated coil writes the inverse of rung power', () {
    final r = buildRung(index: 0, main: [
      _no('A'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Y', modifier: 'negated'),
    ]);
    final p = _proj([_tag('A', 'BOOL', false), _tag('Y', 'BOOL', false)], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Y'), isTrue); // no power -> negated coil energized
    writePath(p, 'A', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Y'), isFalse);
  });

  test('falling-edge contact fires when the tag drops', () {
    final r = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'In', modifier: 'falling'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Out', modifier: 'set'),
    ]);
    final p = _proj([_tag('In', 'BOOL', true), _tag('Out', 'BOOL', false)], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // prev seeded true, no edge
    expect(_b(p, 'Out'), isFalse);
    writePath(p, 'In', false);
    executeLdPrograms(p, 100, rt); // falling edge
    expect(_b(p, 'Out'), isTrue);
  });

  test('rising pulse coil is true for exactly one scan', () {
    final r = buildRung(index: 0, main: [
      _no('A'),
      LdNode(id: '', kind: LdKind.coil, variable: 'P', modifier: 'rising'),
    ]);
    final p = _proj([_tag('A', 'BOOL', false), _tag('P', 'BOOL', false)], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'P'), isFalse);
    writePath(p, 'A', true);
    executeLdPrograms(p, 100, rt); // power rising edge -> pulse
    expect(_b(p, 'P'), isTrue);
    executeLdPrograms(p, 100, rt); // still powered, no edge -> pulse over
    expect(_b(p, 'P'), isFalse);
  });

  test('TON exposes EN and TT while timing, TT clears at DN', () {
    final r = buildRung(index: 0, main: [
      _no('Run'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 200),
    ]);
    final p = _proj([
      _tag('Run', 'BOOL', true),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // timing
    expect(_b(p, 'T.EN'), isTrue);
    expect(_b(p, 'T.TT'), isTrue);
    executeLdPrograms(p, 100, rt); // DN
    expect(_b(p, 'T.DN'), isTrue);
    expect(_b(p, 'T.TT'), isFalse);
  });

  test('block output powers further series elements downstream', () {
    final r = buildRung(index: 0, main: [
      _no('Run'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 100),
      _no('Gate'),
      _coil('Y'),
    ]);
    final p = _proj([
      _tag('Run', 'BOOL', true),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Gate', 'BOOL', false),
      _tag('Y', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // DN true but Gate false
    expect(_b(p, 'Y'), isFalse);
    writePath(p, 'Gate', true);
    executeLdPrograms(p, 100, rt); // DN AND Gate
    expect(_b(p, 'Y'), isTrue);
  });

  test('TP emits a pulse of exactly ceil(pre/dt) scans and is not retriggerable mid-pulse', () {
    final r = buildRung(index: 0, main: [
      _no('In'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TP', variable: 'T', presetMs: 300),
      _coil('Q'),
    ]);
    final p = _proj([
      _tag('In', 'BOOL', false),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Q', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // no edge yet
    expect(_b(p, 'Q'), isFalse);

    writePath(p, 'In', true);
    executeLdPrograms(p, 100, rt); // rising edge -> pulse starts, ACC=100
    expect(_b(p, 'Q'), isTrue);

    writePath(p, 'In', false); // mid-pulse IN drop must NOT cut the pulse short
    executeLdPrograms(p, 100, rt); // ACC=200
    expect(_b(p, 'Q'), isTrue);

    executeLdPrograms(p, 100, rt); // ACC=300 -> pulse complete, Q drops
    expect(_b(p, 'Q'), isFalse);
    expect((readPath(p, 'T.ACC') as num).toInt(), equals(0));

    // A held-high input after completion should not keep it pulsing; only a
    // fresh rising edge retriggers.
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Q'), isFalse);

    writePath(p, 'In', true);
    executeLdPrograms(p, 100, rt); // fresh rising edge -> retriggers
    expect(_b(p, 'Q'), isTrue);
  });

  test('TP with a sub-scan preset (presetMs <= dtMs) still pulses Q true for the starting scan', () {
    final r = buildRung(index: 0, main: [
      _no('In'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TP', variable: 'T', presetMs: 50),
      _coil('Q'),
    ]);
    final p = _proj([
      _tag('In', 'BOOL', false),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Q', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // no edge yet
    expect(_b(p, 'Q'), isFalse);

    writePath(p, 'In', true);
    executeLdPrograms(p, 100, rt); // rising edge, dtMs(100) >= presetMs(50)
    // The pulse must be observable for at least this starting scan.
    expect(_b(p, 'Q'), isTrue);
    expect(_b(p, 'T.DN'), isTrue);

    executeLdPrograms(p, 100, rt); // next scan -> pulse has completed
    expect(_b(p, 'Q'), isFalse);
    expect((readPath(p, 'T.ACC') as num).toInt(), equals(0));
  });

  test('CTU counts once per rising edge, saturates, QU at PV, resets on R', () {
    final r = buildRung(index: 0, main: [
      _no('PB'),
      LdNode(id: '', kind: LdKind.block, blockType: 'CTU', variable: 'Cnt', presetMs: 2),
      _coil('Done'),
    ]);
    final p = _proj(
      [_tag('PB', 'BOOL', false), _counterTag('Cnt'), _tag('Done', 'BOOL', false)],
      [_ldProg([r])],
      structDefs: [_counterDef],
    );
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));

    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge 1 -> CV 1
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(1));

    executeLdPrograms(p, 100, rt); // held high, no new edge -> CV still 1
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(1));

    writePath(p, 'PB', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge 2 -> CV 2, QU true (PV 2)
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(2));
    expect(_b(p, 'Cnt.QU'), isTrue);
    expect(_b(p, 'Done'), isTrue); // block output feeds the coil

    writePath(p, 'Cnt.R', true);
    executeLdPrograms(p, 100, rt);
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));
    expect(_b(p, 'Cnt.QU'), isFalse);
  });

  test('CTD reloads CV to PV and decrements to 0 on rising edges', () {
    final r = buildRung(index: 0, main: [
      _no('PB'),
      LdNode(id: '', kind: LdKind.block, blockType: 'CTD', variable: 'Cnt', presetMs: 2),
      _coil('Done'),
    ]);
    final p = _proj(
      [_tag('PB', 'BOOL', false), _counterTagNoCv('Cnt'), _tag('Done', 'BOOL', false)],
      [_ldProg([r])],
      structDefs: [_counterDef],
    );
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // CV absent (null) -> loads to PV=2
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(2));
    expect(_b(p, 'Cnt.QD'), isFalse);

    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge -> CV 1
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(1));

    writePath(p, 'PB', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge -> CV 0 -> QD
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));
    expect(_b(p, 'Cnt.QD'), isTrue);
    expect(_b(p, 'Done'), isTrue);

    writePath(p, 'Cnt.R', true);
    executeLdPrograms(p, 100, rt); // reset reloads PV
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(2));
  });

  test('CTD preloads CV to PV on its first scan even when CV starts at 0 (editor default)', () {
    final r = buildRung(index: 0, main: [
      _no('PB'),
      LdNode(id: '', kind: LdKind.block, blockType: 'CTD', variable: 'Cnt', presetMs: 3),
      _coil('Done'),
    ]);
    // A normal editor-placed COUNTER tag: CV is present and initialized to 0,
    // not absent/null. Before the fix, CTD only preloaded when CV was null,
    // so this tag would start at CV=0 -> QD true immediately.
    final p = _proj(
      [_tag('PB', 'BOOL', false), _counterTag('Cnt'), _tag('Done', 'BOOL', false)],
      [_ldProg([r])],
      structDefs: [_counterDef],
    );
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0)); // sanity: starts at 0, not null

    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // first scan, no count input yet -> must preload CV to PV
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(3));
    expect(_b(p, 'Cnt.QD'), isFalse);

    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge -> CV 2
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(2));

    writePath(p, 'PB', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge -> CV 1
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(1));

    writePath(p, 'PB', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'PB', true);
    executeLdPrograms(p, 100, rt); // edge -> CV 0 -> QD
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));
    expect(_b(p, 'Cnt.QD'), isTrue);
    expect(_b(p, 'Done'), isTrue);

    writePath(p, 'Cnt.R', true);
    executeLdPrograms(p, 100, rt); // reset reloads PV
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(3));
  });

  test('CTUD counts up then down and clamps at [0, PV]', () {
    final r = buildRung(index: 0, main: [
      _no('Up'),
      LdNode(id: '', kind: LdKind.block, blockType: 'CTUD', variable: 'Cnt', presetMs: 2, operandA: 'Down'),
      _coil('Done'),
    ]);
    final p = _proj(
      [
        _tag('Up', 'BOOL', false),
        _tag('Down', 'BOOL', false),
        _counterTag('Cnt'),
        _tag('Done', 'BOOL', false),
      ],
      [_ldProg([r])],
      structDefs: [_counterDef],
    );
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));

    writePath(p, 'Up', true);
    executeLdPrograms(p, 100, rt); // up edge -> CV 1
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(1));

    writePath(p, 'Up', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'Up', true);
    executeLdPrograms(p, 100, rt); // up edge -> CV 2 (== PV) -> QU
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(2));
    expect(_b(p, 'Cnt.QU'), isTrue);
    expect(_b(p, 'Done'), isTrue);

    writePath(p, 'Up', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'Up', true);
    executeLdPrograms(p, 100, rt); // another up edge -> clamp at PV=2
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(2));

    writePath(p, 'Down', true);
    executeLdPrograms(p, 100, rt); // down edge -> CV 1
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(1));
    expect(_b(p, 'Cnt.QU'), isFalse);

    writePath(p, 'Down', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'Down', true);
    executeLdPrograms(p, 100, rt); // down edge -> CV 0 -> QD
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));
    expect(_b(p, 'Cnt.QD'), isTrue);

    writePath(p, 'Down', false);
    executeLdPrograms(p, 100, rt);
    writePath(p, 'Down', true);
    executeLdPrograms(p, 100, rt); // another down edge -> clamp at 0
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));

    writePath(p, 'Cnt.R', true);
    executeLdPrograms(p, 100, rt);
    expect((readPath(p, 'Cnt.CV') as num).toInt(), equals(0));
  });
}
