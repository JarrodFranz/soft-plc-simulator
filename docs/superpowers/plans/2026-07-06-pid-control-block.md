# PID Control Block (WS10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a stateful PID function block to FBD (`SP,PV,KP,KI,KD → CV`, anti-windup, clamped 0–100) and a closed-loop tank-level demo where the PID drives an analog process — a real control loop in the simulator.

**Architecture:** `PID` joins the `fbd_pins.dart` registry; `fbd_exec.dart` gets per-block PID state in `FbdRuntime` (like `TON`) and a `case 'PID'` producing `{'CV': cv}`; the FBD editor palette gains a PID entry (pins render from the registry). A new "Tank Level PID Control" default project wires a PID block to an analog-scaled `integrate` (WS9) so the loop closes; verified by pure PID tests + the WS6 round-trip guard + a closed-loop settling test.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding (generic control names `SP`/`PV`/`CV`/`KP`/`KI`/`KD` are fine).
- Dark theme; responsive. `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Engines pure Dart in `mobile/lib/models` (UI-free); force-aware `CV` write; NEVER throws / NEVER hangs; scan-tick clock (`dt = dtMs/1000`).
- Lossless persistence preserved — the WS6 `serialization_roundtrip_test.dart` (structural + 20-scan scan-equivalence per default project, including the new demo project) must stay green.
- No RenderFlex overflow at 360/320/1400. Existing 264 tests must keep passing.

**Sequencing:** Task 1 (PID engine) is the foundation. Task 2 (palette + demo project + closed-loop test) builds on it. Task 3 validates.

---

### Task 1: PID engine — registry + stateful executor

**Files:**
- Modify: `mobile/lib/models/fbd_pins.dart` (add `PID` pins), `mobile/lib/models/fbd_exec.dart` (`FbdRuntime` PID state + `case 'PID'`)
- Test: `mobile/test/fbd_exec_test.dart` (extend), `mobile/test/fbd_pins_test.dart` (extend)

**Interfaces:** `fbdInputPins('PID')` → `['SP','PV','KP','KI','KD']`; `fbdOutputPins('PID')` → `['CV']`. `FbdRuntime` carries per-block PID state (integral, prevError). `_evalBlock` handles `PID` → `{'CV': double}`.

- [ ] **Step 1: Write failing tests.**
  - `fbd_pins_test.dart`: `fbdInputPins('PID') == ['SP','PV','KP','KI','KD']`; `fbdOutputPins('PID') == ['CV']`.
  - `fbd_exec_test.dart` (read the existing harness — build a program with a `PID` block fed by `CONST`/`TAG_INPUT` blocks on its pins, wire `CV` to a `TAG_OUTPUT`, run scans with `executeFbdPrograms(p, dtMs, rt)`):
    - **Proportional:** SP=50, PV=0, KP=2, KI=0, KD=0 → CV = clamp(2×50,0,100) = 100 (saturated); with KP=1 → CV=50.
    - **Clamp:** raw > 100 → CV=100; raw < 0 (PV>SP) → CV=0.
    - **Integral accumulates + anti-windup:** SP=50, PV=45, KP=0, KI=1 (dt from dtMs): over scans CV rises as the integral of error×dt; when CV would saturate at 100, the integral stops growing (anti-windup) — assert CV stays ≤100 and the integral is bounded (e.g. after saturating, reducing error brings CV back down promptly, not after a long unwind).
    - **Derivative:** with KD>0, a sudden change in PV between scans produces a derivative kick in CV; steady PV → derivative term ~0.
    - **Unwired gains → 0:** a PID with only SP/PV wired (no KP/KI/KD) → CV=0 (or clamp of 0), no throw.
    - **State reset:** after `rt.clear()`, the integral/prevError reset (a fresh loop starts from integral 0).

- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `fbd_pins.dart`: add `case 'PID': return const ['SP','PV','KP','KI','KD'];` to `fbdInputPins` and `case 'PID': return const ['CV'];` to `fbdOutputPins`.
  - `fbd_exec.dart`: extend `FbdRuntime` with `final Map<String, List<double>> _pid = {};` (per block id: `[integral, prevError]`) and clear it in `clear()`. Add `case 'PID':` in `_evalBlock` (which already receives `dtMs` + `rt` + ordered inputs by pin): read `sp,pv,kp,ki,kd` from the ordered inputs (`_asNum`/existing numeric coercion; null→0); `final dt = dtMs/1000.0; final e = sp - pv;` load `[integral, prevError]` (default `[0,0]`); `final deriv = dt <= 0 ? 0.0 : (e - prevError)/dt; var integ = integral;` — compute `raw = kp*e + ki*(integ + e*dt) + kd*deriv;` then apply **conditional anti-windup**: only commit `integ += e*dt` if the resulting `raw` is within [0,100] OR the integration moves `raw` back toward the band (i.e. don't integrate when saturated in the same direction). Recompute `raw` with the committed `integ`; `cv = raw.clamp(0,100)`. Store `_pid[b.id] = [integ, e]`. Return `{'CV': cv}`. Keep it pure + never-throw (all numeric-guarded).

- [ ] **Step 4: Tests → PASS. `serialization_roundtrip_test.dart` still green (no data change yet). `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(fbd): PID control block (SP/PV/KP/KI/KD -> CV, anti-windup, clamped)`.

---

### Task 2: PID palette entry + closed-loop tank-level PID demo

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart` (palette), `mobile/lib/data/default_projects.dart` (new project)
- Test: `mobile/test/pid_loop_integration_test.dart`

