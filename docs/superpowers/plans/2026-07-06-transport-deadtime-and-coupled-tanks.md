# Transport Dead-Time & Coupled Tanks (WS13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a transport **dead-time** behaviour to the Simulated I/O engine (output = a source signal delayed by a dead time), expose it in the editor, and ship a coupled two-tank cascade demo where the downstream tank lags the upstream one by the transport delay.

**Architecture:** A new `deadTime` behaviour in `sim_engine.dart` reusing the existing `sourcePath` (delayed signal) and `tauSec` (dead time, seconds) `SimRule` fields plus a bounded FIFO buffer in `RuleRuntime` (cleared on project switch like the other per-rule state). No model/serialization change. The editor exposes it; a new "Cascade Tanks with Transport Delay" default project composes analog-scaled `integrate` (WS9) with `deadTime` to couple two tanks. Verified by pure engine tests, the WS6 round-trip guard, and a cascade lag integration test.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding. Dark theme; responsive (WS5) with adaptive dialogs (WS7). `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`; `initialValue:` on dropdowns.
- Engines pure Dart in `mobile/lib/models` (UI-free); forcing wins; scan-tick clock (`dt = dtMs/1000`); NEVER throws / NEVER hangs (bounded buffer, single pass).
- Additions are **additive** — existing sim behaviours must be byte-identical when the new behaviour is unused. NO new serialized `SimRule` field (`deadTime` reuses `sourcePath`/`tauSec`/`minValue`/`maxValue`).
- Lossless persistence preserved: the WS6 `serialization_roundtrip_test.dart` (structural + 20-scan scan-equivalence per default project, including the new demo project) must stay green.
- No RenderFlex overflow at 360/320/1400. Existing 335 tests must keep passing.

**Sequencing:** Task 1 (engine) is the foundation. Task 2 (editor UI + showcase) builds on it. Task 3 validates.

---

### Task 1: Dead-time engine — `deadTime` behaviour + FIFO buffer

**Files:**
- Modify: `mobile/lib/models/sim_engine.dart` (`RuleRuntime` FIFO + `case 'deadTime'`)
- Test: `mobile/test/sim_engine_test.dart` (extend — find the actual sim engine test file first; it may be named differently, e.g. `sim_engine_test.dart`)

**Interfaces:** `applySimRules(PlcProject, List<SimRule>, int dtMs, SimRuntime)` gains a `deadTime` case. `RuleRuntime` gains a bounded `List<double>` FIFO delay buffer. No public signature change.

- [ ] **Step 1: Write failing tests.** Read `sim_engine.dart` and the existing sim engine test for the harness (`applySimRules(p, rules, dtMs, SimRuntime())`, `readPath`, how a `SimRule` is built — note its field names: `id`, `behavior`, `targetPath`, `sourcePath`, `tauSec`, `minValue`, `maxValue`, `condition`, etc.). Cases (use `dtMs = 100`, so 1 scan = 0.1 s):
  - **Step delayed by dead time:** a rule `behavior:'deadTime'`, `sourcePath:'Src'`, `tauSec:0.3` (⇒ n=3 scans), `targetPath:'Out'`. `Src` starts at 0. Run a few scans → `Out` is 0. Set `Src=50`, run scans: `Out` stays at the pre-step value for ~3 scans, then becomes 50. Assert `Out` is still 0 on the scan right after the step and equals 50 after ≈3 scans.
  - **Holds initial while buffer fills:** before n samples exist, `Out` equals the initial source value (0 here), not garbage/null.
  - **Ramp reproduced delayed:** drive `Src` up by a fixed amount each scan; `Out` tracks `Src` but shifted by n scans (e.g. `Out(scan k) ≈ Src(scan k-n)`).
  - **Pass-through when `tauSec <= 0`:** `n=0` → `Out == Src` the same scan.
  - **Bounded buffer:** a very large `tauSec` (e.g. 1e9) must not throw, hang, or grow the buffer without limit — assert it completes quickly and `Out` holds the initial value (delay longer than the run). (Implementation caps buffer length.)
  - **Clamp + forcing:** `Out` clamped to `[minValue,maxValue]`; a forced `Out` root tag is not overwritten.
  - **Condition-gated:** with a non-empty `condition` that's false, the rule writes nothing (and does not advance the buffer, OR advances but writes nothing — pick one and assert it; simplest: when `!cond`, skip entirely like `integrate`/`ramp`).
  - **Back-compat:** an existing `integrate`/`firstOrderLag` rule with default new usage behaves byte-identically (spot-check one).
  - **State reset:** after `SimRuntime.byRuleId.clear()`, the delay line restarts (buffer empty).

- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `sim_engine.dart`: extend `RuleRuntime` with `final List<double> delayBuf = <double>[];` (a FIFO; `delayBuf.add(sample)` at the tail, read/remove from the head).
  - Add `case 'deadTime':` in the `switch`:
    ```
    case 'deadTime':
      if (cond && rule.sourcePath.isNotEmpty) {
        final src = _asDouble(readPath(p, rule.sourcePath));
        final n = rule.tauSec <= 0 ? 0 : (rule.tauSec / dt).round();
        if (n <= 0) {
          _write(p, rule.targetPath, _clamp(src, rule.minValue, rule.maxValue));
          break;
        }
        // Cap the buffer so an absurd dead time can't grow memory unbounded.
        final cap = n + 1 > 100000 ? 100000 : n + 1;
        st.delayBuf.add(src);
        while (st.delayBuf.length > cap) {
          st.delayBuf.removeAt(0);
        }
        // Output the sample from n scans ago; while filling, hold the oldest.
        final idx = st.delayBuf.length > n ? st.delayBuf.length - 1 - n : 0;
        final out = st.delayBuf[idx];
        _write(p, rule.targetPath, _clamp(out, rule.minValue, rule.maxValue));
      }
      break;
    ```
    (Adjust the exact indexing to whatever your tests assert — the invariant is: the value written is `source` from `n` scans ago once the buffer has that history, and the initial/oldest source value before then. Keep it pure and never-hanging: `removeAt(0)` in a `while` bounded by `cap`.)
  - Leave every other behaviour untouched.

