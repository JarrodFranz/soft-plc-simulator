import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// End-to-end: one scan tick exactly as the workspace shell runs it —
// simulated inputs first, then ladder execution.
void _scan(PlcProject p, SimRuntime simRt, LdExecRuntime ldRt, [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, simRt);
  executeLdPrograms(p, dtMs, ldRt);
}

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('motor project: ladder drives seal-in start/stop end-to-end', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_motor');
    final simRt = SimRuntime();
    final ldRt = LdExecRuntime();

    _scan(p, simRt, ldRt);
    expect(_b(p, 'Motor_Run'), isFalse);

    writePath(p, 'Start_PB', true);
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Motor_Latch'), isTrue);
    expect(_b(p, 'Motor_Run'), isTrue);

    writePath(p, 'Start_PB', false); // seal-in must hold
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Motor_Run'), isTrue);

    writePath(p, 'Stop_PB', true); // NC stop drops the latch and the motor
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Motor_Latch'), isFalse);
    expect(_b(p, 'Motor_Run'), isFalse);
  });

  test('conveyor project: JamTimer trips Belt_Jammed after 5s without parts', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_ld_conveyor');
    // Suppress the photo-eye pulse so no parts are ever "seen" (jam scenario).
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final simRt = SimRuntime();
    final ldRt = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Belt_Motor'), isTrue);
    writePath(p, 'Start_PB', false); // Belt_Latch seal-in keeps it running

    // The start scan already accumulated 500ms; 8 more keep ACC below the
    // 5000ms preset, so the belt keeps running.
    for (int i = 0; i < 8; i++) {
      _scan(p, simRt, ldRt);
      expect(_b(p, 'Belt_Motor'), isTrue,
          reason: 'belt should run until the jam trips (scan $i)');
    }
    expect((readPath(p, 'JamTimer.ACC') as num).toInt(), equals(4500));

    _scan(p, simRt, ldRt); // ACC hits 5000: DN fires and rung 4 raises the alarm
    expect(_b(p, 'JamTimer.DN'), isTrue);
    expect(_b(p, 'Belt_Jammed'), isTrue);
    _scan(p, simRt, ldRt); // next scan, rung 0's jam interlock opens
    expect(_b(p, 'Belt_Motor'), isFalse);

    _scan(p, simRt, ldRt);
    expect(_b(p, 'Belt_Jammed'), isTrue, reason: 'jam alarm latches until a part is seen');
  });

  test('conveyor: belt keeps running through part passages (sim rules ON)', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_ld_conveyor');
    final simRt = SimRuntime();
    final ldRt = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, simRt, ldRt);
    writePath(p, 'Start_PB', false); // seal-in takes over

    bool sawPart = false;
    for (int i = 0; i < 30; i++) {
      _scan(p, simRt, ldRt);
      if (_b(p, 'Photo_Eye')) {
        sawPart = true;
      }
      expect(_b(p, 'Belt_Motor'), isTrue,
          reason: 'belt must survive normal part passage (scan $i)');
      expect(_b(p, 'Belt_Jammed'), isFalse,
          reason: 'no jam while parts keep arriving (scan $i)');
    }
    expect(sawPart, isTrue); // the photo eye genuinely pulsed during the run
  });

  test('water project: ladder runs the pump and doses on bad quality', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final simRt = SimRuntime();
    final ldRt = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Pump_Motor'), isTrue);

    // Quality bad (Quality_OK false by default until supervisor sets it):
    // rung 2 = Pump_Motor AND NOT Quality_OK -> Treat_Dosing.
    writePath(p, 'Quality_OK', false);
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Treat_Dosing'), isTrue);

    writePath(p, 'Quality_OK', true);
    _scan(p, simRt, ldRt);
    expect(_b(p, 'Treat_Dosing'), isFalse);
  });
}
