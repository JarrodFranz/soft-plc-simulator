# Advanced Process Simulation (WS9) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "keep building app side"). Roadmap
Phase 9. Design decisions made autonomously.
**Author:** Claude (pairing with Jarrod)

The Simulated I/O engine (WS3) drives inputs with on/off behaviours
(`pulse`/`ramp`/`integrate`/`delayedSet`/`setWhileCondition`) at a **fixed**
rate. Real process training needs **analog** dynamics: a valve % that
proportionally sets flow, and values that respond with realistic **lag** rather
than instant/linear change. This workstream adds those, so a PLC program can
close a real analog loop against the simulator.

## What's added (two clean, composable mechanisms)

### 1. Analog-scaled rate (for `integrate` and `ramp`)
An optional **driving tag** scales the per-second rate. New `SimRule` fields:
- `sourcePath` (String, default `''`) — a tag whose value modulates the rate.
- `refValue` (double, default `100.0`) — the source value that means "full rate".

When `sourcePath` is set, the effective rate is
`ratePerSec × (source / refValue)` (unscaled when `sourcePath` is empty or
`refValue == 0`). So a `Fill_Valve_Pct` at 50 gives half the fill rate; at 0,
none; at 100, full. Negative sources give reverse flow. The value is still
clamped to `[minValue, maxValue]`. This is the enabler for analog control (a PID
or analog output actually modulates the process).

### 2. First-order lag (new behaviour `firstOrderLag`)
A value approaches a **target** with a time constant, the classic first-order
response of temperature/pressure/level:
`pv += (target − pv) × min(1, dt / tauSec)`, then clamp.
- New field `tauSec` (double, default `5.0`) — the time constant (seconds).
- Target = `readPath(sourcePath)` when `sourcePath` is set, else the fixed
  `targetValue`. `tauSec <= 0` snaps straight to target.
- Condition-gated like the others (empty condition = always active).

Both are **additive**: existing behaviours are unchanged (analog scaling only
kicks in when `sourcePath` is set; `firstOrderLag` is a new behaviour). Forcing
still wins; per-second rates and clamping unchanged. No new runtime state needed
(the mechanisms are memoryless beyond the tag value itself).

## Model & serialization
Add `sourcePath`, `refValue`, `tauSec` to `SimRule` (+ `toJson`/`fromJson` with
back-compat defaults on read: `source: ''`, `ref_value: 100.0`, `tau_sec: 5.0`).
The WS6 serialization round-trip + 20-scan scan-equivalence per default project
must stay green (new fields round-trip; behaviour is a superset).

## Editor UI (`simulated_io_screen.dart`)
The rule editor's behaviour dropdown gains **"First-Order Lag"**. When the
behaviour is `integrate`/`ramp`, show an optional **"Rate driven by tag"** field
(`sourcePath` via the WS7 `TagAutocompleteField`) + a "100% at" value
(`refValue`). When `firstOrderLag`, show **Time constant τ (s)** (`tauSec`),
**Target** (`targetValue`) with an optional **"Target from tag"**
(`sourcePath`), and min/max. Reuse the existing adaptive dialog + responsive
layout; no overflow at 360/320.

## Showcase — realistic closed-loop thermal (proj_st_reactor)
Upgrade the reactor's temperature simulation from fixed-rate integrate to a
proper thermal model so the ST deadband controller closes a **realistic** loop:
- **Ambient pull** (always): `firstOrderLag` of `Temp_PV` toward `Temp_Ambient`
  (a modest τ) — temperature drifts toward ambient with no actuation.
- **Heating** (while `Heat_Cmd`): `integrate` `Temp_PV` up at a heat rate.
- **Cooling** (while `Cool_Cmd`): `integrate` `Temp_PV` down at a cool rate.
Net effect: a first-order thermal process the reactor controller regulates —
temperature rises with lag under heat, decays to ambient otherwise, and the
deadband controller cycles Heat/Cool to hold setpoint. Add `Temp_Ambient` as a
tag if not present. Update the reactor integration test to assert the realistic
response (temp trends toward setpoint under control; toward ambient with control
off) rather than the old linear ramp values.

## Testing
- **Engine unit tests** (pure): `firstOrderLag` converges toward a fixed target
  and a tag-driven target with the right time-constant behaviour (after ~τ it's
  ~63% of the way; snaps when τ≤0); analog-scaled `integrate`/`ramp` (source at
  50% gives half rate; 0 gives none; unset = unchanged from today); clamping +
  forcing preserved; existing behaviours byte-identical when the new fields are
  default.
- **Serialization**: the round-trip test (structural + 20-scan scan-equivalence
  per default project) stays green with the new fields and the reactor upgrade.
- **Showcase integration**: `proj_st_reactor` reaches and holds setpoint under
  the deadband controller with the thermal model, and decays toward ambient
  when the controller is disabled.
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints
No third-party/reference-editor branding. Dark theme; responsive (WS5) with
adaptive dialogs (WS7). `flutter analyze` zero. Engines pure Dart in
`mobile/lib/models` (UI-free), forcing wins, scan-tick clocks. Lossless
persistence preserved (round-trip guard). No RenderFlex overflow at 360/320.

## Out of scope (deferred)
- Sensor/measurement **noise** (needs separate clean vs measured state to avoid
  random-walk drift — future).
- Full PID function block / auto-tuning (the PLC programs implement control; the
  sim provides the process).
- Multi-variable coupled plant models, dead time/transport delay, nonlinear
  valve curves.
