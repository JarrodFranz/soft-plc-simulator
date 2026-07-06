import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();

void main() {
  test(
      'Noisy Level Measurement: Level_Meas jitters within the noise amplitude '
      'band around Tank_Level (no drift), varies scan-to-scan, and '
      'Level_Filtered attenuates the jitter relative to Level_Meas', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_noisy_level');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();
    final sfc = SfcRuntime();
    final st = StRuntime();

    const scanPeriodMs = 500;

    // Full scan tick, exactly as the workspace shell's `_executeScan` runs it:
    // sim -> LD -> FBD -> SFC -> ST.
    void scan() {
      applySimRules(p, p.simRules, scanPeriodMs, sim);
      executeLdPrograms(p, scanPeriodMs, ld);
      executeFbdPrograms(p, scanPeriodMs, fbd);
      executeSfcPrograms(p, scanPeriodMs, sfc);
      executeStPrograms(p, scanPeriodMs, st);
    }

    final noiseRule = p.simRules.firstWhere((r) => r.behavior == 'noise');
    expect(noiseRule.sourcePath, 'Tank_Level');
    expect(noiseRule.targetPath, 'Level_Meas');
    final amplitude = noiseRule.targetValue;
    expect(amplitude, greaterThan(0), reason: 'demo must exercise non-trivial noise amplitude');
    const epsilon = 1e-6;

    final lagRule = p.simRules.firstWhere((r) => r.behavior == 'firstOrderLag');
    expect(lagRule.sourcePath, 'Level_Meas');
    expect(lagRule.targetPath, 'Level_Filtered');

    const scanCount = 400; // 400 * 500ms = 200s of simulated process time
    final measHistory = <double>[];
    final filteredHistory = <double>[];

    for (var i = 0; i < scanCount; i++) {
      scan();
      final tankLevel = _d(p, 'Tank_Level');
      final levelMeas = _d(p, 'Level_Meas');
      final levelFiltered = _d(p, 'Level_Filtered');

      // (a) Level_Meas stays within the amplitude band of Tank_Level on EVERY
      // scan and does not drift. A random-walk/in-place noise bug would grow
      // this gap unbounded over 400 scans; a clean source->target rule keeps
      // it bounded by the amplitude forever.
      expect((levelMeas - tankLevel).abs(), lessThanOrEqualTo(amplitude + epsilon),
          reason: 'at scan $i, Level_Meas ($levelMeas) must stay within '
              '±$amplitude of Tank_Level ($tankLevel) - a drifting/in-place '
              'noise bug would violate this as scans accumulate');

      expect(tankLevel, inInclusiveRange(0.0, 100.0));
      expect(levelMeas, inInclusiveRange(0.0, 100.0));
      expect(levelFiltered, inInclusiveRange(0.0, 100.0));

      measHistory.add(levelMeas);
      filteredHistory.add(levelFiltered);
    }

    // (b) Level_Meas actually varies scan-to-scan (noise is really applied,
    // not a constant pass-through). Falsifiable: with amplitude == 0, the
    // noise rule is a pure pass-through and this would fail (no jitter).
    final distinctMeas = measHistory.toSet();
    expect(distinctMeas.length, greaterThan(1),
        reason: 'Level_Meas must take on more than one distinct value across '
            '$scanCount scans - the noise must actually be applied');

    double meanAbsSuccessiveDiff(List<double> xs) {
      double sum = 0;
      for (var i = 1; i < xs.length; i++) {
        sum += (xs[i] - xs[i - 1]).abs();
      }
      return sum / (xs.length - 1);
    }

    final measJitter = meanAbsSuccessiveDiff(measHistory);
    final filteredJitter = meanAbsSuccessiveDiff(filteredHistory);

    expect(measJitter, greaterThan(0), reason: 'Level_Meas must have non-zero scan-to-scan variation');

    // (c) Level_Filtered has a SMALLER scan-to-scan variation than
    // Level_Meas - the existing firstOrderLag block attenuates the raw
    // sensor jitter. Falsifiable: with amplitude == 0 there would be no
    // jitter at all to filter, so this comparison would be vacuous/fail to
    // demonstrate anything; with a broken (non-attenuating) lag, filteredJitter
    // would be >= measJitter.
    expect(filteredJitter, lessThan(measJitter),
        reason: 'Level_Filtered mean abs successive diff ($filteredJitter) must '
            'be smaller than Level_Meas ($measJitter) - the first-order lag '
            'must attenuate the raw measurement jitter');
  });
}
