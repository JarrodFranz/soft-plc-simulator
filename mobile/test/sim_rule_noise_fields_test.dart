import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('new noise/drift fields default and round-trip', () {
    final r = SimRule(
        id: 'r',
        name: 'n',
        targetPath: 'X',
        behavior: 'noise',
        noiseDistribution: 'gaussian',
        driftAmplitude: 2.5,
        driftPeriodSec: 30.0);
    final back = SimRule.fromJson(r.toJson());
    expect(back.noiseDistribution, 'gaussian');
    expect(back.driftAmplitude, 2.5);
    expect(back.driftPeriodSec, 30.0);
  });

  test('legacy SimRule JSON (no new keys) loads with defaults', () {
    final legacy = {
      'id': 'r',
      'name': 'n',
      'target': 'X',
      'behavior': 'noise',
    };
    final r = SimRule.fromJson(legacy);
    expect(r.noiseDistribution, 'uniform');
    expect(r.driftAmplitude, 0.0);
    expect(r.driftPeriodSec, 60.0);
  });
}
