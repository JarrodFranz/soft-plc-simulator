# Measurement Noise: Distribution + Drift

A `noise` Simulated I/O rule turns a clean source tag into a jittery
"measured" reading — modeling a real sensor whose instantaneous reading
never exactly matches the true process value. This doc covers the
selectable **noise distribution** (uniform, Gaussian, or pink/1-over-f) and
the optional **bounded drift** (a slow sensor-bias wander) added on top of
the original deterministic bounded-noise feature.

Implementation: `mobile/lib/models/noise_model.dart` (the pure noise/drift
math), `mobile/lib/models/sim_engine.dart` (the `noise` branch of the scan
loop), `mobile/lib/models/project_model.dart` (`SimRule.noiseDistribution` /
`driftAmplitude` / `driftPeriodSec`), and
`mobile/lib/screens/simulated_io_screen.dart` (the rule editor's
Distribution / Drift amplitude / Drift period controls).

## Background: bounded deterministic noise

A `noise` rule reads a **clean source tag** (`SimRule.sourcePath`) each
scan and writes a noisy measurement to its **target tag**
(`SimRule.targetPath`):

```
measured = clamp(clean + noise + drift, minValue, maxValue)
```

The noise term is generated from a 32-bit xorshift PRNG seeded from a hash
of the rule's `id`, so the same project always reproduces the same noise
sequence run to run (deterministic — not wall-clock random). `noise + drift`
is always bounded before the final clamp, so a `noise` rule can never write
a measurement further from the clean value than its configured amplitude
allows.

## Noise distribution

`SimRule.noiseDistribution` selects the shape of the per-scan noise term
drawn from the amplitude (`SimRule.targetValue`, labeled **"Noise amplitude
(±)"** in the editor):

| Distribution | id / json (`noise_dist`) | Shape |
|---|---|---|
| **Uniform** (default) | `uniform` | One draw, flat across `[-amplitude, +amplitude]`. Matches the noise sequence shipped before this feature — existing projects are unaffected. |
| **Gaussian** | `gaussian` | Two draws combined via Box-Muller into a normal distribution with standard deviation `amplitude`; unbounded before the final measurement clamp, so most samples cluster near the clean value with occasional larger excursions — a closer match to real sensor noise than a flat uniform spread. |
| **Pink (1/f)** | `pink` | One draw, filtered through a one-pole cascade so the noise's energy falls off with frequency; standard deviation `amplitude`. See [Pink (1/f) noise](#pink-1f-noise) below. |

The pure helpers live in `noise_model.dart`:

```dart
double uniformNoise(double u, double amplitude) => (2 * u - 1) * amplitude;

double gaussianNoise(double u1, double u2, double sigma) {
  final r = math.sqrt(-2 * math.log(u1 <= 0 ? 1e-12 : u1));
  return r * math.cos(2 * math.pi * u2) * sigma;
}
```

Choosing `uniform` with no drift reproduces the exact per-scan sequence the
engine produced before this feature shipped — a byte-identical guard so
every project authored before richer noise/drift existed keeps simulating
exactly as it always has.

## Pink (1/f) noise

Uniform and Gaussian noise are both **white**: each scan's sample is drawn
independently of the last, so the jitter is memoryless — it has no memory
of where it just was. Real instrument and process noise usually isn't like
that. It tends to be **1/f** ("one-over-f", or "pink"): its energy falls off
as frequency rises, so instead of jittering independently every scan, the
signal wanders on longer timescales — slow, correlated meander layered
under whatever fast jitter is also present. Selecting **Pink (1/f)** in the
Distribution dropdown models that behaviour.

`amplitude` (`SimRule.targetValue`, the "Noise amplitude (±)" field) means
the same thing for pink as it does for Gaussian: the output's **standard
deviation**, not a hard bound. That keeps magnitude comparable across
distributions — switching a rule between Gaussian and Pink at the same
amplitude keeps roughly the same spread, only the time-correlation changes.
(As with Gaussian, the final measurement is still clamped to `[minValue,
maxValue]`, so a rule can never write further than that regardless of
distribution.)

Pink noise composes with **drift** exactly like the other two
distributions — drift is a separate, independent term added on top
(`measured = clamp(clean + noise + drift, minValue, maxValue)`), so a rule
can have pink measurement jitter *and* a slow sensor-bias wander at the
same time.

It's deterministic like the rest of the noise model: each rule owns its own
filter state, seeded from the rule's `id` (the same FNV-1a-hashed xorshift
stream that drives the other distributions), so a project and its
serialized round-trip reproduce the identical pink sequence.

### Implementation

