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

void _run(PlcProject p) => executeFbdPrograms(p, 500, FbdRuntime());

void main() {
  test('TAG_INPUT -> NOT -> TAG_OUTPUT', () {
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

  test('AND / OR truthiness incl. numeric input and empty AND', () {
    final prog = _fbd([
      FbdBlock(id: 'a', type: 'TAG_INPUT', title: '', tagBinding: 'A'),
      FbdBlock(id: 'b', type: 'TAG_INPUT', title: '', tagBinding: 'B'),
      FbdBlock(id: 'and', type: 'AND', title: ''),
      FbdBlock(id: 'or', type: 'OR', title: ''),
      FbdBlock(id: 'oand', type: 'TAG_OUTPUT', title: '', tagBinding: 'AndOut'),
      FbdBlock(id: 'oor', type: 'TAG_OUTPUT', title: '', tagBinding: 'OrOut'),
    ], [
      FbdWire(fromBlockId: 'a', toBlockId: 'and'),
      FbdWire(fromBlockId: 'b', toBlockId: 'and'),
      FbdWire(fromBlockId: 'a', toBlockId: 'or'),
      FbdWire(fromBlockId: 'b', toBlockId: 'or'),
      FbdWire(fromBlockId: 'and', toBlockId: 'oand'),
      FbdWire(fromBlockId: 'or', toBlockId: 'oor'),
    ]);
    final p = _proj([
      _tag('A', 'BOOL', true), _tag('B', 'INT32', 0), // B numeric 0 -> false
      _tag('AndOut', 'BOOL', false), _tag('OrOut', 'BOOL', false),
    ], prog);
    _run(p);
    expect(readPath(p, 'AndOut'), isFalse); // true AND 0
    expect(readPath(p, 'OrOut'), isTrue);   // true OR 0
  });

  test('SUB respects wire order; DIV by zero -> no write', () {
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: '', tagBinding: 'X'),
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: '1.0'),
      FbdBlock(id: 'sub', type: 'SUB', title: ''),
      FbdBlock(id: 'osub', type: 'TAG_OUTPUT', title: '', tagBinding: 'Sub'),
      FbdBlock(id: 'z', type: 'CONST', title: '', tagBinding: '0'),
      FbdBlock(id: 'div', type: 'DIV', title: ''),
      FbdBlock(id: 'odiv', type: 'TAG_OUTPUT', title: '', tagBinding: 'Div'),
    ], [
      FbdWire(fromBlockId: 'x', toBlockId: 'sub'),   // X first
      FbdWire(fromBlockId: 'c', toBlockId: 'sub'),   // 1.0 second -> X - 1.0
      FbdWire(fromBlockId: 'sub', toBlockId: 'osub'),
      FbdWire(fromBlockId: 'x', toBlockId: 'div'),
      FbdWire(fromBlockId: 'z', toBlockId: 'div'),   // divide by zero
      FbdWire(fromBlockId: 'div', toBlockId: 'odiv'),
    ]);
    final p = _proj([
      _tag('X', 'FLOAT64', 5.0), _tag('Sub', 'FLOAT64', -99.0),
      _tag('Div', 'FLOAT64', -99.0),
    ], prog);
    _run(p);
    expect(readPath(p, 'Sub'), equals(4.0));
    expect(readPath(p, 'Div'), equals(-99.0)); // null result -> not written
  });

  test('comparators on wire-ordered inputs', () {
    FbdBlock cmp(String id, String type) => FbdBlock(id: id, type: type, title: '');
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: '', tagBinding: 'X'),
      FbdBlock(id: 'y', type: 'TAG_INPUT', title: '', tagBinding: 'Y'),
      cmp('gt', 'GT'), cmp('lt', 'LT'), cmp('ge', 'GE'),
      FbdBlock(id: 'ogt', type: 'TAG_OUTPUT', title: '', tagBinding: 'Gt'),
      FbdBlock(id: 'olt', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lt'),
      FbdBlock(id: 'oge', type: 'TAG_OUTPUT', title: '', tagBinding: 'Ge'),
    ], [
      FbdWire(fromBlockId: 'x', toBlockId: 'gt'), FbdWire(fromBlockId: 'y', toBlockId: 'gt'),
      FbdWire(fromBlockId: 'x', toBlockId: 'lt'), FbdWire(fromBlockId: 'y', toBlockId: 'lt'),
      FbdWire(fromBlockId: 'x', toBlockId: 'ge'), FbdWire(fromBlockId: 'y', toBlockId: 'ge'),
      FbdWire(fromBlockId: 'gt', toBlockId: 'ogt'),
      FbdWire(fromBlockId: 'lt', toBlockId: 'olt'),
      FbdWire(fromBlockId: 'ge', toBlockId: 'oge'),
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

  test('LIMIT clamps (MN, IN, MX)', () {
    FbdBlock c(String id, String v) => FbdBlock(id: id, type: 'CONST', title: '', tagBinding: v);
    final prog = _fbd([
      c('mn', '0.0'),
      FbdBlock(id: 'in', type: 'TAG_INPUT', title: '', tagBinding: 'In'),
      c('mx', '100.0'),
      FbdBlock(id: 'lim', type: 'LIMIT', title: ''),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
    ], [
      FbdWire(fromBlockId: 'mn', toBlockId: 'lim'),
      FbdWire(fromBlockId: 'in', toBlockId: 'lim'),
      FbdWire(fromBlockId: 'mx', toBlockId: 'lim'),
      FbdWire(fromBlockId: 'lim', toBlockId: 'o'),
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
    ], [FbdWire(fromBlockId: 'c', toBlockId: 'o')]);
    final p = _proj([_tag('Out', 'FLOAT64', -1.0)], prog);
    _run(p);
    expect(readPath(p, 'Out'), equals(-1.0)); // unparseable const -> null -> no write
  });

  test('forced output tag is not overwritten', () {
    final prog = _fbd([
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: 'TRUE'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Y'),
    ], [FbdWire(fromBlockId: 'c', toBlockId: 'o')]);
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
      FbdWire(fromBlockId: 'i', toBlockId: 'n1'),
      FbdWire(fromBlockId: 'n1', toBlockId: 'n2'),
      FbdWire(fromBlockId: 'n2', toBlockId: 'o'),
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
      FbdWire(fromBlockId: 'x', toBlockId: 'y'),
      FbdWire(fromBlockId: 'y', toBlockId: 'x'),
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
}
