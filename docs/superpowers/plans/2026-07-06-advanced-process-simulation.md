# Advanced Process Simulation (WS9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Simulated I/O engine model real process dynamics — analog-scaled rates (an actuator tag proportionally drives flow) and first-order lag (values respond with a time constant) — expose them in the editor, and showcase a realistic closed-loop thermal process.

**Architecture:** Additive `SimRule` fields (`sourcePath`, `refValue`, `tauSec`) + a new `firstOrderLag` behaviour + analog scaling of `integrate`/`ramp` in `sim_engine.dart` (pure Dart). The Simulated I/O editor exposes them; the reactor project's temperature becomes a first-order thermal process the ST controller regulates. Verified by pure engine tests, the WS6 serialization/scan-equivalence guard, and a reactor closed-loop test.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding. Dark theme; responsive (WS5) with adaptive dialogs (WS7). `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`; `initialValue:` on dropdowns.
- Engines stay pure Dart in `mobile/lib/models` (UI-free); forcing wins; scan-tick clocks. Additions are **additive** — existing sim behaviours must be byte-identical when the new fields are at defaults.
- Lossless persistence preserved: the WS6 `serialization_roundtrip_test.dart` (structural + 20-scan scan-equivalence per default project) must stay green.
- No RenderFlex overflow at 360/320/1400. Existing tests must keep passing (except the reactor integration test, intentionally updated in Task 3).

**Sequencing:** Task 1 (engine + model) is the foundation. Task 2 (editor UI) and Task 3 (showcase) build on it. Task 4 validates.

---

### Task 1: Sim engine + model — analog gain + first-order lag

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`SimRule` fields + serialization), `mobile/lib/models/sim_engine.dart`
- Test: `mobile/test/sim_engine_test.dart` (extend, or the existing sim test file — find it)

**Interfaces:** `SimRule` gains `String sourcePath` (default `''`), `double refValue` (default `100.0`), `double tauSec` (default `5.0`), all serialized (`source`/`ref_value`/`tau_sec`, back-compat defaults on read). `applySimRules` handles `firstOrderLag` and analog-scaled `integrate`/`ramp`.

