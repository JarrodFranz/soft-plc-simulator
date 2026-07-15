# Nonlinear Valve Curves — Design Spec

**Date:** 2026-07-15
**Status:** Approved (design)
**Workstream:** Phase 9, feature 1 of 4 (then: richer noise + sensor drift, PID auto-tune, MIMO coupled plant — each its own spec).

## Goal

Let a Simulated I/O actuator drive its `integrate`/`ramp` rate through a
realistic **nonlinear valve characteristic** — linear, equal-percentage, or
quick-opening — instead of only linear. Fixed standard curve shapes (no tunable
parameter). Additive: a rule with no curve set behaves exactly as today.

## Current behaviour (as-found)

- `SimRule` (`mobile/lib/models/project_model.dart:549`) drives a target tag by
  various behaviours. For `integrate`/`ramp`, an optional **analog gain** scales
  the per-second rate: `_gain` (`mobile/lib/models/sim_engine.dart:123-124`)
  returns `readPath(sourcePath) / refValue` when a `sourcePath` is set (else
  `1.0`). This gain is used at `sim_engine.dart:167` (ramp) and `:181`
  (integrate): `rule.ratePerSec * dt * _gain(p, rule)`.
- So the "valve %" is the raw fraction `source / refValue`, applied **linearly**
  to the rate. `sourcePath` is used differently by `firstOrderLag` (target
  source), `setWhileCondition`, `noise`, and `deadTime` — those must NOT be
  touched.
- The Simulated I/O rule editor is `mobile/lib/screens/simulated_io_screen.dart`.

## Non-goals / YAGNI

- **No tunable curve parameter** — equal-percentage uses a fixed rangeability
  R=50; quick-opening is a fixed square-root. (A future feature can add a
  parameter.)
- No change to `firstOrderLag`/`setWhileCondition`/`noise`/`deadTime`.
- No showcase change to a default project's behaviour in this spec (optional,
  plan-time, guarded by scan-equivalence — see the end).

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. the new
  `models/valve_curve.dart`.
- Additive persistence: `valveCurve` defaults to `'linear'`; a rule with no
  `valve_curve` key loads as linear and is **behaviourally identical** to
  today; the default projects' 20-scan scan-equivalence stays green.
- Deterministic and pure (no clock/`Math.random`).

## Component 1 — Pure curve helper (`mobile/lib/models/valve_curve.dart`)

A Flutter-free unit so the math is unit-testable in isolation.

```dart
import 'dart:math' as math;

/// The three supported valve characteristics.
const String kValveLinear = 'linear';
const String kValveEqualPercentage = 'equalPercentage';
const String kValveQuickOpening = 'quickOpening';

/// Equal-percentage rangeability (fixed, standard).
const double kEqualPercentageR = 50.0;

/// Maps a raw valve fraction (`source / refValue`, typically 0..1) to an
/// effective gain through the selected valve characteristic.
///
/// - `linear` (or any unknown value): returns [fraction] unchanged, including
///   values > 1 or < 0 — numerically identical to the pre-feature behaviour.
/// - `equalPercentage`: fraction clamped to [0,1], then
///   `(R^f - 1) / (R - 1)` with R = 50 — convex (slow open, fast near full);
///   endpoints 0->0, 1->1.
/// - `quickOpening`: fraction clamped to [0,1], then `sqrt(f)` — concave
///   (fast open, then flattens); endpoints 0->0, 1->1.
double valveCurveGain(String curve, double fraction) {
  switch (curve) {
    case kValveEqualPercentage:
      final f = fraction.clamp(0.0, 1.0);
      return (math.pow(kEqualPercentageR, f) - 1) / (kEqualPercentageR - 1);
    case kValveQuickOpening:
      final f = fraction.clamp(0.0, 1.0);
      return math.sqrt(f);
    default: // kValveLinear and any unknown value
      return fraction;
  }
}
```

**Rationale for linear passthrough of out-of-range fractions:** today `_gain`
can exceed 1 (source > refValue) and the rate scales past nominal; preserving
that for `linear` keeps every existing project numerically identical.

## Component 2 — Model field (`SimRule`)

Add a mutable `String valveCurve` field, default `'linear'`:

- Constructor: `this.valveCurve = kValveLinear` (or the literal `'linear'`).
- `fromJson`: `valveCurve: j['valve_curve'] ?? 'linear'`.
- `toJson`: `'valve_curve': valveCurve` (always serialized, matching the file's
  style where all `SimRule` fields are always emitted).

