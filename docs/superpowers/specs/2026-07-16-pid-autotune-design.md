# PID Auto-Tune (Relay Feedback) — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** Phase 9, feature 3 of 4 (then: MIMO coupled plant; optional pink noise).

## Goal

Let the user auto-tune a PID loop against the app's simulated process and get suggested gains. A dedicated **Auto-Tune** panel runs a **relay-feedback (Åström-Hägglund)** experiment in simulation — deterministically — to find the ultimate gain `Ku` and period `Pu`, then offers a table of gain suggestions from several tuning rules and applies the chosen one to the loop's gain sources. No PID/FBD program runs during the experiment; only the project's SimRules (the process) do.

Relay feedback is chosen because several of the app's processes are **integrating** (e.g. tank level = `integrate`), for which an open-loop step-response FOPDT fit has no steady-state gain; the relay method produces a sustained limit cycle for both self-regulating and integrating processes.

## Current behaviour (as-found)

- PID is an FBD block: input pins `SP, PV, KP, KI, KD` → output `CV` (`fbd_pins.dart`). Engine at `fbd_exec.dart:285` uses the **parallel form** `raw = kp*e + ki*integral + kd*deriv` with conditional anti-windup. So the gains are `Kp` (proportional gain), `Ki` (integral gain = Kp/Ti), `Kd` (derivative gain = Kp·Td).
- Gain pins are fed by source blocks over `FbdWire`s. `FbdBlock { String type; String tagBinding; ... }`: a `CONST` block stores its literal in `tagBinding` (parsed by `_parseConst(b.tagBinding)`); a `TAG_INPUT` block's `tagBinding` is a tag path. `FbdWire { String fromBlockId, fromPin, toBlockId, toPin; }`.
- The process is simulated: `applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)` updates PV tags from CV tags each scan (deterministic; no clock).
- The "Tank Level PID Control" default project (`_fbdPidTankLevelProject`) wires `p_kp`/`p_ki`/`p_kd` CONST blocks into the PID's `KP`/`KI`/`KD`, drives `Valve_CV`, and simulates `Level_PV` — the natural showcase.

## Non-goals / YAGNI

- No new persisted model fields; the panel's relay parameters are session-only. "Apply" mutates existing gain sources (CONST `tagBinding` / tag values), which autosave already persists.
- No new default project (reuse the existing PID demo).
- No online/live tuning of the running loop; the experiment runs on a deep copy of the project.
- No auto-selection of the "best" rule; the user picks a row.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `models/pid_autotune.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical project + params → identical result; the experiment runs `applySimRules` on a deep copy.
- Additive/backward-compatible: no persisted schema change; the default projects' 20-scan scan-equivalence stays green.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Component 1 — Pure relay engine (`mobile/lib/models/pid_autotune.dart`)

```dart
class RelayTuneParams {
  final double relayHigh;   // CV output when driving up
  final double relayLow;    // CV output when driving down
  final double hysteresis;  // switch band around SP (in PV units)
  final double setpoint;    // operating point the relay oscillates around
  final int dtMs;           // scan period for the experiment
  final int maxScans;       // hard cap
  final int settleCycles;   // cycles that must be stable to declare converged
  // relay amplitude d = (relayHigh - relayLow) / 2
}

class TunePoint { final double tMs; final double pv; final double cv; ... }

class RelayTuneResult {
  final bool converged;
  final double ku;           // ultimate gain
  final double pu;           // ultimate period (ms)
  final double amplitude;    // PV oscillation amplitude a (half peak-to-peak)
  final List<TunePoint> trace;
  final String? warning;
}

RelayTuneResult relayAutoTune(PlcProject project,
    {required String pvPath, required String cvPath, required RelayTuneParams params});
