import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('reactor ST reproduces the retired hardcoded deadband + alarms', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_st_reactor');
    final sim = SimRuntime();
    final st = StRuntime();

    // One scan tick, exactly as the workspace shell's `_executeScan` runs it
    // for this project: sim -> ST (proj_st_reactor has no LD/FBD/SFC
    // programs, so those stages are no-ops and are omitted here).
    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeStPrograms(p, 500, st);
    }

    void setInputs(bool auto, double temp, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Temp_PV', temp);
      writePath(p, 'Temp_SP', sp);
    }

    // Auto, cold -> heat, ready false (outside deadband).
    setInputs(true, 40.0, 50.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isTrue); // 40 < 50-2
    expect(_b(p, 'Cool_Cmd'), isFalse);
    expect(_b(p, 'Reactor_Ready'), isFalse);

    // Auto, hot -> cool.
    setInputs(true, 60.0, 50.0);
    scan();
    expect(_b(p, 'Cool_Cmd'), isTrue); // 60 > 50+2
    expect(_b(p, 'Heat_Cmd'), isFalse);

    // Auto, in-band -> neither, ready true.
    setInputs(true, 50.0, 50.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
    expect(_b(p, 'Reactor_Ready'), isTrue);

    // Manual -> commands off regardless of temp.
    setInputs(false, 40.0, 50.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);

    // Over-temp alarm and under-temp alarm.
    setInputs(true, 96.0, 50.0);
    scan();
    expect(_b(p, 'Alarm_High'), isTrue); // 96 > 95
    expect(_b(p, 'Reactor_Ready'), isFalse);
    setInputs(true, 4.0, 50.0);
    scan();
    expect(_b(p, 'Alarm_Low'), isTrue); // 4 < 5
  });

  test('water Safety_ST drives Alarm_Active/System_Ready; leaves Quality_OK to '
      'FBD and Treat_Dosing to LD', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();
    final st = StRuntime();

    // One scan tick, exactly as the workspace shell's `_executeScan` runs it:
    // sim -> LD -> FBD -> ST (SFC is irrelevant to the tags under test here).
    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeLdPrograms(p, 500, ld);
      executeFbdPrograms(p, 500, fbd);
      executeStPrograms(p, 500, st);
    }

    // Start the pump (LD seal-in), healthy water.
    writePath(p, 'Start_PB', true);
    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 50.0);
    scan();
    writePath(p, 'Start_PB', false);
    scan();
    expect(_b(p, 'Pump_Motor'), isTrue);
    expect(_b(p, 'Quality_OK'), isTrue);   // FBD still owns this
    expect(_b(p, 'Alarm_Active'), isFalse); // EStop healthy, level ok, turb ok
    expect(_b(p, 'System_Ready'), isTrue);  // pump && quality && !alarm

    // Low level trips Alarm_Active and drops System_Ready.
    writePath(p, 'Level_PV', 3.0);
    scan();
    expect(_b(p, 'Alarm_Active'), isTrue); // level < 5
    expect(_b(p, 'System_Ready'), isFalse);

    // Treat_Dosing remains LD-driven (rung 2: dose while running with bad
    // quality). Bad turbidity, pump running -> LD sets Treat_Dosing; ST must
    // not touch it. Two scans: rung 0's Alarm_Active NC interlock still reads
    // the prior scan's tripped alarm on the first scan (Alarm_Active is
    // written by ST, which runs after LD), so the pump needs one more scan to
    // re-energize before Treat_Dosing can be observed with the pump running.
    writePath(p, 'Level_PV', 50.0);
    writePath(p, 'Turbidity_PV', 20.0);
    scan();
    scan();
    expect(_b(p, 'Pump_Motor'), isTrue);
    expect(_b(p, 'Quality_OK'), isFalse);
    expect(_b(p, 'Treat_Dosing'), isTrue); // owned by PumpControl_LD rung 2
  });
}
