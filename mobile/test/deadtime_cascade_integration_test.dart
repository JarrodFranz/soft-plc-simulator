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
  test('Cascade Tanks with Transport Delay: Tank_B_Level lags Tank_A_Level '
      'by approximately the transport dead time tauSec', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_cascade_tanks');
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

    final tauSec = p.simRules.firstWhere((r) => r.behavior == 'deadTime').tauSec;
    expect(tauSec, greaterThan(0), reason: 'demo must exercise a non-trivial dead time');

    final initialA = _d(p, 'Tank_A_Level');
    final initialB = _d(p, 'Tank_B_Level');

    double? aRisenAtSec;
    double? bRisenAtSec;
    double bLevelWhenARisen = initialB;

    const scanCount = 400; // 400 * 500ms = 200s of simulated process time
    for (var i = 0; i < scanCount; i++) {
      scan();
      final tSec = (i + 1) * scanPeriodMs / 1000.0;
      final a = _d(p, 'Tank_A_Level');
      final b = _d(p, 'Tank_B_Level');

      expect(a, inInclusiveRange(0.0, 100.0), reason: 'Tank_A_Level must stay clamped 0-100');
      expect(b, inInclusiveRange(0.0, 100.0), reason: 'Tank_B_Level must stay clamped 0-100');

      if (aRisenAtSec == null && a > initialA + 5) {
        aRisenAtSec = tSec;
        bLevelWhenARisen = b;
      }
      if (bRisenAtSec == null && b > initialB + 5) {
        bRisenAtSec = tSec;
      }
    }

    expect(aRisenAtSec, isNotNull, reason: 'Tank_A_Level must clearly rise (> init+5) during the run');
    expect(bRisenAtSec, isNotNull, reason: 'Tank_B_Level must clearly rise (> init+5) during the run');

    // The core lag assertion: at the moment Tank_A_Level has clearly risen,
    // Tank_B_Level must still be near its initial value (the transport delay
    // has not yet propagated the rise downstream).
    expect((bLevelWhenARisen - initialB).abs(), lessThan(5.0),
        reason: 'Tank_B_Level must still be near its initial value '
            '(${initialB.toStringAsFixed(2)}) when Tank_A_Level has already '
            'clearly risen (got Tank_B_Level=${bLevelWhenARisen.toStringAsFixed(2)}) '
            '- this is the visible transport delay');

    // Tank_B must rise measurably AFTER Tank_A, on the order of the dead time
    // (allow slack for the ramp-up dynamics of the coupled integrators).
    expect(bRisenAtSec! - aRisenAtSec!, greaterThanOrEqualTo(tauSec * 0.5),
        reason: 'Tank_B_Level must begin rising only after roughly the dead '
            'time tauSec=$tauSec (Tank_A rose at ${aRisenAtSec}s, Tank_B rose '
            'at ${bRisenAtSec}s)');

    // Falsifiable: with tauSec == 0 (a pass-through, per the deadTime spec) or
    // with the deadTime SimRule removed entirely, Transfer_Line would track
    // Tank_A_Level with zero delay and Tank_B_Level would rise in lock-step
    // with Tank_A_Level (same scan, no lag) - the assertions above would then
    // fail because bLevelWhenARisen would already be well above initialB+5.
  });
}
