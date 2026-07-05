import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

dynamic _v(PlcProject p, String path) => readPath(p, path);
bool _b(PlcProject p, String path) => _v(p, path) == true;
int _i(PlcProject p, String path) => (_v(p, path) as num).toInt();

void main() {
  test('Batch Counter: CTU counts Part_Sensor rising edges up to Batch_Size, '
      'fires Batch_Done, and self-resets one scan later via tag feedback', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_batch_counter');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();
    final sfc = SfcRuntime();
    final st = StRuntime();

    // Full scan tick, exactly as the workspace shell's `_executeScan` runs it:
    // sim -> LD -> FBD -> SFC -> ST.
    void scan() {
      applySimRules(p, p.simRules, p.scanPeriodMs, sim);
      executeLdPrograms(p, p.scanPeriodMs, ld);
      executeFbdPrograms(p, p.scanPeriodMs, fbd);
      executeSfcPrograms(p, p.scanPeriodMs, sfc);
      executeStPrograms(p, p.scanPeriodMs, st);
    }

    final batchSize = _i(p, 'Batch_Size');
    expect(batchSize, greaterThan(0));

    // Drive Part_Sensor with explicit true/false writes between scans rather
    // than relying purely on the sim pulse rule, so rising-edge timing is
    // exact and the "one increment per edge, not per scan" assertion is not
    // fiddly. Disable the project's own Part_Sensor pulse sim rule for this
    // test only, so it does not overwrite our explicit writes each scan; the
    // rule itself (and its pulse behavior) is exercised live during normal
    // RUN mode — see default_projects.dart.
    for (final r in p.simRules) {
      if (r.targetPath == 'Part_Sensor') {
        r.enabled = false;
      }
    }
    void setSensor(bool value) => writePath(p, 'Part_Sensor', value);

    setSensor(false);
    scan(); // settle initial state
    expect(_i(p, 'Count'), 0, reason: 'counter must start at 0');
    expect(_b(p, 'Batch_Done'), isFalse);

    // Drive Batch_Size (5) rising edges, holding each edge high for several
    // scans in a row. A LEVEL-triggered (non-edge) counter would increment
    // once per scan while held high, over-counting; the assertions below
    // require exactly one increment per edge regardless of how long the
    // sensor is held true. Reset takes priority over counting on the CTU
    // (per its IEC 61131-3 semantics — R wins even if CU is still held), so
    // once Batch_Done fires it feeds R the very next scan and clears CV even
    // while CU is still asserted — this is the intended one-scan-delayed
    // self-reset, not a bug, so the last edge's "hold" loop stops as soon as
    // the reset is observed instead of asserting Count stays at Batch_Size.
    for (var edge = 1; edge <= batchSize; edge++) {
      setSensor(true);
      scan();
      expect(_i(p, 'Count'), edge,
          reason: 'edge #$edge: Count must advance by exactly one on the rising edge');

      // Hold high for a couple more scans — must NOT over-count while held.
      // (On the final edge, the reset feedback fires here instead — handled
      // below.)
      final isFinalEdge = edge == batchSize;
      scan();
      if (isFinalEdge) {
        // Batch_Done went true the moment Count reached Batch_Size; the
        // feedback TAG_INPUT reads it this scan and drives R, resetting CV
        // to 0 immediately — proof the self-reset is live and not stuck.
        expect(_i(p, 'Count'), 0,
            reason: 'self-reset must fire the scan after Batch_Done goes true, even while '
                'Part_Sensor (CU) is still held — reset takes priority over counting');
        expect(_b(p, 'Batch_Done'), isFalse,
            reason: 'Batch_Done must drop back to false once Count is reset below Batch_Size '
                '(a broken counter would leave this stuck true forever)');
      } else {
        scan();
        expect(_i(p, 'Count'), edge,
            reason: 'holding Part_Sensor true must not keep incrementing Count '
                '(this is what would happen with a level-triggered, non-edge counter)');

        setSensor(false);
        scan();
        expect(_i(p, 'Count'), edge, reason: 'falling edge must not change Count');
        // Hold low for a couple more scans.
        scan();
        scan();
        expect(_i(p, 'Count'), edge, reason: 'holding Part_Sensor false must not change Count');
      }
    }

    // Drop Part_Sensor low so the next edge we drive is a clean rising edge.
    setSensor(false);
    scan();
    expect(_i(p, 'Count'), 0, reason: 'Count must remain reset while Part_Sensor is low');

    // The counter must be ready to count a fresh batch after the reset.
    setSensor(true);
    scan();
    expect(_i(p, 'Count'), 1, reason: 'counter must resume counting a new batch after self-reset');
    setSensor(false);
    scan();
    expect(_i(p, 'Count'), 1);
  });
}
