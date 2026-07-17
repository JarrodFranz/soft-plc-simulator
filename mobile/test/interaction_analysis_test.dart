import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';

PlcProject _twoZone() {
  final tags = [
    PlcTag(name: 'HA', path: 'HA', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    PlcTag(name: 'HB', path: 'HB', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    PlcTag(name: 'TA', path: 'TA', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
    PlcTag(name: 'TB', path: 'TB', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
    PlcTag(name: 'AMB', path: 'AMB', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
  ];
  final rules = [
    // TA: heat from HA + conduction toward TB + loss toward AMB
    SimRule(id: 'a0', name: 'TA heat', targetPath: 'TA', behavior: 'integrate',
        ratePerSec: 3.0, sourcePath: 'HA', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'a1', name: 'TA<->TB', targetPath: 'TA', behavior: 'firstOrderLag',
        sourcePath: 'TB', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'a2', name: 'TA loss', targetPath: 'TA', behavior: 'firstOrderLag',
        sourcePath: 'AMB', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
    // TB: heat from HB + conduction toward TA + loss toward AMB
    SimRule(id: 'b0', name: 'TB heat', targetPath: 'TB', behavior: 'integrate',
        ratePerSec: 3.0, sourcePath: 'HB', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'b1', name: 'TB<->TA', targetPath: 'TB', behavior: 'firstOrderLag',
        sourcePath: 'TA', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'b2', name: 'TB loss', targetPath: 'TB', behavior: 'firstOrderLag',
        sourcePath: 'AMB', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
  ];
  return PlcProject(id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules);
}

StepTestParams _params() => const StepTestParams(
    baseMv: 30, stepDelta: 20, dtMs: 100, maxScans: 20000, settleEps: 1e-4, settleWindow: 20);

void main() {
  test('identifyGainMatrix finds a coupled 2x2 with non-zero off-diagonal', () {
    final g = identifyGainMatrix(_twoZone(),
        mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    expect(g.converged, isTrue, reason: g.warning);
    expect(g.k11.abs(), greaterThan(0));
    expect(g.k22.abs(), greaterThan(0));
    expect(g.k12.abs(), greaterThan(0), reason: 'HB affects TA via conduction');
    expect(g.k21.abs(), greaterThan(0), reason: 'HA affects TB via conduction');
  });

  test('identifyGainMatrix does not mutate the source project', () {
    final p = _twoZone();
    final before = p.tags.firstWhere((t) => t.name == 'TA').value;
    identifyGainMatrix(p, mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    expect(p.tags.firstWhere((t) => t.name == 'TA').value, before);
  });

  test('identifyGainMatrix is deterministic', () {
    final a = identifyGainMatrix(_twoZone(), mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    final b = identifyGainMatrix(_twoZone(), mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    expect(a.k11, b.k11);
    expect(a.k12, b.k12);
    expect(a.k21, b.k21);
    expect(a.k22, b.k22);
  });

  test('computeRga golden + pairing bands', () {
    // Diagonal-dominant, low interaction: K = [[2,0.2],[0.2,2]] -> det=3.96, lambda11=4/3.96=1.0101
    final low = computeRga(const GainMatrix(k11: 2, k12: 0.2, k21: 0.2, k22: 2, converged: true));
    expect(low.lambda11, closeTo(4 / 3.96, 1e-9));
    expect(low.pairing.toLowerCase(), contains('diagonal'));
    expect(low.pairing.toLowerCase(), contains('low interaction'));
    // Off-diagonal / negative RGA: K=[[1,2],[2,1]] det=1-4=-3 lambda11=1/-3=-0.333
    final off = computeRga(const GainMatrix(k11: 1, k12: 2, k21: 2, k22: 1, converged: true));
    expect(off.lambda11, closeTo(1 / -3, 1e-9));
    expect(off.pairing.toLowerCase(), contains('off-diagonal'));
  });

  test('computeRga flags strong interaction on the flagship MIMO plant (not "low interaction")', () {
    // K = [[0.645,0.537],[0.537,0.645]] -> det=0.645^2-0.537^2=0.127656,
    // lambda11=0.416025/0.127656≈3.2585: strongly interacting, diagonal pairing,
    // decoupling recommended. Must NOT read as low interaction or ill-conditioned
    // (the gain matrix here is well-conditioned; only a near-singular det earns
    // "ill-conditioned").
    final strong = computeRga(const GainMatrix(k11: 0.645, k12: 0.537, k21: 0.537, k22: 0.645, converged: true));
    expect(strong.lambda11, greaterThan(1.5));
    expect(strong.lambda11, closeTo(3.2585, 1e-3));
    final p = strong.pairing.toLowerCase();
    expect(p, anyOf(contains('significant interaction'), contains('decoupling')));
    expect(p, isNot(contains('low interaction')));
    expect(p, isNot(contains('ill-conditioned')));
  });

  test('computeRga singular matrix warns and returns NaN lambda', () {
    final s = computeRga(const GainMatrix(k11: 1, k12: 1, k21: 1, k22: 1, converged: true)); // det=0
    expect(s.warning, isNotNull);
    expect(s.warning, contains('ill-conditioned'));
    expect(s.lambda11.isNaN, isTrue);
  });
}
