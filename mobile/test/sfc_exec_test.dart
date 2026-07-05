import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProgram _sfc(List<SfcStep> steps, List<SfcTransition> ts) {
  final prog = PlcProgram(name: 'S1', language: 'SequentialFunctionChart');
  prog.sfcSteps.addAll(steps);
  prog.sfcTransitions.addAll(ts);
  return prog;
}

PlcProject _proj(List<PlcTag> tags, PlcProgram prog) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('initial step activates and its N-action runs every scan', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true, actionSt: 'Out := TRUE;'),
      SfcStep(id: 's1', name: 'RUN', actionSt: 'Out := FALSE;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
    ]);
    final p = _proj([_tag('Out', 'BOOL', false), _tag('Go', 'BOOL', false)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt);
    expect(_b(p, 'Out'), isTrue);
    writePath(p, 'Out', false);
    executeSfcPrograms(p, 100, rt); // still IDLE, N-action re-runs
    expect(_b(p, 'Out'), isTrue);
  });

  test('transition fires and the new step acts on the NEXT scan', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'A', isInitial: true, actionSt: 'X := 1;'),
      SfcStep(id: 's1', name: 'B', actionSt: 'X := 2;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
    ]);
    final p = _proj([_tag('X', 'INT32', 0), _tag('Go', 'BOOL', true)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt); // A acts, then transition fires
    expect(readPath(p, 'X'), equals(1));
    executeSfcPrograms(p, 100, rt); // B acts now
    expect(readPath(p, 'X'), equals(2));
  });

  test('STEP_T gates a timed transition and resets on step entry', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'HOLD', isInitial: true, actionSt: ''),
      SfcStep(id: 's1', name: 'DONE', actionSt: 'Done := TRUE;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'STEP_T >= 300'),
    ]);
    final p = _proj([_tag('Done', 'BOOL', false)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt); // T=100
    executeSfcPrograms(p, 100, rt); // T=200
    expect(_b(p, 'Done'), isFalse);
    executeSfcPrograms(p, 100, rt); // T=300 -> fires
    executeSfcPrograms(p, 100, rt); // DONE acts
    expect(_b(p, 'Done'), isTrue);
  });

  test('one-scan step executes its action exactly once (COUNT idiom)', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'WAIT', isInitial: true, actionSt: ''),
      SfcStep(id: 'sc', name: 'COUNT', actionSt: 'N := N + 1;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 'sc', conditionSt: 'Go'),
      SfcTransition(id: 't1', fromStepId: 'sc', toStepId: 's0', conditionSt: 'TRUE'),
    ]);
    final p = _proj([_tag('N', 'INT32', 0), _tag('Go', 'BOOL', true)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt); // WAIT -> fires to COUNT
    writePath(p, 'Go', false);      // only one visit
    executeSfcPrograms(p, 100, rt); // COUNT acts once, fires back to WAIT
    executeSfcPrograms(p, 100, rt); // WAIT again
    executeSfcPrograms(p, 100, rt);
    expect(readPath(p, 'N'), equals(1));
  });

  test('first true transition wins in list order', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'A', isInitial: true, actionSt: ''),
      SfcStep(id: 's1', name: 'B', actionSt: 'X := 1;'),
      SfcStep(id: 's2', name: 'C', actionSt: 'X := 2;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'TRUE'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'TRUE'),
    ]);
    final p = _proj([_tag('X', 'INT32', 0)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt);
    executeSfcPrograms(p, 100, rt);
    expect(readPath(p, 'X'), equals(1)); // went to B, not C
  });

  test('a forced root tag is not overwritten by an action', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'A', isInitial: true, actionSt: 'Y := TRUE;'),
    ], []);
    final p = _proj([_tag('Y', 'BOOL', false, forced: true, fv: false)], prog);
    executeSfcPrograms(p, 100, SfcRuntime());
    expect(readPath(p, 'Y'), isFalse);
  });

  test('non-SFC programs and empty charts are skipped without throwing', () {
    final prog = PlcProgram(name: 'L', language: 'LadderLogic');
    final p = _proj([_tag('Y', 'BOOL', false)], prog);
    executeSfcPrograms(p, 100, SfcRuntime());
    final empty = PlcProgram(name: 'E', language: 'SequentialFunctionChart');
    final p2 = _proj([], empty);
    executeSfcPrograms(p2, 100, SfcRuntime());
    expect(true, isTrue); // reached without exception
  });
}
