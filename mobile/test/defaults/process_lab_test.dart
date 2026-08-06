import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/process_control_lab.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();

void main() {
  test('the four areas are laid out in the order the screens depend on', () {
    final p = processControlLabProject();
    expect(p.programs.map((x) => x.name).toList(), [
      'LevelPID_FBD',
      'TwoZone_FBD',
      'CascadeMonitor_FBD',
      'NoisyLevelMonitor_FBD',
    ]);
    expect(p.hmis.map((h) => h.id).toList(),
        ['hmi_lab_pid', 'hmi_lab_mimo', 'hmi_lab_cascade', 'hmi_lab_noise']);
    expect(p.tasks.length, 1);
    expect(p.tasks.single.programNames, p.programs.map((x) => x.name).toList());

    // The autotune screen resolves its loop from the FIRST PID in the FIRST
    // FBD program; the interaction screen prefills from the first four analog
    // tags in declaration order.
    final firstFbd = p.programs.firstWhere((x) => x.language == 'FunctionBlockDiagram');
    expect(firstFbd.name, 'LevelPID_FBD');
    expect(firstFbd.fbdBlocks.where((b) => b.type == 'PID').map((b) => b.id).toList(), ['p_pid']);
    expect(defaultInteractionAnalysisTags(p.tags),
        ['Heater_A', 'Heater_B', 'Temp_A', 'Temp_B']);
  });

  test('every sim rule id is unique and the noise rules keep their original ids', () {
    final p = processControlLabProject();
    final ids = p.simRules.map((r) => r.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate SimRule ids');
    final noiseRule = p.simRules.firstWhere((r) => r.behavior == 'noise');
    expect(noiseRule.id, 'sim2',
        reason: 'the noise PRNG is seeded from the rule id — renaming changes the sequence');
  });

  test('the PID area reaches and holds its setpoint with a modulating valve', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    final sp = _d(p, 'Level_SP');
    var minCv = double.infinity;
    var maxCv = -double.infinity;
    for (var i = 0; i < 600; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
      final cv = _d(p, 'Valve_CV');
      minCv = cv < minCv ? cv : minCv;
      maxCv = cv > maxCv ? cv : maxCv;
    }
    expect((_d(p, 'Level_PV') - sp).abs(), lessThanOrEqualTo(4.0));
    expect(maxCv - minCv, greaterThan(1.0), reason: 'the valve must modulate, not stick');
  });

  test('the MIMO area is genuinely cross-coupled', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    // Drive zone A only; zone B must warm through the shared wall.
    writePath(p, 'SP_A', 60.0);
    writePath(p, 'SP_B', 20.0);
    final startB = _d(p, 'Temp_B');
    for (var i = 0; i < 400; i++) {
      applySimRules(p, p.simRules, 200, sim);
      executeFbdPrograms(p, 200, fbd);
    }
    expect(_d(p, 'Temp_B'), greaterThan(startB + 1.0),
        reason: 'the A<->B conduction lag must move zone B when only zone A is driven');
  });

  test('the cascade area lags Tank B behind Tank A by the transport delay', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    for (var i = 0; i < 4; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
    }
    expect(_d(p, 'Tank_A_Level'), greaterThan(_d(p, 'Tank_B_Level')),
        reason: 'Tank B has not seen the transport-delayed signal yet');

    for (var i = 0; i < 60; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
    }
    expect(_d(p, 'Tank_B_Level'), greaterThan(11.0),
        reason: 'after the dead time Tank B fills from the transfer line');
  });

  test('the noise area jitters the raw measurement and the filter attenuates it', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    final measErr = <double>[];
    final filtErr = <double>[];
    for (var i = 0; i < 300; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
      if (i > 100) {
        final clean = _d(p, 'Tank_Level');
        measErr.add((_d(p, 'Level_Meas') - clean).abs());
        filtErr.add((_d(p, 'Level_Filtered') - clean).abs());
      }
    }
    double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
    expect(mean(measErr), greaterThan(0.0), reason: 'the raw reading must jitter');
    for (final e in measErr) {
      expect(e, lessThanOrEqualTo(2.5 + 1e-9), reason: 'jitter stays inside the noise band');
    }
    expect(mean(filtErr), lessThan(mean(measErr)),
        reason: 'the first-order lag must attenuate the measurement noise');
  });
}
