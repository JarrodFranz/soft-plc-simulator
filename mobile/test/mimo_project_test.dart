import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';

PlcProject _mimo() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_mimo_two_zone');

void main() {
  test('MIMO project registered and round-trips', () {
    final p = _mimo();
    expect(p.name, 'MIMO — Two Thermal Zones');
    final back = PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
  });

  test('plant is genuinely coupled (RGA off-diagonal non-zero)', () {
    final g = identifyGainMatrix(_mimo(),
        mv1Path: 'Heater_A',
        mv2Path: 'Heater_B',
        pv1Path: 'Temp_A',
        pv2Path: 'Temp_B',
        params: const StepTestParams(
            baseMv: 30,
            stepDelta: 20,
            dtMs: 100,
            maxScans: 20000,
            settleEps: 1e-4,
            settleWindow: 20));
    expect(g.converged, isTrue, reason: g.warning);
    expect(g.k12.abs(), greaterThan(0));
    expect(g.k21.abs(), greaterThan(0));
  });
}
