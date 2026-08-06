import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/sfc_batch_production.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

void main() {
  test('the merged chart parses to one parallel region (2 branches) and one '
      'alternative region (2 arms)', () {
    final p = sfcBatchProductionProject();
    final prog = p.programs.firstWhere((x) => x.language == 'SequentialFunctionChart');
    final region = parseSfc(prog.sfcSteps, prog.sfcTransitions);
    final pars = <ParRegion>[];
    final alts = <AltRegion>[];
    void walk(SfcRegion r) {
      if (r is ParRegion) {
        pars.add(r);
        for (final b in r.branches) {
          for (final x in b) {
            walk(x);
          }
        }
      } else if (r is AltRegion) {
        alts.add(r);
        for (final b in r.branches) {
          for (final x in b) {
            walk(x);
          }
        }
      } else if (r is SeqRegion) {
        for (final x in r.items) {
          walk(x);
        }
      }
    }

    walk(region);
    expect(pars.length, 1);
    expect(pars.first.branches.length, 2);
    expect(alts.length, 1);
    expect(alts.first.branches.length, 2);
  });

  test('two full cycles: Filled_Count increments once per container and the '
      'STEP_T dwells are honoured', () {
    final p = sfcBatchProductionProject();
    final sim = SimRuntime();
    final rt = SfcRuntime();
    void tick([int ms = 500]) {
      applySimRules(p, p.simRules, ms, sim);
      executeSfcPrograms(p, ms, rt);
    }

    writePath(p, 'Quality_OK', true);
    writePath(p, 'Container_Present', true);
    tick();
    expect(_i(p, 'Sfc_Step'), 0);

    writePath(p, 'Start_Cmd', true);

    var capScans = 0;
    var ejectScans = 0;
    for (var i = 0; i < 300 && _i(p, 'Filled_Count') < 2; i++) {
      tick();
      if (_i(p, 'Sfc_Step') == 3) {
        capScans++;
      }
      if (_i(p, 'Sfc_Step') == 4) {
        ejectScans++;
      }
    }

    expect(_i(p, 'Filled_Count'), 2, reason: 'two containers completed');
    expect(capScans, greaterThanOrEqualTo(2 * 6),
        reason: 'the 3000 ms cap dwell is at least 6 scans of 500 ms, twice');
    expect(ejectScans, greaterThanOrEqualTo(2 * 4),
        reason: 'the 2000 ms eject dwell is at least 4 scans of 500 ms, twice');
    expect(_i(p, 'Batch_Count'), greaterThanOrEqualTo(1),
        reason: 'Quality_OK routes each batch to DISPATCH');
    expect(_i(p, 'Reject_Count'), 0);
  });

  test('the fork activates BOTH branches and the join waits for both', () {
    final p = sfcBatchProductionProject();
    final prog = p.programs.firstWhere((x) => x.language == 'SequentialFunctionChart');
    final sim = SimRuntime();
    final rt = SfcRuntime();
    writePath(p, 'Quality_OK', true);
    writePath(p, 'Container_Present', true);
    writePath(p, 'Start_Cmd', true);

    var maxActive = 0;
    var sawJoinWait = false;
    for (var i = 0; i < 300; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeSfcPrograms(p, 500, rt);
      final active = rt.active[prog.name] ?? <String>{};
      if (active.length > maxActive) {
        maxActive = active.length;
      }
      // One branch parked on its *_DONE step while the other is still working:
      // the join is genuinely holding for both.
      if (active.contains('b_charge_done') && active.contains('b_heating')) {
        sawJoinWait = true;
      }
    }
    expect(maxActive, greaterThanOrEqualTo(2),
        reason: 'the parallel fork must run two steps simultaneously');
    expect(sawJoinWait, isTrue,
        reason: 'the join must hold the finished branch until the other completes');
  });

  test('Quality_OK false routes the batch down the REJECT arm instead', () {
    final p = sfcBatchProductionProject();
    final sim = SimRuntime();
    final rt = SfcRuntime();
    writePath(p, 'Quality_OK', false);
    writePath(p, 'Container_Present', true);
    writePath(p, 'Start_Cmd', true);
    for (var i = 0; i < 300; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeSfcPrograms(p, 500, rt);
    }
    expect(_i(p, 'Reject_Count'), greaterThanOrEqualTo(1));
    expect(_i(p, 'Batch_Count'), 0);
  });

  test('the count steps are true one-shots', () {
    final p = sfcBatchProductionProject();
    final sim = SimRuntime();
    final rt = SfcRuntime();
    void tick() {
      applySimRules(p, p.simRules, 500, sim);
      executeSfcPrograms(p, 500, rt);
    }

    writePath(p, 'Quality_OK', true);
    writePath(p, 'Container_Present', true);
    writePath(p, 'Start_Cmd', true);
    var guard = 0;
    while (_i(p, 'Batch_Count') < 1 && guard < 500) {
      tick();
      guard++;
    }
    expect(_i(p, 'Batch_Count'), 1);

    writePath(p, 'Start_Cmd', false); // no new cycle may start
    for (var i = 0; i < 60; i++) {
      tick();
    }
    expect(_i(p, 'Batch_Count'), 1,
        reason: 'the count step fires once per batch, not once per scan');
  });
}
