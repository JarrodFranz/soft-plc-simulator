import 'dart:math' as math;

const String kNoiseUniform = 'uniform';
const String kNoiseGaussian = 'gaussian';

/// Uniform noise in [-amplitude, amplitude] from one uniform draw.
double uniformNoise(double u, double amplitude) => (2 * u - 1) * amplitude;

/// Gaussian (normal) noise with standard deviation [sigma] from two uniform
/// draws, via Box-Muller. Unbounded; the caller clamps the final measurement.
/// [u1] is guarded away from 0 so log is finite.
double gaussianNoise(double u1, double u2, double sigma) {
  final r = math.sqrt(-2 * math.log(u1 <= 0 ? 1e-12 : u1));
  return r * math.cos(2 * math.pi * u2) * sigma;
}

/// One EMA low-pass step of a slow, strictly-bounded drift wander.
/// A convex blend of [prev] and [target]; if both start in
/// [-amplitude, amplitude] the drift stays in [-amplitude, amplitude].
double driftStep(double prev, double target, double alpha) =>
    prev + alpha * (target - prev);

/// alpha = dt/(dt+tau) for a given scan dt (ms) and drift time-constant tau (s).
/// tau <= 0 -> alpha 1.0 (drift tracks the target immediately).
double driftAlpha(int dtMs, double tauSec) {
  final dt = dtMs / 1000.0;
  final tau = tauSec <= 0 ? 0.0 : tauSec;
  return tau <= 0 ? 1.0 : dt / (dt + tau);
}
