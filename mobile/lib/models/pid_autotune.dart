import 'dart:convert';
import 'dart:math';

import 'project_model.dart';
import 'sim_engine.dart';
import 'tag_resolver.dart';

/// Relative spread (max-min)/mean below which a run of samples is considered
/// "settled" for limit-cycle convergence purposes.
const double _kConvergenceTolerance = 0.05;

/// Inputs to a relay-feedback auto-tune experiment.
class RelayTuneParams {
  final double relayHigh;
  final double relayLow;
  final double hysteresis;
  final double setpoint;
  final int dtMs;
  final int maxScans;
  final int settleCycles;

  const RelayTuneParams({
    required this.relayHigh,
    required this.relayLow,
    required this.hysteresis,
    required this.setpoint,
    required this.dtMs,
    required this.maxScans,
    required this.settleCycles,
  });
}

/// One sample of the relay experiment's trace, for charting/diagnostics.
class TunePoint {
  final double tMs;
  final double pv;
  final double cv;

  const TunePoint({required this.tMs, required this.pv, required this.cv});
}

/// Result of a relay-feedback auto-tune experiment.
class RelayTuneResult {
  final bool converged;
  final double ku;
  final double pu;
  final double amplitude;
  final List<TunePoint> trace;
  final String? warning;

  const RelayTuneResult({
    required this.converged,
    required this.ku,
    required this.pu,
    required this.amplitude,
    required this.trace,
    this.warning,
  });
}

/// A single tuning rule suggestion computed from Ku and Pu.
class TuningSuggestion {
  final String name;
  final String form;
  final double kp;
  final double ki;
  final double kd;

  const TuningSuggestion({
    required this.name,
    required this.form,
    required this.kp,
    required this.ki,
    required this.kd,
  });
}

double _asDouble(dynamic v) => v is num ? v.toDouble() : (v == true ? 1.0 : 0.0);

/// Relative spread of a run of samples: `(max - min) / |mean|`. Returns
/// `double.infinity` when the mean is zero so a zero-mean run never spuriously
/// reads as "settled".
double _relativeSpread(List<double> xs) {
  var maxV = xs.first;
  var minV = xs.first;
  var sum = 0.0;
  for (final x in xs) {
    if (x > maxV) {
      maxV = x;
    }
    if (x < minV) {
      minV = x;
    }
    sum += x;
  }
  final mean = sum / xs.length;
  if (mean == 0) {
    return double.infinity;
  }
  return (maxV - minV) / mean.abs();
}

double _mean(List<double> xs) {
  var sum = 0.0;
  for (final x in xs) {
    sum += x;
  }
  return sum / xs.length;
}

