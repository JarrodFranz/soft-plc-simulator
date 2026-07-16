import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _mimo() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_mimo_two_zone');

double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();

/// Sets the decoupler CONST blocks' (`a_d12`/`b_d21`) `tagBinding` in the
/// project's `TwoZone_FBD` FBD program. Both default to `'0'` (loops
/// coupled); setting them to the identified `K12/K11`/`K21/K22` ratio
/// cancels the cross-loop interaction (see `_mimoTwoZoneProject` doc
/// comment in `default_projects.dart`).
void _setDecouplerGains(PlcProject p, String d12, String d21) {
  final fbd = p.programs.firstWhere((prog) => prog.name == 'TwoZone_FBD');
  fbd.fbdBlocks.firstWhere((b) => b.id == 'a_d12').tagBinding = d12;
  fbd.fbdBlocks.firstWhere((b) => b.id == 'b_d21').tagBinding = d21;
}

/// Runs the closed-loop scan tick (sim rules + FBD, mirroring the scan order
/// in `pid_loop_integration_test.dart`) to near-steady with both setpoints
/// held at their project defaults, then steps `SP_A` by [spAStep] and tracks
/// the maximum absolute deviation of `Temp_B` from its pre-step value over
/// [stepTicks] further ticks. This is the cross-loop disturbance metric:
/// bigger means `SP_A` moves disturb `Temp_B` more.
double crossDisturbance(
  PlcProject p, {
  int settleTicks = 60,
  int stepTicks = 120,
  double spAStep = 15.0,
}) {
  final sim = SimRuntime();
  final fbd = FbdRuntime();
  const dtMs = 200; // matches p.scanPeriodMs / TwoZoneTask periodMs

  void scan() {
    applySimRules(p, p.simRules, dtMs, sim);
    executeFbdPrograms(p, dtMs, fbd);
  }

  for (var i = 0; i < settleTicks; i++) {
    scan();
  }

  final tb0 = _d(p, 'Temp_B');
  writePath(p, 'SP_A', _d(p, 'SP_A') + spAStep);

  var maxDev = 0.0;
  for (var i = 0; i < stepTicks; i++) {
    scan();
    final dev = (_d(p, 'Temp_B') - tb0).abs();
    if (dev > maxDev) {
      maxDev = dev;
    }
  }
  return maxDev;
}

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

  test('static decoupler reduces cross-loop disturbance vs the coupled case', () {
    // Coupled case: fresh project, decoupler CONST blocks left at their
    // default '0' tagBinding (no decoupling applied).
    final coupledProject = _mimo();
    final coupled = crossDisturbance(coupledProject);

    // Decoupled case: a separate fresh project so the two runs cannot share
    // any mutable state, with the decoupler gains set to the identified
    // K12/K11 and K21/K22 ratios (~0.833, per Task 2's identified gain
    // matrix K=[[0.645,0.537],[0.537,0.645]]).
    final decoupledProject = _mimo();
    _setDecouplerGains(decoupledProject, '0.833', '0.833');
    final decoupled = crossDisturbance(decoupledProject);

    // There must be a real cross-loop disturbance to reduce in the first
    // place (the plant is genuinely coupled, per the RGA test above).
    expect(coupled, greaterThan(0.5),
        reason: 'coupled run should show a real Temp_B disturbance from the '
            'SP_A step (got $coupled)');

    // The decoupler must meaningfully shrink that disturbance.
    expect(decoupled, lessThan(coupled),
        reason: 'static decoupler (d12=d21=0.833) should reduce the Temp_B '
            'disturbance caused by an SP_A step vs the coupled '
            '(d12=d21=0) case (coupled=$coupled, decoupled=$decoupled)');
  });
}
