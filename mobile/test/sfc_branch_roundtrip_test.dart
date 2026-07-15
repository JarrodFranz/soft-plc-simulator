import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('a branched SFC round-trips with transition order (priority) preserved', () {
    final prog = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true),
      SfcStep(id: 's1', name: 'FILL'),
      SfcStep(id: 's2', name: 'ABORT'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Bottle'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Abort'),
      SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's0', conditionSt: 'TRUE'),
    ]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    final round = PlcProject.fromJson(proj.toJson());
    final rp = round.programs.single;
    expect(rp.sfcTransitions.map((t) => '${t.fromStepId}->${t.toStepId}:${t.conditionSt}').toList(),
        ['s0->s1:Bottle', 's0->s2:Abort', 's1->s0:TRUE']);
    // Stable re-serialize.
    expect(round.toJson().toString(), proj.toJson().toString());
  });
}
