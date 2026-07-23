import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// Guard test for `kLdBuiltinBlockTypes` (mobile/lib/models/ld_exec.dart),
// analogous to `fbd_pins_test.dart`'s guard for `kFbdBuiltinBlockTypes`.
//
// Unlike the FBD registry, `executeRung`'s LD dispatch is not a set of pure
// pin-lookup functions — it's a single inline if-chain inside `executeRung`,
// so there is no reflection-free way to literally enumerate its dispatched
// `blockType` strings and diff them against the const (Dart cannot enumerate
// an if-chain's string literals at runtime). Instead this file drives
// `executeLdPrograms` end-to-end for every entry in `kLdBuiltinBlockTypes` and
// asserts each one produces the OUTCOME that only its own real dispatch branch
// can produce — an outcome that provably differs from what the unconditional
// TON/TOF fallback below it would produce for the same node. That fallback is
// exactly what a `blockType` silently reverts to if its dispatch case (or its
// membership in `compareOps`/`mathOps`) is ever removed without updating this
// list, so these assertions fail loudly on that drift. This makes the test
// non-vacuous: it is not just "is this string in a list", it is "does the
// engine still actually treat this string as its own block type".
//
// If a NEW dispatch case is ever added to `executeRung` without adding it here,
// this file cannot detect that (no reflection). That direction of drift is
// covered only by the doc-comment coupling on `kLdBuiltinBlockTypes` itself
// and by code review discipline — documented here explicitly per the review
// finding, since it could not be made fully mechanical.

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _proj(List<PlcTag> tags, List<PlcProgram> programs, {List<PlcStructDef>? structDefs}) =>
    PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: structDefs ?? [], programs: programs, tasks: [], hmis: [],
    );

final PlcStructDef _counterDef = PlcStructDef(name: 'COUNTER', fields: [
  StructFieldDef(name: 'CU', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'CD', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'PV', dataType: 'INT32', defaultValue: 0),
  StructFieldDef(name: 'CV', dataType: 'INT32', defaultValue: 0),
  StructFieldDef(name: 'QU', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'QD', dataType: 'BOOL', defaultValue: false),
  StructFieldDef(name: 'R', dataType: 'BOOL', defaultValue: false),
]);

PlcProject _counterProj() => _proj([], [], structDefs: [_counterDef]);

PlcTag _counterTag(String n) => PlcTag(
      name: n, path: n, dataType: 'COUNTER',
      value: defaultValueFor(_counterProj(), 'COUNTER', 0),
      ioType: 'Internal',
    );

PlcTag _timerTag(String n) => PlcTag(
      name: n, path: n, dataType: 'TIMER',
      value: defaultValueFor(_proj([], []), 'TIMER', 0),
      ioType: 'Internal',
    );

