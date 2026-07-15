import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';

PlcProject _proj(PlcProgram prog, {List<PlcTag>? tags}) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: tags ?? [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
SfcStep _s(String id, {bool init = false, String action = ''}) =>
    SfcStep(id: id, name: id, isInitial: init, actionSt: action);

void main() {
  test('single-token chart advances first-true, one at a time (unchanged)', () {
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([_s('a', init: true), _s('b'), _s('c')]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 'a', toStepId: 'b', conditionSt: 'TRUE'),
      SfcTransition(id: 't1', fromStepId: 'b', toStepId: 'c', conditionSt: 'TRUE'),
    ]);
    final proj = _proj(prog);
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt); // a -> b
    expect(rt.active['M'], {'b'});
    executeSfcPrograms(proj, 100, rt); // b -> c
    expect(rt.active['M'], {'c'});
  });

  test('parallel fork activates all branch heads; join waits for all', () {
    // a --[fork T]--> {p1, q1};  p1 --[TRUE]--> p2 ; q1 --[TRUE]--> q2 ;
    // join {p2, q2} --[TRUE]--> done
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      _s('a', init: true), _s('p1'), _s('p2'), _s('q1'), _s('q2'), _s('done'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 'f', fromStepId: 'a', toStepId: '', conditionSt: 'TRUE',
          kind: 'parallelFork', toStepIds: ['p1', 'q1']),
      SfcTransition(id: 'tp', fromStepId: 'p1', toStepId: 'p2', conditionSt: 'Pgo'),
      SfcTransition(id: 'tq', fromStepId: 'q1', toStepId: 'q2', conditionSt: 'Qgo'),
      SfcTransition(id: 'j', fromStepId: '', toStepId: 'done', conditionSt: 'TRUE',
          kind: 'parallelJoin', fromStepIds: ['p2', 'q2']),
    ]);
    final tags = [
      PlcTag(name: 'Pgo', path: 'Pgo', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'Qgo', path: 'Qgo', dataType: 'BOOL', value: false, ioType: 'Internal'),
    ];
    final proj = _proj(prog, tags: tags);
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt);            // a fork -> {p1,q1}
    expect(rt.active['M'], {'p1', 'q1'});
    proj.tags.firstWhere((t) => t.name == 'Pgo').value = true;
    executeSfcPrograms(proj, 100, rt);            // p1 -> p2 ; q1 stays
    expect(rt.active['M'], {'p2', 'q1'});
    executeSfcPrograms(proj, 100, rt);            // join not satisfied (q not done)
    expect(rt.active['M'], {'p2', 'q1'});
    proj.tags.firstWhere((t) => t.name == 'Qgo').value = true;
    executeSfcPrograms(proj, 100, rt);            // q1 -> q2
    expect(rt.active['M'], {'p2', 'q2'});
    executeSfcPrograms(proj, 100, rt);            // join fires -> done
    expect(rt.active['M'], {'done'});
  });

  test('alternative divergence still first-true (priority order)', () {
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([_s('a', init: true), _s('x'), _s('y')]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 'a', toStepId: 'x', conditionSt: 'A'),
      SfcTransition(id: 't1', fromStepId: 'a', toStepId: 'y', conditionSt: 'B'),
    ]);
    final tags = [
      PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'),
      PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true, ioType: 'Internal'),
    ];
    final rt = SfcRuntime();
    executeSfcPrograms(_proj(prog, tags: tags), 100, rt);
    expect(rt.active['M'], {'x'}); // A wins (list order)
  });
}
