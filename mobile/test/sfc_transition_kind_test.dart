import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('new kind/fork/join fields default and round-trip', () {
    final t = SfcTransition(
      id: 't', fromStepId: 's0', toStepId: 's1', conditionSt: 'X',
      kind: 'parallelFork', toStepIds: ['s1', 's2']);
    final r = SfcTransition.fromJson(t.toJson());
    expect(r.kind, 'parallelFork');
    expect(r.toStepIds, ['s1', 's2']);
    expect(r.fromStepIds, isEmpty);
  });

  test('legacy transition JSON (no new keys) loads as single', () {
    final legacy = {
      'id': 't', 'from_step_id': 's0', 'to_step_id': 's1', 'condition_st': 'X',
    };
    final r = SfcTransition.fromJson(legacy);
    expect(r.kind, 'single');
    expect(r.toStepIds, isEmpty);
    expect(r.fromStepIds, isEmpty);
  });
}
