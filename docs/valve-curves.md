# Nonlinear Valve Curves

Selectable valve characteristics for an `integrate`/`ramp` Simulated I/O
rule's actuator gain — the same analog-scaled-rate feature Phase 9 shipped
(an optional `sourcePath` + `refValue` tag pair proportionally driving the
rule's per-second rate), now with a choice of *how* that proportional drive
maps onto rate instead of always being a straight line.

Implementation: `mobile/lib/models/valve_curve.dart` (the pure curve
function + the three curve-id constants), `mobile/lib/models/sim_engine.dart`
(`_gain`, which routes the actuator fraction through the curve),
`mobile/lib/models/project_model.dart` (`SimRule.valveCurve`), and
`mobile/lib/screens/simulated_io_screen.dart` (the rule editor's "Valve
characteristic" dropdown).

## Background: the actuator fraction

An `integrate`/`ramp` rule can already be driven by an actuator tag instead
of a fixed rate: when `SimRule.sourcePath` is non-empty and `SimRule.refValue`
is non-zero, the rule's effective per-second rate is scaled by

```
fraction = readPath(sourcePath) / refValue
```

— e.g. a `refValue` of `100` and a `sourcePath` reading `40` yields a
`fraction` of `0.4`, so the rule runs at 40% of its configured
`ratePerSec`. This models a PLC analog output (a valve-position or
damper-position signal) proportionally driving a physical rate — a real
closed-loop actuator, not a shortcut. Leaving `sourcePath` empty (or
`refValue` at `0`) disables scaling entirely; the rule runs at its fixed
`ratePerSec`, exactly as before this feature and before valve curves
existed.

## The valve characteristic

Every real control valve's *installed* flow-vs-position relationship is
rarely a straight line — most industrial valves are selected for one of a
small number of standard characteristic curves. `SimRule.valveCurve` picks
which curve transforms the raw `fraction` above into the actual gain applied
to the rate:

| Curve | id / json (`valve_curve`) | Formula | Shape |
|---|---|---|---|
| **Linear** (default) | `linear` | `f` (passthrough) | Straight line; gain tracks position 1:1. |
| **Equal-percentage** | `equalPercentage` | `(50^f − 1) / 49` | Convex — slow response at low position, opens increasingly fast near full travel. Endpoints `0→0`, `1→1`. |
| **Quick-opening** | `quickOpening` | `sqrt(f)` | Concave — fast response at low position, then flattens out approaching full travel. Endpoints `0→0`, `1→1`. |

The pure helper is `valveCurveGain(String curve, double fraction)` in
`mobile/lib/models/valve_curve.dart`:

```dart
double valveCurveGain(String curve, double fraction) {
  switch (curve) {
    case kValveEqualPercentage:
      final f = fraction.clamp(0.0, 1.0);
      return (math.pow(kEqualPercentageR, f) - 1) / (kEqualPercentageR - 1);
    case kValveQuickOpening:
      final f = fraction.clamp(0.0, 1.0);
      return math.sqrt(f);
    default:
      return fraction;
  }
}
```

- **`linear` (or any unrecognized value) passes `fraction` through
  unchanged** — including values outside `[0,1]` (an actuator reading above
  its `refValue`, or a negative reading). This is deliberate: it keeps
  `linear` numerically byte-identical to the pre-curve analog-scaled-rate
  behaviour, so every project authored before this feature shipped continues
  to simulate exactly as it always has.
- **`equalPercentage` and `quickOpening` clamp `fraction` to `[0,1]`** before
  applying their curve — an actuator signal beyond its reference range maps
  to the curve's `0`/`1` endpoint rather than extrapolating past it, which
  would produce non-physical (e.g. negative, or `>1` compounding) gains for
  these particular formulas.

`sim_engine.dart`'s `_gain` calls this helper as the last step of computing
the rule's scaling factor:

```dart
double _gain(PlcProject p, SimRule r) {
  if (r.sourcePath.isEmpty || r.refValue == 0) {
    return 1.0;
  }
  final fraction = _asDouble(readPath(p, r.sourcePath)) / r.refValue;
  return valveCurveGain(r.valveCurve, fraction);
}
```

A rule with no actuator (`sourcePath` empty or `refValue == 0`) never
reaches the curve at all — it still returns a flat `1.0` gain, so a
non-actuated `integrate`/`ramp` rule is completely unaffected by this
feature regardless of its `valveCurve` value.

## Model and persistence

`SimRule.valveCurve` is an additive `String` field, default `'linear'`,
serialized as `valve_curve`:

```dart
class SimRule {
  ...
  String valveCurve; // 'linear' | 'equalPercentage' | 'quickOpening'
  ...
  SimRule({..., this.valveCurve = 'linear', ...});

  factory SimRule.fromJson(Map j) => SimRule(
    ...
    valveCurve: j['valve_curve'] ?? 'linear',
    ...
  );

  Map toJson() => {
    ...
    'valve_curve': valveCurve,
  };
}
```

A project saved before this field existed has no `valve_curve` key at all;
`fromJson`'s `?? 'linear'` fallback means an absent key round-trips to the
`linear` default — the same passthrough behaviour those rules always had.
Nothing else about `SimRule`'s shape changed.

## Editor

The Simulated I/O rule editor shows a **Valve characteristic** dropdown
(Linear / Equal-percentage / Quick-opening) only when both conditions hold:

- the rule's behaviour is `integrate` or `ramp`, **and**
- the rule has an actuator configured (`sourcePath` is non-empty).

A rule with no actuator, or a `pulse`/`delayedSet`/`setWhileCondition`/
`firstOrderLag`/`deadTime`/`noise` rule, never shows the dropdown — the
curve only has meaning where the analog-scaled-rate gain applies.
