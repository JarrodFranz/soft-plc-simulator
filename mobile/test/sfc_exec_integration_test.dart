import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// One scan tick, exactly as the workspace shell's `_executeScan` runs it
// (minus `_evaluateActiveLogic`, which is hardcoded FBD/ST logic outside the
// LD/SFC pipeline under test here — see the water-plant test below for how
// its one relevant output, `Quality_OK`, is emulated).
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, SfcRuntime sfc,
    [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeSfcPrograms(p, dtMs, sfc);
}

bool _b(PlcProject p, String path) => readPath(p, path) == true;
int _i(PlcProject p, String path) => (readPath(p, path) as num?)?.toInt() ?? 0;

void main() {
  test('bottle filler: two full cycles, one count each, display tag tracks',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_sfc_filling');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final sfc = SfcRuntime();

    _scan(p, sim, ld, sfc); // IDLE
    expect(_i(p, 'Sfc_Step'), equals(0));
    writePath(p, 'Start_Cmd', true);
    _scan(p, sim, ld, sfc); // IDLE fires -> WAIT_BOTTLE next
    writePath(p, 'Bottle_Present', true);

    int counted = 0;
    for (int i = 0; i < 80 && counted < 2; i++) {
      _scan(p, sim, ld, sfc);
      if (_i(p, 'Sfc_Step') == 5) {
        counted++;
        // One-scan COUNT step: Filled_Count must have incremented exactly
        // once per visit (asserted below via the final tally, not per-visit,
        // since COUNT is visited on distinct scans for each bottle).
      }
    }
    expect(counted, equals(2),
        reason: 'two bottles should complete within 40s sim time');
    expect(_i(p, 'Filled_Count'), equals(2)); // exactly one increment per bottle
  });

  test('water plant: 30s ladder timer starts backwash; SFC sequences valve/pump',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final sfc = SfcRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld, sfc);
    writePath(p, 'Start_PB', false);
    expect(_b(p, 'Pump_Motor'), isTrue);

    // Force bad quality persistently: pin turbidity above setpoint so the
    // ladder's 30s BackwashTimer (rung 3: NOT Quality_OK AND Pump_Motor) runs.
    final turb = p.tags.firstWhere((t) => t.name == 'Turbidity_PV');
    turb.isForced = true;
    turb.forcedValue = 12.0;
    turb.value = 12.0;

    // Quality_OK is normally computed by the shell's hardcoded
    // `_evaluateActiveLogic` (FBD-domain: Turbidity_PV < Turbidity_SP &&
    // Level_PV > 10.0), which this pure sim->LD->SFC harness intentionally
    // does not run. Pin it false each scan to emulate that output, since with
    // Turbidity_PV forced to 12.0 (> the 5.0 setpoint) it would evaluate to
    // false anyway.
    writePath(p, 'Quality_OK', false);

    bool sawBackwash = false;
    bool sawValve = false;
    for (int i = 0; i < 70; i++) {
      _scan(p, sim, ld, sfc);
      writePath(p, 'Quality_OK', false); // keep FBD-domain emulation pinned
      if (_b(p, 'Backwash_Active')) {
        sawBackwash = true;
      }
      if (_b(p, 'Backwash_Valve')) {
        sawValve = true;
      }
    }
    expect(sawBackwash, isTrue, reason: 'BackwashTimer (30s) should trip within 35s');
    expect(sawValve, isTrue, reason: 'SFC should open the backwash valve');
  });
}
