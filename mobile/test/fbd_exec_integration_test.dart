import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// One scan tick, exactly as the workspace shell's `_executeScan` runs it up
// to (and including) FBD: sim -> LD -> FBD. SFC/`_evaluateActiveLogic` are
// not relevant to either diagram under test here.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, FbdRuntime fbd,
    [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeFbdPrograms(p, dtMs, fbd);
}

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('HVAC diagram reproduces the hardcoded heat/cool/enable truth table',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_fbd_hvac');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();

    void setInputs(bool occ, bool win, double temp, double sp) {
      writePath(p, 'Occupied', occ);
      writePath(p, 'Window_Open', win);
      writePath(p, 'Room_Temp', temp);
      writePath(p, 'Setpoint', sp);
    }

    // Occupied, window shut, cold -> enable + heat, not cool.
    setInputs(true, false, 18.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isTrue);
    expect(_b(p, 'Fan_Cmd'), isTrue);
    expect(_b(p, 'Heat_Cmd'), isTrue); // 18 < 21-1
    expect(_b(p, 'Cool_Cmd'), isFalse);

    // Occupied, window shut, hot -> cool, not heat.
    setInputs(true, false, 24.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Cool_Cmd'), isTrue); // 24 > 21+1
    expect(_b(p, 'Heat_Cmd'), isFalse);

    // Window open -> everything disabled regardless of temp.
    setInputs(true, true, 18.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isFalse);
    expect(_b(p, 'Fan_Cmd'), isFalse);
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);

    // Unoccupied -> disabled.
    setInputs(false, false, 18.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isFalse);
    expect(_b(p, 'Heat_Cmd'), isFalse);

    // In-band temperature -> enabled, neither heat nor cool.
    setInputs(true, false, 21.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isTrue);
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
  });

  test(
      'water Quality_OK tracks turb<SP && level>10; FBD leaves Flow_PV to sim',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();

    // Good quality: low turbidity, healthy level.
    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Quality_OK'), isTrue);

    // Bad turbidity -> not OK.
    writePath(p, 'Turbidity_PV', 20.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Quality_OK'), isFalse);

    // Turbidity fine but level too low -> not OK.
    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 5.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Quality_OK'), isFalse);

    // Flow_PV is driven by the sim rules, not the FBD: with the pump stopped
    // (no Start_PB, so PumpControl_LD never energizes Pump_Motor), sim5 ramps
    // it toward 0 from its 0.0 default and the FBD never writes it (the water
    // FBD diagram only has a Turbidity/Level -> Quality_OK chain).
    expect(_b(p, 'Pump_Motor'), isFalse);
    expect((readPath(p, 'Flow_PV') as num).toDouble(), lessThan(1.0));
  });
}