- [ ] **Step 4: Tests → PASS. `serialization_roundtrip_test.dart` stays green (no data change yet; no new serialized field). `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(sim): transport dead-time behaviour (source delayed by a dead time)`.

---

### Task 2: Editor UI + Cascade Tanks with Transport Delay showcase

**Files:**
- Modify: `mobile/lib/screens/simulated_io_screen.dart` (behaviour dropdown + conditional fields), `mobile/lib/data/default_projects.dart` (new project)
- Test: `mobile/test/simulated_io_screen_test.dart` (extend if present), `mobile/test/deadtime_cascade_integration_test.dart`

- [ ] **Step 1: Editor UI.** In `simulated_io_screen.dart`, add **"Transport Dead-Time"** (value `deadTime`) to the behaviour dropdown. When selected, show (reusing the WS9 conditional-field pattern + the WS7 `TagAutocompleteField` + adaptive dialog): a **"Delayed source tag"** field bound to `sourcePath`, a **"Dead time τ (seconds)"** numeric field bound to `tauSec`, and the min/max fields. Read the existing `firstOrderLag` field group and mirror it (it already binds `sourcePath`/`tauSec`). No overflow at 360/320; dark theme; `initialValue:` on the dropdown.
  - Write/extend a widget test: open the rule editor, select "Transport Dead-Time", assert the source + τ fields appear and editing them updates the rule (`sourcePath`/`tauSec`); `takeException()` null at 320.

- [ ] **Step 2: Cascade Tanks demo project.** Add **"Cascade Tanks with Transport Delay"** in `default_projects.dart` (mirror an existing sim-driven project — read the WS9 reactor thermal project or the WS10 tank project for the exact `SimRule`/`PlcTag`/HMI/`PlcTask` constructors, and add it to `DefaultProjects.all()`). Content:
  - Tags: `Feed_Valve` (FLOAT64 %, Internal, e.g. 60), `Tank_A_Level` (FLOAT64 %, SimulatedInput, init ~10), `Transfer_Line` (FLOAT64 %, Internal, init ~10), `Tank_B_Level` (FLOAT64 %, SimulatedInput, init ~10).
  - Sim rules:
    - `Tank_A_Level`: analog-scaled `integrate` inflow (`sourcePath:'Feed_Valve'`, `refValue:100`, positive `ratePerSec`), empty condition; plus a constant outflow (`integrate` small negative rate). Clamp 0–100.
    - `Transfer_Line`: `deadTime` (`sourcePath:'Tank_A_Level'`, `tauSec` a few seconds, e.g. 3.0), clamp 0–100.
    - `Tank_B_Level`: analog-scaled `integrate` inflow (`sourcePath:'Transfer_Line'`, `refValue:100`, positive `ratePerSec`) + constant outflow. Clamp 0–100.
  - HMI: gauges for `Tank_A_Level`, `Tank_B_Level`, a display of `Feed_Valve`.
  - A Continuous `PlcTask` (an empty/simple program is fine — the process is sim-driven; mirror how other sim-only demos wire a task, or reuse a trivial program). Ensure the project is self-consistent for the round-trip guard.

- [ ] **Step 3: Cascade integration test** (`mobile/test/deadtime_cascade_integration_test.dart`): load the new project; run the full scan pipeline for enough scans; assert that after `Feed_Valve` drives the process, `Tank_A_Level` rises first and `Tank_B_Level` **lags** it — e.g. at the scan where `Tank_A_Level` has clearly risen, `Tank_B_Level` is still near its initial value, and only after ≈the dead time does `Tank_B_Level` begin rising. Falsifiable: note that with `tauSec:0` (or removing the `deadTime` rule) `Tank_B` would rise together with `Tank_A`. Confirm `serialization_roundtrip_test.dart` stays green with the new project.

- [ ] **Step 4: Verify.** `flutter analyze` → clean; `flutter test` → all pass (335 + new); `flutter build web --release` → succeeds. Discard regenerated plugin-registrant churn (`git checkout -- linux/flutter macos/Flutter windows/flutter` from `mobile/`) before finishing.
- [ ] **Step 5: Commit** `feat(sim): coupled cascade-tank demo with transport delay + editor support`.

---

### Task 3: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user can configure a Transport Dead-Time rule in the Simulated I/O editor, and the Cascade Tanks project shows Tank B lagging Tank A by the transport delay.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** `deadTime` behaviour + FIFO buffer (Task 1) ✓; editor UI + coupled cascade demo + lag test (Task 2) ✓; validation (Task 3) ✓.
- **Additivity/guard:** `deadTime` is a new behaviour string reusing existing serialized fields (no model change); existing behaviours untouched; the new demo project is additive; WS6 round-trip stays green (deterministic buffer from fresh state). Engine stays never-throws/hangs (bounded buffer).
- **Type consistency:** `RuleRuntime.delayBuf`, the `case 'deadTime'` output write, and the demo's `sourcePath`/`tauSec` usage are consistent; `SimRuntime.byRuleId.clear()` already clears the buffer at every lifecycle site.
- **Deferred:** measurement noise (needs deterministic seeded PRNG + clean-vs-measured state — its own workstream), nonlinear valve curves, auto-tune, MIMO plants.
