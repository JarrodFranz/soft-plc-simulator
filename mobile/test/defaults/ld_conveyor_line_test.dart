import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/ladder_conveyor_line.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
int _i(PlcProject p, String path) => (readPath(p, path) as num?)?.toInt() ?? 0;

/// One scan tick exactly as the workspace shell runs it for an LD-only
/// project: simulated inputs first, then ladder execution.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
}

void main() {
  test('seal-in latches on Start and drops on Stop and on E-Stop', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isFalse);
    expect(_b(p, 'Zone1_Motor'), isFalse);

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isTrue);
    expect(_b(p, 'Zone1_Motor'), isTrue);

    writePath(p, 'Start_PB', false); // seal-in holds
    _scan(p, sim, ld);
    expect(_b(p, 'Zone1_Motor'), isTrue);

    writePath(p, 'Stop_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isFalse);
    expect(_b(p, 'Zone1_Motor'), isFalse);
  });

  test('E-Stop latches Line_Fault; only a FRESH Start press unlatches it', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isFalse);

    writePath(p, 'EStop_OK', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isTrue);

    writePath(p, 'EStop_OK', true); // healthy again, but the fault LATCHES
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isTrue);

    writePath(p, 'Start_PB', true); // rising edge unlatches
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isFalse);

    // Holding Start is NOT a fresh press: re-fault, hold Start, no unlatch.
    writePath(p, 'EStop_OK', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isTrue,
        reason: 'a held Start_PB gives no rising edge, so OTU never fires');
  });

  test('the pulse coil fires for exactly one scan per falling photo-eye edge, '
      'and Part_Count increments once per part (not once per scan)', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    // Part arrives (photo eye blocked) and stays blocked for 3 scans.
    writePath(p, 'Photo_Eye', true);
    for (var i = 0; i < 3; i++) {
      _scan(p, sim, ld);
      expect(_b(p, 'Part_Edge'), isFalse, reason: 'no falling edge yet');
    }
    expect(_i(p, 'Part_Count'), 0);

    // Part clears: exactly one falling edge -> one pulse -> one count.
    writePath(p, 'Photo_Eye', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Part_Edge'), isTrue);
    expect(_i(p, 'Part_Count'), 1);
    expect(_i(p, 'Shift_Total'), 1);

    _scan(p, sim, ld);
    expect(_b(p, 'Part_Edge'), isFalse, reason: 'the pulse coil is one scan wide');
    expect(_i(p, 'Part_Count'), 1, reason: 'no double count while the eye stays clear');
  });

  test('the FALLING pulse coil fires for one scan when the line stops and '
      'abandons the partial batch', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Stop_Edge'), isFalse);

    // Feed two parts so the batch is genuinely partial.
    for (var part = 0; part < 2; part++) {
      writePath(p, 'Photo_Eye', true);
      _scan(p, sim, ld);
      writePath(p, 'Photo_Eye', false);
      _scan(p, sim, ld);
    }
    expect(_i(p, 'Part_Count'), 2);

    writePath(p, 'Stop_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Stop_Edge'), isTrue, reason: 'falling power edge on Line_Latch');
    expect(_i(p, 'Part_Count'), 0, reason: 'the partial batch was abandoned');
    expect(_i(p, 'Shift_Total'), 2, reason: 'the shift total is never reset by a stop');

    _scan(p, sim, ld);
    expect(_b(p, 'Line_Stop_Edge'), isFalse, reason: 'the pulse coil is one scan wide');
  });

  test('SUB tracks Parts_Remaining, EQ requests zone 2, MOVE zeroes the batch, '
      'the negated coil clears Batch_Running, and CTU counts the parts', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);
    final target = _i(p, 'Batch_Target');
    expect(target, 10);

    var sawRequest = false;
    for (var part = 0; part < target; part++) {
      writePath(p, 'Photo_Eye', true);
      _scan(p, sim, ld);
      writePath(p, 'Photo_Eye', false);
      _scan(p, sim, ld);
      if (_b(p, 'Zone2_Request')) {
        sawRequest = true;
      }
    }

    expect(sawRequest, isTrue,
        reason: 'EQ Part_Count == Batch_Target must request zone 2 for at least one scan');
    expect(_i(p, 'PartCtu.CV'), target, reason: 'CTU counted one per part edge');
    expect(_i(p, 'Part_Count'), 0, reason: 'MOVE zeroed the count at the batch end');
    // Parts_Remaining is recomputed from the freshly-zeroed count.
    _scan(p, sim, ld);
    expect(_i(p, 'Parts_Remaining'), target);
    expect(_b(p, 'Batch_Running'), isTrue,
        reason: 'the negated coil re-asserts Batch_Running once the batch restarts');
  });

  test('the jam TON trips after 5 s without parts and a part clears it', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    for (var i = 0; i < 8; i++) {
      _scan(p, sim, ld);
      expect(_b(p, 'Zone1_Motor'), isTrue, reason: 'runs until the jam trips (scan $i)');
    }
    expect(_i(p, 'JamTimer.ACC'), 4500);

    _scan(p, sim, ld);
    expect(_b(p, 'JamTimer.DN'), isTrue);
    expect(_b(p, 'Belt_Jammed'), isTrue);

    _scan(p, sim, ld);
    expect(_b(p, 'Zone1_Motor'), isFalse, reason: 'the jam interlock opens rung 1');

    writePath(p, 'Photo_Eye', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Belt_Jammed'), isFalse, reason: 'a part unlatches the jam');
  });

  test('TOF holds the zone-2 permit for 3 s after the line stops', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);
    expect(_b(p, 'Zone2_Permit'), isTrue);

    writePath(p, 'Stop_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isFalse);
    expect(_b(p, 'Zone2_Permit'), isTrue, reason: 'TOF run-on has not expired');

    // 3000 ms preset at 500 ms/scan: still held at 2500, dropped at 3000.
    for (var i = 0; i < 4; i++) {
      _scan(p, sim, ld);
    }
    expect(_b(p, 'Zone2_Permit'), isTrue);
    _scan(p, sim, ld);
    expect(_b(p, 'Zone2_Permit'), isFalse);
  });

  test('the LADDER-BODIED MotorStarter FB keeps its seal-in state INSIDE the '
      'instance, not in a global tag', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    final fb = p.fbDefinitions.firstWhere((f) => f.name == 'MotorStarter');
    expect(fb.ladderRungs, isNotEmpty,
        reason: 'this FB is the ladder-bodied showcase — stSource must stay empty');
    expect(fb.stSource, isEmpty);
    expect(p.tags.any((t) => t.name == 'Seal'), isFalse,
        reason: 'Seal exists only as an FB-internal var, never as a global tag');

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    // Drive one part edge for every part in the batch so the EQ rung raises
    // Zone2_Request for a single scan; the FB must LATCH on that one scan.
    for (var part = 0; part < 10; part++) {
      writePath(p, 'Photo_Eye', true);
      _scan(p, sim, ld);
      writePath(p, 'Photo_Eye', false);
      _scan(p, sim, ld);
    }

    // The loop exits ON the scan where rung 10's EQ set Zone2_Request true;
    // rung 11's MOVE only zeroes Part_Count for the NEXT scan's comparison, so
    // step one scan further to see the request drop while the FB keeps holding.
    _scan(p, sim, ld);

    expect(_b(p, 'Zone2Starter.Seal'), isTrue,
        reason: 'the one-scan request sealed in inside the instance struct');
    expect(_b(p, 'Zone2_Motor'), isTrue);
    expect(_b(p, 'Zone2_Request'), isFalse,
        reason: 'the request itself is long gone — only the FB seal holds zone 2');

    // Dropping the permit (line stops, TOF expires) drops the FB seal and Out.
    writePath(p, 'Stop_PB', true);
    for (var i = 0; i < 10; i++) {
      _scan(p, sim, ld);
    }
    expect(_b(p, 'Zone2_Permit'), isFalse);
    expect(_b(p, 'Zone2Starter.Seal'), isFalse);
    expect(_b(p, 'Zone2_Motor'), isFalse);
  });

  test('the DUT members mirror the line state', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_DUT.Running'), isTrue);
    expect(_i(p, 'Line_DUT.Speed'), 1450);
    expect(_b(p, 'Line_DUT.Faulted'), isFalse);

    writePath(p, 'EStop_OK', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_DUT.Faulted'), isTrue);
  });

  test('with sim rules ON the line survives normal part passage', () {
    final p = ladderConveyorLineProject();
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    var sawPart = false;
    for (var i = 0; i < 30; i++) {
      _scan(p, sim, ld);
      if (_b(p, 'Photo_Eye')) {
        sawPart = true;
      }
      expect(_b(p, 'Zone1_Motor'), isTrue, reason: 'no jam while parts arrive (scan $i)');
      expect(_b(p, 'Belt_Jammed'), isFalse, reason: 'no jam while parts arrive (scan $i)');
    }
    expect(sawPart, isTrue, reason: 'the photo eye genuinely pulsed during the run');
  });
}
