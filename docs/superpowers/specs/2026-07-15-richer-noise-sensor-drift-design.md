# Richer Measurement Noise + Sensor Drift — Design Spec

**Date:** 2026-07-15
**Status:** Approved (design)
**Workstream:** Phase 9, feature 2 of 4 (then: PID auto-tune, MIMO coupled plant).

## Goal

Extend the Simulated I/O `noise` behaviour with (a) a selectable noise
**distribution** — uniform (today) or Gaussian — and (b) an optional slow,
bounded **sensor drift** added to the measurement. Everything stays pure and
deterministic (reuses the seeded xorshift PRNG; no clock / `Math.random`).
Additive: a rule with the defaults behaves byte-identically to today.

## Current behaviour (as-found)

`sim_engine.dart` `noise` branch (lines ~220-233):

```dart
case 'noise':
  if (cond && rule.sourcePath.isNotEmpty) {
    final clean = _asDouble(readPath(p, rule.sourcePath));
    final a = rule.targetValue;                       // ± amplitude
    if (a <= 0) {
      _write(p, rule.targetPath, _clamp(clean, rule.minValue, rule.maxValue));
      break;
    }
    st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
    final u = st.noiseState! / 0xffffffff;            // [0,1]
    final noise = (2 * u - 1) * a;                     // uniform [-a, a]
    _write(p, rule.targetPath, _clamp(clean + noise, rule.minValue, rule.maxValue));
  }
  break;
```

- `st` is the per-rule `RuleRuntime` (has `int? noiseState`). Helpers:
  `_xorshift32(int)`, `_fnv1a(String)`, `_clamp(v, min, max)`, `_write(p, path, v)`.
- Non-accumulating: a fresh uniform draw each scan; deterministic via the
  carried `noiseState`. `rule.targetValue` is the amplitude, `rule.sourcePath`
  the clean source, `rule.targetPath` the measured output.

## Non-goals / YAGNI

- No new PRNG algorithm — reuse `_xorshift32` / `_fnv1a`.
- No per-sample-rate config; drift/noise advance once per scan tick as today.
- No default-project showcase in this spec (optional, plan-time, guarded by
  scan-equivalence — see the end).

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. new
  `models/noise_model.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical seed + inputs →
  identical output; survives a serialization round-trip.
- Additive persistence: defaults (`noiseDistribution == 'uniform'`,
  `driftAmplitude == 0`) reproduce today's exact per-scan sequence; the default
  projects' 20-scan scan-equivalence stays green.

## Component 1 — Pure noise/drift math (`mobile/lib/models/noise_model.dart`)

A Flutter-free unit so the stochastic math is unit-testable. It does NOT own
PRNG state — callers pass in normalized uniforms `u ∈ [0,1]`.

```dart
import 'dart:math' as math;

const String kNoiseUniform = 'uniform';
const String kNoiseGaussian = 'gaussian';

/// Uniform noise in [-amplitude, amplitude] from one uniform draw.
double uniformNoise(double u, double amplitude) => (2 * u - 1) * amplitude;

/// Gaussian (normal) noise with standard deviation [sigma] from two uniform
/// draws, via Box-Muller. Unbounded; the caller clamps the final measurement.
/// u1 is guarded away from 0 so log is finite.
double gaussianNoise(double u1, double u2, double sigma) {
  final r = math.sqrt(-2 * math.log(u1 <= 0 ? 1e-12 : u1));
  return r * math.cos(2 * math.pi * u2) * sigma;
}

/// One EMA low-pass step of a slow, strictly-bounded drift wander.
/// [prev] is the last drift value; [target] is the new white-noise target
/// (in [-amplitude, amplitude]); [alpha] = dt/(dt+tau) in [0,1]. Because the
/// result is a convex blend of `prev` and `target`, if both start in
/// [-amplitude, amplitude] the drift stays in [-amplitude, amplitude] — no
/// runaway, no separate clamp needed. Larger tau (smaller alpha) = slower.
double driftStep(double prev, double target, double alpha) =>
    prev + alpha * (target - prev);

