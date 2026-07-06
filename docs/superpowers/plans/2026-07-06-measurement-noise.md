# Measurement Noise (WS14) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `noise` Simulated I/O behaviour — a measured tag = a clean source tag + bounded, deterministic random noise (non-accumulating, no drift) — expose it in the editor, and ship a "Noisy Level Measurement" demo (true / noisy / filtered levels).

**Architecture:** A source→target `noise` behaviour in `sim_engine.dart` (like `deadTime`) reusing `sourcePath` (clean source), `targetValue` (noise amplitude ±A), and min/max — no model change. Each rule owns a deterministic xorshift32 PRNG in `RuleRuntime`, seeded from a stable FNV-1a hash of `rule.id` (round-trip-safe, so the WS6 scan-equivalence guard stays green). The editor exposes it; a new demo composes `integrate` (clean) → `noise` (measured) → `firstOrderLag` (filtered). Verified by pure engine tests (bounded / varies / no-drift / deterministic), the round-trip guard, and a showcase integration test.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding. Dark theme; responsive (WS5) with adaptive dialogs (WS7). `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`; `initialValue:` on dropdowns.
- Engines pure Dart in `mobile/lib/models` (UI-free); forcing wins; scan-tick clock; NEVER throws / NEVER hangs (single PRNG step per scan).
- **Determinism is mandatory:** noise MUST be a deterministic function of `rule.id` + scan index (NO `Math.random()`, NO `DateTime.now()`, NO `String.hashCode` for the seed — use a stable FNV-1a over the id's code units). This is what keeps the round-trip scan-equivalence green.
- Additive — existing behaviours byte-identical when `noise` is unused. NO new serialized `SimRule` field (`noise` reuses `sourcePath`/`targetValue`/`minValue`/`maxValue`).
- Lossless persistence: the WS6 `serialization_roundtrip_test.dart` (structural + 20-scan scan-equivalence per default project, including the new demo project) must stay green.
- No RenderFlex overflow at 360/320/1400. Existing 354 tests must keep passing.

**Sequencing:** Task 1 (engine) is the foundation. Task 2 (editor UI + showcase) builds on it. Task 3 validates.

---

### Task 1: Noise engine — deterministic PRNG + `noise` behaviour

**Files:**
- Modify: `mobile/lib/models/sim_engine.dart` (`RuleRuntime` PRNG state + helpers + `case 'noise'`)
- Test: `mobile/test/sim_engine_test.dart` (extend)

**Interfaces:** `applySimRules(PlcProject, List<SimRule>, int dtMs, SimRuntime)` gains a `noise` case. `RuleRuntime` gains an `int` PRNG state (lazily seeded). No public signature change.

- [ ] **Step 1: Write failing tests.** Read `sim_engine.dart` and the existing sim test for the harness (how a `SimRule` is built — fields `id`, `behavior`, `targetPath`, `sourcePath`, `targetValue`, `minValue`, `maxValue`, `condition`; `applySimRules(p, rules, dtMs, SimRuntime())`; `readPath`). Cases:
  - **Bounded:** a `noise` rule, `sourcePath:'Clean'`, `targetValue:2.0` (amplitude A=2), `targetPath:'Meas'`, `Clean=50`, min 0 / max 100. Over many scans, `Meas` always in `[48, 52]` (`|Meas-Clean| <= A`).
  - **Varies (not constant):** over ~30 scans the set of `Meas` values has more than one distinct value (noise is actually applied), and its spread is > 0.
  - **No drift (the key test):** hold `Clean=50` fixed for 500 scans; assert `|Meas - 50| <= A` on EVERY scan (never grows). (An in-place `tag += noise` random-walk bug would exceed A — this catches it.)
  - **Deterministic:** run the SAME rule twice, each with a FRESH `SimRuntime`, for N scans; assert the two `Meas` sequences are IDENTICAL. Then a rule with a DIFFERENT `id` produces a DIFFERENT sequence (not identical).
  - **A <= 0 pass-through:** `targetValue:0` ⇒ `Meas == clamp(Clean)` every scan (no jitter).
  - **Clamp + forcing:** with `Clean` near a bound, `Meas` clamped to `[min,max]`; a forced `Meas` root tag isn't overwritten.
  - **Condition-gated:** a false non-empty condition writes nothing.
  - **Back-compat:** an existing `integrate`/`firstOrderLag`/`deadTime` rule behaves identically (spot-check one).
  - **clear() restart:** after `SimRuntime.byRuleId.clear()`, the SAME rule re-seeds and reproduces its sequence from the start (deterministic restart).

- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `sim_engine.dart`: add pure helpers:
    ```
    int _fnv1a(String s) {
      var h = 0x811c9dc5;
      for (final c in s.codeUnits) {
        h = (h ^ c) & 0xffffffff;
        h = (h * 0x01000193) & 0xffffffff;
      }
      return h == 0 ? 0x1a2b3c4d : h; // xorshift needs a non-zero seed
    }
    int _xorshift32(int x) {
      x = (x ^ ((x << 13) & 0xffffffff)) & 0xffffffff;
      x = (x ^ (x >> 17)) & 0xffffffff;
      x = (x ^ ((x << 5) & 0xffffffff)) & 0xffffffff;
      return x & 0xffffffff;
    }
    ```
  - Extend `RuleRuntime` with `int? noiseState;` (null until first seeded).
  - Add `case 'noise':`:
    ```
    case 'noise':
      if (cond && rule.sourcePath.isNotEmpty) {
        final clean = _asDouble(readPath(p, rule.sourcePath));
        final a = rule.targetValue;
        if (a <= 0) {
          _write(p, rule.targetPath, _clamp(clean, rule.minValue, rule.maxValue));
          break;
        }
        st.noiseState = _xorshift32(st.noiseState ?? _fnv1a(rule.id));
        final u = st.noiseState! / 0xffffffff; // [0,1]
        final noise = (2 * u - 1) * a;         // [-a, a]
        _write(p, rule.targetPath, _clamp(clean + noise, rule.minValue, rule.maxValue));
      }
      break;
    ```
    (Seed lazily on first use: `st.noiseState ?? _fnv1a(rule.id)`, then step. This guarantees the first scan already uses a stepped value derived deterministically from the id. Keep everything else byte-identical. Adjust the `u` normalization/divisor to whatever your bounded/deterministic tests assert — the invariants are: `|noise| <= a`, deterministic from `rule.id`, and varies across scans.)

- [ ] **Step 4: Tests → PASS. `serialization_roundtrip_test.dart` stays green (no data change yet; determinism holds). `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(sim): measurement-noise behaviour (clean source + bounded deterministic noise)`.

---

### Task 2: Editor UI + Noisy Level Measurement showcase

**Files:**
- Modify: `mobile/lib/screens/simulated_io_screen.dart` (dropdown + fields), `mobile/lib/data/default_projects.dart` (new project)
- Test: `mobile/test/simulated_io_screen_test.dart` (extend), `mobile/test/noise_measurement_integration_test.dart`

- [ ] **Step 1: Editor UI.** Add **"Measurement Noise"** (value `noise`) to the behaviour dropdown. When selected, show (mirroring the WS9 `firstOrderLag`/`deadTime` conditional-field pattern + `TagAutocompleteField` + adaptive dialog): a **"Clean source tag"** field bound to `sourcePath`, a **"Noise amplitude (±)"** numeric field bound to `targetValue`, and min/max. `initialValue:` on the dropdown; no overflow at 360/320; dark theme.
  - Extend the sim editor widget test: open the rule editor, select "Measurement Noise", assert the source + amplitude fields appear and editing them updates the rule (`sourcePath`/`targetValue`); `takeException()` null at 320.

- [ ] **Step 2: Noisy Level Measurement demo** in `default_projects.dart` (mirror the WS13 `proj_cascade_tanks` or WS9 reactor project for exact constructors; add to `DefaultProjects.all()`):
  - Tags: `Fill_Valve` (FLOAT64 %, Internal, 55), `Tank_Level` (FLOAT64 %, SimulatedInput, init ~20 — the clean level), `Level_Meas` (FLOAT64 %, SimulatedInput, init ~20 — noisy), `Level_Filtered` (FLOAT64 %, SimulatedInput, init ~20 — smoothed).
  - Sim rules:
    - `Tank_Level`: analog-scaled `integrate` from `Fill_Valve` (`sourcePath:'Fill_Valve'`, `refValue:100`, positive `ratePerSec`) + a constant outflow; clamp 0–100.
    - `Level_Meas`: `noise` — `sourcePath:'Tank_Level'`, `targetValue:` a few % (e.g. 2.5), clamp 0–100.
    - `Level_Filtered`: `firstOrderLag` — `sourcePath:'Level_Meas'`, a modest `tauSec` (e.g. 1.5), clamp 0–100.
  - HMI: gauges for `Tank_Level`, `Level_Meas`, `Level_Filtered`.
  - A Continuous `PlcTask` (trivial program; the process is sim-driven — mirror how `proj_cascade_tanks` wires its task) so the project is self-consistent for the round-trip guard.

- [ ] **Step 3: Showcase integration test** (`mobile/test/noise_measurement_integration_test.dart`): load the project; run the full scan pipeline for enough scans; assert (a) `Level_Meas` stays within the amplitude band of `Tank_Level` (`|Level_Meas - Tank_Level| <= amplitude`) on every scan and does NOT drift, (b) `Level_Meas` VARIES scan-to-scan (records more than one distinct value / non-zero variance), and (c) `Level_Filtered` has a SMALLER scan-to-scan variation than `Level_Meas` (the lag attenuates the jitter) — compute successive-difference magnitudes and compare. Falsifiable (with amplitude 0 there'd be no jitter to filter). Confirm `serialization_roundtrip_test.dart` stays green with the new project (the determinism crux).

- [ ] **Step 4: Verify.** `flutter analyze` → clean; `flutter test` → all pass (354 + new); `flutter build web --release` → succeeds. Discard regenerated plugin-registrant churn (`git checkout -- linux/flutter macos/Flutter windows/flutter` from `mobile/`) before finishing.
- [ ] **Step 5: Commit** `feat(sim): Noisy Level Measurement demo (clean/noisy/filtered) + editor support`.

---

### Task 3: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user can configure a Measurement Noise rule, and the Noisy Level project shows a smooth true level, a jittery measurement bounded around it, and a filtered reading with attenuated jitter.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** deterministic seeded PRNG + `noise` behaviour reusing existing fields (Task 1) ✓; editor UI + clean/noisy/filtered demo + variance test (Task 2) ✓; validation (Task 3) ✓.
- **Additivity/guard:** `noise` is a new behaviour string reusing serialized fields (no model change); existing behaviours untouched; the new project is additive; WS6 round-trip stays green **because the PRNG is seeded deterministically from `rule.id`** (a stable FNV hash, identical across a project and its round-trip within a run). Engine stays never-throws/hangs.
- **Type consistency:** `RuleRuntime.noiseState`, `_fnv1a`/`_xorshift32` helpers, the `case 'noise'` write, and the demo's `sourcePath`/`targetValue` usage are consistent; `SimRuntime.byRuleId.clear()` already clears the PRNG state at every lifecycle site.
- **Deferred:** Gaussian/pink noise, per-sensor drift/bias, auto-tune, MIMO plants.
