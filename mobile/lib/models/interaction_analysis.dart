import 'dart:convert';

import 'project_model.dart';
import 'sim_engine.dart';
import 'tag_resolver.dart';

/// Parameters controlling an open-loop step test: the MV levels to hold, scan
/// timing, and the convergence criteria used to decide a PV pair has settled
/// to steady state.
class StepTestParams {
  final double baseMv;
  final double stepDelta;
  final int dtMs;
  final int maxScans;
  final double settleEps;
  final int settleWindow;

  const StepTestParams({
    required this.baseMv,
    required this.stepDelta,
    required this.dtMs,
    required this.maxScans,
    required this.settleEps,
    required this.settleWindow,
  });
}

/// A 2x2 steady-state process gain matrix identified from open-loop step
/// tests: `k11`/`k21` are PV1/PV2's response to MV1, `k12`/`k22` are
/// PV1/PV2's response to MV2.
class GainMatrix {
  final double k11;
  final double k12;
  final double k21;
  final double k22;
  final bool converged;
  final String? warning;

  const GainMatrix({
    required this.k11,
    required this.k12,
    required this.k21,
    required this.k22,
    required this.converged,
    this.warning,
  });
}

/// Relative Gain Array result for a 2x2 process: the (1,1) relative gain and
/// a recommended MV/PV pairing derived from it.
class RgaResult {
  final double lambda11;
  final String pairing;
  final String? warning;

  const RgaResult({
    required this.lambda11,
    required this.pairing,
    this.warning,
  });
}

double _asDouble(dynamic v) => v is num ? v.toDouble() : (v == true ? 1.0 : 0.0);

/// Outcome of one settle run: the final PV1/PV2 values and whether steady
/// state was reached before `StepTestParams.maxScans`.
class _Settled {
  final double pv1;
  final double pv2;
  final bool converged;
  const _Settled(this.pv1, this.pv2, this.converged);
}

PlcProject _deepCopy(PlcProject project) => PlcProject.fromJson(
    jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>);

/// Holds MV1 at [mv1] and MV2 at [mv2] on [copy] (advancing [rt]'s per-rule
/// state), scanning `applySimRules` until both PV1 and PV2's per-scan
/// absolute delta fall below `params.settleEps` for `params.settleWindow`
/// consecutive scans, or `params.maxScans` is exhausted without settling.
_Settled _settle(
  PlcProject copy,
  SimRuntime rt, {
  required double mv1,
  required double mv2,
  required String mv1Path,
  required String mv2Path,
  required String pv1Path,
  required String pv2Path,
  required StepTestParams params,
}) {
  var consecutive = 0;
  var prevPv1 = _asDouble(readPath(copy, pv1Path));
  var prevPv2 = _asDouble(readPath(copy, pv2Path));
  for (var scan = 0; scan < params.maxScans; scan++) {
    writePath(copy, mv1Path, mv1);
    writePath(copy, mv2Path, mv2);
    applySimRules(copy, copy.simRules, params.dtMs, rt);

    final pv1 = _asDouble(readPath(copy, pv1Path));
    final pv2 = _asDouble(readPath(copy, pv2Path));
    final d1 = (pv1 - prevPv1).abs();
    final d2 = (pv2 - prevPv2).abs();
    if (d1 < params.settleEps && d2 < params.settleEps) {
      consecutive++;
      if (consecutive >= params.settleWindow) {
        return _Settled(pv1, pv2, true);
      }
    } else {
      consecutive = 0;
    }
    prevPv1 = pv1;
    prevPv2 = pv2;
  }
  return _Settled(prevPv1, prevPv2, false);
}

