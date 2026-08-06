import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/st_reactor_control.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();
int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

void main() {
  test('the deadband controller heats, cools, reports ready and alarms', () {
    final p = stReactorControlProject();
    final st = StRuntime();
    void set(bool auto, double temp, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Temp_PV', temp);
      writePath(p, 'Temp_SP', sp);
    }

    set(true, 40.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Heat_Cmd'), isTrue);
    expect(_b(p, 'Reactor_Ready'), isFalse);

    set(true, 60.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Cool_Cmd'), isTrue);

    set(true, 50.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
    expect(_b(p, 'Reactor_Ready'), isTrue);

    set(false, 40.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Heat_Cmd'), isFalse);

    set(true, 96.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Alarm_High'), isTrue);

    set(true, 4.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Alarm_Low'), isTrue);
  });

  test('the INT16 array supplies the setpoint on recipe select', () {
    final p = stReactorControlProject();
    final st = StRuntime();
    final recipe = p.tags.firstWhere((t) => t.name == 'Recipe_Setpoints');
    expect(recipe.dataType, 'INT16');
    expect(recipe.arrayLength, 8);

    writePath(p, 'Recipe_Setpoints[0]', 65);
    writePath(p, 'Recipe_Select', false);
    writePath(p, 'Temp_SP', 75.0);
    executeStPrograms(p, 500, st);
    expect(_d(p, 'Temp_SP'), 75.0, reason: 'recipe select is off');

    writePath(p, 'Recipe_Select', true);
    executeStPrograms(p, 500, st);
    expect(_d(p, 'Temp_SP'), 65.0, reason: 'Recipe_Setpoints[0] drives the setpoint');
  });

  test('the DUT members mirror the commands and count heat cycles', () {
    final p = stReactorControlProject();
    final st = StRuntime();
    writePath(p, 'Auto_Mode', true);

    writePath(p, 'Temp_PV', 40.0);
    writePath(p, 'Temp_SP', 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Reactor_Status.Heating'), isTrue);
    expect(_b(p, 'Reactor_Status.Cooling'), isFalse);
    expect(_i(p, 'Reactor_Status.Cycles'), 1);

    executeStPrograms(p, 500, st); // still heating, no new rising edge
    expect(_i(p, 'Reactor_Status.Cycles'), 1);

    writePath(p, 'Temp_PV', 60.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Reactor_Status.Heating'), isFalse);
    expect(_b(p, 'Reactor_Status.Cooling'), isTrue);

    writePath(p, 'Temp_PV', 40.0);
    executeStPrograms(p, 500, st);
    expect(_i(p, 'Reactor_Status.Cycles'), 2, reason: 'a second heat start counted');
  });

  test('the Hysteresis FB sets above High, HOLDS through the deadband and '
      'resets below Low', () {
    final p = stReactorControlProject();
    final rt = FbdRuntime();
    void runWith(double temp) {
      writePath(p, 'Temp_PV', temp);
      executeFbdPrograms(p, 500, rt, only: {'ReactorAlarm_FBD'});
    }

    runWith(20.0);
    expect(_b(p, 'Alarm_Latched'), isFalse);
    runWith(65.0);
    expect(_b(p, 'Alarm_Latched'), isTrue);
    runWith(50.0);
    expect(_b(p, 'Alarm_Latched'), isTrue, reason: 'Q holds inside the 40–60 deadband');
    runWith(35.0);
    expect(_b(p, 'Alarm_Latched'), isFalse);
    runWith(50.0);
    expect(_b(p, 'Alarm_Latched'), isFalse, reason: 'the deadband is symmetric');
  });

  test('closed loop: the thermal plant reaches and holds the setpoint under '
      'Auto, and decays toward ambient with control off', () {
    final p = stReactorControlProject();
    final sim = SimRuntime();
    final st = StRuntime();
    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeStPrograms(p, 500, st);
    }

    final ambient = _d(p, 'Temp_Ambient');
    final sp = _d(p, 'Temp_SP');
    expect(sp, greaterThan(ambient));
    writePath(p, 'Auto_Mode', true);

    for (var i = 0; i < 400; i++) {
      scan();
    }
    expect((_d(p, 'Temp_PV') - sp).abs(), lessThanOrEqualTo(5.0));
    expect(_b(p, 'Reactor_Ready'), isTrue);

    writePath(p, 'Auto_Mode', false);
    scan();
    final handoff = _d(p, 'Temp_PV');
    for (var i = 0; i < 200; i++) {
      scan();
    }
    expect(_d(p, 'Temp_PV'), lessThan(handoff),
        reason: 'ambient pull alone must carry the reactor back down');
  });
}