```

Algorithm:
1. Deep-copy `project` (`PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())))`). Create a fresh `SimRuntime`.
2. Each scan up to `maxScans`: read `pv = readPath(copy, pvPath)`; choose relay output — if `pv < setpoint - hysteresis` → `relayHigh`; if `pv > setpoint + hysteresis` → `relayLow`; else keep the previous output (start `relayHigh`). Write `cv` to `cvPath` (`writePath`), append a `TunePoint`, then `applySimRules(copy, copy.simRules, params.dtMs, rt)`.
3. Detect the limit cycle from PV extrema between relay switches: record successive peak and trough values and the times of like-direction switches. Oscillation amplitude `a` = average of `(peak − trough)/2` over the last `settleCycles`; period `Pu` = average time between successive rising switches over the last `settleCycles`.
4. Converged when the last `settleCycles` amplitudes and periods are each within a small relative tolerance (e.g. 5%). Else `converged=false` with a warning.
5. `d = (relayHigh − relayLow)/2`; `Ku = 4·d / (π·a)` (guard `a>0`); `Pu` as measured (guard `Pu>0`).

Edge cases: PV never leaves the hysteresis band (no switching) → `converged=false`, warning "no oscillation — increase relay amplitude or check PV/CV wiring". `a≈0` or `Pu≈0` → guarded, `converged=false`. Always returns the `trace` for display.

## Component 2 — Pure tuning rules (`pid_autotune.dart`)

```dart
class TuningSuggestion { final String name; final String form; // 'PID' | 'PI'
  final double kp, ki, kd; }

List<TuningSuggestion> tuningRules(double ku, double pu);
```

Rules (Pu in the SAME time unit the gains expect — the engine integrates in **seconds**, so convert `Pu_s = pu/1000`; `Ki = Kp/Ti`, `Kd = Kp·Td`, both with `Ti`/`Td` in seconds):

| Name | Form | Kp | Ti (s) | Td (s) |
|---|---|---|---|---|
| Ziegler-Nichols | PID | 0.6·Ku | 0.5·Pu_s | 0.125·Pu_s |
| Ziegler-Nichols | PI | 0.45·Ku | 0.833·Pu_s | — (Kd=0) |
| Tyreus-Luyben | PID | Ku/2.2 | 2.2·Pu_s | Pu_s/6.3 |
| Tyreus-Luyben | PI | Ku/3.2 | 2.2·Pu_s | — (Kd=0) |
| ZN no-overshoot | PID | 0.2·Ku | 0.5·Pu_s | Pu_s/3 |
| ZN no-overshoot | PI | 0.13·Ku | 0.5·Pu_s | — (Kd=0) |

`Ki = Kp/Ti` (guard `Ti>0`), `Kd = Kp·Td` (0 for PI rows). All arithmetic pure/deterministic.

## Component 3 — Loop introspection (helper in `pid_autotune.dart`, pure)

```dart
class PidLoopBinding {
  final String pidBlockId;
  final String? pvPath;      // source of the PV pin (a tag path)
  final String? cvPath;      // destination of the CV output (a tag path)
  final double? setpoint;    // resolved SP value/path if available
  final String? kpSourceBlockId, kiSourceBlockId, kdSourceBlockId; // writable CONST/TAG_INPUT feeding the gain pins
}

