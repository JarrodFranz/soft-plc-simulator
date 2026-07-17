import 'dart:math' as math;

const String kNoiseUniform = 'uniform';
const String kNoiseGaussian = 'gaussian';
const String kNoisePink = 'pink';

/// Filter-state slots a pink generator needs (Kellet b0..b6).
const int kPinkStateLen = 7;

/// Scales the raw Kellet output so that, for white input uniform in [-1,1],
/// the result's standard deviation is ~1.0 — making `amplitude` mean the
/// output's standard deviation, matching [gaussianNoise]'s sigma.
/// Derived empirically: running [pinkStep] over 20000 samples of the
/// engine's OWN white stream (xorshift32, as used by `applySimRules` in
/// sim_engine.dart, fed through `2u-1`) gives a raw output standard
/// deviation `s` ~= 1.7625, so kPinkNormalise = 1/s ~= 0.5674. (A prior
/// version of this constant, 1.015, was calibrated against a test helper
/// that produced a spectrally non-white sawtooth ramp rather than true
/// white noise; the Kellet cascade is low-pass weighted and heavily
/// attenuates that band, which understated the raw std and produced a
/// constant that made pink output ~79% wider than `amplitude`.)
///
/// Calibrated once against a representative seed: a given rule's realised
/// standard deviation lands within roughly ±10-15% of `amplitude` depending
/// on the seed its id hashes to. That spread is the finite-sample variance
/// inherent to a 1/f process (most of its energy sits at low frequencies, so
/// a finite run's measured spread wanders more than white noise's would), not
/// a calibration error. `amplitude` is the nominal spread, not a guarantee.
const double kPinkNormalise = 0.5674;

/// Advances the Paul Kellet one-pole cascade one step. [b] is the
/// [kPinkStateLen]-element filter state (mutated in place); [w] is white noise
/// in [-1,1]. Returns the RAW pink sample (before normalisation). All poles
/// have |coefficient| < 1, so the cascade is stable and cannot diverge.
double pinkStep(List<double> b, double w) {
  b[0] = 0.99886 * b[0] + w * 0.0555179;
  b[1] = 0.99332 * b[1] + w * 0.0750759;
  b[2] = 0.96900 * b[2] + w * 0.1538520;
  b[3] = 0.86650 * b[3] + w * 0.3104856;
  b[4] = 0.55000 * b[4] + w * 0.5329522;
  b[5] = -0.7616 * b[5] - w * 0.0168980;
  final pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362;
  b[6] = w * 0.115926;
  return pink;
}

/// Pink (1/f) noise normalised so the output's standard deviation ≈
/// [amplitude]. [u] is one uniform draw in [0,1]; [b] is the per-rule filter
/// state (mutated in place).
double pinkNoise(List<double> b, double u, double amplitude) =>
    pinkStep(b, 2 * u - 1) * kPinkNormalise * amplitude;

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