Pink noise is generated with a **Paul Kellet one-pole filter cascade** — a
standard, cheap approximation of a true 1/f spectrum built from seven
first-order low-pass-ish stages combined with the raw white input:

```dart
const int kPinkStateLen = 7;

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
```

Every pole coefficient has magnitude below 1, so the cascade is
unconditionally stable — it cannot diverge regardless of how long a rule
runs. The raw cascade output isn't unit-amplitude, so it's scaled by a
derived normalisation constant (`kPinkNormalise`, ~1.015) so that, for white
input uniform in `[-1, 1]`, the result's standard deviation is ~1.0 —
making `amplitude` mean the output's standard deviation, matching
Gaussian's `sigma`:

```dart
double pinkNoise(List<double> b, double u, double amplitude) =>
    pinkStep(b, 2 * u - 1) * kPinkNormalise * amplitude;
```

The per-rule filter state (`b`, `kPinkStateLen` = 7 slots) lives in the
engine's `RuleRuntime.pinkState`, mirroring how the other per-rule runtime
state (dead-time buffers, drift value, etc.) is cleared on project switch.

## Sensor drift (slow bounded wander)

`SimRule.driftAmplitude` adds a second, independent noise stream that
models a slowly wandering sensor bias — e.g. calibration creep — separate
from the fast per-scan jitter above:

- **Drift amplitude** (`driftAmplitude`, default `0.0`): the bound of the
  drift term, in the same units as the target tag. `0` (the default)
  disables drift entirely — the rule behaves exactly as it did before this
  feature.
- **Drift period (s)** (`driftPeriodSec`, default `60.0`, only shown/used
  when `driftAmplitude > 0`): the drift's time-constant — how quickly the
  wander tracks a new random target. A short period drifts quickly; a long
  period wanders slowly and smoothly.

Each scan (only while `driftAmplitude > 0`), the engine draws a new random
drift *target* within `[-driftAmplitude, +driftAmplitude]` from its own
PRNG stream (seeded independently of the fast-noise stream, so turning
drift on or off never perturbs the fast-noise sequence), then blends the
current drift value toward that target with a low-pass (EMA) step:

```dart
double driftStep(double prev, double target, double alpha) =>
    prev + alpha * (target - prev);

double driftAlpha(int dtMs, double tauSec) {
  final dt = dtMs / 1000.0;
  final tau = tauSec <= 0 ? 0.0 : tauSec;
  return tau <= 0 ? 1.0 : dt / (dt + tau);
}
```

Because this is a convex blend (`alpha` in `[0, 1]`) of the previous drift
value and a target that is itself always within
`[-driftAmplitude, +driftAmplitude]`, the drift value stays within that
same bound by construction — no separate clamp is needed beyond the final
measurement clamp shared with the noise term.

## Model and persistence

The three fields are additive on `SimRule`, defaulting to today's
pre-feature behaviour:

```dart
class SimRule {
  ...
  String noiseDistribution; // 'uniform' | 'gaussian' | 'pink'
  double driftAmplitude;
  double driftPeriodSec;
  ...
  SimRule({..., this.noiseDistribution = 'uniform', this.driftAmplitude = 0.0,
      this.driftPeriodSec = 60.0, ...});

  factory SimRule.fromJson(Map j) => SimRule(
    ...
    noiseDistribution: j['noise_dist'] ?? 'uniform',
    driftAmplitude: (j['drift_amp'] as num?)?.toDouble() ?? 0.0,
    driftPeriodSec: (j['drift_period_sec'] as num?)?.toDouble() ?? 60.0,
    ...
  );

  Map toJson() => {
    ...
    'noise_dist': noiseDistribution,
    'drift_amp': driftAmplitude,
    'drift_period_sec': driftPeriodSec,
  };
}
```

A project saved before these fields existed has none of the three JSON
keys; `fromJson`'s fallbacks mean an absent project round-trips to
`uniform` / `0.0` / `60.0` — uniform noise with drift off, identical to the
rule's behaviour before this feature.

## Editor

The Simulated I/O rule editor shows, only for a `noise`-behaviour rule and
after the existing "Clean source tag" / "Noise amplitude (±)" / Min / Max
fields:

- A **Distribution** dropdown (Uniform / Gaussian / Pink (1/f)) bound to
  `noiseDistribution`.
- A **Drift amplitude** field bound to `driftAmplitude`.
- A **Drift period (s)** field bound to `driftPeriodSec`, shown only while
  `driftAmplitude > 0` — leaving the amplitude at its default `0` keeps the
  editor uncluttered and drift fully disabled.

None of these three controls appear for any non-`noise` behaviour.
