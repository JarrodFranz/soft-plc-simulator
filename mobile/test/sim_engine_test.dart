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
}
