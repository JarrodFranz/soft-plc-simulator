import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProgram _fbd(List<FbdBlock> blocks, List<FbdWire> wires) {
  final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
  prog.fbdBlocks.addAll(blocks);
  prog.fbdWires.addAll(wires);
  return prog;
}

PlcProject _proj(List<PlcTag> tags, PlcProgram prog) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

void _run(PlcProject p, [FbdRuntime? rt, int dtMs = 500]) =>
    executeFbdPrograms(p, dtMs, rt ?? FbdRuntime());

void main() {
  test('TAG_INPUT -> NOT -> TAG_OUTPUT (legacy no-pin wires fall back to first pins)', () {
    final prog = _fbd([
      FbdBlock(id: 'i', type: 'TAG_INPUT', title: 'In', tagBinding: 'A'),
      FbdBlock(id: 'n', type: 'NOT', title: 'Not'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'B'),
    ], [
      FbdWire(fromBlockId: 'i', toBlockId: 'n'),
      FbdWire(fromBlockId: 'n', toBlockId: 'o'),
    ]);
    final p = _proj([_tag('A', 'BOOL', true), _tag('B', 'BOOL', false)], prog);
    _run(p);
    expect(readPath(p, 'B'), isFalse);
  });

  test('AND / OR truthiness incl. numeric input and empty AND (pin-addressed)', () {
    final prog = _fbd([
      FbdBlock(id: 'a', type: 'TAG_INPUT', title: '', tagBinding: 'A'),
      FbdBlock(id: 'b', type: 'TAG_INPUT', title: '', tagBinding: 'B'),
      FbdBlock(id: 'and', type: 'AND', title: ''),
      FbdBlock(id: 'or', type: 'OR', title: ''),
      FbdBlock(id: 'oand', type: 'TAG_OUTPUT', title: '', tagBinding: 'AndOut'),
      FbdBlock(id: 'oor', type: 'TAG_OUTPUT', title: '', tagBinding: 'OrOut'),
    ], [
      FbdWire(fromBlockId: 'a', fromPin: 'OUT', toBlockId: 'and', toPin: 'IN1'),
      FbdWire(fromBlockId: 'b', fromPin: 'OUT', toBlockId: 'and', toPin: 'IN2'),
      FbdWire(fromBlockId: 'a', fromPin: 'OUT', toBlockId: 'or', toPin: 'IN1'),
      FbdWire(fromBlockId: 'b', fromPin: 'OUT', toBlockId: 'or', toPin: 'IN2'),
      FbdWire(fromBlockId: 'and', fromPin: 'OUT', toBlockId: 'oand', toPin: 'IN'),
      FbdWire(fromBlockId: 'or', fromPin: 'OUT', toBlockId: 'oor', toPin: 'IN'),
    ]);
    final p = _proj([
      _tag('A', 'BOOL', true), _tag('B', 'INT32', 0), // B numeric 0 -> false
      _tag('AndOut', 'BOOL', false), _tag('OrOut', 'BOOL', false),
    ], prog);
    _run(p);
    expect(readPath(p, 'AndOut'), isFalse); // true AND 0
    expect(readPath(p, 'OrOut'), isTrue);   // true OR 0
  });

  test('SUB is pin-addressed (IN1, IN2), not wire order; DIV by zero -> no write', () {
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: '', tagBinding: 'X'),
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: '1.0'),
      FbdBlock(id: 'sub', type: 'SUB', title: ''),
      FbdBlock(id: 'osub', type: 'TAG_OUTPUT', title: '', tagBinding: 'Sub'),
      FbdBlock(id: 'z', type: 'CONST', title: '', tagBinding: '0'),
      FbdBlock(id: 'div', type: 'DIV', title: ''),
      FbdBlock(id: 'odiv', type: 'TAG_OUTPUT', title: '', tagBinding: 'Div'),
    ], [
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'sub', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'sub', toPin: 'IN2'), // X - 1.0
      FbdWire(fromBlockId: 'sub', fromPin: 'OUT', toBlockId: 'osub', toPin: 'IN'),
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'div', toPin: 'IN1'),
      FbdWire(fromBlockId: 'z', fromPin: 'OUT', toBlockId: 'div', toPin: 'IN2'), // divide by zero
      FbdWire(fromBlockId: 'div', fromPin: 'OUT', toBlockId: 'odiv', toPin: 'IN'),
    ]);
    final p = _proj([
      _tag('X', 'FLOAT64', 5.0), _tag('Sub', 'FLOAT64', -99.0),
      _tag('Div', 'FLOAT64', -99.0),
    ], prog);
    _run(p);
    expect(readPath(p, 'Sub'), equals(4.0));
    expect(readPath(p, 'Div'), equals(-99.0)); // null result -> not written
  });

  test('reversing which const feeds IN1 vs IN2 flips the SUB result (proves pins, not wire order)', () {
    PlcProgram build(String firstToPin, String secondToPin) => _fbd([
          FbdBlock(id: 'c5', type: 'CONST', title: '', tagBinding: '5'),
          FbdBlock(id: 'c3', type: 'CONST', title: '', tagBinding: '3'),
          FbdBlock(id: 'sub', type: 'SUB', title: ''),
          FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
        ], [
          FbdWire(fromBlockId: 'c5', fromPin: 'OUT', toBlockId: 'sub', toPin: firstToPin),
          FbdWire(fromBlockId: 'c3', fromPin: 'OUT', toBlockId: 'sub', toPin: secondToPin),
          FbdWire(fromBlockId: 'sub', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
        ]);

    final p1 = _proj([_tag('Out', 'INT32', -1)], build('IN1', 'IN2')); // 5 - 3 = 2
    _run(p1);
    expect(readPath(p1, 'Out'), equals(2));

    final p2 = _proj([_tag('Out', 'INT32', -1)], build('IN2', 'IN1')); // 3 - 5 = -2
    _run(p2);
    expect(readPath(p2, 'Out'), equals(-2));
  });

  test('fan-out: one CONST OUT wired to two different blocks both see it', () {
    final prog = _fbd([
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: '7'),
      FbdBlock(id: 'add', type: 'ADD', title: ''),
      FbdBlock(id: 'mul', type: 'MUL', title: ''),
      FbdBlock(id: 'oadd', type: 'TAG_OUTPUT', title: '', tagBinding: 'AddOut'),
      FbdBlock(id: 'omul', type: 'TAG_OUTPUT', title: '', tagBinding: 'MulOut'),
    ], [
      FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'add', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'add', toPin: 'IN2'),
      FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'mul', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'mul', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add', fromPin: 'OUT', toBlockId: 'oadd', toPin: 'IN'),
      FbdWire(fromBlockId: 'mul', fromPin: 'OUT', toBlockId: 'omul', toPin: 'IN'),
    ]);
    final p = _proj([_tag('AddOut', 'INT32', 0), _tag('MulOut', 'INT32', 0)], prog);
    _run(p);
    expect(readPath(p, 'AddOut'), equals(14)); // 7 + 7
    expect(readPath(p, 'MulOut'), equals(49)); // 7 * 7
  });

  test('comparators are pin-addressed (IN1, IN2)', () {
    FbdBlock cmp(String id, String type) => FbdBlock(id: id, type: type, title: '');
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: '', tagBinding: 'X'),
      FbdBlock(id: 'y', type: 'TAG_INPUT', title: '', tagBinding: 'Y'),
      cmp('gt', 'GT'), cmp('lt', 'LT'), cmp('ge', 'GE'),
      FbdBlock(id: 'ogt', type: 'TAG_OUTPUT', title: '', tagBinding: 'Gt'),
      FbdBlock(id: 'olt', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lt'),
      FbdBlock(id: 'oge', type: 'TAG_OUTPUT', title: '', tagBinding: 'Ge'),
    ], [
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'gt', toPin: 'IN1'),
      FbdWire(fromBlockId: 'y', fromPin: 'OUT', toBlockId: 'gt', toPin: 'IN2'),
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'lt', toPin: 'IN1'),
      FbdWire(fromBlockId: 'y', fromPin: 'OUT', toBlockId: 'lt', toPin: 'IN2'),
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'ge', toPin: 'IN1'),
      FbdWire(fromBlockId: 'y', fromPin: 'OUT', toBlockId: 'ge', toPin: 'IN2'),
      FbdWire(fromBlockId: 'gt', fromPin: 'OUT', toBlockId: 'ogt', toPin: 'IN'),
      FbdWire(fromBlockId: 'lt', fromPin: 'OUT', toBlockId: 'olt', toPin: 'IN'),
      FbdWire(fromBlockId: 'ge', fromPin: 'OUT', toBlockId: 'oge', toPin: 'IN'),
    ]);
    final p = _proj([
      _tag('X', 'FLOAT64', 7.0), _tag('Y', 'FLOAT64', 7.0),
      _tag('Gt', 'BOOL', false), _tag('Lt', 'BOOL', false), _tag('Ge', 'BOOL', false),
    ], prog);
    _run(p);
    expect(readPath(p, 'Gt'), isFalse); // 7 > 7
    expect(readPath(p, 'Lt'), isFalse); // 7 < 7
    expect(readPath(p, 'Ge'), isTrue);  // 7 >= 7
  });

  test('LIMIT clamps (MN, IN, MX) — pin-addressed', () {
    FbdBlock c(String id, String v) => FbdBlock(id: id, type: 'CONST', title: '', tagBinding: v);
    final prog = _fbd([
      c('mn', '0.0'),
      FbdBlock(id: 'in', type: 'TAG_INPUT', title: '', tagBinding: 'In'),
      c('mx', '100.0'),
      FbdBlock(id: 'lim', type: 'LIMIT', title: ''),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
    ], [
      FbdWire(fromBlockId: 'mn', fromPin: 'OUT', toBlockId: 'lim', toPin: 'MN'),
      FbdWire(fromBlockId: 'in', fromPin: 'OUT', toBlockId: 'lim', toPin: 'IN'),
      FbdWire(fromBlockId: 'mx', fromPin: 'OUT', toBlockId: 'lim', toPin: 'MX'),
      FbdWire(fromBlockId: 'lim', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
    ]);
    final p = _proj([_tag('In', 'FLOAT64', 150.0), _tag('Out', 'FLOAT64', 0.0)], prog);
    _run(p);
    expect(readPath(p, 'Out'), equals(100.0)); // clamped to max
    writePath(p, 'In', -20.0);
    _run(p);
    expect(readPath(p, 'Out'), equals(0.0)); // clamped to min
    writePath(p, 'In', 42.0);
    _run(p);
    expect(readPath(p, 'Out'), equals(42.0)); // within
  });

  test('CONST parses num/bool, garbage -> null (no write)', () {
    final prog = _fbd([
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: 'garbage'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
    ], [FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN')]);
    final p = _proj([_tag('Out', 'FLOAT64', -1.0)], prog);
    _run(p);
    expect(readPath(p, 'Out'), equals(-1.0)); // unparseable const -> null -> no write
  });

  test('forced output tag is not overwritten', () {
    final prog = _fbd([
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: 'TRUE'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Y'),
    ], [FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN')]);
    final p = _proj([_tag('Y', 'BOOL', false, forced: true, fv: false)], prog);
    _run(p);
    expect(readPath(p, 'Y'), isFalse);
  });

  test('multi-layer topological order resolves deep chains', () {
    // o = NOT(NOT(A)) == A, but blocks listed out of dependency order.
    final prog = _fbd([
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
      FbdBlock(id: 'n2', type: 'NOT', title: ''),
      FbdBlock(id: 'n1', type: 'NOT', title: ''),
      FbdBlock(id: 'i', type: 'TAG_INPUT', title: '', tagBinding: 'A'),
    ], [
      FbdWire(fromBlockId: 'i', fromPin: 'OUT', toBlockId: 'n1', toPin: 'IN'),
      FbdWire(fromBlockId: 'n1', fromPin: 'OUT', toBlockId: 'n2', toPin: 'IN'),
      FbdWire(fromBlockId: 'n2', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
    ]);
    final p = _proj([_tag('A', 'BOOL', true), _tag('Out', 'BOOL', false)], prog);
    _run(p);
    expect(readPath(p, 'Out'), isTrue);
  });

  test('a cycle terminates without hanging', () {
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'AND', title: ''),
      FbdBlock(id: 'y', type: 'AND', title: ''),
    ], [
      FbdWire(fromBlockId: 'x', fromPin: 'OUT', toBlockId: 'y', toPin: 'IN1'),
      FbdWire(fromBlockId: 'y', fromPin: 'OUT', toBlockId: 'x', toPin: 'IN1'),
    ]);
    final p = _proj([], prog);
    _run(p); // must return, not hang
    expect(true, isTrue);
  });

  test('non-FBD and empty programs are skipped', () {
    final ld = PlcProgram(name: 'L', language: 'LadderLogic');
    final p = _proj([_tag('A', 'BOOL', true)], ld);
    _run(p);
    final empty = PlcProgram(name: 'E', language: 'FunctionBlockDiagram');
    final p2 = _proj([], empty);
    _run(p2);
    expect(true, isTrue);
  });

  test('AND with inputCount 3 reads three pin-addressed inputs', () {
    final prog = _fbd([
      FbdBlock(id: 'a', type: 'TAG_INPUT', title: '', tagBinding: 'A'),
      FbdBlock(id: 'b', type: 'TAG_INPUT', title: '', tagBinding: 'B'),
      FbdBlock(id: 'c', type: 'TAG_INPUT', title: '', tagBinding: 'C'),
      FbdBlock(id: 'and3', type: 'AND', title: '', inputCount: 3),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
    ], [
      FbdWire(fromBlockId: 'a', fromPin: 'OUT', toBlockId: 'and3', toPin: 'IN1'),
      FbdWire(fromBlockId: 'b', fromPin: 'OUT', toBlockId: 'and3', toPin: 'IN2'),
      FbdWire(fromBlockId: 'c', fromPin: 'OUT', toBlockId: 'and3', toPin: 'IN3'),
      FbdWire(fromBlockId: 'and3', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
    ]);
    final p = _proj([
      _tag('A', 'BOOL', true), _tag('B', 'BOOL', true), _tag('C', 'BOOL', false),
      _tag('Out', 'BOOL', true),
    ], prog);
    _run(p);
    expect(readPath(p, 'Out'), isFalse); // C is false
  });

  test('multi-output TON: Q and ET both evolve correctly over scans', () {
    final prog = _fbd([
      FbdBlock(id: 'cin', type: 'CONST', title: '', tagBinding: 'TRUE'),
      FbdBlock(id: 'cpt', type: 'CONST', title: '', tagBinding: '300'),
      FbdBlock(id: 'ton', type: 'TON', title: ''),
      FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
      FbdBlock(id: 'oet', type: 'TAG_OUTPUT', title: '', tagBinding: 'EtOut'),
    ], [
      FbdWire(fromBlockId: 'cin', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'cpt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
      FbdWire(fromBlockId: 'ton', fromPin: 'ET', toBlockId: 'oet', toPin: 'IN'),
    ]);
    final p = _proj([
      _tag('QOut', 'BOOL', false), _tag('EtOut', 'INT32', -1),
    ], prog);
    final rt = FbdRuntime();

    // Scan 1: dtMs=100, ET=100 < PT=300 -> Q false, ET=100
    executeFbdPrograms(p, 100, rt);
    expect(readPath(p, 'QOut'), isFalse);
    expect(readPath(p, 'EtOut'), equals(100));

    // Scan 2: ET=200 < PT=300 -> Q still false, ET increased
    executeFbdPrograms(p, 100, rt);
    expect(readPath(p, 'QOut'), isFalse);
    expect(readPath(p, 'EtOut'), equals(200));

    // Scan 3: ET=300 >= PT=300 -> Q now true
    executeFbdPrograms(p, 100, rt);
    expect(readPath(p, 'QOut'), isTrue);
    expect(readPath(p, 'EtOut'), equals(300));
  });

  test('TON resets ET and Q when IN goes false', () {
    final prog = _fbd([
      FbdBlock(id: 'i', type: 'TAG_INPUT', title: '', tagBinding: 'In'),
      FbdBlock(id: 'cpt', type: 'CONST', title: '', tagBinding: '200'),
      FbdBlock(id: 'ton', type: 'TON', title: ''),
      FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
      FbdBlock(id: 'oet', type: 'TAG_OUTPUT', title: '', tagBinding: 'EtOut'),
    ], [
      FbdWire(fromBlockId: 'i', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'cpt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
      FbdWire(fromBlockId: 'ton', fromPin: 'ET', toBlockId: 'oet', toPin: 'IN'),
    ]);
    final p = _proj([
      _tag('In', 'BOOL', true), _tag('QOut', 'BOOL', false), _tag('EtOut', 'INT32', -1),
    ], prog);
    final rt = FbdRuntime();
    executeFbdPrograms(p, 250, rt); // ET=250 >= PT=200 -> Q true
    expect(readPath(p, 'QOut'), isTrue);
    expect(readPath(p, 'EtOut'), equals(200)); // clamped to PT

    writePath(p, 'In', false);
    executeFbdPrograms(p, 100, rt);
    expect(readPath(p, 'QOut'), isFalse);
    expect(readPath(p, 'EtOut'), equals(0));
  });

  group('PID', () {
    // Builds a PID block fed by TAG_INPUT SP/PV and CONST KP/KI/KD, with CV
    // wired to a TAG_OUTPUT. Any of the gain bindings may be null to leave
    // that pin unwired.
    PlcProject buildPid({
      String? kp,
      String? ki,
      String? kd,
      double sp = 0,
      double pv = 0,
    }) {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'sp', type: 'TAG_INPUT', title: '', tagBinding: 'SP'),
        FbdBlock(id: 'pv', type: 'TAG_INPUT', title: '', tagBinding: 'PV'),
        FbdBlock(id: 'pid', type: 'PID', title: ''),
        FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'CV'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'sp', fromPin: 'OUT', toBlockId: 'pid', toPin: 'SP'),
        FbdWire(fromBlockId: 'pv', fromPin: 'OUT', toBlockId: 'pid', toPin: 'PV'),
        FbdWire(fromBlockId: 'pid', fromPin: 'CV', toBlockId: 'o', toPin: 'IN'),
      ];
      if (kp != null) {
        blocks.add(FbdBlock(id: 'kp', type: 'CONST', title: '', tagBinding: kp));
        wires.add(FbdWire(fromBlockId: 'kp', fromPin: 'OUT', toBlockId: 'pid', toPin: 'KP'));
      }
      if (ki != null) {
        blocks.add(FbdBlock(id: 'ki', type: 'CONST', title: '', tagBinding: ki));
        wires.add(FbdWire(fromBlockId: 'ki', fromPin: 'OUT', toBlockId: 'pid', toPin: 'KI'));
      }
      if (kd != null) {
        blocks.add(FbdBlock(id: 'kd', type: 'CONST', title: '', tagBinding: kd));
        wires.add(FbdWire(fromBlockId: 'kd', fromPin: 'OUT', toBlockId: 'pid', toPin: 'KD'));
      }
      final prog = _fbd(blocks, wires);
      return _proj([
        _tag('SP', 'FLOAT64', sp), _tag('PV', 'FLOAT64', pv), _tag('CV', 'FLOAT64', -1.0),
      ], prog);
    }

    test('proportional only: CV = clamp(KP * error, 0, 100)', () {
      // SP=50, PV=0 -> error=50. KP=2 -> raw=100 -> clamp -> 100 (saturated).
      final p1 = buildPid(kp: '2', ki: '0', kd: '0', sp: 50, pv: 0);
      _run(p1, FbdRuntime(), 500);
      expect(readPath(p1, 'CV'), equals(100.0));

      // KP=1 -> raw=50 -> CV=50.
      final p2 = buildPid(kp: '1', ki: '0', kd: '0', sp: 50, pv: 0);
      _run(p2, FbdRuntime(), 500);
      expect(readPath(p2, 'CV'), equals(50.0));

      // KP=0.5 -> raw=25 -> CV=25.
      final p3 = buildPid(kp: '0.5', ki: '0', kd: '0', sp: 50, pv: 0);
      _run(p3, FbdRuntime(), 500);
      expect(readPath(p3, 'CV'), equals(25.0));
    });

    test('clamps both ends: raw>100 -> 100, raw<0 -> 0', () {
      final pHigh = buildPid(kp: '10', ki: '0', kd: '0', sp: 50, pv: 0);
      _run(pHigh, FbdRuntime(), 500);
      expect(readPath(pHigh, 'CV'), equals(100.0));

      // PV > SP with positive KP -> negative error -> raw < 0 -> clamp to 0.
      final pLow = buildPid(kp: '10', ki: '0', kd: '0', sp: 0, pv: 50);
      _run(pLow, FbdRuntime(), 500);
      expect(readPath(pLow, 'CV'), equals(0.0));
    });

    test('integral accumulates and anti-windup bounds it (prompt come-down on reversal)', () {
      final p = buildPid(kp: '0', ki: '1', kd: '0', sp: 50, pv: 45);
      final rt = FbdRuntime();

      // error = 5, dt = 0.5s -> integral grows by 2.5 each scan; raw = KI*integral.
      _run(p, rt, 500);
      final cv1 = readPath(p, 'CV') as double;
      expect(cv1, greaterThan(0));

      _run(p, rt, 500);
      final cv2 = readPath(p, 'CV') as double;
      expect(cv2, greaterThanOrEqualTo(cv1)); // rising as integral accumulates

      // Keep scanning until CV saturates at 100.
      for (var i = 0; i < 50; i++) {
        _run(p, rt, 500);
      }
      expect(readPath(p, 'CV'), equals(100.0));

      // Now reverse the error (PV > SP) and confirm CV comes down promptly
      // (within a couple of scans), proving the integral didn't wind up
      // unboundedly while saturated.
      writePath(p, 'PV', 55.0); // error now -5
      _run(p, rt, 500);
      final afterReversal1 = readPath(p, 'CV') as double;
      _run(p, rt, 500);
      final afterReversal2 = readPath(p, 'CV') as double;
      expect(afterReversal2, lessThan(100.0));
      expect(afterReversal1, lessThanOrEqualTo(100.0));
      // Should be dropping, not stuck pinned at 100 for many scans.
      expect(afterReversal2, lessThan(afterReversal1 + 1e-9));
    });

    test('derivative: sudden PV change produces a kick; steady PV -> ~0 derivative', () {
      final p = buildPid(kp: '0', ki: '0', kd: '1', sp: 50, pv: 50);
      final rt = FbdRuntime();

      // First scan: error=0, prevError defaults to 0 -> derivative=0 -> CV=0.
      _run(p, rt, 500);
      expect(readPath(p, 'CV'), equals(0.0));

      // Sudden PV change -> error jumps -> derivative kick this scan.
      writePath(p, 'PV', 40.0); // error = 10
      _run(p, rt, 500);
      expect(readPath(p, 'CV'), greaterThan(0));

      // Steady PV afterward -> error unchanged -> derivative back to ~0.
      _run(p, rt, 500);
      expect(readPath(p, 'CV'), equals(0.0));
    });

    test('unwired gains -> 0, CV = 0, no throw', () {
      final p = buildPid(sp: 50, pv: 0); // KP/KI/KD all unwired
      _run(p, FbdRuntime(), 500);
      expect(readPath(p, 'CV'), equals(0.0));
    });

    test('rt.clear() resets PID integral/prevError state', () {
      final p = buildPid(kp: '0', ki: '1', kd: '0', sp: 50, pv: 45);
      final rt = FbdRuntime();
      _run(p, rt, 500);
      _run(p, rt, 500);
      final beforeClear = readPath(p, 'CV') as double;
      expect(beforeClear, greaterThan(0));

      rt.clear();
      // Single scan after clear should match the very first scan's CV from a
      // fresh runtime (integral/prevError both reset to 0).
      final fresh = buildPid(kp: '0', ki: '1', kd: '0', sp: 50, pv: 45);
      _run(fresh, FbdRuntime(), 500);
      final freshFirstScan = readPath(fresh, 'CV') as double;

      _run(p, rt, 500);
      expect(readPath(p, 'CV'), equals(freshFirstScan));
    });
  });

  group('CTU', () {
    // Builds a CTU block fed by TAG_INPUT CU/R and CONST PV, with Q/CV wired
    // to TAG_OUTPUTs. `withR`/`withPv` control whether those pins are wired.
    PlcProject buildCtu({bool withR = true, String? pv = '3'}) {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'cu', type: 'TAG_INPUT', title: '', tagBinding: 'CU'),
        FbdBlock(id: 'ctu', type: 'CTU', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
        FbdBlock(id: 'ocv', type: 'TAG_OUTPUT', title: '', tagBinding: 'CvOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'cu', fromPin: 'OUT', toBlockId: 'ctu', toPin: 'CU'),
        FbdWire(fromBlockId: 'ctu', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
        FbdWire(fromBlockId: 'ctu', fromPin: 'CV', toBlockId: 'ocv', toPin: 'IN'),
      ];
      if (withR) {
        blocks.add(FbdBlock(id: 'r', type: 'TAG_INPUT', title: '', tagBinding: 'R'));
        wires.add(FbdWire(fromBlockId: 'r', fromPin: 'OUT', toBlockId: 'ctu', toPin: 'R'));
      }
      if (pv != null) {
        blocks.add(FbdBlock(id: 'pv', type: 'CONST', title: '', tagBinding: pv));
        wires.add(FbdWire(fromBlockId: 'pv', fromPin: 'OUT', toBlockId: 'ctu', toPin: 'PV'));
      }
      final prog = _fbd(blocks, wires);
      final tags = <PlcTag>[
        _tag('CU', 'BOOL', false), _tag('QOut', 'BOOL', false), _tag('CvOut', 'INT32', -1),
      ];
      if (withR) {
        tags.add(_tag('R', 'BOOL', false));
      }
      return _proj(tags, prog);
    }

    test('rising-edge counts once while held true (not level-triggered)', () {
      final p = buildCtu();
      final rt = FbdRuntime();

      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      expect(readPath(p, 'QOut'), isFalse);

      // Held true across further scans -> stays at 1 (edge, not level).
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      // Toggle false then true again -> increments to 2.
      writePath(p, 'CU', false);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));

      // One more rising edge -> CV=3 -> Q true (PV=3).
      writePath(p, 'CU', false);
      _run(p, rt);
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(3));
      expect(readPath(p, 'QOut'), isTrue);
    });

    test('reset priority: R=true zeroes CV even with a simultaneous CU rising edge', () {
      final p = buildCtu();
      final rt = FbdRuntime();
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      writePath(p, 'CU', false);
      _run(p, rt);

      // Simultaneous R=true and CU rising edge -> reset wins.
      writePath(p, 'R', true);
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('reset-then-held: CU held true through and after R -> no spurious re-fire', () {
      final p = buildCtu();
      final rt = FbdRuntime();
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      writePath(p, 'CU', false);
      _run(p, rt);

      // Simultaneous R=true and CU rising edge -> reset wins, CV=0.
      writePath(p, 'R', true);
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QOut'), isFalse);

      // One more scan: R=false, CU STILL held true (no new edge, since CU was
      // already true last scan) -> must NOT spuriously re-fire. CV stays 0.
      writePath(p, 'R', false);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('unwired R/PV -> CV counts from 0 with PV=0, Q true immediately, no throw', () {
      final p = buildCtu(withR: false, pv: null);
      final rt = FbdRuntime();
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      expect(readPath(p, 'QOut'), isTrue); // PV unwired -> 0, CV(1) >= 0
    });

    test('rt.clear() resets CV and edge state', () {
      final p = buildCtu();
      final rt = FbdRuntime();
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      rt.clear();
      writePath(p, 'CU', false);
      _run(p, rt);
      writePath(p, 'CU', true);
      _run(p, rt);
      // Fresh edge from 0 after clear -> CV=1, same as very first scan.
      expect(readPath(p, 'CvOut'), equals(1));
    });
  });

  group('CTD', () {
    PlcProject buildCtd({String pv = '2'}) {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'cd', type: 'TAG_INPUT', title: '', tagBinding: 'CD'),
        FbdBlock(id: 'ld', type: 'TAG_INPUT', title: '', tagBinding: 'LD'),
        FbdBlock(id: 'pv', type: 'CONST', title: '', tagBinding: pv),
        FbdBlock(id: 'ctd', type: 'CTD', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
        FbdBlock(id: 'ocv', type: 'TAG_OUTPUT', title: '', tagBinding: 'CvOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'cd', fromPin: 'OUT', toBlockId: 'ctd', toPin: 'CD'),
        FbdWire(fromBlockId: 'ld', fromPin: 'OUT', toBlockId: 'ctd', toPin: 'LD'),
        FbdWire(fromBlockId: 'pv', fromPin: 'OUT', toBlockId: 'ctd', toPin: 'PV'),
        FbdWire(fromBlockId: 'ctd', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
        FbdWire(fromBlockId: 'ctd', fromPin: 'CV', toBlockId: 'ocv', toPin: 'IN'),
      ];
      final prog = _fbd(blocks, wires);
      return _proj([
        _tag('CD', 'BOOL', false), _tag('LD', 'BOOL', false),
        _tag('QOut', 'BOOL', false), _tag('CvOut', 'INT32', -1),
      ], prog);
    }

    test('LD loads PV, CD edges decrement, floors at 0, Q true at CV<=0', () {
      final p = buildCtd();
      final rt = FbdRuntime();

      writePath(p, 'LD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));
      expect(readPath(p, 'QOut'), isFalse);

      writePath(p, 'LD', false);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      expect(readPath(p, 'QOut'), isFalse);

      writePath(p, 'CD', false);
      _run(p, rt);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QOut'), isTrue);

      // Further rising edges must not go negative.
      writePath(p, 'CD', false);
      _run(p, rt);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QOut'), isTrue);
    });

    test('CTD does not keep counting while CD held true', () {
      final p = buildCtd(pv: '3');
      final rt = FbdRuntime();

      // Load PV=3 so CV>0.
      writePath(p, 'LD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(3));

      writePath(p, 'LD', false);

      // Hold CD true across 2+ consecutive scans -> decrements exactly ONCE
      // (3 -> 2), then STAYS at 2 (edge-triggered, not level-triggered).
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));
      expect(readPath(p, 'QOut'), isFalse);

      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));

      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));
    });
  });

  group('CTUD', () {
    PlcProject buildCtud({String pv = '2'}) {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'cu', type: 'TAG_INPUT', title: '', tagBinding: 'CU'),
        FbdBlock(id: 'cd', type: 'TAG_INPUT', title: '', tagBinding: 'CD'),
        FbdBlock(id: 'r', type: 'TAG_INPUT', title: '', tagBinding: 'R'),
        FbdBlock(id: 'ld', type: 'TAG_INPUT', title: '', tagBinding: 'LD'),
        FbdBlock(id: 'pv', type: 'CONST', title: '', tagBinding: pv),
        FbdBlock(id: 'ctud', type: 'CTUD', title: ''),
        FbdBlock(id: 'oqu', type: 'TAG_OUTPUT', title: '', tagBinding: 'QuOut'),
        FbdBlock(id: 'oqd', type: 'TAG_OUTPUT', title: '', tagBinding: 'QdOut'),
        FbdBlock(id: 'ocv', type: 'TAG_OUTPUT', title: '', tagBinding: 'CvOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'cu', fromPin: 'OUT', toBlockId: 'ctud', toPin: 'CU'),
        FbdWire(fromBlockId: 'cd', fromPin: 'OUT', toBlockId: 'ctud', toPin: 'CD'),
        FbdWire(fromBlockId: 'r', fromPin: 'OUT', toBlockId: 'ctud', toPin: 'R'),
        FbdWire(fromBlockId: 'ld', fromPin: 'OUT', toBlockId: 'ctud', toPin: 'LD'),
        FbdWire(fromBlockId: 'pv', fromPin: 'OUT', toBlockId: 'ctud', toPin: 'PV'),
        FbdWire(fromBlockId: 'ctud', fromPin: 'QU', toBlockId: 'oqu', toPin: 'IN'),
        FbdWire(fromBlockId: 'ctud', fromPin: 'QD', toBlockId: 'oqd', toPin: 'IN'),
        FbdWire(fromBlockId: 'ctud', fromPin: 'CV', toBlockId: 'ocv', toPin: 'IN'),
      ];
      final prog = _fbd(blocks, wires);
      return _proj([
        _tag('CU', 'BOOL', false), _tag('CD', 'BOOL', false),
        _tag('R', 'BOOL', false), _tag('LD', 'BOOL', false),
        _tag('QuOut', 'BOOL', false), _tag('QdOut', 'BOOL', false), _tag('CvOut', 'INT32', -1),
      ], prog);
    }

    test('CU up / CD down (floored), QU/QD thresholds, R priority, LD load', () {
      final p = buildCtud();
      final rt = FbdRuntime();

      // Rising CU edges raise CV: 0 -> 1 -> 2.
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      expect(readPath(p, 'QuOut'), isFalse);
      expect(readPath(p, 'QdOut'), isFalse);

      writePath(p, 'CU', false);
      _run(p, rt);
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));
      expect(readPath(p, 'QuOut'), isTrue); // CV(2) >= PV(2)

      // Rising CD edges lower CV: 2 -> 1 -> 0, floored (never negative).
      writePath(p, 'CU', false);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      expect(readPath(p, 'QdOut'), isFalse);

      writePath(p, 'CD', false);
      _run(p, rt);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QdOut'), isTrue);

      writePath(p, 'CD', false);
      _run(p, rt);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0)); // floored, doesn't go negative

      // R priority over LD and counting: even with LD/CU also asserted.
      writePath(p, 'CD', false);
      writePath(p, 'LD', true);
      writePath(p, 'CU', true);
      writePath(p, 'R', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QuOut'), isFalse);
      expect(readPath(p, 'QdOut'), isTrue);

      // R false, LD true -> loads PV.
      writePath(p, 'R', false);
      writePath(p, 'CU', false);
      _run(p, rt);
      writePath(p, 'LD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));
    });

    test('CTUD does not keep counting up while CU held true', () {
      final p = buildCtud(pv: '3');
      final rt = FbdRuntime();

      // Hold CU true across 2+ consecutive scans with CD=R=LD=false ->
      // CV goes up exactly ONCE (0 -> 1), then STAYS at 1.
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));
      expect(readPath(p, 'QuOut'), isFalse);
      expect(readPath(p, 'QdOut'), isFalse);

      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      // Now hold CD true from that loaded level -> one decrement then hold.
      writePath(p, 'CU', false);
      _run(p, rt);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));

      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
    });

    test('CTUD load of a negative preset is floored to 0 (CV never negative)', () {
      // Guards the invariant that CV cannot go negative even via LD, not just
      // via the decrement path.
      final p = buildCtud(pv: '-5');
      final rt = FbdRuntime();

      writePath(p, 'LD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(0));
      expect(readPath(p, 'QdOut'), isTrue); // CV(0) <= 0
    });

    test('CTUD simultaneous CU/CD rising edges in same scan net to no change', () {
      final p = buildCtud(pv: '3');
      final rt = FbdRuntime();

      // Count up twice to CV=2 (each edge isolated by a false scan in between).
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(1));

      writePath(p, 'CU', false);
      _run(p, rt);
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));

      // Both CU and CD were false last scan (CU is true, so first make CU
      // false and let CD settle false too before the simultaneous-edge scan).
      writePath(p, 'CU', false);
      writePath(p, 'CD', false);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));

      // Simultaneous rising edges on CU and CD in the SAME scan (both were
      // false last scan) -> net +1 -1 = 0, CV unchanged.
      writePath(p, 'CU', true);
      writePath(p, 'CD', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(2));

      // Prove independence (not mutually-exclusive if/else-if): a following
      // scan with only CU rising (CD dropped first) should still +1.
      writePath(p, 'CU', false);
      writePath(p, 'CD', false);
      _run(p, rt);
      writePath(p, 'CU', true);
      _run(p, rt);
      expect(readPath(p, 'CvOut'), equals(3));
    });
  });

  group('R_TRIG', () {
    PlcProject buildRTrig() {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'clk', type: 'TAG_INPUT', title: '', tagBinding: 'Clk'),
        FbdBlock(id: 'rt', type: 'R_TRIG', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'clk', fromPin: 'OUT', toBlockId: 'rt', toPin: 'CLK'),
        FbdWire(fromBlockId: 'rt', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
      ];
      return _proj([
        _tag('Clk', 'BOOL', false), _tag('QOut', 'BOOL', false),
      ], _fbd(blocks, wires));
    }

    test('CLK already true on scan 1 IS a rising edge (prevCLK defaults false)', () {
      final p = buildRTrig();
      final rt = FbdRuntime();
      writePath(p, 'Clk', true);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);
    });

    test('holding CLK true across scans -> Q true first scan only', () {
      final p = buildRTrig();
      final rt = FbdRuntime();
      writePath(p, 'Clk', true);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);

      _run(p, rt); // still held true, no new edge
      expect(readPath(p, 'QOut'), isFalse);

      _run(p, rt);
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('toggle CLK false then true -> Q true again for one scan', () {
      final p = buildRTrig();
      final rt = FbdRuntime();
      writePath(p, 'Clk', true);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);

      writePath(p, 'Clk', false);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isFalse);

      writePath(p, 'Clk', true);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);

      _run(p, rt);
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('unwired CLK -> Q false, no throw', () {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'rt', type: 'R_TRIG', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'rt', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
      ];
      final p = _proj([_tag('QOut', 'BOOL', true)], _fbd(blocks, wires));
      _run(p);
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('rt.clear() resets prevCLK edge state', () {
      final p = buildRTrig();
      final rt = FbdRuntime();
      writePath(p, 'Clk', true);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isFalse);

      rt.clear();
      _run(p, rt); // CLK still true, but state cleared -> edge again
      expect(readPath(p, 'QOut'), isTrue);
    });
  });

  group('F_TRIG', () {
    PlcProject buildFTrig() {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'clk', type: 'TAG_INPUT', title: '', tagBinding: 'Clk'),
        FbdBlock(id: 'ft', type: 'F_TRIG', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'clk', fromPin: 'OUT', toBlockId: 'ft', toPin: 'CLK'),
        FbdWire(fromBlockId: 'ft', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
      ];
      return _proj([
        _tag('Clk', 'BOOL', false), _tag('QOut', 'BOOL', false),
      ], _fbd(blocks, wires));
    }

    test('CLK starting false -> no spurious Q on scan 1', () {
      final p = buildFTrig();
      final rt = FbdRuntime();
      _run(p, rt); // CLK false, prevCLK defaults false -> no falling edge
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('CLK true then false -> Q true one scan on falling edge', () {
      final p = buildFTrig();
      final rt = FbdRuntime();
      writePath(p, 'Clk', true);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isFalse);

      writePath(p, 'Clk', false);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);

      _run(p, rt); // held false, no new edge
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('unwired CLK -> Q false, no throw', () {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'ft', type: 'F_TRIG', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'ft', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
      ];
      final p = _proj([_tag('QOut', 'BOOL', true)], _fbd(blocks, wires));
      _run(p);
      expect(readPath(p, 'QOut'), isFalse);
    });

    test('rt.clear() resets prevCLK edge state', () {
      final p = buildFTrig();
      final rt = FbdRuntime();
      writePath(p, 'Clk', true);
      _run(p, rt);
      writePath(p, 'Clk', false);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isTrue);
      _run(p, rt);
      expect(readPath(p, 'QOut'), isFalse);

      rt.clear();
      _run(p, rt); // CLK still false, but state cleared -> prevCLK defaults false, no edge
      expect(readPath(p, 'QOut'), isFalse);
    });
  });

  group('TP', () {
    PlcProject buildTp({String pt = '300'}) {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'i', type: 'TAG_INPUT', title: '', tagBinding: 'In'),
        FbdBlock(id: 'cpt', type: 'CONST', title: '', tagBinding: pt),
        FbdBlock(id: 'tp', type: 'TP', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
        FbdBlock(id: 'oet', type: 'TAG_OUTPUT', title: '', tagBinding: 'EtOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'i', fromPin: 'OUT', toBlockId: 'tp', toPin: 'IN'),
        FbdWire(fromBlockId: 'cpt', fromPin: 'OUT', toBlockId: 'tp', toPin: 'PT'),
        FbdWire(fromBlockId: 'tp', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
        FbdWire(fromBlockId: 'tp', fromPin: 'ET', toBlockId: 'oet', toPin: 'IN'),
      ];
      return _proj([
        _tag('In', 'BOOL', false), _tag('QOut', 'BOOL', false), _tag('EtOut', 'INT32', -1),
      ], _fbd(blocks, wires));
    }

    test('fixed-width pulse: IN drops early but Q stays true until ET reaches PT', () {
      final p = buildTp(pt: '300');
      final rt = FbdRuntime();

      // Scan 1: rising edge on IN starts the pulse. dtMs=100 -> ET=100, Q true.
      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(100));

      // Scan 2: IN drops false, but pulse keeps running (not retriggerable,
      // width set by PT not IN) -> ET=200, Q still true.
      writePath(p, 'In', false);
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(200));

      // Scan 3: ET reaches PT=300 -> Q goes false, ET holds at 300 (the scan
      // the pulse completes on).
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(300));

      // Scan 4: pulse already completed and IN is (still) false -> idle
      // reset kicks in, ET resets to 0, re-arming the next pulse. Q remains
      // false throughout.
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(0));
    });

    test('non-retriggerable: an IN edge mid-pulse does not restart/extend it', () {
      final p = buildTp(pt: '300');
      final rt = FbdRuntime();

      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt); // ET=100, Q true
      expect(readPath(p, 'EtOut'), equals(100));

      // Drop and re-raise IN mid-pulse: should not restart the timer.
      writePath(p, 'In', false);
      executeFbdPrograms(p, 100, rt); // ET=200
      writePath(p, 'In', true); // new rising edge while still running
      executeFbdPrograms(p, 100, rt); // ET=300, pulse ends (not restarted to 0)
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(300));
    });

    test('re-arm: after pulse completes and IN returns false, a new edge starts a fresh pulse', () {
      final p = buildTp(pt: '300');
      final rt = FbdRuntime();

      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt); // ET=100
      writePath(p, 'In', false);
      executeFbdPrograms(p, 100, rt); // ET=200
      executeFbdPrograms(p, 100, rt); // ET=300, Q false, pulse done
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(300));

      // IN idle false -> ET resets to 0 (re-arm).
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'EtOut'), equals(0));
      expect(readPath(p, 'QOut'), isFalse);

      // New rising edge starts a fresh pulse from ET=0.
      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(100));
    });

    test('PT<=0 is a zero-width pulse: Q does not latch true beyond the trigger', () {
      final p = buildTp(pt: '0');
      final rt = FbdRuntime();
      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(0));

      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(0));
    });

    test('unwired IN/PT -> Q false, ET 0, no throw', () {
      final blocks = <FbdBlock>[
        FbdBlock(id: 'tp', type: 'TP', title: ''),
        FbdBlock(id: 'oq', type: 'TAG_OUTPUT', title: '', tagBinding: 'QOut'),
        FbdBlock(id: 'oet', type: 'TAG_OUTPUT', title: '', tagBinding: 'EtOut'),
      ];
      final wires = <FbdWire>[
        FbdWire(fromBlockId: 'tp', fromPin: 'Q', toBlockId: 'oq', toPin: 'IN'),
        FbdWire(fromBlockId: 'tp', fromPin: 'ET', toBlockId: 'oet', toPin: 'IN'),
      ];
      final p = _proj([
        _tag('QOut', 'BOOL', true), _tag('EtOut', 'INT32', -1),
      ], _fbd(blocks, wires));
      executeFbdPrograms(p, 100, FbdRuntime());
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(0));
    });

    test('TP holds ET at PT and does not retrigger while IN held true past completion', () {
      final p = buildTp(pt: '300');
      final rt = FbdRuntime();

      // Raise IN and hold it true continuously through the whole test.
      writePath(p, 'In', true);

      // Scan 1: rising edge starts the pulse -> ET=100, Q true.
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(100));

      // Scan 2: ET=200, Q still true.
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(200));

      // Scan 3: ET reaches PT=300 -> pulse completes, Q false, ET holds at 300.
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(300));

      // Scans 4-7: IN is STILL held true. Non-retriggerable behavior means
      // there is no new rising edge (prevIN was already 1), so the pulse
      // must not restart: Q stays false and ET stays pinned at 300 with no
      // reset to 0, every scan.
      for (var i = 0; i < 4; i++) {
        executeFbdPrograms(p, 100, rt);
        expect(readPath(p, 'QOut'), isFalse);
        expect(readPath(p, 'EtOut'), equals(300));
      }

      // Drop IN to false for one scan: this is the idle re-arm -> ET resets
      // to 0, Q remains false.
      writePath(p, 'In', false);
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isFalse);
      expect(readPath(p, 'EtOut'), equals(0));

      // Raise IN again: a fresh rising edge starts a brand-new pulse from
      // ET=0, proving re-arm still works after the long held-true hold.
      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(100));
    });

    test('rt.clear() resets pulse state (et/running/prevIN)', () {
      final p = buildTp(pt: '300');
      final rt = FbdRuntime();
      writePath(p, 'In', true);
      executeFbdPrograms(p, 100, rt); // ET=100, running
      expect(readPath(p, 'EtOut'), equals(100));

      rt.clear();
      // After clear, state is gone; IN is still true but prevIN resets to 0,
      // so this scan is seen as a fresh rising edge starting a new pulse.
      executeFbdPrograms(p, 100, rt);
      expect(readPath(p, 'QOut'), isTrue);
      expect(readPath(p, 'EtOut'), equals(100));
    });
  });
}
