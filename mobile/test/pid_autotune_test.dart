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
}