PidLoopBinding resolvePidLoop(PlcProgram program, PlcProject project, String pidBlockId);
```

Resolution: for each input pin, find the `FbdWire` with `toBlockId == pidBlockId && toPin == '<PIN>'`; its `fromBlockId` is the source block. For `PV`/`SP`, if the source is a `TAG_INPUT` its `tagBinding` is the path; for the gain pins, keep the source block id if it is a writable `CONST`/`TAG_INPUT`. For `CV`, find the wire with `fromBlockId == pidBlockId && fromPin == 'CV'`; the destination `TAG_OUTPUT` block's `tagBinding` is `cvPath`. Missing/ambiguous fields stay null (the panel offers manual override).

## Component 4 — Auto-Tune panel (`mobile/lib/screens/pid_autotune_screen.dart`, new nav section)

A new center-workspace section (added to the shell nav next to Simulated I/O), following the Simulated I/O / Trends screen patterns:
- **Loop:** a dropdown of the project's PID blocks (across FBD programs). Selecting one calls `resolvePidLoop` and prefills PV/CV paths + SP; PV and CV are editable (tag-autocomplete) for manual override.
- **Relay params:** relay high, relay low, hysteresis, setpoint (default SP), max duration (scans or seconds). Sensible defaults derived from the loop (e.g. relayHigh/low = CV tag's min/max or 0/100; setpoint = SP; hysteresis = a small fraction of PV span).
- **Run Auto-Tune** → calls `relayAutoTune` synchronously (fast, deterministic). Shows:
  - the **PV & CV oscillation trend** (reuse the existing `TrendChartDisplay` from the historian/Trends feature, fed the `trace`),
  - the computed **Ku / Pu** (and a "not converged" warning if applicable),
  - a **table** of `tuningRules(ku, pu)` rows (name, form, Kp, Ki, Kd), each with an **Apply** button.
- **Apply(row)** → writes Kp/Ki/Kd into the resolved gain sources: for a `CONST` source, set its `tagBinding` to the formatted number; for a `TAG_INPUT` source, set the referenced tag's value. If a gain pin has no writable source, show a message and skip that gain. Applying marks the project dirty (autosave).

Dark theme; no overflow at 320/360/1400 (the table scrolls horizontally in its own container; the trend uses the responsive chart).

## Data flow

Panel → `resolvePidLoop` (prefill) → user sets relay params → `relayAutoTune` runs `applySimRules` on a deep copy driving CV via the relay, reading PV → `RelayTuneResult` (trace + Ku/Pu) → `tuningRules(ku,pu)` → table → **Apply** mutates the live project's gain sources + autosave. Nothing new persisted; the experiment never mutates live tags (deep copy).

## Error handling / edge cases

- No sustained oscillation within `maxScans` → `converged=false` + warning; no gains offered (table hidden or disabled).
- Degenerate amplitude/period → guarded (no NaN/Inf); `converged=false`.
- Unresolved PV/CV (no wiring) → the panel requires the user to pick them before Run.
- Non-writable gain source on Apply → per-gain message, others still applied.

## Testing

- **Pure (`pid_autotune_test`):**
  - `relayAutoTune` on a self-regulating process (a `firstOrderLag` + `deadTime` sim) produces `converged==true` with plausible `Ku>0`, `Pu>0`, and a limit-cycle trace; on an **integrating** process (an `integrate` sim driven by CV) also converges. A too-small relay / over-damped case returns `converged==false` with a warning.
  - Determinism: same project + params → identical `Ku`/`Pu`/trace across two runs.
  - `tuningRules` golden numbers for a fixed `(Ku, Pu)` — every row's Kp/Ki/Kd matches the table above (with `Pu_s = pu/1000`), PI rows have `kd==0`, `Ki==Kp/Ti`.
  - `resolvePidLoop` on the Tank Level PID demo resolves PV=`Level_PV`, CV=`Valve_CV`, and the `p_kp`/`p_ki`/`p_kd` gain sources.
- **Widget (`pid_autotune_screen_test`):** the panel renders; selecting the Tank Level PID prefills PV/CV; Run produces a trend + a non-empty suggestions table; Apply writes the row's gains into the CONST sources (assert `p_kp.tagBinding` etc. changed); no overflow at 320/1400.
- **Round-trip / scan-equivalence:** the default projects' round-trip stays green (no schema change); a deep-copy experiment does not mutate the source project (assert live tags unchanged after a run).
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`.

## Files

- **Create:** `mobile/lib/models/pid_autotune.dart` (pure: `RelayTuneParams`/`TunePoint`/`RelayTuneResult`/`relayAutoTune`, `TuningSuggestion`/`tuningRules`, `PidLoopBinding`/`resolvePidLoop`) + its test; `mobile/lib/screens/pid_autotune_screen.dart` + its widget test.
- **Modify:** `mobile/lib/screens/workspace_shell.dart` (add the Auto-Tune nav section + center-workspace case).
- **Docs:** a `docs/pid-autotune.md` note + `ROADMAP.md` (Phase 9 feature 3) + the PID/Simulated bullet in `README.md`.

## Optional (plan-time)

Decompose into ~5 tasks: (1) relay engine + detection; (2) tuning rules; (3) `resolvePidLoop`; (4) panel + nav + run/trend/table + apply; (5) validation + docs. Tasks 1-3 are pure/TDD-heavy; task 4 is the UI integration.
