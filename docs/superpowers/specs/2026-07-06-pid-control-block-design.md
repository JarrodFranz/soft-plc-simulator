# PID Control Block (WS10) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "keep building app side"). Design made
autonomously.
**Author:** Claude (pairing with Jarrod)

Ties together WS7 (pin-based FBD) and WS9 (analog process sim): a **PID function
block** in FBD whose control output (CV) drives an analog actuator, so the
simulator can run a real closed control loop (PID holds a process value at
setpoint against a first-order plant).

## The block

A new FBD block `type: 'PID'`, stateful like `TON`:
- **Input pins:** `SP`, `PV`, `KP`, `KI`, `KD` (setpoint, process value, and the
  three gains — gains are pins so they can come from `CONST` blocks or be
  tag-driven for gain scheduling).
- **Output pin:** `CV` (control variable, %).
- **Semantics** (positional PID, per scan, `dt = dtMs/1000`):
  - `error = SP − PV`
  - `integral += error × dt` (with anti-windup — see below)
  - `derivative = (error − prevError) / dt` (0 on the first scan / dt≤0)
  - `raw = KP×error + KI×integral + KD×derivative`
  - `CV = clamp(raw, 0, 100)` — a percentage output suited to a valve/heater.
  - **Anti-windup:** when `raw` saturates (outside 0–100), do not accumulate the
    integral in the direction that worsens saturation (conditional integration),
    so the integral can't wind up while the output is pinned.
  - `prevError = error` stored for next scan.
- **State** in `FbdRuntime` keyed by block id (`integral`, `prevError`), cleared
  on project switch — mirroring the `TON`/`TOF` state pattern.
- Missing/unwired gain pins read as 0 (a P-only or disabled loop), never throw.
  CV range fixed at 0–100 for v1 (pairs with the sim's `refValue: 100`); CV_MIN/
  CV_MAX pins are a future extension.

## Where it plugs in

- **`fbd_pins.dart`:** add `PID` → inputs `['SP','PV','KP','KI','KD']`, output
  `['CV']`.
- **`fbd_exec.dart`:** `FbdRuntime` gains a per-block PID-state map; `_evalBlock`
  gets a `case 'PID'` producing `{'CV': cv}`. Stays pure, never throws, never
  hangs (PID is memoryless-per-scan beyond its stored state; topological
  evaluation unchanged).
- **`fbd_editor_screen.dart`:** add `PID` to the block palette (pins render
  automatically from the registry — 5 input dots, 1 output dot).

## Showcase — a closed-loop PID demo (new default project)

Add a default project **"Tank Level PID Control"** demonstrating the loop:
- **Tags:** `Level_PV` (%, sim input), `Level_SP` (%, e.g. 60), `Valve_CV` (%,
  the PID output), gains `Kp`/`Ki`/`Kd` (internal), and a small constant
  `Outflow` disturbance.
- **FBD program `LevelPID_FBD`:** a `PID` block — `SP`←`Level_SP` (TAG_INPUT),
  `PV`←`Level_PV`, `KP`/`KI`/`KD`←`CONST` blocks — `CV`→`TAG_OUTPUT Valve_CV`.
- **Simulated I/O:** `Level_PV` driven by **analog-scaled `integrate`** with
  `sourcePath: 'Valve_CV'`, `refValue: 100` (inflow proportional to valve %),
  net of a constant outflow (a second integrate with a small negative rate, or
  fold the outflow into the model). Tuned so the PID holds `Level_PV` near
  `Level_SP`.
- **HMI:** a dashboard showing Level (gauge), SP, and Valve CV.
- **Closed-loop test:** from an initial level below SP, `Level_PV` **rises toward
  and settles near `Level_SP`** (within a tolerance) under PID control, and
  `Valve_CV` moves in `[0,100]`; the integral doesn't wind up (CV bounded).

## Testing

- **Engine unit tests** (pure): PID drives error toward zero over scans (a step
  from PV=0, SP=50, sensible gains → CV>0 initially, PV-tracking left to the
  loop test); P/I/D contributions behave (larger KP → larger immediate CV;
  integral accumulates and is bounded by anti-windup when saturated; derivative
  responds to error change); CV clamped to 0–100; unwired gains → 0, no throw;
  `FbdRuntime.clear()` resets PID state.
- **Serialization:** the new `PID` block + its wires round-trip (WS6 structural +
  20-scan scan-equivalence per default project stays green — the new demo
  project included and self-consistent).
- **Closed-loop integration:** the Tank Level PID project settles `Level_PV` near
  `Level_SP` under the loop (falsifiable: zero gains wouldn't control it).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding (IEC-style pin names `SP`/`PV`/`CV`/
`KP` are generic). Dark theme; responsive. `flutter analyze` zero. Engines pure
Dart in `mobile/lib/models`; force-aware `CV` write; never throws/hangs; scan-tick
clock. Lossless persistence preserved (round-trip guard). No RenderFlex overflow.

## Out of scope (deferred)
- CV_MIN/CV_MAX / bipolar output pins; manual/auto bumpless transfer; setpoint
  ramping; derivative-on-measurement vs error; auto-tuning.
- PID as an ST/IL function (this is the FBD block; ST programs can implement PID
  by hand today).
