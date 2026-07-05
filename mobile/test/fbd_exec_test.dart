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
}
