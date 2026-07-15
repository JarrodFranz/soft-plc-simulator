import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_edit.dart';

PlcProgram _prog() {
  final p = PlcProgram(name: 'P', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'A', isInitial: true),
    SfcStep(id: 's1', name: 'B'),
    SfcStep(id: 's2', name: 'C'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'X'),
    SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Y'),
    SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's0', conditionSt: 'Z'),
  ]);
  return p;
}

void main() {
  test('id generators avoid collisions', () {
    final p = _prog();
    expect(p.sfcSteps.any((s) => s.id == newSfcStepId(p)), isFalse);
    expect(p.sfcTransitions.any((t) => t.id == newSfcTransitionId(p)), isFalse);
  });

  test('addSfcBranch appends an outgoing transition from the step', () {
    final p = _prog();
    final t = addSfcBranch(p, 's1');
    expect(t.fromStepId, 's1');
    expect(p.sfcTransitions.last.id, t.id);
  });

  test('deleteSfcStep removes the step and every transition touching it', () {
    final p = _prog();
    deleteSfcStep(p, 's0'); // s0 is from of t0,t1 and to of t2
    expect(p.sfcSteps.any((s) => s.id == 's0'), isFalse);
    expect(p.sfcTransitions.map((t) => t.id).toSet(), <String>{}); // all referenced s0
    // s0 was initial; a remaining step is promoted.
    expect(p.sfcSteps.where((s) => s.isInitial).length, 1);
  });

  test('reorderSfcBranch swaps priority within the same from-step group', () {
    final p = _prog();
    // s0 has t0 (index0) then t1 (index1). Move t1 up → t1 before t0.
    reorderSfcBranch(p, 't1', -1);
    final s0Trans = p.sfcTransitions.where((t) => t.fromStepId == 's0').map((t) => t.id).toList();
    expect(s0Trans, ['t1', 't0']);
    // t2 (different from-step) is undisturbed relative to the group.
  });

  test('reorder is a no-op at the group boundary', () {
    final p = _prog();
    reorderSfcBranch(p, 't0', -1); // already first in its group
    expect(p.sfcTransitions.where((t) => t.fromStepId == 's0').map((t) => t.id).toList(), ['t0', 't1']);
  });
}
