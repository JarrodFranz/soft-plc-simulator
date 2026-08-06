import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/flagship_production_line.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();
int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

/// The full scan tick in the shell's order: sim -> LD -> FBD -> SFC -> ST.
class _Rig {
  final PlcProject p;
  final sim = SimRuntime();
  final ld = LdExecRuntime();
  final fbd = FbdRuntime();
  final sfc = SfcRuntime();
  final st = StRuntime();
  _Rig(this.p);

  void scan([int dtMs = 100]) {
    applySimRules(p, p.simRules, dtMs, sim);
    executeLdPrograms(p, dtMs, ld);
    executeFbdPrograms(p, dtMs, fbd, ldRt: ld);
    executeSfcPrograms(p, dtMs, sfc);
    executeStPrograms(p, dtMs, st);
  }
}

void main() {
  test(
      'exactly three tasks — Startup, Continuous and Periodic — and every '
      'program is referenced by at least one of them', () {
    final p = flagshipProductionLineProject();
    expect(p.tasks.map((t) => t.type).toSet(),
        {'Startup', 'Continuous', 'Periodic'});
    expect(p.tasks.length, 3);
    final referenced = <String>{for (final t in p.tasks) ...t.programNames};
    for (final prog in p.programs) {
      expect(referenced, contains(prog.name), reason: '${prog.name} has no task');
    }
    expect(p.programs.map((x) => x.language).toSet(), {
      'LadderLogic',
      'FunctionBlockDiagram',
      'SequentialFunctionChart',
      'StructuredText',
    });
  });

  test('all four programs execute in the same scan pipeline', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    writePath(p, 'Line_Start', true);
    writePath(p, 'Batch_Start', true);
    rig.scan();
    rig.scan();

    // Every assertion below moves a tag OFF its declared initial value, so a
    // program that never ran would fail it.
    expect(_b(p, 'Line_Run'), isTrue, reason: 'Infeed_LD ran (initial false)');
    expect(_b(p, 'Conv1_Motor'), isTrue, reason: 'Infeed_LD ran (initial false)');
    expect(_d(p, 'Blend_mA'), greaterThan(4.0),
        reason: 'Blend_FBD ran — the Scale FB mapped the level off its 4.0 mA initial');
    expect(_d(p, 'Blend_mA'), lessThan(20.0));
    expect(_i(p, 'Batch_Step'), 1, reason: 'Batch_SFC ran and advanced IDLE -> CHARGE');
    expect(_b(p, 'Batch_Running'), isTrue);
    expect(_b(p, 'Alarm_Active'), isTrue,
        reason: 'Safety_ST ran — the guard interlock has not engaged yet '
            '(initial Alarm_Active is false)');
  });

  test('the Startup guard initialises the line exactly once', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    // Every tag checked here has exactly ONE writer (the startup block), so a
    // guard that never ran — or that ran every scan — fails.
    writePath(p, 'Batch_Count', 7);
    writePath(p, 'Part_Count', 42);
    writePath(p, 'Batch_Target', 99);
    writePath(p, 'System.FirstScan', true);
    rig.scan();
    expect(_i(p, 'Batch_Count'), 0, reason: 'the first-scan guard cleared the counters');
    expect(_i(p, 'Part_Count'), 0);
    expect(_i(p, 'Batch_Target'), 5, reason: 'the guard restored the planned batch count');

    writePath(p, 'System.FirstScan', false);
    writePath(p, 'Batch_Count', 3);
    writePath(p, 'Batch_Target', 99);
    rig.scan();
    expect(_i(p, 'Batch_Count'), 3, reason: 'the guard must not re-run after the first scan');
    expect(_i(p, 'Batch_Target'), 99, reason: 'the guard must not re-run after the first scan');
  });

  test(
      'the PID drives Blend_Level to Blend_SP against a constant draw and '
      'holds it with a non-saturated valve', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    final sp = _d(p, 'Blend_SP');
    expect(_d(p, 'Blend_Level'), lessThan(sp));

    var minCv = double.infinity;
    var maxCv = -double.infinity;
    for (var i = 0; i < 6000; i++) {
      rig.scan();
      final cv = _d(p, 'Blend_Valve');
      expect(cv, greaterThanOrEqualTo(0.0));
      expect(cv, lessThanOrEqualTo(100.0));
      if (i > 3000) {
        minCv = cv < minCv ? cv : minCv;
        maxCv = cv > maxCv ? cv : maxCv;
      }
    }
    expect((_d(p, 'Blend_Level') - sp).abs(), lessThanOrEqualTo(5.0),
        reason: 'the loop must regulate to setpoint');
    expect(minCv, greaterThan(1.0), reason: 'the valve must not sit shut');
    expect(maxCv, lessThan(99.0), reason: 'the valve must not sit wide open');
  });

  test('the deadTime rule makes Line_Transfer lag Blend_Level', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    // 4.0 s of dead time at 100 ms/scan == 40 scans of delay.
    for (var i = 0; i < 20; i++) {
      rig.scan();
    }
    final levelEarly = _d(p, 'Blend_Level');
    final transferEarly = _d(p, 'Line_Transfer');
    expect(levelEarly, greaterThan(transferEarly + 0.5),
        reason: 'the transfer line has not yet seen the level rise');

    for (var i = 0; i < 120; i++) {
      rig.scan();
    }
    expect(_d(p, 'Line_Transfer'), greaterThan(transferEarly + 0.5),
        reason: 'after the dead time the transfer line follows the level');
  });

  test(
      'setWhileCondition mirrors the compressor and delayedSet locks the guard '
      'only after 2 s', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);

    writePath(p, 'Guard_Closed', false);
    writePath(p, 'Compressor_On', false);
    rig.scan();
    expect(_b(p, 'Air_Pressure_OK'), isFalse);
    expect(_b(p, 'Guard_Locked'), isFalse);

    writePath(p, 'Compressor_On', true);
    rig.scan();
    expect(_b(p, 'Air_Pressure_OK'), isTrue, reason: 'setWhileCondition is immediate');

    writePath(p, 'Guard_Closed', true);
    for (var i = 0; i < 15; i++) {
      rig.scan();
      expect(_b(p, 'Guard_Locked'), isFalse, reason: 'still inside the 2 s delay (scan $i)');
    }
    for (var i = 0; i < 10; i++) {
      rig.scan();
    }
    expect(_b(p, 'Guard_Locked'), isTrue, reason: 'delayedSet fired after 2 s');

    writePath(p, 'Guard_Closed', false);
    rig.scan();
    expect(_b(p, 'Guard_Locked'), isFalse, reason: 'delayedSet drops immediately');
  });

  test('the batch SFC forks, joins and counts one batch per cycle', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    final prog = p.programs.firstWhere((x) => x.name == 'Batch_SFC');
    writePath(p, 'Batch_Start', true);

    var maxActive = 0;
    for (var i = 0; i < 2000 && _i(p, 'Batch_Count') < 1; i++) {
      rig.scan();
      final active = rig.sfc.active[prog.name] ?? <String>{};
      if (active.length > maxActive) {
        maxActive = active.length;
      }
    }
    expect(maxActive, greaterThanOrEqualTo(2), reason: 'the fork ran two branches at once');
    expect(_i(p, 'Batch_Count'), 1);
  });

  test(
      'BOTH custom-FB kinds execute: the ST-bodied Scale maps 0-100 % to '
      '4-20 mA and the ladder-bodied ZoneStarter holds per-instance state', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);

    final scale = p.fbDefinitions.firstWhere((f) => f.name == 'Scale');
    expect(scale.stSource, isNotEmpty);
    expect(scale.ladderRungs, isEmpty);
    final zone = p.fbDefinitions.firstWhere((f) => f.name == 'ZoneStarter');
    expect(zone.ladderRungs, isNotEmpty);
    expect(zone.stSource, isEmpty);

    // The sim stage runs BEFORE the FBD stage, so the constant-draw rule (fl1)
    // has already nudged Blend_Level down by the time the Scale FB reads it —
    // assert the linear map against the level the FB actually saw, not 50.0.
    writePath(p, 'Blend_Level', 50.0);
    rig.scan();
    expect(_d(p, 'Blend_mA'), closeTo(4.0 + _d(p, 'Blend_Level') * 0.16, 1e-9),
        reason: 'Out = (In - 0) * (20 - 4) / (100 - 0) + 4');

    // Ladder-bodied FB: Conv2_Request is level-driven, but the FB's own TON
    // start delay lives INSIDE the instance, so Out lags the request by 2 s.
    writePath(p, 'Line_Start', true);
    rig.scan();
    expect(_b(p, 'Conv2_Request'), isTrue);
    expect(_b(p, 'Zone2Start.Seal'), isTrue, reason: 'the FB sealed in');
    expect(_b(p, 'Conv2_Motor'), isFalse, reason: 'the instance TON has not expired');
    for (var i = 0; i < 25; i++) {
      rig.scan();
    }
    expect(_b(p, 'Conv2_Motor'), isTrue, reason: 'the instance TON expired after 2 s');
    expect(_i(p, 'Zone2Start.T.PRE'), 2000,
        reason: 'the timer state lives inside the instance struct, not in a global tag');
    expect(p.tags.any((t) => t.name == 'Seal'), isFalse);
  });

  test('the reserved System tag ships with the project and its members update', () {
    final p = flagshipProductionLineProject();
    expect(p.tags.any((t) => t.name == 'System'), isTrue,
        reason: 'the builder calls ensureSystemTag before generating protocol maps');
    updateSystemStatus(
      p,
      const SystemSnapshot(
        fault: false, faultTask: '', faultCode: 0, running: true, firstScan: false,
        scanCount: 1234, scanTimeMs: 2.5, maxScanTimeMs: 9.5, minScanTimeMs: 0.5,
        freeRun: false, uptimeMs: 60000, year: 2026, month: 8, day: 6, hour: 12,
        minute: 0, second: 0, dateTime: '2026-08-06T12:00:00',
      ),
    );
    expect(_i(p, 'System.ScanCount'), 1234);
    expect(_d(p, 'System.ScanTimeMs'), 2.5);
    expect(_i(p, 'System.UptimeMs'), 60000);
    expect(_b(p, 'System.Running'), isTrue);
  });

  test('every trend pen and every HMI binding resolves to a real tag', () {
    final p = flagshipProductionLineProject();
    expect(p.trends.length, 5);
    final penPaths = p.trends.map((t) => t.tagPath).toSet();
    for (final pen in p.trends) {
      expect(readPath(p, pen.tagPath), isNotNull, reason: 'pen ${pen.tagPath} is dangling');
    }
    expect(p.hmis.length, 3);
    var trendComponents = 0;
    var textInputs = 0;
    var systemBindings = 0;
    for (final screen in p.hmis) {
      for (final c in screen.components) {
        if (c.type == kTrendChartDisplay) {
          trendComponents++;
          expect(c.trendPens, isNotEmpty);
          for (final ref in c.trendPens) {
            expect(penPaths, contains(ref.penTagPath),
                reason: '${ref.penTagPath} has no matching project pen');
          }
          continue;
        }
        if (c.type == 'TextInputField') {
          textInputs++;
        }
        if (c.tagBinding.startsWith('System.')) {
          systemBindings++;
        }
        expect(c.tagBinding, isNotEmpty, reason: '${c.id} has no binding');
        expect(readPath(p, c.tagBinding), isNotNull, reason: '${c.id} binds a missing tag');
      }
    }
    expect(trendComponents, 2, reason: 'one analog chart and one BOOL step-lane chart');
    expect(textInputs, 2);
    expect(systemBindings, greaterThanOrEqualTo(6));
  });

  test(
      'the Modbus and OPC UA maps are pre-generated, enabled, and mark every '
      'System.* leaf ReadOnly', () {
    final p = flagshipProductionLineProject();
    final protocols = p.protocols;
    expect(protocols, isNotNull);
    final modbus = protocols!.modbus;
    final opcua = protocols.opcua;
    expect(modbus, isNotNull);
    expect(opcua, isNotNull);
    expect(modbus!.enabled, isTrue);
    expect(opcua!.enabled, isTrue);
    expect(modbus.map.entries, isNotEmpty);
    expect(opcua.map.nodes, isNotEmpty);
    expect(opcua.namespaceUri, 'urn:softplc:proj_flagship_line');

    final systemModbus = modbus.map.entries.where((e) => e.tag.startsWith('System.'));
    expect(systemModbus, isNotEmpty, reason: 'the System tag must reach the map');
    for (final e in systemModbus) {
      expect(e.access, 'ReadOnly', reason: '${e.tag} must not be externally writable');
    }
    final systemOpcua = opcua.map.nodes.where((n) => n.tag.startsWith('System.'));
    expect(systemOpcua, isNotEmpty);
    for (final n in systemOpcua) {
      expect(n.access, 'ReadOnly', reason: '${n.tag} must not be externally writable');
    }
  });
}
