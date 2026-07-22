import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// One scan tick, exactly as the workspace shell's `_executeScan` runs it up
// to (and including) FBD: sim -> LD -> FBD. SFC/ST are not relevant to either
// diagram under test here.
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
      'water Quality_OK (computed by WaterQuality_FBD) tracks turb<SP && '
      'level>10; FBD leaves Flow_PV to sim', () {
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

  test(
      'WaterQuality_FBD is split across 2 networks: network 0 computes the '
      'threshold tags, network 1 ANDs them into Quality_OK the same scan',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final prog =
        p.programs.firstWhere((x) => x.name == 'WaterQuality_FBD');

    // Structural proof: 2 networks, and blocks are actually split across
    // both (not all parked on network 0 with an unused second header).
    expect(prog.fbdNetworks.length, 2);
    final netsInUse = prog.fbdBlocks.map((b) => b.network).toSet();
    expect(netsInUse, {0, 1});

    // No wire crosses a network boundary — cross-network data must go via
    // tags (TAG_OUTPUT in one network, TAG_INPUT in another).
    final byId = {for (final b in prog.fbdBlocks) b.id: b};
    for (final w in prog.fbdWires) {
      final from = byId[w.fromBlockId];
      final to = byId[w.toBlockId];
      expect(from, isNotNull);
      expect(to, isNotNull);
      expect(from!.network, to!.network,
          reason: 'wire ${w.fromBlockId}->${w.toBlockId} must stay within one network');
    }

    // Behavioral proof: same-scan cross-network propagation via the
    // Turbidity_Below_SP / Level_Above_Min handoff tags reproduces the exact
    // truth table as the single-network diagram did.
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();

    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Turbidity_Below_SP'), isTrue);
    expect(_b(p, 'Level_Above_Min'), isTrue);
    expect(_b(p, 'Quality_OK'), isTrue);

    // Bad turbidity: network 0's result tag flips false, network 1 (same
    // scan) reads that fresh value and Quality_OK follows immediately.
    writePath(p, 'Turbidity_PV', 20.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Turbidity_Below_SP'), isFalse);
    expect(_b(p, 'Quality_OK'), isFalse);
  });

  test('tank TankLevel_FBD reproduces the retired hardcoded fill/drain/alarm',
      () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_tank');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();

    void setInputs(bool auto, double pv, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Level_PV', pv);
      writePath(p, 'Level_SP', sp);
    }

    // Auto, well below setpoint band -> fill, not drain.
    setInputs(true, 40.0, 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Fill_Valve'), isTrue); // 40 < 50-5
    expect(_b(p, 'Drain_Valve'), isFalse);
    expect(_b(p, 'High_Alarm'), isFalse);

    // Auto, well above setpoint band -> drain, not fill.
    setInputs(true, 60.0, 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Drain_Valve'), isTrue); // 60 > 50+5
    expect(_b(p, 'Fill_Valve'), isFalse);

    // Auto, inside the deadband -> neither.
    setInputs(true, 50.0, 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Fill_Valve'), isFalse);
    expect(_b(p, 'Drain_Valve'), isFalse);

    // Manual (Auto off) -> neither, regardless of level.
    setInputs(false, 40.0, 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Fill_Valve'), isFalse);
    expect(_b(p, 'Drain_Valve'), isFalse);

    // High alarm is unconditional on level > 85 (even in manual).
    setInputs(false, 90.0, 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'High_Alarm'), isTrue);
    setInputs(true, 80.0, 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'High_Alarm'), isFalse);
  });
}