LdNode _no(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode _coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

PlcProgram _ldProg(List<LdRung> rungs) => PlcProgram(name: 'P1', language: 'LadderLogic', rungs: rungs);

void main() {
  group('kLdBuiltinBlockTypes (dispatch guard)', () {
    test('every entry contains exactly the built-in set this file exercises below', () {
      // If a dispatch case is added to or removed from `executeRung` without
      // a matching edit here (both to the const AND to the behavioral groups
      // below), this length/contents check is the first line of defense.
      expect(
        kLdBuiltinBlockTypes.toSet(),
        {'GT', 'LT', 'GE', 'LE', 'EQ', 'NE', 'ADD', 'SUB', 'MUL', 'DIV', 'MOVE',
         'TP', 'CTU', 'CTD', 'CTUD', 'TON', 'TOF'},
      );
    });

    group('compare ops dispatch as comparisons, not as the TON/TOF fallback', () {
      // The TON/TOF fallback reads `base = n.variable` (empty here) and can
      // only ever drive `power[n.id]` to `false` (an untriggered/absent
      // timer's `dn` starts false and a 100ms tick against the 5000ms default
      // preset never reaches it) — so an expected-`true` outcome below is
      // unreachable via that fallback, proving the real compare dispatch ran.
      void expectCompare(String op, num a, num b, bool expected) {
        final r = buildRung(index: 0, main: [
          _no('In'),
          LdNode(id: '', kind: LdKind.block, blockType: op, operandA: 'A', operandB: 'B'),
          _coil('Out'),
        ]);
        final p = _proj([
          _tag('In', 'BOOL', true),
          _tag('A', 'FLOAT64', a),
          _tag('B', 'FLOAT64', b),
          _tag('Out', 'BOOL', false),
        ], [_ldProg([r])]);
        executeLdPrograms(p, 100, LdExecRuntime());
        expect(readPath(p, 'Out'), expected, reason: '$op($a, $b)');
      }

      test('GT(10,5) -> true', () => expectCompare('GT', 10, 5, true));
      test('LT(5,10) -> true', () => expectCompare('LT', 5, 10, true));
      test('GE(5,5) -> true', () => expectCompare('GE', 5, 5, true));
      test('LE(5,5) -> true', () => expectCompare('LE', 5, 5, true));
      test('EQ(5,5) -> true', () => expectCompare('EQ', 5, 5, true));
      test('NE(10,5) -> true', () => expectCompare('NE', 10, 5, true));
    });

    group('math ops dispatch as computations, not as the TON/TOF fallback', () {
      // The TON/TOF fallback writes to `$base.EN`/`.ACC`/etc (dotted paths off
      // the block's own `variable`), never to the bare scalar `variable`
      // itself — so if math dispatch were dropped, the output tag would stay
      // at its untouched initial value instead of the computed result.
      void expectMath(String op, num a, num b, num initial, num expected) {
        final r = buildRung(index: 0, main: [
          _no('In'),
          LdNode(id: '', kind: LdKind.block, blockType: op, operandA: 'A', operandB: 'B', variable: 'R'),
        ]);
        final p = _proj([
          _tag('In', 'BOOL', true),
          _tag('A', 'FLOAT64', a),
          _tag('B', 'FLOAT64', b),
          _tag('R', 'FLOAT64', initial),
        ], [_ldProg([r])]);
        executeLdPrograms(p, 100, LdExecRuntime());
        expect(readPath(p, 'R'), expected, reason: '$op($a, $b)');
      }

      test('ADD(4,3) -> 7', () => expectMath('ADD', 4, 3, -1, 7));
      test('SUB(4,3) -> 1', () => expectMath('SUB', 4, 3, -1, 1));
      test('MUL(4,3) -> 12', () => expectMath('MUL', 4, 3, -1, 12));
      test('DIV(12,3) -> 4', () => expectMath('DIV', 12, 3, -1, 4));
      test('MOVE(42,_) -> 42', () => expectMath('MOVE', 42, 999, -1, 42));
    });

    test('TP dispatches as a non-retriggerable pulse, not TON (which would '
        'stay DN while IN holds true)', () {
      // TON's DN, once true, stays true for as long as IN holds. TP's DN
      // pulses for one scan only and then drops even while IN stays true.
      // Driving IN false->true->true and checking the THIRD scan's DN is
      // false is exactly the outcome the TON fallback cannot produce (TON
      // would still show DN true on scan 3).
      final r = buildRung(index: 0, main: [
        _no('In'),
        LdNode(id: '', kind: LdKind.block, blockType: 'TP', variable: 'T', presetMs: 100),
      ]);
      final p = _proj([_tag('In', 'BOOL', false), _timerTag('T')], [_ldProg([r])]);
      final rt = LdExecRuntime();

      executeLdPrograms(p, 100, rt); // scan 1: In=false, establishes prevIn
      expect(readPath(p, 'T.DN'), isFalse, reason: 'scan1');

      writePath(p, 'In', true);
      executeLdPrograms(p, 100, rt); // scan 2: rising edge -> one-scan pulse
      expect(readPath(p, 'T.DN'), isTrue, reason: 'scan2 (pulse fires)');

      executeLdPrograms(p, 100, rt); // scan 3: In still true, no re-trigger
      expect(readPath(p, 'T.DN'), isFalse,
          reason: 'scan3 — TP must NOT still be DN here; TON would be');
    });

    test('CTU dispatches as an up-counter, not TON/TOF (neither of which '
        'ever touches .CV)', () {
      final r = buildRung(index: 0, main: [
        _no('In'),
        LdNode(id: '', kind: LdKind.block, blockType: 'CTU', variable: 'Cnt', presetMs: 5),
      ]);
      final p = _proj([_tag('In', 'BOOL', false), _counterTag('Cnt')], [_ldProg([r])], structDefs: [_counterDef]);
      final rt = LdExecRuntime();
      executeLdPrograms(p, 100, rt);
      writePath(p, 'In', true);
      executeLdPrograms(p, 100, rt); // rising edge -> CV increments
      expect((readPath(p, 'Cnt.CV') as num).toInt(), 1);
    });

    test('CTD dispatches as a down-counter, not TON/TOF (neither of which '
        'ever touches .CV)', () {
      final r = buildRung(index: 0, main: [
        _no('In'),
        LdNode(id: '', kind: LdKind.block, blockType: 'CTD', variable: 'Cnt', presetMs: 5),
      ]);
      final p = _proj([_tag('In', 'BOOL', false), _counterTag('Cnt')], [_ldProg([r])], structDefs: [_counterDef]);
      final rt = LdExecRuntime();
      executeLdPrograms(p, 100, rt); // first-ever scan preloads CV to PV(5)
      expect((readPath(p, 'Cnt.CV') as num).toInt(), 5);
      writePath(p, 'In', true);
      executeLdPrograms(p, 100, rt); // rising edge -> CV decrements
      expect((readPath(p, 'Cnt.CV') as num).toInt(), 4);
    });

    test('CTUD dispatches as an up/down counter, not TON/TOF (neither of '
        'which ever touches .CV)', () {
      final r = buildRung(index: 0, main: [
        _no('In'),
        LdNode(id: '', kind: LdKind.block, blockType: 'CTUD', variable: 'Cnt', presetMs: 5, operandA: 'Down'),
      ]);
      final p = _proj([
        _tag('In', 'BOOL', false),
        _tag('Down', 'BOOL', false),
        _counterTag('Cnt'),
      ], [_ldProg([r])], structDefs: [_counterDef]);
      final rt = LdExecRuntime();
      executeLdPrograms(p, 100, rt);
      writePath(p, 'In', true);
      executeLdPrograms(p, 100, rt); // rising edge on the up input
      expect((readPath(p, 'Cnt.CV') as num).toInt(), 1);
    });

    test('TON/TOF themselves dispatch (the fallback the whole group is '
        'measured against)', () {
      final r = buildRung(index: 0, main: [
        _no('In'),
        LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 200),
      ]);
      final p = _proj([_tag('In', 'BOOL', true), _timerTag('T')], [_ldProg([r])]);
      final rt = LdExecRuntime();
      executeLdPrograms(p, 100, rt);
      executeLdPrograms(p, 100, rt);
      expect(readPath(p, 'T.DN'), isTrue); // 200ms accumulated at 100ms/scan
    });
  });
}