/// Identifies a 2x2 steady-state process gain matrix by three open-loop step
/// tests, each run on its own fresh deep copy of [project]'s simulated
/// process (with its own [SimRuntime]): hold both MVs at `params.baseMv`
/// (base point), step MV1 alone to `params.baseMv + params.stepDelta` (MV2
/// held at base), then step MV2 alone the same way (MV1 held at base). Each
/// test settles per [StepTestParams] before its PV pair is recorded; the
/// four gains are finite differences from the base point divided by
/// `params.stepDelta`.
///
/// The source [project] is never mutated — every experiment runs against a
/// JSON round-trip deep copy. Deterministic: identical inputs always produce
/// identical results. If any of the three settles hits `params.maxScans`
/// without converging, `converged` is `false` and `warning` explains why.
GainMatrix identifyGainMatrix(
  PlcProject project, {
  required String mv1Path,
  required String mv2Path,
  required String pv1Path,
  required String pv2Path,
  required StepTestParams params,
}) {
  final incomplete = <String>[];

  final base = _settle(
    _deepCopy(project),
    SimRuntime(),
    mv1: params.baseMv,
    mv2: params.baseMv,
    mv1Path: mv1Path,
    mv2Path: mv2Path,
    pv1Path: pv1Path,
    pv2Path: pv2Path,
    params: params,
  );
  if (!base.converged) {
    incomplete.add('base point');
  }

  final mv1Step = _settle(
    _deepCopy(project),
    SimRuntime(),
    mv1: params.baseMv + params.stepDelta,
    mv2: params.baseMv,
    mv1Path: mv1Path,
    mv2Path: mv2Path,
    pv1Path: pv1Path,
    pv2Path: pv2Path,
    params: params,
  );
  if (!mv1Step.converged) {
    incomplete.add('MV1 step');
  }

  final mv2Step = _settle(
    _deepCopy(project),
    SimRuntime(),
    mv1: params.baseMv,
    mv2: params.baseMv + params.stepDelta,
    mv1Path: mv1Path,
    mv2Path: mv2Path,
    pv1Path: pv1Path,
    pv2Path: pv2Path,
    params: params,
  );
  if (!mv2Step.converged) {
    incomplete.add('MV2 step');
  }

  final k11 = (mv1Step.pv1 - base.pv1) / params.stepDelta;
  final k21 = (mv1Step.pv2 - base.pv2) / params.stepDelta;
  final k12 = (mv2Step.pv1 - base.pv1) / params.stepDelta;
  final k22 = (mv2Step.pv2 - base.pv2) / params.stepDelta;

  final converged = incomplete.isEmpty;
  return GainMatrix(
    k11: k11,
    k12: k12,
    k21: k21,
    k22: k22,
    converged: converged,
    warning: converged ? null : 'step test did not settle — increase duration',
  );
}

/// Computes the Relative Gain Array's (1,1) element and a recommended
/// MV/PV pairing for a 2x2 process from its steady-state gain matrix [g].
///
/// `lambda11 = (k11*k22) / det` where `det = k11*k22 - k12*k21`. A
/// near-singular gain matrix (`|det| < 1e-9`) yields `NaN` and a warning
/// instead of a division by ~zero. Otherwise the pairing recommendation is
/// banded on `lambda11`: `>= 0.67` favors the diagonal pairing (low
/// interaction), `(0.33, 0.67)` calls for decoupling, and `<= 0.33` favors
/// the off-diagonal pairing; a `lambda11` outside `[0, 1]` additionally notes
/// the matrix is ill-conditioned.
RgaResult computeRga(GainMatrix g) {
  final det = g.k11 * g.k22 - g.k12 * g.k21;
  if (det.abs() < 1e-9) {
    return const RgaResult(
      lambda11: double.nan,
      pairing: 'N/A',
      warning: 'ill-conditioned (near-singular gain matrix)',
    );
  }

  final lambda11 = (g.k11 * g.k22) / det;

  String pairing;
  if (lambda11 >= 0.67) {
    pairing = 'Diagonal: MV1→PV1, MV2→PV2 (low interaction)';
  } else if (lambda11 > 0.33) {
    pairing = 'Strong interaction — decoupling recommended (diagonal pairing)';
  } else {
    pairing = 'Off-diagonal: MV1→PV2, MV2→PV1';
  }
  if (lambda11 < 0 || lambda11 > 1) {
    pairing = '$pairing — ill-conditioned';
  }

  return RgaResult(lambda11: lambda11, pairing: pairing);
}
