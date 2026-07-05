import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProgram _st(String src) =>
    PlcProgram(name: 'P', language: 'StructuredText', stSource: src);

PlcProject _proj(List<PlcTag> tags, PlcProgram prog) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

void _run(PlcProject p) => executeStPrograms(p, 500, StRuntime());
dynamic _v(PlcProject p, String path) => readPath(p, path);

void main() {
  test('assignment list runs top to bottom', () {
    final p = _proj([
      _tag('A', 'BOOL', false), _tag('B', 'INT32', 0), _tag('C', 'FLOAT64', 0.0),
    ], _st('A := TRUE;\nB := 3 + 4;\nC := B * 2;'));
    _run(p);
    expect(_v(p, 'A'), isTrue);
    expect(_v(p, 'B'), equals(7));
    expect(_v(p, 'C'), equals(14.0));
  });

  test('IF/ELSIF/ELSE selects the correct branch', () {
    PlcProject build(double t) => _proj([
          _tag('Temp', 'FLOAT64', t), _tag('SP', 'FLOAT64', 50.0),
          _tag('Heat', 'BOOL', false), _tag('Cool', 'BOOL', false),
        ], _st('''
IF Temp < (SP - 2.0) THEN
    Heat := TRUE; Cool := FALSE;
ELSIF Temp > (SP + 2.0) THEN
    Heat := FALSE; Cool := TRUE;
ELSE
    Heat := FALSE; Cool := FALSE;
END_IF;'''));
    final cold = build(40.0);
    _run(cold);
    expect(_v(cold, 'Heat'), isTrue);
    expect(_v(cold, 'Cool'), isFalse);
    final hot = build(60.0);
    _run(hot);
    expect(_v(hot, 'Cool'), isTrue);
    expect(_v(hot, 'Heat'), isFalse);
    final band = build(50.0);
    _run(band);
    expect(_v(band, 'Heat'), isFalse);
    expect(_v(band, 'Cool'), isFalse);
  });

  test('nested IF executes inner branch', () {
    PlcProject build(bool auto, double t) => _proj([
          _tag('Auto', 'BOOL', auto), _tag('Temp', 'FLOAT64', t), _tag('SP', 'FLOAT64', 50.0),
          _tag('Heat', 'BOOL', true), _tag('Cool', 'BOOL', true),
        ], _st('''
IF Auto THEN
    IF Temp < (SP - 2.0) THEN
        Heat := TRUE; Cool := FALSE;
    ELSE
        Heat := FALSE; Cool := FALSE;
    END_IF;
ELSE
    Heat := FALSE; Cool := FALSE;
END_IF;'''));
    final autoCold = build(true, 40.0);
    _run(autoCold);
    expect(_v(autoCold, 'Heat'), isTrue);
    expect(_v(autoCold, 'Cool'), isFalse);
    final manual = build(false, 40.0);
    _run(manual);
    expect(_v(manual, 'Heat'), isFalse); // outer ELSE
    expect(_v(manual, 'Cool'), isFalse);
  });

  test('multi-line boolean expression assignment', () {
    final p = _proj([
      _tag('AH', 'BOOL', false), _tag('AL', 'BOOL', false),
      _tag('Temp', 'FLOAT64', 50.0), _tag('SP', 'FLOAT64', 50.0),
      _tag('Ready', 'BOOL', false),
    ], _st('''
Ready := NOT AH
     AND NOT AL
     AND (Temp >= SP - 2.0)
     AND (Temp <= SP + 2.0);'''));
    _run(p);
    expect(_v(p, 'Ready'), isTrue);
  });

  test('comments are ignored', () {
    final p = _proj([_tag('A', 'BOOL', false)], _st('''
(* block comment *)
A := TRUE; // line comment
'''));
    _run(p);
    expect(_v(p, 'A'), isTrue);
  });

  test('forced tag is not overwritten', () {
    final p = _proj([_tag('A', 'BOOL', false, forced: true, fv: false)],
        _st('A := TRUE;'));
    _run(p);
    expect(_v(p, 'A'), isFalse);
  });

  test('malformed statements are skipped, valid ones still run', () {
    final p = _proj([_tag('A', 'BOOL', false), _tag('B', 'BOOL', false)],
        _st('A := TRUE;\n@@ garbage @@;\nB := TRUE;'));
    _run(p);
    expect(_v(p, 'A'), isTrue);
    expect(_v(p, 'B'), isTrue);
  });

  test('non-ST and empty-source programs are skipped without throwing', () {
    final ld = PlcProgram(name: 'L', language: 'LadderLogic');
    final p = _proj([_tag('A', 'BOOL', true)], ld);
    _run(p);
    final empty = PlcProgram(name: 'E', language: 'StructuredText', stSource: '');
    final p2 = _proj([], empty);
    _run(p2);
    expect(true, isTrue);
  });

  // Regression: a stray or duplicated keyword at statement position must not
  // hang the parser (the executor runs every scan over user-editable source, so
  // an ordinary typo cannot be allowed to freeze the scan loop). Each of these
  // would previously spin parseBlock forever; the test simply completing (the
  // suite has a per-test timeout) is the guard, plus we assert recovery.
  test('stray/misplaced keywords terminate without hanging', () {
    _run(_proj([_tag('A', 'BOOL', false)], _st('THEN')));
    _run(_proj([_tag('A', 'BOOL', false)], _st('THEN THEN')));
    _run(_proj([_tag('A', 'BOOL', false)], _st('END_IF ELSE THEN')));

    // A duplicated-THEN typo: the malformed IF is recovered from and a later
    // valid statement still executes.
    final p = _proj([_tag('A', 'BOOL', false), _tag('B', 'BOOL', false)],
        _st('IF A THEN THEN B := TRUE; END_IF;\nB := TRUE;'));
    _run(p);
    expect(_v(p, 'B'), isTrue); // the trailing valid assignment ran
  });
}
