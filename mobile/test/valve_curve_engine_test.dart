import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';

PlcProject _projWith(String curve) {
  final proj = PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [
      PlcTag(name: 'Valve', path: 'Valve', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
      PlcTag(name: 'Level', path: 'Level', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    ],
    structDefs: [], programs: [], tasks: [], hmis: [],
  );
  proj.simRules.add(SimRule(
    id: 'r', name: 'fill', targetPath: 'Level', behavior: 'integrate',
    ratePerSec: 100.0, minValue: 0.0, maxValue: 1000.0,
    sourcePath: 'Valve', refValue: 100.0, valveCurve: curve,
  ));
  return proj;
}

void main() {
  test('equal-percentage integrates less than linear at a low valve %', () {
    final lin = _projWith('linear');
    final eq = _projWith('equalPercentage');
    final rtL = SimRuntime();
    final rtE = SimRuntime();
    // One 1-second scan; Valve=20 -> fraction 0.2.
    applySimRules(lin, lin.simRules, 1000, rtL);
    applySimRules(eq, eq.simRules, 1000, rtE);
    final linLevel = lin.tags.firstWhere((t) => t.name == 'Level').value as num;
    final eqLevel = eq.tags.firstWhere((t) => t.name == 'Level').value as num;
    // linear: 100*1*0.2 = 20; equal-pct gain(0.2) ~ 0.024 -> ~2.4.
    expect(linLevel, closeTo(20.0, 1e-6));
    expect(eqLevel, lessThan(linLevel));
    expect(eqLevel, greaterThan(0.0));
  });

  test('linear (default) reproduces the pre-feature accumulation exactly', () {
    final lin = _projWith('linear');
    final rt = SimRuntime();
    applySimRules(lin, lin.simRules, 1000, rt);
    expect(lin.tags.firstWhere((t) => t.name == 'Level').value as num, closeTo(20.0, 1e-9));
  });

  test('SimRule.valveCurve round-trips; absent key loads as linear', () {
    final r = SimRule(
      id: 'r', name: 'n', targetPath: 'L', behavior: 'integrate',
      sourcePath: 'V', refValue: 100.0, valveCurve: 'quickOpening');
    expect(SimRule.fromJson(r.toJson()).valveCurve, 'quickOpening');
    final legacy = Map<String, dynamic>.from(r.toJson())..remove('valve_curve');
    expect(SimRule.fromJson(legacy).valveCurve, 'linear');
  });
}