/// alpha for a given scan dt (ms) and drift period/time-constant tau (s).
/// tau <= 0 -> alpha 1.0 (drift tracks the target immediately).
double driftAlpha(int dtMs, double tauSec) {
  final dt = dtMs / 1000.0;
  final tau = tauSec <= 0 ? 0.0 : tauSec;
  return tau <= 0 ? 1.0 : dt / (dt + tau);
}
```

## Component 2 — Model fields (`SimRule`)

Add three mutable fields, all with byte-identical defaults:

- `String noiseDistribution;` — default `'uniform'`; json `noise_dist`;
  `fromJson: j['noise_dist'] ?? 'uniform'`.
- `double driftAmplitude;` — default `0.0`; json `drift_amp`;
  `fromJson: (j['drift_amp'] as num?)?.toDouble() ?? 0.0`.
- `double driftPeriodSec;` — default `60.0`; json `drift_period_sec`;
  `fromJson: (j['drift_period_sec'] as num?)?.toDouble() ?? 60.0`.

All three always serialized in `toJson` (matching the file's always-emit
style). No import of `noise_model.dart` into the model (use string literals for
the default).

## Component 3 — RuleRuntime state (`sim_engine.dart`)

Add two per-rule fields for the drift, seeded/advanced independently of the
noise stream:

```dart
int? driftState;          // 32-bit xorshift PRNG for drift (separate stream)
double driftValue = 0.0;  // current drift (EMA-filtered wander)
```

Reset with the rest of `RuleRuntime` on project switch (`SimRuntime` is cleared
via `resetSession`).

## Component 4 — Engine wiring (`noise` branch)

Rewrite the `noise` branch to compose `clean + noise + drift`:

```dart
case 'noise':
  if (cond && rule.sourcePath.isNotEmpty) {
    final clean = _asDouble(readPath(p, rule.sourcePath));
    final a = rule.targetValue;

    // --- noise term ---
    double noise = 0.0;
    if (a > 0) {
      if (rule.noiseDistribution == kNoiseGaussian) {
        st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
        final u1 = st.noiseState! / 0xffffffff;
        st.noiseState = _xorshift32(st.noiseState!);
        final u2 = st.noiseState! / 0xffffffff;
        noise = gaussianNoise(u1, u2, a);
      } else {
        st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
        final u = st.noiseState! / 0xffffffff;
        noise = uniformNoise(u, a);
      }
    }

    // --- drift term (separate PRNG stream; skipped entirely when off) ---
    double drift = 0.0;
    if (rule.driftAmplitude > 0) {
      st.driftState = _xorshift32(st.driftState ?? _fnv1a('${rule.id}#drift'));
      final ud = st.driftState! / 0xffffffff;
      final target = uniformNoise(ud, rule.driftAmplitude);       // [-A, A]
      st.driftValue = driftStep(st.driftValue, target, driftAlpha(dtMs, rule.driftPeriodSec));
      drift = st.driftValue;
    }

    _write(p, rule.targetPath, _clamp(clean + noise + drift, rule.minValue, rule.maxValue));
  }
  break;
