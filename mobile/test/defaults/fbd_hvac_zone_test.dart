import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/fbd_hvac_zone.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();
int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

void main() {
  late PlcProject p;
  late FbdRuntime rt;

  setUp(() {
    p = fbdHvacZoneProject();
    for (final r in p.simRules) {
      r.enabled = false; // hand-drive the inputs; no plant drift
    }
    rt = FbdRuntime();
  });

  void scan([int dtMs = 500]) {
    applySimRules(p, p.simRules, dtMs, SimRuntime());
    executeFbdPrograms(p, dtMs, rt);
  }

  test('the program has seven networks', () {
    final prog = p.programs.firstWhere((x) => x.name == 'HvacZone_FBD');
    expect(prog.fbdNetworks.length, 7);
  });

  test('occupancy / override / window enable truth table (NOT, AND, OR)', () {
    void set(bool occ, bool ovr, bool win) {
      writePath(p, 'Occupied', occ);
      writePath(p, 'Override_On', ovr);
      writePath(p, 'Window_Open', win);
    }

    set(true, false, false);
    scan();
    expect(_b(p, 'Hvac_Active'), isTrue);
    expect(_b(p, 'Fan_Cmd'), isTrue);

    set(false, false, false);
    scan();
    expect(_b(p, 'Hvac_Active'), isFalse);

    set(false, true, false); // override alone enables (the OR)
    scan();
    expect(_b(p, 'Hvac_Active'), isTrue);

    set(true, true, true); // an open window vetoes everything (the NOT + AND)
    scan();
    expect(_b(p, 'Hvac_Active'), isFalse);
    expect(_b(p, 'Fan_Cmd'), isFalse);
  });

  test('heat/cool deadband around Setpoint (SUB/ADD/LT/GT/AND)', () {
    void set(double temp, double sp) {
      writePath(p, 'Occupied', true);
      writePath(p, 'Window_Open', false);
      writePath(p, 'Room_Temp', temp);
      writePath(p, 'Setpoint', sp);
    }

    set(18.0, 21.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isTrue);
    expect(_b(p, 'Cool_Cmd'), isFalse);

    set(24.0, 21.0);
    scan();
    expect(_b(p, 'Cool_Cmd'), isTrue);
    expect(_b(p, 'Heat_Cmd'), isFalse);

    set(21.0, 21.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
  });

  test(
      'SEL picks comfort vs setback, and the DIV/ADD/SUB/LIMIT chain clamps '
      'the effective setpoint; MUL computes the span', () {
    writePath(p, 'Level_PV', 50.0); // Level_PV/50 == 1.0 reset trim
    writePath(p, 'Occupied', true);
    scan();
    // SEL -> Comfort_SP (22.0); + (50/50 = 1.0) - 1.0 = 22.0; LIMIT 16..28.
    expect(_d(p, 'Effective_SP'), closeTo(22.0, 1e-9));

    writePath(p, 'Occupied', false);
    scan();
    // SEL -> Setback_SP (18.0); + 1.0 - 1.0 = 18.0.
    expect(_d(p, 'Effective_SP'), closeTo(18.0, 1e-9));

    // A higher level pushes the reset schedule up: 22 + (100/50) - 1 = 23.
    writePath(p, 'Occupied', true);
    writePath(p, 'Level_PV', 100.0);
    scan();
    expect(_d(p, 'Effective_SP'), closeTo(23.0, 1e-9));

    // (Comfort_SP - Setback_SP) * 2.0 = (22 - 18) * 2 = 8.
    expect(_d(p, 'Sp_Span'), closeTo(8.0, 1e-9));
  });

  test('the six comparators agree with direct arithmetic on the same inputs',
      () {
    writePath(p, 'Occupied', true);
    writePath(p, 'Level_PV', 50.0); // Effective_SP == Comfort_SP == 22.0
    writePath(p, 'Setpoint', 22.0);

    for (final t in <double>[18.0, 22.0, 26.0]) {
      writePath(p, 'Room_Temp', t);
      scan();
      final esp = _d(p, 'Effective_SP');
      expect(_b(p, 'Temp_GE'), t >= esp, reason: 'GE at $t vs $esp');
      expect(_b(p, 'Temp_LE'), t <= esp, reason: 'LE at $t vs $esp');
      expect(_b(p, 'Temp_EQ'), t == esp, reason: 'EQ at $t vs $esp');
      expect(_b(p, 'Temp_NE'), t != esp, reason: 'NE at $t vs $esp');
    }
  });

  test(
      'TON staging delay, TOF fan run-on, TP purge one-shot, R_TRIG/F_TRIG '
      'each fire for exactly one scan', () {
    writePath(p, 'Occupied', true);
    writePath(p, 'Window_Open', false);
    writePath(p, 'Setpoint', 21.0);
    writePath(p, 'Room_Temp', 10.0); // hard call for heat

    // Networks execute in ASCENDING INDEX ORDER within a single scan, so net 2
    // writes Heat_Cmd and net 3's R_TRIG/TON/TP read it back on that same scan.
    scan();
    expect(_b(p, 'Heat_Cmd'), isTrue);
    expect(_b(p, 'Heat_Start_Edge'), isTrue, reason: 'R_TRIG on the heat call');
    expect(_b(p, 'Purge_Pulse'), isTrue,
        reason: 'TP started by the R_TRIG pulse (ET 500 < 2000)');
    expect(_b(p, 'Heat_Stage2'), isFalse,
        reason: 'TON is at 500 ms of its 5000 ms preset');

    scan();
    expect(_b(p, 'Heat_Start_Edge'), isFalse,
        reason: 'R_TRIG is one scan wide');

    // 5000 ms TON at 500 ms/scan.
    for (var i = 0; i < 10; i++) {
      scan();
    }
    expect(_b(p, 'Heat_Stage2'), isTrue);
    expect(_b(p, 'Purge_Pulse'), isFalse, reason: 'the 2000 ms TP has expired');

    // Drop the heat call: F_TRIG fires once (same scan, net 3 after net 2),
    // and the fan TOF holds for 10 s.
    writePath(p, 'Room_Temp', 21.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Heat_Stop_Edge'), isTrue, reason: 'F_TRIG on the heat drop');
    scan();
    expect(_b(p, 'Heat_Stop_Edge'), isFalse);

    writePath(p, 'Occupied', false); // Fan_Cmd drops; TOF keeps Fan_RunOn true
    scan();
    expect(_b(p, 'Fan_Cmd'), isFalse);
    expect(_b(p, 'Fan_RunOn'), isTrue);
    for (var i = 0; i < 22; i++) {
      scan();
    }
    expect(_b(p, 'Fan_RunOn'), isFalse, reason: 'the 10 s run-on expired');
  });

  test(
      'CTU counts heat starts, CTD counts filter life down, CTUD tracks the '
      'occupancy net', () {
    writePath(p, 'Occupied', true);
    writePath(p, 'Window_Open', false);
    writePath(p, 'Setpoint', 21.0);

    // Lead-in scan with the room ABOVE setpoint: no heat call, so the CTD's
    // one-shot LD preload lands on a scan with no CD edge. `fbd_exec`'s CTD
    // takes the LD branch OR the CD branch, never both in one scan — without
    // this the first heat start would be swallowed by the preload.
    writePath(p, 'Room_Temp', 30.0);
    scan();

    for (var cycle = 0; cycle < 3; cycle++) {
      writePath(p, 'Room_Temp', 10.0);
      scan();
      scan();
      writePath(p, 'Room_Temp', 30.0);
      scan();
      scan();
    }
    expect(_i(p, 'Heat_Starts'), 3, reason: 'one CTU count per heat start');
    expect(_i(p, 'Filter_Life'), 97,
        reason:
            'the first-scan R_TRIG preloaded CV to the 100 preset, then the '
            'same three heat-start edges counted it down');
    expect(_b(p, 'Filter_Due'), isFalse,
        reason: 'without the preload the CTD would sit at CV 0 and Q would be '
            'true from scan 1 — this is what makes the countdown falsifiable');

    // CTUD: occupancy falls then rises — one down-count and one up-count cancel.
    final before = _i(p, 'Occupancy_Net');
    writePath(p, 'Occupied', false);
    scan();
    scan();
    writePath(p, 'Occupied', true);
    scan();
    scan();
    expect(_i(p, 'Occupancy_Net'), before);

    writePath(p, 'Ctu_Reset', true);
    scan();
    expect(_i(p, 'Heat_Starts'), 0, reason: 'the CTU reset pin works');
  });

  test(
      'the absorbed tank network fills below SP-5, drains above SP+5 and '
      'alarms above the high limit', () {
    void set(bool auto, double pv, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Level_PV', pv);
      writePath(p, 'Level_SP', sp);
    }

    set(true, 40.0, 50.0);
    scan();
    expect(_b(p, 'Fill_Valve'), isTrue);
    expect(_b(p, 'Drain_Valve'), isFalse);
    expect(_b(p, 'High_Alarm'), isFalse);

    set(true, 60.0, 50.0);
    scan();
    expect(_b(p, 'Drain_Valve'), isTrue);
    expect(_b(p, 'Fill_Valve'), isFalse);

    set(true, 50.0, 50.0);
    scan();
    expect(_b(p, 'Fill_Valve'), isFalse);
    expect(_b(p, 'Drain_Valve'), isFalse);

    set(false, 40.0, 50.0);
    scan();
    expect(_b(p, 'Fill_Valve'), isFalse);

    set(false, 90.0, 50.0);
    scan();
    expect(_b(p, 'High_Alarm'), isTrue);
  });

  test('the ST-bodied SetpointShift FB drops the setpoint when unoccupied', () {
    final fb = p.fbDefinitions.firstWhere((f) => f.name == 'SetpointShift');
    expect(fb.stSource, isNotEmpty);
    expect(fb.ladderRungs, isEmpty,
        reason: 'this one is the ST-bodied showcase');

    writePath(p, 'Occupied', true);
    scan();
    expect(_d(p, 'Shifted_SP'), closeTo(22.0, 1e-9));

    writePath(p, 'Occupied', false);
    scan();
    expect(_d(p, 'Shifted_SP'), closeTo(18.0, 1e-9),
        reason: 'Base 22.0 - Setback 4.0');
  });

  test('with sim rules ON the room converges toward the setpoint', () {
    final live = fbdHvacZoneProject();
    final liveRt = FbdRuntime();
    final sim = SimRuntime();
    writePath(live, 'Occupied', true);
    writePath(live, 'Window_Open', false);
    writePath(live, 'Setpoint', 22.0);
    writePath(live, 'Room_Temp', 15.0);
    for (var i = 0; i < 400; i++) {
      applySimRules(live, live.simRules, 500, sim);
      executeFbdPrograms(live, 500, liveRt);
    }
    expect((readPath(live, 'Room_Temp') as num).toDouble(), closeTo(22.0, 2.0),
        reason: 'the on/off deadband controller must reach the comfort band');
  });
}