/// Runs a relay-feedback (Åström-Hägglund) auto-tune experiment against a
/// deep copy of [project]'s simulated process, driving [cvPath] with a
/// two-level relay keyed off [pvPath] vs [params.setpoint], and estimates the
/// ultimate gain `Ku` and ultimate period `Pu` from the resulting limit cycle.
///
/// The source [project] is never mutated: the experiment runs entirely on a
/// JSON round-trip deep copy. Every scan of the experiment is recorded in
/// [RelayTuneResult.trace], whether or not the limit cycle converges.
RelayTuneResult relayAutoTune(
  PlcProject project, {
  required String pvPath,
  required String cvPath,
  required RelayTuneParams params,
}) {
  final copy = PlcProject.fromJson(
      jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>);
  final rt = SimRuntime();

  final trace = <TunePoint>[];
  final risingTimesMs = <double>[];
  final peaks = <double>[];
  final troughs = <double>[];

  String? phase; // 'HIGH' | 'LOW'; null until the first sample is taken.
  double extremum = 0.0;
  double t = 0.0;

  for (var scan = 0; scan < params.maxScans; scan++) {
    final pv = _asDouble(readPath(copy, pvPath));

    String desired;
    if (pv < params.setpoint - params.hysteresis) {
      desired = 'HIGH';
    } else if (pv > params.setpoint + params.hysteresis) {
      desired = 'LOW';
    } else {
      desired = phase ?? 'HIGH';
    }

    if (phase == null) {
      // First sample: no prior phase to switch away from.
      phase = desired;
      extremum = pv;
    } else if (desired != phase) {
      // Relay switch event: close out the ending half-cycle's extremum.
      if (phase == 'HIGH') {
        peaks.add(extremum);
      } else {
        troughs.add(extremum);
      }
      if (desired == 'HIGH') {
        risingTimesMs.add(t);
      }
      phase = desired;
      extremum = pv;
    } else {
      extremum = phase == 'HIGH' ? max(extremum, pv) : min(extremum, pv);
    }

    final out = phase == 'HIGH' ? params.relayHigh : params.relayLow;
    writePath(copy, cvPath, out);
    trace.add(TunePoint(tMs: t, pv: pv, cv: out));

    applySimRules(copy, copy.simRules, params.dtMs, rt);
    t += params.dtMs;
  }

  // Pair up successive (peak, trough) half-cycles into full-cycle amplitudes.
  final cycles = min(peaks.length, troughs.length);
  final amplitudes = <double>[
    for (var i = 0; i < cycles; i++) (peaks[i] - troughs[i]).abs() / 2.0,
  ];
  // Period between consecutive rising (LOW->HIGH) switches.
  final periods = <double>[
    for (var i = 1; i < risingTimesMs.length; i++) risingTimesMs[i] - risingTimesMs[i - 1],
  ];

  final settle = params.settleCycles;
  final d = (params.relayHigh - params.relayLow) / 2.0;

  if (periods.length < settle ||
      amplitudes.length < settle ||
      risingTimesMs.length < settle + 1) {
    return RelayTuneResult(
      converged: false,
      ku: 0.0,
      pu: 0.0,
      amplitude: 0.0,
      trace: trace,
      warning: 'relay did not complete $settle full oscillation cycles '
          'within ${params.maxScans} scans (no sustained limit cycle detected)',
    );
  }

  final lastPeriods = periods.sublist(periods.length - settle);
  final lastAmplitudes = amplitudes.sublist(amplitudes.length - settle);
  final periodSpread = _relativeSpread(lastPeriods);
  final amplitudeSpread = _relativeSpread(lastAmplitudes);
  final pu = _mean(lastPeriods);
  final amplitude = _mean(lastAmplitudes);

  if (periodSpread > _kConvergenceTolerance || amplitudeSpread > _kConvergenceTolerance) {
    return RelayTuneResult(
      converged: false,
      ku: 0.0,
      pu: pu,
      amplitude: amplitude,
      trace: trace,
      warning: 'limit cycle has not settled: period spread '
          '${(periodSpread * 100).toStringAsFixed(1)}%, amplitude spread '
          '${(amplitudeSpread * 100).toStringAsFixed(1)}% (want <= '
          '${(_kConvergenceTolerance * 100).toStringAsFixed(0)}%)',
    );
  }

  if (amplitude <= 0) {
    return RelayTuneResult(
      converged: false,
      ku: 0.0,
      pu: pu,
      amplitude: amplitude,
      trace: trace,
      warning: 'measured limit-cycle amplitude is zero; cannot estimate Ku',
    );
  }

  final ku = 4 * d / (pi * amplitude);
  return RelayTuneResult(
    converged: true,
    ku: ku,
    pu: pu,
    amplitude: amplitude,
    trace: trace,
    warning: null,
  );
}

/// Computes six classic PID/PI tuning-rule suggestions from ultimate gain [ku]
/// and ultimate period [pu] (in milliseconds).
///
/// Returns tuning rules from three families (Ziegler-Nichols, Tyreus-Luyben,
/// ZN no-overshoot), each with both PID and PI variants. The engine integrates
/// in seconds, so the period is first converted to seconds: `puS = pu / 1000`.
///
/// For each rule, Ki is computed as `Kp / Ti` (guarded: if `Ti <= 0`, then `Ki = 0`).
/// For PI rules, Kd is always 0. For PID rules, Kd = Kp * Td.
List<TuningSuggestion> tuningRules(double ku, double pu) {
  final puS = pu / 1000.0;

  return [
    // Ziegler-Nichols PID
    _makeTuning(
      name: 'Ziegler-Nichols',
      form: 'PID',
      kp: 0.6 * ku,
      ti: 0.5 * puS,
      td: 0.125 * puS,
    ),
    // Ziegler-Nichols PI
    _makeTuning(
      name: 'Ziegler-Nichols',
      form: 'PI',
      kp: 0.45 * ku,
      ti: 0.833 * puS,
      td: 0.0,
    ),
    // Tyreus-Luyben PID
    _makeTuning(
      name: 'Tyreus-Luyben',
      form: 'PID',
      kp: ku / 2.2,
      ti: 2.2 * puS,
      td: puS / 6.3,
    ),
    // Tyreus-Luyben PI
    _makeTuning(
      name: 'Tyreus-Luyben',
      form: 'PI',
      kp: ku / 3.2,
      ti: 2.2 * puS,
      td: 0.0,
    ),
    // ZN no-overshoot PID
    _makeTuning(
      name: 'ZN no-overshoot',
      form: 'PID',
      kp: 0.2 * ku,
      ti: 0.5 * puS,
      td: puS / 3.0,
    ),
    // ZN no-overshoot PI
    _makeTuning(
      name: 'ZN no-overshoot',
      form: 'PI',
      kp: 0.13 * ku,
      ti: 0.5 * puS,
      td: 0.0,
    ),
  ];
}

/// Helper to construct a TuningSuggestion from name, form, Kp, Ti, and Td.
TuningSuggestion _makeTuning({
  required String name,
  required String form,
  required double kp,
  required double ti,
  required double td,
}) {
  final ki = ti > 0 ? kp / ti : 0.0;
  final kd = kp * td;
  return TuningSuggestion(
    name: name,
    form: form,
    kp: kp,
    ki: ki,
    kd: kd,
  );
}