```

Key byte-identity properties:
- `noiseDistribution == 'uniform'` **and** `a > 0`: exactly one `_xorshift32`
  draw and `uniformNoise(u, a) == (2u-1)*a` — the same sequence as today.
- `driftAmplitude == 0`: the drift block never runs, so `driftState`/
  `driftValue` never change and never touch `noiseState` — no perturbation.
- `a <= 0` today short-circuited to `clamp(clean)`; the rewrite yields the same
  (noise 0) — with drift additionally applied only if `driftAmplitude > 0`
  (a deliberate, opt-in superset; a legacy rule has `driftAmplitude == 0` so it
  is unchanged).

## Component 5 — Editor (`simulated_io_screen.dart`, `noise` params)

In `_behaviorParams`, in the `r.behavior == 'noise'` block, add after the
existing amplitude/source fields:

- A **Distribution** `DropdownButtonFormField<String>` (Uniform / Gaussian)
  bound to `r.noiseDistribution` (values `kNoiseUniform` / `kNoiseGaussian`).
- A **Drift amplitude** numeric field (`_numField`) bound to `r.driftAmplitude`.
- A **Drift period (s)** numeric field bound to `r.driftPeriodSec`, shown only
  when `r.driftAmplitude > 0`.

Follow the file's existing dropdown/field styling; no overflow at 320/360/1400.

## Data flow

Scan tick → `applySimRules` → `noise` branch reads `clean`, advances the noise
PRNG (1 draw uniform / 2 draws Gaussian) and, if enabled, the drift PRNG
(1 draw + EMA), writes `clamp(clean + noise + drift)`. Editor edits mutate the
rule in place + autosave. State lives only in `RuleRuntime` (reset on project
switch); nothing new persisted beyond the 3 additive fields.

## Error handling / edge cases

- `a <= 0` → noise term 0 (as today).
- `driftAmplitude == 0` → drift skipped (off).
- `driftPeriodSec <= 0` → `driftAlpha` returns 1.0 (drift tracks its target
  each scan — a fast, still-bounded wander); never divides by zero.
- Gaussian `u1 == 0` → guarded to `1e-12` so `log` is finite (no `-Inf`).
- The final measurement is always `_clamp(min, max)`, bounding Gaussian tails.

## Testing

- **Pure (`noise_model_test`):** `uniformNoise` endpoints (`u=0 -> -a`,
  `u=1 -> a`, `u=0.5 -> 0`); `gaussianNoise` deterministic exact value for a
  fixed `(u1,u2,sigma)` and scales linearly with sigma; over a fixed
  pseudo-sequence the sample mean ≈ 0 and sample std ≈ sigma within tolerance;
  `driftStep` strictly bounded (`|driftStep(p,t,alpha)| <= max(|p|,|t|)` and a
  sequence with targets in `[-A,A]` stays in `[-A,A]`), EMA identity
  (`alpha=1 -> target`, `alpha=0 -> prev`); `driftAlpha` (`tau<=0 -> 1.0`,
  monotonic in tau).
- **Engine:** uniform + no drift reproduces today's exact per-scan sequence
  (numeric byte guard against a pre-feature reference); Gaussian produces a
  different but clamped sequence; with drift on, `|measured − clean|` stays
  `<= a + driftAmplitude` over N scans and the drift component is slow (changes
  by a small bounded step per scan); determinism (same seed → same sequence).
- **Round-trip:** the 3 fields survive `toJson`/`fromJson`; a `SimRule` JSON
  without them loads as `'uniform'`/`0`/`60`; the default projects' 20-scan
  scan-equivalence round-trip stays green.
- **Widget:** the distribution dropdown + drift fields appear for a `noise`
  rule (drift-period field hidden when amplitude 0, shown when > 0); not shown
  for non-noise behaviours; no overflow at 320/360/1400.
- Full green gate: `flutter test`, `flutter analyze`, `flutter build web
  --release`.

## Files

- **Create:** `mobile/lib/models/noise_model.dart` (pure) + its test.
- **Modify:** `mobile/lib/models/project_model.dart` (3 SimRule fields + json),
  `mobile/lib/models/sim_engine.dart` (2 RuleRuntime fields + noise branch),
  `mobile/lib/screens/simulated_io_screen.dart` (3 editor controls).
- **Docs:** extend the noise/Simulated I/O doc + `ROADMAP.md` (Phase 9) +
  `README.md` on completion.

## Optional showcase (plan-time call)

Optionally switch the existing "Noisy Level Measurement" demo's noise rule to
`gaussian` and give it a small `driftAmplitude`, so the richer model is visible
out of the box. This changes that default project's simulated sequence, so it
must be guarded by the 20-scan scan-equivalence round-trip and a deliberate
re-baseline. Left as a plan-time decision to avoid silently shifting a default
project here.
