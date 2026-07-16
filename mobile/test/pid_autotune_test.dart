import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/pid_autotune.dart';

PlcProject _lagProcess() {
  // CV (0..100) drives PV via a first-order lag toward CV, plus a small dead time.
  final tags = [
    PlcTag(name: 'CV', path: 'CV', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    PlcTag(name: 'PV', path: 'PV', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
  ];
  final rules = [
    SimRule(id: 's0', name: 'lag', targetPath: 'PV', behavior: 'firstOrderLag',
        sourcePath: 'CV', tauSec: 2.0, minValue: -1000, maxValue: 1000,
        condition: const []),
  ];
  return PlcProject(id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules);
}

RelayTuneParams _params() => const RelayTuneParams(
    relayHigh: 100, relayLow: 0, hysteresis: 0.5, setpoint: 50,
    dtMs: 100, maxScans: 4000, settleCycles: 3);

void main() {
  test('relay produces a sustained limit cycle on a lag process', () {
    final r = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(r.converged, isTrue, reason: r.warning);
    expect(r.ku, greaterThan(0));
    expect(r.pu, greaterThan(0));
    expect(r.trace.length, greaterThan(10));
  });

  test('experiment does not mutate the source project', () {
    final p = _lagProcess();
    final beforePv = p.tags.firstWhere((t) => t.name == 'PV').value;
    relayAutoTune(p, pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(p.tags.firstWhere((t) => t.name == 'PV').value, beforePv);
  });

  test('deterministic: same project + params -> identical Ku/Pu', () {
    final a = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV', params: _params());
    final b = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(a.ku, b.ku);
    expect(a.pu, b.pu);
  });

  test('integrating process also converges', () {
    final tags = [
      PlcTag(name: 'CV', path: 'CV', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal'),
      PlcTag(name: 'PV', path: 'PV', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal'),
    ];
    // The sim engine's integrate gain is `sourcePath / refValue` (unsigned) —
    // it scales the rate, it does not flip its sign. So a relay that only
    // ever commands CV in [0, 100] (as in `_params()`) can only ever push PV
    // up or hold it (gain 0 at CV=0); it can never integrate PV back down and
    // so can never form a limit cycle. Driving CV symmetrically about the
    // refValue (+50/-50 around ref 50) makes the gain flip sign with the
    // relay, so PV genuinely ramps up on relayHigh and down on relayLow,
    // producing a real triangular limit cycle around the setpoint.
    final rules = [
      SimRule(id: 's0', name: 'int', targetPath: 'PV', behavior: 'integrate',
          sourcePath: 'CV', refValue: 50.0, ratePerSec: 5.0, minValue: -1000, maxValue: 1000,
          condition: const []),
    ];
    final proj = PlcProject(id: 'p', name: 'P', controllerName: 'C',
        tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules);
    final r = relayAutoTune(proj, pvPath: 'PV', cvPath: 'CV',
        params: const RelayTuneParams(relayHigh: 50, relayLow: -50, hysteresis: 2,
            setpoint: 50, dtMs: 100, maxScans: 4000, settleCycles: 3));
    expect(r.converged, isTrue, reason: r.warning);
  });

  test('no oscillation -> converged false with warning', () {
    // hysteresis larger than any achievable PV swing about SP given a tiny relay.
    final r = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV',
        params: const RelayTuneParams(relayHigh: 50.1, relayLow: 49.9, hysteresis: 40,
            setpoint: 50, dtMs: 100, maxScans: 500, settleCycles: 3));
    expect(r.converged, isFalse);
    expect(r.warning, isNotNull);
  });

  group('tuningRules', () {
    test('tuningRules golden numbers', () {
      final s = tuningRules(10.0, 4000.0); // puS = 4.0
      TuningSuggestion row(String name, String form) =>
          s.firstWhere((x) => x.name == name && x.form == form);
      // ZN PID: Kp=6.0, Ti=2.0 -> Ki=3.0, Td=0.5 -> Kd=3.0
      final zn = row('Ziegler-Nichols', 'PID');
      expect(zn.kp, closeTo(6.0, 1e-9));
      expect(zn.ki, closeTo(3.0, 1e-9));
      expect(zn.kd, closeTo(3.0, 1e-9));
      // ZN PI: Kp=4.5, Ti=3.332 -> Ki=1.3506..., Kd=0
      final znpi = row('Ziegler-Nichols', 'PI');
      expect(znpi.kp, closeTo(4.5, 1e-9));
      expect(znpi.kd, 0);
      // Tyreus-Luyben PID: Kp=10/2.2=4.5454..., Ti=8.8 -> Ki=0.5165..., Td=4/6.3=0.6349 -> Kd=2.886...
      final tl = row('Tyreus-Luyben', 'PID');
      expect(tl.kp, closeTo(10 / 2.2, 1e-9));
      expect(tl.kd, closeTo((10 / 2.2) * (4.0 / 6.3), 1e-9));
      // ZN no-overshoot PID: Kp=2.0, Ti=2.0 -> Ki=1.0, Td=4/3 -> Kd=2.666...
      final no = row('ZN no-overshoot', 'PID');
      expect(no.kp, closeTo(2.0, 1e-9));
      expect(no.kd, closeTo(2.0 * (4.0 / 3.0), 1e-9));
      // all PI rows have kd == 0; all Ki == kp/Ti (Ti>0)
      for (final x in s.where((x) => x.form == 'PI')) {
        expect(x.kd, 0);
      }
      expect(s.length, 6);
    });
  });
}
