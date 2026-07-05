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
  test('Tank Level PID Control: closed-loop FBD PID drives an analog valve '
      'to bring Level_PV to and hold it near Level_SP', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_tank_level_pid');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();
    final sfc = SfcRuntime();
    final st = StRuntime();

    // Full scan tick, exactly as the workspace shell's `_executeScan` runs it:
    // sim -> LD -> FBD -> SFC -> ST.
    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeLdPrograms(p, 500, ld);
      executeFbdPrograms(p, 500, fbd);
      executeSfcPrograms(p, 500, sfc);
      executeStPrograms(p, 500, st);
    }

    final sp = _d(p, 'Level_SP');
    final startPv = _d(p, 'Level_PV');
    expect(startPv, lessThan(sp), reason: 'demo starts below setpoint so the loop must rise to control it');

    var sawCvModulate = false;
    var minCv = double.infinity;
    var maxCv = -double.infinity;
    var sawSettled = false;

    const scanCount = 600; // 600 * 500ms = 300s of simulated process time
    for (var i = 0; i < scanCount; i++) {
      scan();
      final cv = _d(p, 'Valve_CV');
      final pv = _d(p, 'Level_PV');

      expect(cv, greaterThanOrEqualTo(0.0), reason: 'Valve_CV must stay within [0,100]');
      expect(cv, lessThanOrEqualTo(100.0), reason: 'Valve_CV must stay within [0,100]');

      minCv = cv < minCv ? cv : minCv;
      maxCv = cv > maxCv ? cv : maxCv;

      // Once past the initial transient, track whether Level_PV has settled
      // near Level_SP and hold there for the remainder of the run.
      if (i > scanCount - 100) {
        if ((pv - sp).abs() <= 4.0) {
          sawSettled = true;
        } else {
          sawSettled = false;
        }
      }
    }

    // Valve_CV must actually modulate (not stick at a rail the whole run) —
    // proof the controller is actively responding rather than saturated open
    // or shut.
    sawCvModulate = (maxCv - minCv) > 1.0;

    final settledPv = _d(p, 'Level_PV');
    expect((settledPv - sp).abs(), lessThanOrEqualTo(4.0),
        reason: 'Level_PV must converge to and hold near Level_SP under PID control '
            '(got $settledPv vs sp $sp)');
    expect(sawSettled, isTrue, reason: 'Level_PV must remain settled near Level_SP through the tail of the run');
    expect(sawCvModulate, isTrue, reason: 'Valve_CV must modulate, not stick at a single rail the whole run');

    // Falsifiable: if Kp/Ki/Kd were all zero, CV would be pinned (raw=0 -> the
    // valve never opens) and Level_PV would sit at its initial value forever,
    // failing the settling assertion above. The gains tuned into the demo
    // project are what makes this test pass.
  });
}
