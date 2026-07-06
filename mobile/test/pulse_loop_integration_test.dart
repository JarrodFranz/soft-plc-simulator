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
  test('Pulse Output: R_TRIG-gated TP produces a fixed-width one-shot pulse '
      'that is independent of how long Start_Btn is held, and re-fires on the '
      'next rising edge', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_pulse_output');
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

    final pulseTime = _i(p, 'Pulse_Time');
    expect(pulseTime, greaterThan(0));
    final scanMs = p.scanPeriodMs;
    expect(scanMs, greaterThan(0));
    final scansForPulse = (pulseTime / scanMs).round();

    // Drive Start_Btn with explicit true/false writes between scans rather
    // than relying purely on the sim pulse rule, so rising-edge timing and
    // the "held well past Pulse_Time" assertion are exact. Disable the
    // project's own Start_Btn pulse sim rule for this test only, so it does
    // not overwrite our explicit writes each scan; the rule itself (and its
    // pulse behavior, with an on-phase longer than Pulse_Time) is exercised
    // live during normal RUN mode — see default_projects.dart.
    for (final r in p.simRules) {
      if (r.targetPath == 'Start_Btn') {
        r.enabled = false;
      }
    }
    void setBtn(bool value) => writePath(p, 'Start_Btn', value);

    setBtn(false);
    scan(); // settle initial state
    expect(_b(p, 'Pulse_Out'), isFalse, reason: 'pulse output must start false');
    expect(_i(p, 'Pulse_ET'), 0, reason: 'elapsed time must start at 0');

    // Rising edge of Start_Btn.
    setBtn(true);
    scan();

    // Hold Start_Btn true for FAR longer than Pulse_Time — many more scans
    // than scansForPulse. This is the falsifiable heart of the demo: if TP
    // were retriggerable, or if R_TRIG were missing (level-triggered IN),
    // Pulse_Out would stay true for as long as the button is held. A correct
    // R_TRIG-gated non-retriggerable TP instead drops Pulse_Out after exactly
    // Pulse_Time, even though Start_Btn never went false.
    var pulseSeenTrue = false;
    var dropScan = -1;
    var etAtDrop = -1;
    for (var i = 1; i <= scansForPulse + 20; i++) {
      if (i > 1) {
        scan();
      }
      final out = _b(p, 'Pulse_Out');
      if (out) {
        pulseSeenTrue = true;
      }
      if (pulseSeenTrue && !out && dropScan == -1) {
        dropScan = i;
        etAtDrop = _i(p, 'Pulse_ET');
      }
    }

    expect(pulseSeenTrue, isTrue, reason: 'Pulse_Out must go true after the Start_Btn rising edge');
    expect(dropScan, greaterThan(0), reason: 'Pulse_Out must drop back to false within the observed window');
    expect(dropScan, closeTo(scansForPulse, 1),
        reason: 'Pulse_Out must drop after ~Pulse_Time (${pulseTime}ms = $scansForPulse scans at ${scanMs}ms/scan), '
            'NOT stay true for as long as Start_Btn (still held true) — this is what would happen '
            'without TP (output just following the button) or with a retriggerable timer '
            '(pulse extended by the continued hold)');
    expect(etAtDrop, pulseTime,
        reason: 'ET must reach exactly Pulse_Time on the scan the pulse completes (the elapsed-time readout '
            'proves the width came from TP.PT, not from watching Start_Btn)');
    expect(_b(p, 'Pulse_Out'), isFalse, reason: 'Pulse_Out must remain false once the one-shot has completed, '
        'even though Start_Btn is STILL held true');

    // Keep holding Start_Btn true for a few more scans: must stay dropped
    // (non-retriggerable — the button never went false, so no new edge).
    // R_TRIG.Q (TP.IN) is idle-false on these scans (it only pulses true for
    // the one scan of the original rising edge), so TP's idle re-arm also
    // resets ET back to 0 here — that is a re-arm side effect, not evidence
    // of a stuck/broken timer.
    for (var i = 0; i < 5; i++) {
      scan();
      expect(_b(p, 'Pulse_Out'), isFalse,
          reason: 'holding Start_Btn true with no new rising edge must not re-fire the pulse');
    }

    // Drop Start_Btn low, then drive a fresh rising edge — must produce
    // ANOTHER identical pulse (proves TP re-arms correctly).
    setBtn(false);
    scan();
    expect(_b(p, 'Pulse_Out'), isFalse);

    setBtn(true);
    scan();
    var pulseSeenTrue2 = false;
    var dropScan2 = -1;
    var etAtDrop2 = -1;
    for (var i = 1; i <= scansForPulse + 20; i++) {
      if (i > 1) {
        scan();
      }
      final out = _b(p, 'Pulse_Out');
      if (out) {
        pulseSeenTrue2 = true;
      }
      if (pulseSeenTrue2 && !out && dropScan2 == -1) {
        dropScan2 = i;
        etAtDrop2 = _i(p, 'Pulse_ET');
      }
    }
    expect(pulseSeenTrue2, isTrue, reason: 'second Start_Btn rising edge must produce another pulse');
    expect(dropScan2, closeTo(scansForPulse, 1),
        reason: 'the second pulse must have the same ~Pulse_Time width as the first');
    expect(etAtDrop2, pulseTime, reason: 'the second pulse must also reach exactly Pulse_Time before dropping');
  });
}
