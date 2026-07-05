# Counter Function Blocks (WS11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the IEC 61131-3 counter function blocks — `CTU`/`CTD`/`CTUD` (edge-triggered up/down counters with reset/load and preset) — as executable, stateful FBD blocks, plus a self-resetting "Batch Counter" demo project.

**Architecture:** The counters join the `fbd_pins.dart` registry; `fbd_exec.dart` gets per-block counter state in `FbdRuntime` (count + previous edge-input levels, like `TON`'s `_elapsedMs` / `PID`'s `_pid`) and `case 'CTU'/'CTD'/'CTUD'` producing the output maps; the FBD editor palette gains the three entries (pins render from the registry). A new "Batch Counter" default project wires a `CTU` with `Q` fed back to `R` (self-resetting batch) driven by a pulsed part sensor; verified by pure counter tests + the WS6 round-trip guard + a closed-loop counting test.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding (generic IEC pin names `CU`/`CD`/`R`/`LD`/`PV`/`Q`/`CV`/`QU`/`QD` are fine).
- Dark theme; responsive. `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Engines pure Dart in `mobile/lib/models` (UI-free); force-aware writes; NEVER throws / NEVER hangs. Counters are edge-triggered (advance only on a rising edge of the count input) and clock-independent (`dtMs` unused).
- Lossless persistence preserved — the WS6 `serialization_roundtrip_test.dart` (structural + 20-scan scan-equivalence per default project, including the new demo project) must stay green.
- No RenderFlex overflow at 360/320/1400. Existing 277 tests must keep passing.

**Sequencing:** Task 1 (counter engine) is the foundation. Task 2 (palette + demo project + closed-loop test) builds on it. Task 3 validates.

---

### Task 1: Counter engine — registry + stateful executor

**Files:**
- Modify: `mobile/lib/models/fbd_pins.dart` (add `CTU`/`CTD`/`CTUD` pins), `mobile/lib/models/fbd_exec.dart` (`FbdRuntime` counter state + the three `case`s)
- Test: `mobile/test/fbd_exec_test.dart` (extend), `mobile/test/fbd_pins_test.dart` (extend)

**Interfaces:**
- `fbdInputPins('CTU')` → `['CU','R','PV']`; `fbdInputPins('CTD')` → `['CD','LD','PV']`; `fbdInputPins('CTUD')` → `['CU','CD','R','LD','PV']`.
- `fbdOutputPins('CTU')` → `['Q','CV']`; `fbdOutputPins('CTD')` → `['Q','CV']`; `fbdOutputPins('CTUD')` → `['QU','QD','CV']`.
- `FbdRuntime` carries per-block counter state keyed by block id. `_evalBlock` handles `CTU`/`CTD`/`CTUD` → output maps.

- [ ] **Step 1: Write failing tests.**
  - `fbd_pins_test.dart`: assert the six pin lists above (input + output for each of CTU/CTD/CTUD).
  - `fbd_exec_test.dart` — read the existing harness (build a program with the counter block fed by `CONST`/`TAG_INPUT` blocks on its pins, wire outputs to `TAG_OUTPUT`s, run scans with the existing `executeFbdPrograms`/`FbdRuntime` entry point; look at how the TON and PID tests are written and mirror them). Cases:
    - **CTU rising-edge counts once:** `PV=3`. Hold `CU` true across several scans with `R=false` → `CV` increments to **1 and stays 1** (level, not edge, would keep counting — this catches it). Toggle `CU` false then true again → `CV` becomes 2. After 3 rising edges `Q` becomes true (`CV>=PV`).
    - **CTU reset priority:** with `CV>0`, set `R=true` → `CV=0`, `Q=false`, even if `CU` also has a rising edge that scan (reset wins).
    - **CTD counts down + floors + load:** `PV=2`. `LD=true` once → `CV=2`. Then rising edges on `CD` → `CV` 1, 0, and **stays 0** (floors, doesn't go negative). `Q` true when `CV<=0`.
    - **CTUD up/down + priority:** `PV=2`. Rising `CU` edges raise `CV`; rising `CD` edges lower it (floored at 0). `QU` true at `CV>=PV`, `QD` true at `CV<=0`. `R=true` → `CV=0` (priority over `LD` and counting); `LD=true` (with `R=false`) → `CV=PV`.
    - **Unwired inputs → false/0:** a counter with only `CU` wired (no `R`/`PV`) counts on edges with `PV` read as 0 (so `Q` true immediately), no throw.
    - **State reset:** after `rt.clear()`, `CV` and the stored edge levels reset (a fresh counter starts at 0).

- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `fbd_pins.dart`: add the `CTU`/`CTD`/`CTUD` cases to `fbdInputPins` and `fbdOutputPins` (use `const` lists exactly as in the Interfaces above).
  - `fbd_exec.dart`: extend `FbdRuntime` with a counter-state map, e.g. `final Map<String, List<num>> _counters = {};` holding `[cv, prevCU, prevCD]` (prev levels stored as 0/1; CTU uses index 1, CTD uses index 2, CTUD uses both) and clear it in `clear()` alongside `_elapsedMs` and `_pid`. Add the three `case`s in `_evalBlock`. Read inputs by ordered pin position (the ordered `inputs` list follows `fbdInputPins(type)`), coerce BOOLs with the existing `_truthy(...) ?? false`, coerce `PV` with `_asNum(...)` truncated to `int`. Load `[cv, prevCU, prevCD]` (default `[0,0,0]`), apply the priority logic (reset/load first, then edge counting: rising edge = input true AND stored prev level 0), floor `CV` at 0 on down paths, compute the boolean outputs, store the updated `[cv, curCU?1:0, curCD?1:0]`, and return the output map (`{'Q':q,'CV':cvInt}` / `{'QU':qu,'QD':qd,'CV':cvInt}`). Keep it pure + never-throw (all numeric/null-guarded); `dtMs` is unused for counters.

- [ ] **Step 4: Tests → PASS. `serialization_roundtrip_test.dart` still green (no data change yet). `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(fbd): CTU/CTD/CTUD counter blocks (edge-triggered, reset/load/preset)`.

---

### Task 2: Counter palette entries + self-resetting Batch Counter demo

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart` (palette), `mobile/lib/data/default_projects.dart` (new project)
- Test: `mobile/test/counter_loop_integration_test.dart`