No other model change. A legacy rule (no `valve_curve`) loads as `'linear'`.

## Component 3 — Engine wiring (`sim_engine.dart`)

Change `_gain` to route the fraction through the curve:

```dart
double _gain(PlcProject p, SimRule r) {
  if (r.sourcePath.isEmpty || r.refValue == 0) {
    return 1.0;
  }
  final fraction = _asDouble(readPath(p, r.sourcePath)) / r.refValue;
  return valveCurveGain(r.valveCurve, fraction);
}
```

(Import `valve_curve.dart`.) The `integrate`/`ramp` call sites are unchanged.
For `valveCurve == 'linear'` this returns exactly `fraction` as before, so
`ramp`/`integrate` numerics are byte-identical for every existing rule.

## Component 4 — Editor (`simulated_io_screen.dart`)

In the rule editor, add a **Valve characteristic** dropdown with items
`Linear` / `Equal-percentage` / `Quick-opening` (values `kValveLinear` /
`kValveEqualPercentage` / `kValveQuickOpening`), bound to `rule.valveCurve`.

- **Visibility:** shown only when `rule.behavior` is `'integrate'` or `'ramp'`
  **and** `rule.sourcePath` is non-empty (the analog-gain case where the curve
  has any effect). Hidden otherwise (linear-only paths / no actuator).
- A short helper caption, e.g. "Valve % → flow characteristic (applies to the
  actuator gain)".
- Follows the existing editor's dropdown styling; no layout overflow at
  320/360/1400.

## Data flow

Scan tick → `applySimRules` → for an `integrate`/`ramp` rule with an actuator,
`_gain` reads the actuator, forms the fraction, and passes it through
`valveCurveGain` → scales `ratePerSec * dt`. Editor edits mutate
`rule.valveCurve` in place + the existing autosave. No new runtime state.

## Error handling / edge cases

- Unknown `valveCurve` string → treated as linear (the `default` branch).
- `refValue == 0` or empty `sourcePath` → gain 1.0 (unchanged; curve not
  applied — there is no fraction).
- `fraction < 0` or `> 1` → linear passes through; nonlinear curves clamp the
  input to [0,1] (valve saturates), never NaN.

## Testing

- **Pure (`valve_curve_test`):** linear passthrough (incl. `1.5` and `-0.2`);
  equal-percentage and quick-opening endpoints (`gain(_, 0) == 0`,
  `gain(_, 1) == 1`); monotonic increasing on [0,1]; equal-percentage **convex**
  (`gain(eq, 0.5) < 0.5`); quick-opening **concave** (`gain(qo, 0.5) > 0.5`);
  clamping (`gain(eq, 1.5) == gain(eq, 1.0)`).
- **Engine (`sim_engine` test):** two identical `integrate` rules driven by the
  same actuator at, say, 20% — one `linear`, one `equalPercentage` — over N
  scans: the equal-percentage target accumulates **less** than the linear one
  (slow-open region). A `linear`/unset rule reproduces the exact pre-feature
  accumulation (numeric guard).
- **Round-trip:** `valveCurve` survives `toJson`/`fromJson`; a `SimRule` JSON
  without `valve_curve` loads as `'linear'`; the existing default-projects
  20-scan scan-equivalence round-trip stays green.
- **Widget:** the dropdown appears for an `integrate` rule with an actuator and
  is hidden for a `setWhileCondition` rule (or one with no `sourcePath`); no
  overflow at 320/360/1400; changing it updates `rule.valveCurve`.
- Full green gate: `flutter test`, `flutter analyze`, `flutter build web
  --release`.

## Files

- **Create:** `mobile/lib/models/valve_curve.dart` (pure) + its test.
- **Modify:** `mobile/lib/models/project_model.dart` (SimRule `valveCurve` +
  json), `mobile/lib/models/sim_engine.dart` (`_gain` routes through the
  helper), `mobile/lib/screens/simulated_io_screen.dart` (dropdown).
- **Docs:** extend the Simulated I/O / sim docs + `ROADMAP.md` (Phase 9 note)
  + `README.md` on completion.

## Optional showcase (plan-time call)

Optionally set an existing valve-driven demo (e.g. a tank-fill rule in "Tank
Level Simulation" or "Tank Level PID Control") to `equalPercentage` so the
feature is visible out of the box. This changes that default project's
simulated behaviour, so it must be guarded by the 20-scan scan-equivalence
round-trip and a deliberate re-baseline. Left as a plan-time decision to avoid
silently shifting a default project here.