- [ ] **Step 1: Write failing tests** in the sim engine test file. Read `sim_engine.dart` + the existing sim test for the harness (`applySimRules(p, rules, dtMs, SimRuntime())`, `readPath`). Cases:
  - **firstOrderLag toward fixed target:** rule `behavior:'firstOrderLag'`, `targetValue:100`, `tauSec:1.0`, target tag starts at 0. After 1 s of scans (e.g. 10×100ms), the value is ≈63% of the way to 100 (first-order: `1 - e^-1 ≈ 0.632`) — assert within a tolerance (e.g. 55–70). After many τ it approaches 100 (clamped by max). `tauSec:0` snaps to target in one scan.
  - **firstOrderLag toward a tag target:** `sourcePath:'SetTemp'`; changing `SetTemp` moves the tracked value toward the new source.
  - **analog-scaled integrate:** `behavior:'integrate'`, `ratePerSec:10`, `sourcePath:'Valve'`, `refValue:100`. With `Valve=50`, after 1 s the value rose ≈5 (half rate); `Valve=100` → ≈10; `Valve=0` → unchanged; `sourcePath:''` → full 10 (identical to today).
  - **analog-scaled ramp** similarly modulates the step.
  - **back-compat:** an existing `integrate`/`ramp`/`pulse`/etc. rule with the new fields absent/default behaves byte-identically to before (spot-check one).
  - forcing still wins (a forced target tag isn't written); clamping to min/max holds.

- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `project_model.dart`: add the three fields + constructor defaults + `toJson`/`fromJson` keys.
  - `sim_engine.dart`: add a gain helper — `double _gain(PlcProject p, SimRule r) => r.sourcePath.isEmpty || r.refValue == 0 ? 1.0 : _asDouble(readPath(p, r.sourcePath)) / r.refValue;`. In `integrate`/`ramp`, multiply the per-scan step by `_gain(...)`. Add the `firstOrderLag` case: `final target = r.sourcePath.isNotEmpty ? _asDouble(readPath(p, r.sourcePath)) : r.targetValue; final k = r.tauSec <= 0 ? 1.0 : (dt / r.tauSec).clamp(0.0, 1.0); final next = cur + (target - cur) * k;` then `_write` clamped — gated on `cond`. Keep everything else unchanged.
  - Note: for `firstOrderLag` the `sourcePath` is the TARGET source; for `integrate`/`ramp` it's the GAIN source. That dual use is fine (documented) — the same field, different role per behaviour.

- [ ] **Step 4: Tests → PASS. `serialization_roundtrip_test.dart` stays green (new fields round-trip; behaviour a superset). `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(sim): analog-scaled integrate/ramp + first-order-lag process dynamics`.

---

### Task 2: Simulated I/O editor — expose the new dynamics

**Files:**
- Modify: `mobile/lib/screens/simulated_io_screen.dart`
- Test: `mobile/test/simulated_io_screen_test.dart` (create if absent, or extend)

**Behavior spec:** In the rule editor dialog:
- Add **"First-Order Lag"** to the behaviour dropdown (value `firstOrderLag`).
- When behaviour is `integrate` or `ramp`: show an optional **"Rate driven by tag (optional)"** — a `TagAutocompleteField` bound to `sourcePath` (options from the project tags/paths) + a numeric **"= 100% at"** field bound to `refValue`. Empty source = fixed rate (as today).
- When behaviour is `firstOrderLag`: show **"Time constant τ (seconds)"** (`tauSec`), **"Target value"** (`targetValue`) and an optional **"Target from tag (optional)"** (`sourcePath` via `TagAutocompleteField`), plus min/max.
- Fields show/hide based on the selected behaviour; use the WS7 `showAdaptiveWidthDialog` + `TagAutocompleteField`; no overflow at 360/320; dark theme.

- [ ] **Step 1: Write a widget test** — open the rule editor at phone + desktop; select "First-Order Lag" → assert the τ + target fields appear and editing them updates the rule (`tauSec`/`targetValue`); select "integrate" → assert the "rate driven by tag" + refValue fields appear and setting them updates `sourcePath`/`refValue`; `takeException()` null at 320.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the conditional fields, reusing `TagAutocompleteField` and the adaptive dialog.
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes; web build succeeds.**
- [ ] **Step 5: Commit** `feat(sim-editor): configure first-order lag + tag-driven rate in the Simulated I/O editor`.

---

### Task 3: Showcase — realistic closed-loop thermal (proj_st_reactor)

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (`proj_st_reactor` sim rules + a `Temp_Ambient` tag)
- Modify: the reactor integration test (find it — likely `st_exec_integration_test.dart` asserts reactor behaviour) to the new thermal dynamics
- Test: add a closed-loop assertion

**Behavior spec:** Replace the reactor's fixed-rate temperature integrate rules with a thermal model:
- Add tag `Temp_Ambient` (e.g. 20.0 °C, Internal) if not present.
- Sim rules on `Temp_PV`:
  - **Ambient pull** (always, empty condition): `firstOrderLag` toward `Temp_Ambient` (`sourcePath:'Temp_Ambient'`) with a modest τ (e.g. `tauSec: 30`).
  - **Heating** (`condition: Heat_Cmd == true`): `integrate` up (e.g. `ratePerSec: 2.0`).
  - **Cooling** (`condition: Cool_Cmd == true`): `integrate` down (`ratePerSec: -2.0` or a down integrate).
- The existing `ReactorTemp_ST` deadband controller (Heat/Cool on SP±2) then regulates this realistic process.
- Update the reactor integration test: over many scans with `Auto_Mode` on and a setpoint above ambient, `Temp_PV` **trends toward and holds near `Temp_SP`** (within the deadband ± a tolerance) rather than the old linear values; with `Auto_Mode` off (no Heat/Cool), `Temp_PV` **decays toward `Temp_Ambient`**. Keep the scan-equivalence round-trip green (it compares the project to its own round-trip, so the new behaviour is fine).

- [ ] **Step 1: Update the reactor sim data + write the new closed-loop test** (RED against the old data if it still asserts linear values — then update).
- [ ] **Step 2: Implement** the thermal sim rules + `Temp_Ambient`. Ensure `serialization_roundtrip_test.dart` stays green.
- [ ] **Step 3: Tests → PASS; analyze clean; full suite passes.**
- [ ] **Step 4: Commit** `feat(sim): reactor uses a first-order thermal process the ST controller regulates`.

---

### Task 4: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, incl. round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user can build an analog loop (tag-driven rate) and a lagged process in the editor; the reactor holds setpoint against the thermal model.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** analog-scaled integrate/ramp + first-order lag engine + serialization (Task 1) ✓; editor UI for both (Task 2) ✓; reactor thermal showcase + test (Task 3) ✓; validation (Task 4) ✓.
- **Additivity guard:** existing sim behaviours byte-identical at default fields (Task 1 test); WS6 scan-equivalence round-trip stays green.
- **Type consistency:** `SimRule.sourcePath`/`refValue`/`tauSec`, `firstOrderLag` behaviour string, `_gain` helper used consistently.
- **Deferred:** measurement noise, PID FB/auto-tune, coupled/nonlinear plant, dead time.
