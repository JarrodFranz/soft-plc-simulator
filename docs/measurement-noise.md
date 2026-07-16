# Measurement Noise: Distribution + Drift

A `noise` Simulated I/O rule turns a clean source tag into a jittery
"measured" reading — modeling a real sensor whose instantaneous reading
never exactly matches the true process value. This doc covers the
selectable **noise distribution** (uniform vs Gaussian) and the optional
**bounded drift** (a slow sensor-bias wander) added on top of the original
deterministic bounded-noise feature.

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
  String noiseDistribution; // 'uniform' | 'gaussian'
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

- A **Distribution** dropdown (Uniform / Gaussian) bound to
  `noiseDistribution`.
- A **Drift amplitude** field bound to `driftAmplitude`.
- A **Drift period (s)** field bound to `driftPeriodSec`, shown only while
  `driftAmplitude > 0` — leaving the amplitude at its default `0` keeps the
  editor uncluttered and drift fully disabled.

None of these three controls appear for any non-`noise` behaviour.
