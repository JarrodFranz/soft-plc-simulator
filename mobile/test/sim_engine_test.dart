import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProject _proj(List<PlcTag> tags, List<SimRule> rules) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules,
    );

SimClause _cl(String left, String cmp, String operand, {String kind = 'literal'}) =>
    SimClause(leftPath: left, comparator: cmp, operandKind: kind, operand: operand);

void main() {
  test('evalCondition: empty means always true', () {
    final p = _proj([], []);
    expect(evalCondition(p, []), isTrue);
  });

  test('evalCondition: numeric comparator + AND', () {
    final p = _proj([_tag('L', 'FLOAT64', 60.0), _tag('B', 'BOOL', true)], []);
    expect(evalCondition(p, [_cl('L', '>', '50')]), isTrue);
    expect(evalCondition(p, [_cl('L', '>', '70')]), isFalse);
    expect(evalCondition(p, [_cl('L', '>', '50'), _cl('B', '==', 'true')]), isTrue);
    expect(evalCondition(p, [_cl('L', '>', '50'), _cl('B', '==', 'false')]), isFalse);
  });

  test('evalCondition: tag operand', () {
    final p = _proj([_tag('A', 'FLOAT64', 10.0), _tag('B', 'FLOAT64', 5.0)], []);
    expect(evalCondition(p, [_cl('A', '>', 'B', kind: 'tag')]), isTrue);
    expect(evalCondition(p, [_cl('B', '>', 'A', kind: 'tag')]), isFalse);
  });

  test('setWhileCondition drives a bool from its condition', () {
    final rule = SimRule(id: 'r', name: 'sw', targetPath: 'Sw', behavior: 'setWhileCondition',
        condition: [_cl('L', '>', '50')]);
    final p = _proj([_tag('Sw', 'BOOL', false), _tag('L', 'FLOAT64', 60.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Sw').value, isTrue);
    (p.tags.firstWhere((t) => t.name == 'L')).value = 40.0;
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Sw').value, isFalse);
  });

  test('integrate accumulates rate*dt and clamps', () {
    final rule = SimRule(id: 'r', name: 'fill', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // +10
    expect(p.tags.first.value, closeTo(10.0, 0.001));
    for (int i = 0; i < 20; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(100.0)); // clamped
  });

  test('ramp moves toward target and stops there', () {
    final rule = SimRule(id: 'r', name: 'ramp', targetPath: 'PV', behavior: 'ramp',
        ratePerSec: 5.0, targetValue: 20.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('PV', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // +5 -> 5
    expect(p.tags.first.value, closeTo(5.0, 0.001));
    for (int i = 0; i < 10; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(20.0)); // reaches target, no overshoot
  });

  test('pulse toggles on/off by timing while condition holds', () {
    final rule = SimRule(id: 'r', name: 'pulse', targetPath: 'Eye', behavior: 'pulse',
        onMs: 200, offMs: 300, condition: [_cl('Run', '==', 'true')]);
    final p = _proj([_tag('Eye', 'BOOL', false), _tag('Run', 'BOOL', true)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 100, rt); // 100ms into on-phase
    expect(p.tags.firstWhere((t) => t.name == 'Eye').value, isTrue);
    applySimRules(p, p.simRules, 100, rt); // 200ms -> flip to off
    applySimRules(p, p.simRules, 100, rt); // into off-phase
    expect(p.tags.firstWhere((t) => t.name == 'Eye').value, isFalse);
    // condition false -> forced off
    (p.tags.firstWhere((t) => t.name == 'Run')).value = false;
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Eye').value, isFalse);
  });

  test('delayedSet fires after delayMs and resets when condition drops', () {
    final rule = SimRule(id: 'r', name: 'del', targetPath: 'Trip', behavior: 'delayedSet',
        delayMs: 300, condition: [_cl('Run', '==', 'true')]);
    final p = _proj([_tag('Trip', 'BOOL', false), _tag('Run', 'BOOL', true)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 200, rt); // 200 < 300
    expect(p.tags.firstWhere((t) => t.name == 'Trip').value, isFalse);
    applySimRules(p, p.simRules, 200, rt); // 400 >= 300
    expect(p.tags.firstWhere((t) => t.name == 'Trip').value, isTrue);
    (p.tags.firstWhere((t) => t.name == 'Run')).value = false;
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Trip').value, isFalse);
  });

  test('a forced target is not overwritten', () {
    final rule = SimRule(id: 'r', name: 'i', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0, forced: true, fv: 42.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt);
    expect(p.tags.first.value, equals(0.0)); // untouched (forced)
  });

  test('disabled rule does nothing', () {
    final rule = SimRule(id: 'r', name: 'i', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, enabled: false, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [rule]);
    applySimRules(p, p.simRules, 1000, SimRuntime());
    expect(p.tags.first.value, equals(0.0));
  });

  test('pulse with zero on-time does not get stuck on', () {
    final rule = SimRule(id: 'r', name: 'p0', targetPath: 'Eye', behavior: 'pulse',
        onMs: 0, offMs: 200, condition: []);
    final p = _proj([_tag('Eye', 'BOOL', false)], [rule]);
    final rt = SimRuntime();
    bool sawFalse = false;
    for (int i = 0; i < 5; i++) {
      applySimRules(p, p.simRules, 100, rt);
      if (p.tags.first.value == false) {
        sawFalse = true;
      }
    }
    expect(sawFalse, isTrue); // a 0ms on-phase must not freeze the output true
  });

  test('ramp decreases toward a lower target and stops', () {
    final rule = SimRule(id: 'r', name: 'down', targetPath: 'PV', behavior: 'ramp',
        ratePerSec: 5.0, targetValue: 10.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('PV', 'FLOAT64', 30.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // 30 -> 25
    expect(p.tags.first.value, closeTo(25.0, 0.001));
    for (int i = 0; i < 10; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(10.0)); // reaches target, no undershoot
  });

  // --- WS9 Task 1: analog-scaled rates + first-order lag ---------------

  test('firstOrderLag toward a fixed target: ~63% after one tau, snaps at tau<=0', () {
    final rule = SimRule(id: 'r', name: 'lag', targetPath: 'PV', behavior: 'firstOrderLag',
        targetValue: 100.0, tauSec: 1.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('PV', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    for (int i = 0; i < 10; i++) {
      applySimRules(p, p.simRules, 100, rt); // 10 x 100ms = 1.0s = 1 tau
    }
    final afterOneTau = p.tags.first.value as double;
    expect(afterOneTau, inInclusiveRange(55.0, 70.0), reason: '1-e^-1 ~= 0.632');

    for (int i = 0; i < 200; i++) {
      applySimRules(p, p.simRules, 100, rt); // many more tau
    }
    expect(p.tags.first.value, closeTo(100.0, 0.01)); // converges to target, clamped

    // tauSec <= 0 snaps immediately.
    final snapRule = SimRule(id: 'r2', name: 'snap', targetPath: 'PV2', behavior: 'firstOrderLag',
        targetValue: 42.0, tauSec: 0.0, minValue: 0, maxValue: 100, condition: []);
    final p2 = _proj([_tag('PV2', 'FLOAT64', 0.0)], [snapRule]);
    applySimRules(p2, p2.simRules, 100, SimRuntime());
    expect(p2.tags.first.value, equals(42.0));
  });

  test('firstOrderLag toward a tag target: tracks and retargets on change', () {
    final rule = SimRule(id: 'r', name: 'lag', targetPath: 'Temp', behavior: 'firstOrderLag',
        sourcePath: 'SetTemp', tauSec: 1.0, minValue: 0, maxValue: 200, condition: []);
    final p = _proj([_tag('Temp', 'FLOAT64', 0.0), _tag('SetTemp', 'FLOAT64', 50.0)], [rule]);
    final rt = SimRuntime();
    for (int i = 0; i < 10; i++) {
      applySimRules(p, p.simRules, 100, rt);
    }
    final tempAfterOneTau = p.tags.firstWhere((t) => t.name == 'Temp').value as double;
    expect(tempAfterOneTau, inInclusiveRange(0.55 * 50, 0.70 * 50));

    // Retarget: bump SetTemp and confirm Temp keeps moving toward the new value.
    (p.tags.firstWhere((t) => t.name == 'SetTemp')).value = 80.0;
    final before = p.tags.firstWhere((t) => t.name == 'Temp').value as double;
    applySimRules(p, p.simRules, 100, rt);
    final after = p.tags.firstWhere((t) => t.name == 'Temp').value as double;
    expect(after, greaterThan(before));
    expect(after, lessThan(80.0));
  });

  test('analog-scaled integrate: rate scaled by source/refValue', () {
    SimRule ruleFor(double valve) => SimRule(id: 'r', name: 'fill', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, sourcePath: 'Valve', refValue: 100.0, minValue: 0, maxValue: 1000, condition: []);

    // Valve = 50 -> half rate -> +5 after 1s.
    final p50 = _proj([_tag('Lvl', 'FLOAT64', 0.0), _tag('Valve', 'FLOAT64', 50.0)], [ruleFor(50)]);
    applySimRules(p50, p50.simRules, 1000, SimRuntime());
    expect(p50.tags.firstWhere((t) => t.name == 'Lvl').value, closeTo(5.0, 0.001));

    // Valve = 100 -> full rate -> +10 after 1s.
    final p100 = _proj([_tag('Lvl', 'FLOAT64', 0.0), _tag('Valve', 'FLOAT64', 100.0)], [ruleFor(100)]);
    applySimRules(p100, p100.simRules, 1000, SimRuntime());
    expect(p100.tags.firstWhere((t) => t.name == 'Lvl').value, closeTo(10.0, 0.001));

    // Valve = 0 -> no rate -> unchanged.
    final p0 = _proj([_tag('Lvl', 'FLOAT64', 0.0), _tag('Valve', 'FLOAT64', 0.0)], [ruleFor(0)]);
    applySimRules(p0, p0.simRules, 1000, SimRuntime());
    expect(p0.tags.firstWhere((t) => t.name == 'Lvl').value, closeTo(0.0, 0.001));

    // sourcePath empty -> identical to today (full rate).
    final unscaledRule = SimRule(id: 'r', name: 'fill', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, minValue: 0, maxValue: 1000, condition: []);
    final pUnscaled = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [unscaledRule]);
    applySimRules(pUnscaled, pUnscaled.simRules, 1000, SimRuntime());
    expect(pUnscaled.tags.first.value, closeTo(10.0, 0.001));
  });

  test('analog-scaled ramp: step scaled by source/refValue', () {
    final rule = SimRule(id: 'r', name: 'ramp', targetPath: 'PV', behavior: 'ramp',
        ratePerSec: 10.0, targetValue: 100.0, sourcePath: 'Valve', refValue: 100.0,
        minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('PV', 'FLOAT64', 0.0), _tag('Valve', 'FLOAT64', 50.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // half rate -> +5
    expect(p.tags.firstWhere((t) => t.name == 'PV').value, closeTo(5.0, 0.001));

    // sourcePath empty -> byte-identical to today's ramp behaviour.
    final unscaledRule = SimRule(id: 'r', name: 'ramp', targetPath: 'PV2', behavior: 'ramp',
        ratePerSec: 5.0, targetValue: 20.0, minValue: 0, maxValue: 100, condition: []);
    final p2 = _proj([_tag('PV2', 'FLOAT64', 0.0)], [unscaledRule]);
    applySimRules(p2, p2.simRules, 1000, SimRuntime());
    expect(p2.tags.first.value, closeTo(5.0, 0.001));
  });

  test('back-compat: integrate with new fields at defaults is byte-identical to before', () {
    final rule = SimRule(id: 'r', name: 'fill', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, minValue: 0, maxValue: 100, condition: []);
    expect(rule.sourcePath, equals(''));
    expect(rule.refValue, equals(100.0));
    expect(rule.tauSec, equals(5.0));
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // +10
    expect(p.tags.first.value, closeTo(10.0, 0.001));
    for (int i = 0; i < 20; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(100.0)); // clamped, same as legacy test
  });

  test('firstOrderLag respects forcing and clamping', () {
    final rule = SimRule(id: 'r', name: 'lag', targetPath: 'Lvl', behavior: 'firstOrderLag',
        targetValue: 500.0, tauSec: 0.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0, forced: true, fv: 42.0)], [rule]);
    applySimRules(p, p.simRules, 1000, SimRuntime());
    expect(p.tags.first.value, equals(0.0)); // untouched (forced)

    final clampRule = SimRule(id: 'r2', name: 'lag2', targetPath: 'Lvl2', behavior: 'firstOrderLag',
        targetValue: 500.0, tauSec: 0.0, minValue: 0, maxValue: 100, condition: []);
    final p2 = _proj([_tag('Lvl2', 'FLOAT64', 0.0)], [clampRule]);
    applySimRules(p2, p2.simRules, 1000, SimRuntime());
    expect(p2.tags.first.value, equals(100.0)); // clamped to max
  });

  // --- WS13 Task 1: transport dead-time (deadTime behaviour) ------------

  test('deadTime: step is delayed by ~n scans (n = tauSec/dt)', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.3, minValue: 0, maxValue: 1000, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    // Run a few scans while Src == 0 -> Out stays 0.
    for (int i = 0; i < 3; i++) {
      applySimRules(p, p.simRules, 100, rt);
    }
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(0.0));

    // Step Src to 50.
    (p.tags.firstWhere((t) => t.name == 'Src')).value = 50.0;
    applySimRules(p, p.simRules, 100, rt); // step scan itself
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(0.0),
        reason: 'Out must still be pre-step value right after the step');
    applySimRules(p, p.simRules, 100, rt); // 1 scan after step
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(0.0));
    applySimRules(p, p.simRules, 100, rt); // 2 scans after step
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(0.0));
    applySimRules(p, p.simRules, 100, rt); // 3 scans after step -> n=3 scans elapsed
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(50.0),
        reason: 'Out becomes 50 after ~3 scans (n = 0.3/0.1)');
  });

  test('deadTime: holds initial source value while buffer fills', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.5, minValue: 0, maxValue: 1000, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 7.0)], [rule]);
    final rt = SimRuntime();
    // n = 5 scans; before the buffer has n+1 samples, Out must hold the
    // initial source value (7.0), never null/garbage/zero.
    for (int i = 0; i < 4; i++) {
      applySimRules(p, p.simRules, 100, rt);
      expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(7.0));
    }
  });

  test('deadTime: ramp is reproduced at the output shifted by n scans', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.2, minValue: -1000, maxValue: 1000, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    const n = 2; // 0.2 / 0.1
    final srcHistory = <double>[];
    final outHistory = <double>[];
    for (int i = 0; i < 10; i++) {
      final srcTag = p.tags.firstWhere((t) => t.name == 'Src');
      srcTag.value = (i + 1) * 3.0; // ramps by fixed step each scan
      applySimRules(p, p.simRules, 100, rt);
      srcHistory.add(srcTag.value as double);
      outHistory.add(p.tags.firstWhere((t) => t.name == 'Out').value as double);
    }
    // Once past the fill period, Out(k) == Src(k-n) (0-indexed histories).
    for (int k = n; k < 10; k++) {
      expect(outHistory[k], closeTo(srcHistory[k - n], 0.001));
    }
  });

  test('deadTime: tauSec <= 0 is pass-through (n=0, Out==Src same scan)', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.0, minValue: 0, maxValue: 1000, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 33.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(33.0));

    // Negative tauSec also treated as pass-through.
    final rule2 = SimRule(id: 'r2', name: 'dead2', targetPath: 'Out2', behavior: 'deadTime',
        sourcePath: 'Src2', tauSec: -1.0, minValue: 0, maxValue: 1000, condition: []);
    final p2 = _proj([_tag('Out2', 'FLOAT64', 0.0), _tag('Src2', 'FLOAT64', 9.0)], [rule2]);
    applySimRules(p2, p2.simRules, 100, SimRuntime());
    expect(p2.tags.firstWhere((t) => t.name == 'Out2').value, equals(9.0));
  });

  test('deadTime: absurdly large tauSec is bounded, completes fast, holds initial value', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 1e9, minValue: 0, maxValue: 1000, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 12.0)], [rule]);
    final rt = SimRuntime();
    final sw = Stopwatch()..start();
    for (int i = 0; i < 50; i++) {
      applySimRules(p, p.simRules, 100, rt);
    }
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(2000)); // must not hang
    // Delay (1e9 s) is vastly longer than the run (5s) -> holds initial value.
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(12.0));
  });

  test('deadTime: output is clamped and a forced target is not overwritten', () {
    final clampRule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.0, minValue: 0, maxValue: 10, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 999.0)], [clampRule]);
    applySimRules(p, p.simRules, 100, SimRuntime());
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(10.0)); // clamped to max

    final forcedRule = SimRule(id: 'r2', name: 'dead2', targetPath: 'Out2', behavior: 'deadTime',
        sourcePath: 'Src2', tauSec: 0.0, minValue: 0, maxValue: 1000, condition: []);
    final p2 = _proj(
        [_tag('Out2', 'FLOAT64', 0.0, forced: true, fv: 5.0), _tag('Src2', 'FLOAT64', 999.0)], [forcedRule]);
    applySimRules(p2, p2.simRules, 100, SimRuntime());
    expect(p2.tags.firstWhere((t) => t.name == 'Out2').value, equals(0.0)); // untouched (forced)
  });

  test('deadTime: false condition writes nothing', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.0, minValue: 0, maxValue: 1000,
        condition: [_cl('Run', '==', 'true')]);
    final p = _proj([_tag('Out', 'FLOAT64', 3.0), _tag('Src', 'FLOAT64', 999.0), _tag('Run', 'BOOL', false)], [rule]);
    applySimRules(p, p.simRules, 100, SimRuntime());
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(3.0)); // unchanged
  });

  test('deadTime: back-compat spot-check — existing integrate rule unaffected', () {
    final rule = SimRule(id: 'r', name: 'fill', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // +10
    expect(p.tags.first.value, closeTo(10.0, 0.001));
    for (int i = 0; i < 20; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(100.0)); // clamped, same as legacy test
  });

  test('deadTime: state resets when SimRuntime.byRuleId is cleared', () {
    final rule = SimRule(id: 'r', name: 'dead', targetPath: 'Out', behavior: 'deadTime',
        sourcePath: 'Src', tauSec: 0.3, minValue: 0, maxValue: 1000, condition: []);
    final p = _proj([_tag('Out', 'FLOAT64', 0.0), _tag('Src', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    (p.tags.firstWhere((t) => t.name == 'Src')).value = 50.0;
    for (int i = 0; i < 3; i++) {
      applySimRules(p, p.simRules, 100, rt);
    }
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(50.0));

    // Clear runtime state -> delay line restarts from empty buffer.
    rt.byRuleId.clear();
    (p.tags.firstWhere((t) => t.name == 'Out')).value = 0.0;
    applySimRules(p, p.simRules, 100, rt); // first scan after reset -> buffer had 0, now 1 sample
    // With a fresh buffer, Out should hold the (only buffered) sample, not
    // jump straight back to the old delayed value.
    expect(p.tags.firstWhere((t) => t.name == 'Out').value, equals(50.0));
  });
}