- [ ] **Step 1: Add `CTU`, `CTD`, `CTUD` to the FBD editor palette** (`fbd_editor_screen.dart`), following the existing palette-item pattern (the same helper the `TON`/`PID` entries use — read it and match its signature). Sensible labels ("Count Up", "Count Down", "Up/Down Counter") and icons. Pins render automatically from `fbd_pins.dart`.

- [ ] **Step 2: Add the "Batch Counter" default project** in `default_projects.dart` (mirror the structure of an existing FBD project — read the WS10 `proj_tank_level_pid` project added in the previous workstream and copy its shape: tags, one FBD program, sim rules, an HMI, tasks). Content:
  - Tags: `Part_Sensor` (BOOL, SimulatedInput), `Batch_Size` (INT, Internal, e.g. 5), `Batch_Done` (BOOL, SimulatedOutput or Internal), `Count` (INT, SimulatedOutput).
  - FBD `BatchCount_FBD`: blocks — `TAG_INPUT Part_Sensor`→CTU.CU, a `TAG_INPUT Batch_Size` (or `CONST 5`)→CTU.PV, `CTU`, `TAG_OUTPUT Batch_Done`←CTU.Q, `TAG_OUTPUT Count`←CTU.CV, and the reset: wire `CTU.Q`→`CTU.R` (self-reset — the same `Q` output pin fans out to both the `Batch_Done` TAG_OUTPUT and back to the `R` input). Pin-addressed `FbdWire`s. (If a direct output→same-block-input wire is awkward in the evaluator's topological order, instead route `Q` to `Batch_Done` and wire `Batch_Done`'s tag into `R` via a second `TAG_INPUT Batch_Done`→CTU.R — pick whichever the evaluator supports cleanly; verify with the test.)
  - Sim rules: `Part_Sensor` driven by a `pulse` behaviour (periodic part arrivals) so the counter advances in RUN mode.
  - HMI dashboard: components for `Count` (numeric/gauge), `Batch_Size` (display), `Batch_Done` (indicator) — match existing HMI component constructors.
  - Task wiring so `BatchCount_FBD` runs (Continuous task).

- [ ] **Step 3: Write `mobile/test/counter_loop_integration_test.dart`** — load the new project; run the full scan pipeline (sim → LD → FBD → SFC → ST) for enough scans; assert (a) `Count` advances on successive part rising edges (one per edge, **not** once per scan — drive `Part_Sensor` with explicit true/false transitions in the test if the pulse timing makes per-edge assertions fiddly, or run long enough to observe monotonic stepped increments), (b) `Batch_Done` fires when `Count` reaches `Batch_Size`, and (c) the self-reset brings `Count` back down toward 0 to begin the next batch (not latched forever). Falsifiable: note that a level-triggered counter would over-count and a broken reset would latch `Batch_Done`. Confirm `serialization_roundtrip_test.dart` stays green with the new project.

- [ ] **Step 4: Verify.** `flutter analyze` → clean; `flutter test` → all pass (277 + new); `flutter build web --release` → succeeds. Discard any regenerated plugin-registrant churn (`git checkout -- linux/flutter macos/Flutter windows/flutter` from `mobile/`) before finishing.
- [ ] **Step 5: Commit** `feat(fbd): self-resetting Batch Counter demo (CTU counts parts to preset) + palette`.

---

### Task 3: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user can place a `CTU`/`CTD`/`CTUD` block, wire it, and the Batch Counter project counts parts, fires `Batch_Done` at the preset, and self-resets.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** CTU/CTD/CTUD pins + stateful edge-triggered executor with reset/load priority + floors (Task 1) ✓; palette entries + self-resetting closed-loop demo project + counting test (Task 2) ✓; validation (Task 3) ✓.
- **Additivity/guard:** the counters are new block types (existing FBD unchanged); the new demo project is additive; WS6 round-trip stays green (new project self-consistent, no new persisted field). Engine stays never-throws/hangs and clock-independent.
- **Type consistency:** `CTU`/`CTD`/`CTUD` pins match between `fbd_pins.dart`, the executor output maps (`{'Q','CV'}` / `{'QU','QD','CV'}`), and the demo wiring; `FbdRuntime` counter state cleared alongside `_elapsedMs`/`_pid`.
- **Deferred:** ST/IL counter calls; retentive counters; DINT range specifics.