- [ ] **Step 1: Add `PID` to the FBD editor palette** (`fbd_editor_screen.dart`), following the existing `_buildBlockPaletteItem('TON', …)` pattern — a sensible icon/label ("PID Controller"). Pins render automatically from `fbd_pins.dart`.

- [ ] **Step 2: Add the "Tank Level PID Control" default project** in `default_projects.dart` (mirror the structure of an existing project — tags, one FBD program, sim rules, an HMI, tasks). Content:
  - Tags: `Level_PV` (FLOAT64 %, SimulatedInput, init below SP e.g. 10), `Level_SP` (FLOAT64 %, Internal, 60), `Valve_CV` (FLOAT64 %, SimulatedOutput), `Kp`/`Ki`/`Kd` (FLOAT64, Internal — tuned, see below) or fold gains into `CONST` blocks.
  - FBD `LevelPID_FBD`: blocks — `TAG_INPUT Level_SP`→PID.SP, `TAG_INPUT Level_PV`→PID.PV, three `CONST` (Kp,Ki,Kd)→PID.KP/KI/KD, `PID`, `TAG_OUTPUT Valve_CV`←PID.CV. Pin-addressed wires.
  - Sim rules on `Level_PV`: analog-scaled `integrate` `sourcePath:'Valve_CV'`, `refValue:100`, a positive fill `ratePerSec` (inflow at full valve), condition empty; plus a constant outflow (`integrate` small negative rate, always) so the loop must hold against a disturbance. Clamp 0–100. Tune Kp/Ki (+ maybe small Kd) so `Level_PV` settles near `Level_SP` — VERIFY by running the loop test and adjusting.
  - HMI dashboard: gauge/among components for `Level_PV`, a display for `Level_SP` and `Valve_CV`.
  - Task wiring so `LevelPID_FBD` runs (Continuous task).

- [ ] **Step 3: Write `mobile/test/pid_loop_integration_test.dart`** — load the new project; run the full scan pipeline (sim → LD → FBD → SFC → ST) for enough scans; assert `Level_PV` **converges to and holds near `Level_SP`** (e.g. `|Level_PV - Level_SP| <= ~4` after settling) and `Valve_CV` stays within `[0,100]` and modulates (not stuck at 0 or 100 forever). Falsifiable: note that zeroing the gains would leave the level uncontrolled. Confirm `serialization_roundtrip_test.dart` stays green with the new project.

- [ ] **Step 4: Verify.** `flutter analyze` → clean; `flutter test` → all pass (264 + new); `flutter build web --release` → succeeds. If the loop won't settle, tune gains/rates until it does (that's the demo's point).
- [ ] **Step 5: Commit** `feat(sim): closed-loop Tank Level PID demo (FBD PID drives an analog valve) + palette`.

---

### Task 3: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user can place a PID block, wire it, and the Tank Level PID project holds level at setpoint.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** PID pins + stateful executor with anti-windup + clamp (Task 1) ✓; palette entry + closed-loop demo project + settling test (Task 2) ✓; validation (Task 3) ✓.
- **Additivity/guard:** PID is a new block type (existing FBD unchanged); the new demo project is additive; WS6 round-trip stays green (new project self-consistent). Engine stays never-throws/hangs.
- **Type consistency:** `PID` pins (`SP,PV,KP,KI,KD`/`CV`), `FbdRuntime` PID state, the `case 'PID'` output map `{'CV':…}` used consistently.
- **Deferred:** CV limits/bipolar, manual/auto, setpoint ramp, auto-tune, ST PID.
