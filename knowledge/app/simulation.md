---
id: knowledge:app/simulation
title: Simulation
domain: app
version: "2026-08"
topics: [sim-rules, rule-runtime, determinism, prng, noise-model, valve-curve, signal-generators]
summary: The eight SimRule behaviors and their per-rule RuleRuntime state, the FNV-1a-seeded xorshift32 PRNG that makes noise/drift/random reproducible from a rule's id (CL-8), valve-curve gain shaping, and the seven SignalGen waveform kinds.
related:
  - knowledge:app/index
  - knowledge:app/scan-engine
  - knowledge:app/tag-model
learnings: [CL-8]
---

# Simulation

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/models/sim_engine.dart`, `noise_model.dart`,
> `valve_curve.dart`, `signal_engine.dart`, `signal_gen.dart`, `docs/measurement-noise.md`,
> `docs/valve-curves.md`, `docs/simulated-test-tags.md`, and `DECISIONS.md` ADR-008.
> **Read this before:** adding or debugging a `SimRule`, reasoning about whether a simulated
> value is reproducible across runs, or working with valve-curve gain shaping or bulk
> `SignalGen` test tags.

---

## 1. The headline rule

**Every source of "randomness" in this engine - noise, drift, and the `random` signal
generator - is a deterministic xorshift32 stream seeded by a stable FNV-1a hash of the
rule's or generator's own `id`; there is no `Random()` or wall-clock entropy anywhere in the
simulation layer.**

```dart
/// Stable FNV-1a hash of [s]. Deliberately NOT Dart's `String.hashCode` (which is
/// not guaranteed stable across runs) - keeps the seed (and the noise sequence)
/// reproducible within a run and across a serialization round-trip.
int _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h == 0 ? 0x1a2b3c4d : h; // xorshift needs a non-zero seed
}
```
(`mobile/lib/models/sim_engine.dart:104-116`)

## 2. `applySimRules` and the eight behaviors

`applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)`
(`sim_engine.dart:138-268`) runs every enabled rule unconditionally each scan (see
[scan-engine.md](./scan-engine.md) §1 for where in the tick). `SimRule.behavior` is a string
switched on eight cases - three more than `DECISIONS.md` ADR-008's original decision text lists
(`pulse`, `ramp`, `integrate`, `delayedSet`, `setWhileCondition` only). **Corrected 2026-08-07:**
`firstOrderLag`, `deadTime`, and `noise` were added later; ADR-008 now carries a dated addendum
noting the three additions (ADRs are historical records, so the original decision text is left
unchanged) - treat the code, plus the addendum, as current:

| Behavior | Semantics |
|---|---|
| `setWhileCondition` | Writes `target = condition`, every scan the condition is (re)evaluated - target tracks the condition live. |
| `delayedSet` | On-delay timer: accumulates `heldMs` while condition is true, sets `target = true` once `heldMs >= delayMs`; drops to `false` and resets `heldMs` the instant the condition goes false. |
| `pulse` | Free-running on/off square wave, gated by condition: alternates phase after `onMs`/`offMs` elapse; a zero/negative phase length flips immediately rather than sticking forever. |
| `ramp` | Moves `target` toward `targetValue` at `ratePerSec * dt * gain`, clamped so it can never overshoot `targetValue`, then clamped to `[minValue, maxValue]`. |
| `integrate` | Unbounded accumulator: `target += ratePerSec * dt * gain`, clamped only to `[minValue, maxValue]` (no `targetValue` ceiling, unlike `ramp`). |
| `firstOrderLag` | Exponential lag toward a source (or a fixed `targetValue` if `sourcePath` is empty): `next = cur + (target - cur) * k`, `k = clamp(dt / tauSec, 0, 1)`. |
| `deadTime` | Pure transport delay: a per-rule FIFO of source samples outputs the sample from `n = round(tauSec / dt)` scans ago; the buffer is capped at 100,000 entries. |
| `noise` | Adds noise + drift to a clean source: `measured = clamp(clean + noise + drift, min, max)`, noise shape selected by `noiseDistribution` (uniform / gaussian / pink). |

`gain` for `integrate`/`ramp` is `_gain(p, rule)` (`sim_engine.dart:130-136`): `1.0` if
`sourcePath` is empty or `refValue == 0`; otherwise `fraction = source / refValue` routed
through the rule's `valveCurve` (§4).

## 3. `RuleRuntime` and the determinism guarantee (CL-8)

**CL-8: Sim-rule noise PRNG is seeded from the rule id - renaming a rule changes its noise
sequence; tests must pin rule ids, not positions or names.**

Each rule's cross-scan state lives in a `RuleRuntime` (`sim_engine.dart:6-17`), created lazily
and keyed by `rule.id` in `SimRuntime.byRuleId` (`sim_engine.dart:19-22`):

```dart
class RuleRuntime {
  int phaseMs = 0;      // pulse: elapsed within current on/off phase
  bool pulseOn = true;  // pulse: current phase is the on-phase
  int heldMs = 0;       // delayedSet: how long the condition has held
  final List<double> delayBuf = <double>[]; // deadTime: FIFO of source samples
  int? noiseState;      // noise: 32-bit xorshift PRNG state, lazily seeded
  int? driftState;          // noise-drift: separate 32-bit xorshift PRNG stream
  double driftValue = 0.0;  // current drift (EMA-filtered wander)
  final List<double> pinkState = List<double>.filled(kPinkStateLen, 0.0); // pink filter memory
}
```

The `noise` PRNG lazily seeds from `_fnv1a(rule.id)` on first use, then advances via a
32-bit xorshift step (`_xorshift32`) each subsequent scan (`sim_engine.dart:234,240,244`). The
**drift** stream is a second, independent PRNG seeded from `'${rule.id}#drift'`
(`sim_engine.dart:253`) specifically so toggling drift on/off never perturbs the noise
sequence. **Only `id` feeds the seed** - `SimRule.name` is never hashed anywhere in
`sim_engine.dart`, so a display-name rename has zero effect on the simulated sequence; only
changing `id` reseeds it.

**Determinism holds** for a fixed project (same rule/generator ids) run against a fixed tick
sequence (same `dtMs` per step): nothing in `sim_engine.dart` or `signal_engine.dart` reads
`Random()` or a wall clock. What *does* change a run's trajectory:

- Changing a `SimRule.id` or `SignalGen.id` (reseeds that rule's/generator's streams from
  their first use onward).
- Changing scan `dtMs`/tick timing - `deadTime`'s buffer depth (`n = round(tauSec/dt)`) and
  `firstOrderLag`'s `k = dt/tauSec` are `dt`-dependent, independent of any PRNG.
- A project switch or other event that resets `RuleRuntime`/`SignalRuntime` state mid-run
  differently than a comparison run (see [scan-engine.md](./scan-engine.md) §9).

```
Wrong:  pin a test's expected noise sequence to a rule's list position or display name.
Correct: pin it to the rule's id - only the id feeds the PRNG seed.
```

## 4. Noise shapes and valve curves

`noise_model.dart` implements three distributions, all mixed with a separately-seeded EMA
drift term (`driftStep`/`driftAlpha`, `noise_model.dart:64-76`, `alpha = dt/(dt+tau)`):

- **uniform**: `(2u - 1) * amplitude` from one draw.
- **gaussian**: Box-Muller from two draws, `sqrt(-2 ln(u1)) * cos(2*pi*u2) * sigma`.
- **pink** (1/f): a Paul Kellet one-pole cascade (7-tap filter state `pinkState`), normalized by
  `kPinkNormalise = 0.5674` - a constant calibrated empirically against the engine's *own*
  xorshift32 white-noise stream (not an idealized white source) so that `amplitude` approximates
  the output's standard deviation, with an inherent +-10-15% finite-sample spread typical of a
  1/f process.

`valve_curve.dart` maps a raw fraction (`source / refValue`) to a gain through one of three
characteristics, applied only to `integrate`/`ramp` rules via `_gain` (§2):

| Curve | Formula | Shape |
|---|---|---|
| `linear` (default/unknown) | `fraction` unchanged, including values outside `[0,1]` | passthrough, numerically identical to pre-feature behavior |
| `equalPercentage` | `(R^f - 1)/(R - 1)`, `R = 50`, `f` clamped `[0,1]` | convex, endpoints `0->0`, `1->1` |
| `quickOpening` | `sqrt(f)`, `f` clamped `[0,1]` | concave, endpoints `0->0`, `1->1` |

## 5. Signal generators

`SignalGen.type` (`mobile/lib/models/signal_gen.dart:7`) supports seven kinds: `ramp | sine |
square | triangle | random | counter | toggle`. `generatedPaths(gens)`
(`signal_engine.dart:15-23`) collects every enabled generator's `targetPath` into a set the
logic write path must treat as read-only (see [scan-engine.md](./scan-engine.md) §1) - a
generator and program logic are never meant to fight over the same tag.

Continuous waveforms (`signalValueAt`, `signal_engine.dart:47-64`) share one phase fraction,
`frac = (((elapsedMs/periodMs) + phase) % 1.0 + 1.0) % 1.0`:

| Type | Value |
|---|---|
| `sine` | `min + span * (0.5 + 0.5*sin(2*pi*frac))` |
| `square` | `frac < 0.5 ? min : max` |
| `triangle` | `min + span * (1 - \|2*frac - 1\|)` |
| `ramp` (default) | `min + span * frac` |

Discrete kinds are computed per **period index** `n = floor(elapsedMs/periodMs + phase)`
(`_periodIndex`, `signal_engine.dart:67-68`):

- `counter`: `(lo + n).clamp(lower, upper)` where `lo/hi` are `min/maxValue.round()`.
- `toggle`: `n.isOdd`.
- `random`: xorshift32 seeded by `FNV1a('${g.id}#$n')` (`signal_engine.dart:27-42`, 91-99) -
  the same FNV-1a/xorshift32 pattern as `noise` (§1, §3), keyed by generator id **and** period
  index, so `random` is reproducible without ever calling `Math.random()`.

---

## What this means practically

### "I renamed a `SimRule` and now my test's expected noise values don't match - why?"
Renaming a rule's display `name` never touches its PRNG seed (§3, CL-8) - if the values
changed, the rule's `id` changed, or its position in a list that a test was incorrectly using
as a stand-in for identity changed.

### "My `integrate` rule barely moves even though `ratePerSec` is set - why?"
Check `sourcePath`/`refValue` (§2, §4): if both are set, the effective rate is scaled by
`gain = valveCurveGain(curve, source/refValue)`, which can be far below `1.0` for a small
`source/refValue` fraction under `equalPercentage` (convex - stays low until near full scale).

### "A `noise` rule's measured value drifts slowly over long runs even with a stable clean source - is that a bug?"
Not necessarily - check `driftAmplitude`/`driftPeriodSec` (§4): a nonzero `driftAmplitude`
adds an independently-seeded, EMA-bounded wander on top of the per-tick noise, by design.

---

## Related

- [scan-engine.md](./scan-engine.md) - where `applySimRules`/`applySignalGens` run in the tick,
  and why their writes are visible to logic in the same scan.
- [tag-model.md](./tag-model.md) - `_write`'s force-check before every `SimRule` write, and the
  `readPath`/`writePath` resolver every rule's condition/target goes through.
- [index.md](./index.md) - domain hub.
