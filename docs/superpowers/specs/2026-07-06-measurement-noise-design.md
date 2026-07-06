# Measurement Noise (WS14) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "pick up measurement noise"). Design
made autonomously; the two design questions WS9 flagged (drift and determinism)
are resolved below.
**Author:** Claude (pairing with Jarrod)

Adds sensor **measurement noise** to the Simulated I/O engine — the last of the
Phase 9 process-realism items. A measured tag reads its clean process value plus
bounded random noise, so a PLC program sees a realistic noisy signal (and can, in
turn, filter it with the existing `firstOrderLag`).

## The two problems WS9 flagged, and how this resolves them

### 1. Random-walk drift → use a source→target (clean-vs-measured) rule
Adding noise **in place** (`tag = tag + noise` each scan) accumulates into a
random walk that corrupts the true value. Instead, `noise` is a **source→target**
behaviour (exactly like `deadTime`): the *clean* process value lives in one tag
(driven by the other sim rules / control loop), and the noise rule writes
`measured = clean + noise` to a **separate** tag, recomputed fresh from the clean
source every scan. Non-accumulating ⇒ no drift; the measured value stays within
±amplitude of the clean value forever.

### 2. Non-determinism → a stable seeded PRNG (round-trip-safe)
`Math.random()` would make a project and its serialized round-trip diverge,
breaking the WS6 20-scan scan-equivalence guard. Instead each `noise` rule owns a
small deterministic PRNG (xorshift32) whose seed is a **stable FNV-1a hash of
`rule.id`** (not Dart's per-run `String.hashCode`). The PRNG state lives in
`RuleRuntime` (fresh per `SimRuntime`, cleared on project switch) and advances one
step per active scan. Because equal `rule.id`s yield equal seeds within a run,
the original and round-tripped projects produce the **identical** noise sequence
⇒ scan-equivalent. (Across separate app sessions the sequence may differ — which
is fine and even desirable for a sim; only within-run determinism matters for the
guard.)

## The behaviour

A new Simulated I/O behaviour `type: 'noise'`, reusing existing `SimRule` fields
(**no new serialized field**, mirroring `deadTime`):
- `sourcePath` — the **clean** source tag being measured (required; empty ⇒ inert).
- `targetValue` — the noise **amplitude** `A` (dual-use, documented — like
  `tauSec`'s dual use for lag vs dead time). The noise is uniform in `[−A, +A]`.
- `minValue`/`maxValue` — clamp the measured output.
- **Semantics per scan** (condition-gated like the others):
  - `clean = readPath(sourcePath)`; advance the PRNG once; `u ∈ [0,1)`;
    `noise = (2u − 1) · A`; `measured = clamp(clean + noise, minValue, maxValue)`;
    `_write(targetPath, measured)` (force-aware).
  - `A ≤ 0` ⇒ pass-through (`measured = clamp(clean)`), PRNG still advances (cheap,
    keeps behaviour uniform) — or is skipped; pick one and test it.
  - Uniform (bounded) noise is chosen over Gaussian so the output is strictly
    bounded by the clamp and can't emit rare huge spikes; Gaussian/band-limited
    noise is a future option.
- **State** in `RuleRuntime`: a 32-bit PRNG state `int`, lazily seeded from
  `fnv1a(rule.id)` (forced non-zero), keyed by `rule.id` in `SimRuntime.byRuleId`,
  cleared on project switch alongside the other per-rule state.

## Where it plugs in

- **`sim_engine.dart`:** add `case 'noise'` to `applySimRules`; extend
  `RuleRuntime` with the PRNG state; add small pure helpers `_fnv1a(String)` and
  a xorshift step. Pure Dart, never throws, never hangs (single step per scan).
  Existing behaviours byte-identical.
- **`project_model.dart`:** **no change** — `noise` reuses `sourcePath`/
  `targetValue`/`minValue`/`maxValue`, all already serialized.
- **`simulated_io_screen.dart`:** add **"Measurement Noise"** to the behaviour
  dropdown; when selected show a **"Clean source tag"** (`sourcePath` via
  `TagAutocompleteField`) and a **"Noise amplitude (±)"** field (`targetValue`),
  plus min/max — reusing the WS9 conditional-field pattern + adaptive dialog; no
  overflow at 360/320.

## Showcase — "Noisy Level Measurement" (new default project)

Demonstrates clean-vs-measured and (optionally) filtering:
- **Tags:** `Fill_Valve` (%, internal, e.g. 55), `Tank_Level` (%, sim input — the
  **clean** true level), `Level_Meas` (%, sim input — the **noisy** sensor
  reading), `Level_Filtered` (%, sim input — a smoothed reading).
- **Simulated I/O:**
  - `Tank_Level`: analog-scaled `integrate` from `Fill_Valve` minus a constant
    outflow, clamped 0–100 (a smooth true level).
  - `Level_Meas`: `noise` of `Tank_Level` (`sourcePath:'Tank_Level'`,
    `targetValue:` a few percent, clamp 0–100) — the raw noisy measurement.
  - `Level_Filtered`: `firstOrderLag` of `Level_Meas` (`sourcePath:'Level_Meas'`,
    a modest `tauSec`) — showing the existing lag block smoothing the noise.
- **HMI:** gauges/trends for `Tank_Level` (true), `Level_Meas` (noisy),
  `Level_Filtered` (smoothed).
- **Behaviour:** `Level_Meas` jitters around the smooth `Tank_Level` within the
  amplitude band; `Level_Filtered` tracks the trend with the jitter attenuated.

## Testing

- **Engine unit tests** (pure): the measured output stays within `[clean−A,
  clean+A]` (bounded); it **varies** scan-to-scan (not constant) yet does **not
  drift** — over many scans with a fixed clean source, `|measured − clean|` never
  exceeds `A` (a random-walk/in-place bug would grow it); **determinism** — two
  runs of the same rule (fresh `SimRuntime` each) produce the identical measured
  sequence, and a differing `rule.id` produces a different sequence; `A ≤ 0` ⇒
  pass-through; clamp and forcing hold; existing behaviours byte-identical when
  unused; `SimRuntime.byRuleId.clear()` restarts the PRNG (same seed ⇒ same
  sequence again).
- **Serialization:** the round-trip guard (structural + 20-scan scan-equivalence
  per default project) stays green — no new serialized field, and the seeded PRNG
  is scan-equivalent to its own round-trip (the crux; a unit test asserts the
  new project's 20-scan trace equals its round-trip's).
- **Showcase integration:** in the Noisy Level project, `Tank_Level` is smooth,
  `Level_Meas` jitters within the band around it (varies but bounded, no drift),
  and `Level_Filtered` has a smaller scan-to-scan variance than `Level_Meas`
  (the filter attenuates the noise) — falsifiable.
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding. Dark theme; responsive (WS5) with
adaptive dialogs (WS7). `flutter analyze` zero. Engines pure Dart in
`mobile/lib/models` (UI-free); forcing wins; scan-tick clock; never throws/hangs.
Lossless persistence preserved (round-trip guard). No RenderFlex overflow at
360/320/1400. Additive — existing behaviours unchanged when `noise` is unused.

## Out of scope (deferred)
- Gaussian / band-limited / 1-f (pink) noise, and per-sensor drift/bias — the
  uniform bounded model is the v1.
- Auto-tune, nonlinear valve curves, and full MIMO plant models.
