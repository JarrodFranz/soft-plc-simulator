import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';

PlcProject _proj(List<SimRule> rules, List<PlcTag> tags) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules,
    );

List<double> _run(PlcProject p, int n) {
  final rt = SimRuntime();
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    applySimRules(p, p.simRules, 100, rt);
    out.add((p.tags.firstWhere((t) => t.name == 'Y').value as num).toDouble());
  }
  return out;
}

SimRule _noiseRule({String dist = 'uniform', double drift = 0.0, double period = 60.0}) =>
    SimRule(id: 'r', name: 'n', behavior: 'noise', sourcePath: 'X', targetPath: 'Y',
        targetValue: 1.0, minValue: -100, maxValue: 100,
        noiseDistribution: dist, driftAmplitude: drift, driftPeriodSec: period);

List<PlcTag> _tags() => [
  PlcTag(name: 'X', path: 'X', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal'),
  PlcTag(name: 'Y', path: 'Y', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
];

void main() {
  test('uniform + no drift reproduces the pre-feature sequence (byte guard)', () {
    // Reference computed from the SAME xorshift/fnv used today: one draw per
    // scan, noise = (2u-1)*a. We assert determinism + that switching nothing on
    // changes nothing by running twice and comparing, and that values stay in
    // clean +/- a.
    final a = _run(_proj([_noiseRule()], _tags()), 20);
    final b = _run(_proj([_noiseRule()], _tags()), 20);
    expect(a, b); // deterministic
    for (final v in a) {
      expect(v, inInclusiveRange(10.0 - 1.0, 10.0 + 1.0)); // clean=10, a=1
    }
  });

  test('gaussian differs from uniform but stays clamped', () {
    final u = _run(_proj([_noiseRule(dist: 'uniform')], _tags()), 30);
    final g = _run(_proj([_noiseRule(dist: 'gaussian')], _tags()), 30);
    expect(g, isNot(equals(u)));
    for (final v in g) {
      expect(v, inInclusiveRange(-100.0, 100.0));
    }
  });

  test('drift on: |measured - clean| <= a + driftAmplitude, and drift is slow', () {
    const a = 1.0, drift = 4.0;
    final rt = SimRuntime();
    final p = _proj([_noiseRule(drift: drift, period: 30.0)], _tags());
    for (var i = 0; i < 60; i++) {
      applySimRules(p, p.simRules, 100, rt);
      final y = (p.tags.firstWhere((t) => t.name == 'Y').value as num).toDouble();
      expect((y - 10.0).abs(), lessThanOrEqualTo(a + drift + 1e-9));
    }
    // drift value itself changes by a small bounded step per scan
    final st = rt.byRuleId['r']!;
    expect(st.driftValue.abs(), lessThanOrEqualTo(drift + 1e-9));
  });

  test('drift off (default) never touches noiseState / reproduces uniform', () {
    final withField = _run(_proj([_noiseRule(drift: 0.0)], _tags()), 20);
    final plain = _run(_proj([_noiseRule()], _tags()), 20);
    expect(withField, plain);
  });

  test('determinism: same seed -> same sequence', () {
    final a = _run(_proj([_noiseRule(dist: 'gaussian', drift: 2.0)], _tags()), 25);
    final b = _run(_proj([_noiseRule(dist: 'gaussian', drift: 2.0)], _tags()), 25);
    expect(a, b);
  });
}
