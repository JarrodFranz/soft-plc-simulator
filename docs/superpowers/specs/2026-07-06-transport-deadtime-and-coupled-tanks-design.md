# Transport Dead-Time & Coupled Tanks (WS13) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "resume the WS13 process simulation
work"). Design made autonomously, mirroring the WS9 additive-`SimRule`-behaviour
pattern.
**Author:** Claude (pairing with Jarrod)

Extends the process-simulation engine with **transport dead-time** (a delay
line — the classic hard-to-control process element) and a **coupled multi-tank**
showcase, the two most valuable of the remaining Phase 9 items. This makes the
simulator able to pose a realistic control challenge: a process whose response
is delayed, driving one tank from another.

## What's added

### Transport dead-time (new behaviour `deadTime`)
A value follows a **source signal delayed by a dead time** — `out(t) =
source(t − τ_dead)`. This is the pure transport-delay element (a pipe/conveyor):
the output is the source from `τ_dead` seconds ago.
- **Reused `SimRule` fields (no new serialized field):**
  - `sourcePath` — the signal being delayed (the pipe's input). Required; empty
    source ⇒ the rule is inert (writes nothing).
  - `tauSec` — the dead time in seconds (dual-use, exactly like WS9's dual use of
    `sourcePath`: `tauSec` is the *lag time constant* for `firstOrderLag` and the
    *dead time* for `deadTime`).
- **Semantics** (per scan, `dt = dtMs/1000`, condition-gated like the others):
  - Delay length in scans: `n = round(τ_dead / dt)` (≥ 0).
  - A per-rule FIFO buffer of recent source samples is kept in the runtime. Each
    scan pushes the current source value; the output written to `targetPath` is
    the sample from `n` scans ago. Before the buffer holds `n` samples, the
    output is the **oldest** buffered sample (so the output holds the initial
    source value until the delay line fills — no spurious spike).
  - `τ_dead ≤ 0` (⇒ `n = 0`) is a pass-through: `out = source` this scan.
  - Output clamped to `[minValue, maxValue]`; forcing still wins (`_write`).
- **State:** a bounded `List<double>` FIFO in `RuleRuntime`, keyed by `rule.id`
  in `SimRuntime.byRuleId`, cleared on project switch alongside the other
  per-rule state (the shell already clears `byRuleId` at every lifecycle site).
  The buffer is capped so a huge `τ_dead` can't grow it without bound.

### Coupled multi-tank showcase (composition, no new engine mechanism)
Coupling is expressed with the **existing** analog-scaled `integrate`
(`sourcePath`/`refValue` from WS9): one tank's inflow rate is driven by an
upstream signal. Combined with `deadTime` on the transfer line, this yields a
realistic cascade — the downstream tank responds to the upstream one only after
the transport delay.

## Where it plugs in

- **`sim_engine.dart`:** add `case 'deadTime'` to `applySimRules`; extend
  `RuleRuntime` with the FIFO buffer and a small helper. Pure Dart, never throws,
  never hangs (bounded buffer, single pass). Existing behaviours byte-identical.
- **`project_model.dart`:** **no change** — `deadTime` reuses `sourcePath`/
  `tauSec`/`minValue`/`maxValue`, all already serialized. (This keeps the WS6
  round-trip guard structurally unaffected.)
- **`simulated_io_screen.dart`:** add **"Transport Dead-Time"** to the behaviour
  dropdown. When selected, show a **"Delayed source tag"** (`sourcePath` via the
  WS7 `TagAutocompleteField`) and a **"Dead time τ (seconds)"** field (`tauSec`),
  plus min/max — reusing the WS9 conditional-field pattern and the adaptive
  dialog; no overflow at 360/320.

## Showcase — "Cascade Tanks with Transport Delay" (new default project)

A two-tank cascade with a delayed transfer:
- **Tags:** `Feed_Valve` (%, internal — the manipulated inflow, e.g. 60),
  `Tank_A_Level` (%, sim input), `Transfer_Line` (%, internal — the delayed
  transfer signal), `Tank_B_Level` (%, sim input).
- **Simulated I/O:**
  - `Tank_A_Level`: analog-scaled `integrate` inflow driven by `Feed_Valve`
    (`sourcePath: Feed_Valve`, `refValue: 100`) minus a constant outflow, clamped
    0–100.
  - `Transfer_Line`: `deadTime` of `Tank_A_Level` (`sourcePath: Tank_A_Level`,
    `tauSec` a few seconds) — the transport delay of the pipe between the tanks.
  - `Tank_B_Level`: analog-scaled `integrate` inflow driven by `Transfer_Line`
    (`sourcePath: Transfer_Line`, `refValue: 100`) minus a constant outflow,
    clamped 0–100.
- **HMI:** a dashboard with gauges for `Tank_A_Level` and `Tank_B_Level` and a
  display of `Feed_Valve`.
- **Behaviour:** opening `Feed_Valve` raises `Tank_A_Level` immediately, but
  `Tank_B_Level` only begins rising after the dead time — a visible transport
  delay between the two tanks.

## Testing

- **Engine unit tests** (pure): a step on the source appears at the output after
  ≈`τ_dead` (n scans), not before; the output holds the initial value while the
  buffer fills; a ramped source is reproduced delayed; `τ_dead ≤ 0` is a
  pass-through; the buffer is bounded (a very large `τ_dead` doesn't grow memory
  without limit); clamping and forcing hold; existing behaviours are
  byte-identical when the new behaviour is unused; `SimRuntime.byRuleId.clear()`
  resets the delay line.
- **Serialization:** the round-trip guard (structural + 20-scan scan-equivalence
  per default project) stays green — no new serialized field, and the new
  project's dead-time buffer evolves deterministically from fresh state, so it is
  scan-equivalent to its own round-trip.
- **Closed-loop / cascade integration:** in the Cascade Tanks project,
  `Tank_B_Level` **lags** `Tank_A_Level` by ≈the dead time (falsifiable: with a
  zero dead time, or without the `deadTime` rule, `Tank_B` would rise together
  with `Tank_A`).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding. Dark theme; responsive (WS5) with
adaptive dialogs (WS7). `flutter analyze` zero. Engines pure Dart in
`mobile/lib/models` (UI-free); forcing wins; scan-tick clock; never throws/hangs.
Lossless persistence preserved (round-trip guard). No RenderFlex overflow at
360/320/1400. Additions are additive — existing sim behaviours unchanged when the
new behaviour is unused.

## Out of scope (deferred)
- **Measurement noise** — still deferred: it needs a deterministic seeded PRNG
  and separate clean-vs-measured state to avoid a random walk and to keep the
  scan-equivalence round-trip guard green; a workstream of its own.
- Nonlinear valve curves, PID auto-tuning, and full multivariable (MIMO) plant
  models.
