import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_expr.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _proj(List<PlcTag> tags) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [],
    );

void main() {
  final p = _proj([
    _tag('Start_Cmd', 'BOOL', true),
    _tag('Bottle_Present', 'BOOL', false),
    _tag('Fill_Level', 'FLOAT64', 96.5),
    _tag('Filled_Count', 'INT32', 7),
    _tag('Turbidity_SP', 'FLOAT64', 5.0),
  ]);

  test('literals and identifiers', () {
    expect(evalExpr(p, 'TRUE'), isTrue);
    expect(evalExpr(p, 'false'), isFalse);
    expect(evalExpr(p, '42'), equals(42));
    expect(evalExpr(p, '95.0'), equals(95.0));
    expect(evalExpr(p, 'Start_Cmd'), isTrue);
    expect(evalExpr(p, 'Filled_Count'), equals(7));
    expect(evalExpr(p, 'No_Such_Tag'), isNull);
  });

  test('extraVars shadow tags (STEP_T)', () {
    expect(evalExpr(p, 'STEP_T', extraVars: {'STEP_T': 1200}), equals(1200));
    expect(evalStCondition(p, 'STEP_T >= 3000', extraVars: {'STEP_T': 2999}), isFalse);
    expect(evalStCondition(p, 'STEP_T >= 3000', extraVars: {'STEP_T': 3000}), isTrue);
  });

  test('comparators', () {
    expect(evalExpr(p, 'Fill_Level >= 95.0'), isTrue);
    expect(evalExpr(p, 'Fill_Level < 95.0'), isFalse);
    expect(evalExpr(p, 'Filled_Count = 7'), isTrue);
    expect(evalExpr(p, 'Filled_Count <> 7'), isFalse);
    expect(evalExpr(p, 'Start_Cmd = TRUE'), isTrue);
    expect(evalExpr(p, 'Start_Cmd <> FALSE'), isTrue);
  });

  test('boolean operators and precedence', () {
    expect(evalExpr(p, 'Start_Cmd AND NOT Bottle_Present'), isTrue);
    expect(evalExpr(p, 'Bottle_Present OR Start_Cmd'), isTrue);
    expect(evalExpr(p, 'NOT Start_Cmd OR Start_Cmd AND Start_Cmd'), isTrue);
    expect(evalExpr(p, 'Start_Cmd AND (Bottle_Present OR TRUE)'), isTrue);
    expect(evalExpr(p, 'Start_Cmd XOR Start_Cmd'), isFalse);
  });

  test('arithmetic keeps int-ness and supports mixing', () {
    expect(evalExpr(p, 'Filled_Count + 1'), equals(8));
    expect(evalExpr(p, 'Filled_Count + 1') is int, isTrue);
    expect(evalExpr(p, '2 * 3 + 4'), equals(10));
    expect(evalExpr(p, '2 + 3 * 4'), equals(14));
    expect(evalExpr(p, '-Filled_Count'), equals(-7));
    expect(evalExpr(p, 'Turbidity_SP + 1'), equals(6.0));
    expect(evalExpr(p, '1 / 0'), isNull); // division by zero -> null
  });

  test('comments are stripped', () {
    expect(evalExpr(p, 'TRUE  (* 1s cap press timer *)'), isTrue);
    expect(evalStCondition(p, 'Start_Cmd (* gate *) AND TRUE'), isTrue);
  });

  test('malformed input returns null / false, never throws', () {
    expect(evalExpr(p, ''), isNull);
    expect(evalExpr(p, 'AND AND'), isNull);
    expect(evalExpr(p, 'Fill_Level >='), isNull);
    expect(evalExpr(p, '((('), isNull);
    expect(evalStCondition(p, 'garbage ~~ here'), isFalse);
  });

  test('runStatements executes assignment lists, skipping comments', () {
    final p2 = _proj([
      _tag('Fill_Valve', 'BOOL', false),
      _tag('Filled_Count', 'INT32', 7),
      _tag('Sfc_Step', 'INT32', 0),
    ]);
    final writes = <String, dynamic>{};
    runStatements(p2, '''
Fill_Valve := TRUE;
// line comment
Filled_Count := Filled_Count + 1;
Sfc_Step := 4;  (* display sync *)
''', (path, v) => writes[path] = v);
    expect(writes['Fill_Valve'], isTrue);
    expect(writes['Filled_Count'], equals(8));
    expect(writes['Sfc_Step'], equals(4));
  });

  test('runStatements skips malformed lines without throwing', () {
    final p2 = _proj([_tag('A', 'BOOL', false)]);
    final writes = <String, dynamic>{};
    runStatements(p2, 'A := TRUE;\nnonsense here;\nA := FALSE;',
        (path, v) => writes[path] = v);
    expect(writes['A'], isFalse); // both valid lines ran, bad one skipped
  });
}
