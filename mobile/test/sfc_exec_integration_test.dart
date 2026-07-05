import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// One scan tick, covering only sim -> LD -> SFC (this harness intentionally
// omits FBD/ST, which are outside the LD/SFC pipeline under test here — see
// the water-plant test below for how its one relevant output, `Quality_OK`
// (normally computed by WaterQuality_FBD), is emulated).
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

    // Quality_OK is normally computed by WaterQuality_FBD (FBD-domain:
    // Turbidity_PV < Turbidity_SP && Level_PV > 10.0), which this pure
    // sim->LD->SFC harness intentionally does not run. Pin it false each scan
    // to emulate that output, since with Turbidity_PV forced to 12.0 (> the
    // 5.0 setpoint) it would evaluate to false anyway.
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

  test('water backwash does not strand the pump when quality never recovers',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final sfc = SfcRuntime();

    // Stranding scenario: the reservoir drains below the Quality_OK level
    // threshold during backwash, so Quality_OK never recovers. Force the
    // backwash to stay active (LD rung 4 won't overwrite a forced tag) and pin
    // Quality_OK false every scan. BACKWASH_PUMPING (bw2) must still advance
    // via the STEP_T >= 30000 flush cap so Backwash_Pump does not latch on.
    final ba = p.tags.firstWhere((t) => t.name == 'Backwash_Active');
    ba.isForced = true;
    ba.forcedValue = true;
    ba.value = true;

    bool pumpTurnedOn = false;
    bool pumpTurnedOffAfterOn = false;
    for (int i = 0; i < 90; i++) {
      writePath(p, 'Quality_OK', false); // never recovers
      _scan(p, sim, ld, sfc);
      if (_b(p, 'Backwash_Pump')) {
        pumpTurnedOn = true;
      } else if (pumpTurnedOn) {
        pumpTurnedOffAfterOn = true;
      }
    }
    expect(pumpTurnedOn, isTrue,
        reason: 'the sequence should reach BACKWASH_PUMPING');
    expect(pumpTurnedOffAfterOn, isTrue,
        reason: 'the 30s flush cap must advance past pumping even when '
            'Quality_OK never recovers (no stranded pump)');
  });
}
