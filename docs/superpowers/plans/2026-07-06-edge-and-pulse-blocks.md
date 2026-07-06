# Edge Detectors & Pulse Timer (WS12) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the IEC 61131-3 edge detectors `R_TRIG`/`F_TRIG` and the pulse timer `TP` as executable, stateful FBD blocks, plus a "Pulse Output" demo showing an edge-gated fixed-width pulse.

**Architecture:** The three blocks join the `fbd_pins.dart` registry; `fbd_exec.dart` gets per-block edge state (previous `CLK` for R_TRIG/F_TRIG) and pulse state (`[et, running, prevIN]` for TP) in `FbdRuntime` and `case 'R_TRIG'/'F_TRIG'/'TP'` producing the output maps; the FBD editor palette gains the three entries (pins render from the registry). A new "Pulse Output" default project wires `Start_Btn → R_TRIG → TP → Pulse_Out` so each button rising edge fires a one-shot of fixed width; verified by pure unit tests + the WS6 round-trip guard + a closed-loop pulse test.

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding (generic IEC pin names `CLK`/`IN`/`PT`/`Q`/`ET` are fine).
- Dark theme; responsive. `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Engines pure Dart in `mobile/lib/models` (UI-free); force-aware writes; NEVER throws / NEVER hangs. `TP` uses the scan clock (`dtMs`); `R_TRIG`/`F_TRIG` are clock-independent. Edge/pulse state keyed by block id, cleared on project switch.
- Lossless persistence preserved — the WS6 `serialization_roundtrip_test.dart` (structural + 20-scan scan-equivalence per default project, including the new demo project) must stay green.
- No RenderFlex overflow at 360/320/1400. Existing 299 tests must keep passing.

**Sequencing:** Task 1 (engine) is the foundation. Task 2 (palette + demo project + closed-loop test) builds on it. Task 3 validates.

---

### Task 1: Edge/pulse engine — registry + stateful executor

**Files:**
- Modify: `mobile/lib/models/fbd_pins.dart` (add `R_TRIG`/`F_TRIG`/`TP` pins), `mobile/lib/models/fbd_exec.dart` (`FbdRuntime` edge+pulse state + the three `case`s)
- Test: `mobile/test/fbd_exec_test.dart` (extend), `mobile/test/fbd_pins_test.dart` (extend)

**Interfaces:**
- `fbdInputPins('R_TRIG')` → `['CLK']`; `fbdInputPins('F_TRIG')` → `['CLK']`; `fbdInputPins('TP')` → `['IN','PT']`.
- `fbdOutputPins('R_TRIG')` → `['Q']`; `fbdOutputPins('F_TRIG')` → `['Q']`; `fbdOutputPins('TP')` → `['Q','ET']`.
- `FbdRuntime` carries per-block edge state (prev `CLK`) and pulse state (`[et, running, prevIN]`). `_evalBlock` handles the three types → output maps.

- [ ] **Step 1: Write failing tests.**
  - `fbd_pins_test.dart`: assert the six pin lists above.
  - `fbd_exec_test.dart` — read the existing TON/PID/counter tests for the harness (build a program with the block fed by `CONST`/`TAG_INPUT`, wire outputs to `TAG_OUTPUT`s, run scans with the existing runtime). Cases:
    - **R_TRIG:** hold `CLK` true across scans → `Q` true on the FIRST scan only, false thereafter; toggle `CLK` false then true → `Q` true again for one scan. (A level-passthrough would keep Q true — this catches it.)
    - **F_TRIG:** `CLK` true then false → `Q` true one scan on the falling edge, false otherwise; `CLK` starting false → no spurious Q.
    - **TP fixed-width, IN drops early:** `PT=300ms`, scan `dtMs=100`. Rising edge on `IN`, then drop `IN` to false the next scan → `Q` STAYS true until `ET` reaches 300 (≈3 scans), then `Q` false; `ET` holds at 300. (Proves the pulse width is set by PT, not IN.)
    - **TP non-retriggerable:** while a pulse is running, another `IN` rising edge does NOT restart/extend it.
    - **TP re-arm:** after the pulse completes and `IN` returns false, a new `IN` rising edge starts a fresh pulse; `ET` reset to 0 at re-arm.
    - **TP PT<=0:** zero-width — `Q` does not latch true beyond the trigger.
    - **Unwired inputs → false/0:** an R_TRIG/F_TRIG/TP with no wired input → `Q` false, `ET` 0, no throw.
    - **State reset:** after `rt.clear()`, all three reset (edge prev cleared, pulse et/running/prevIN cleared).

- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `fbd_pins.dart`: add the three cases to `fbdInputPins` and `fbdOutputPins` (const lists exactly as in Interfaces).
  - `fbd_exec.dart`: extend `FbdRuntime` with `final Map<String, bool> _prevClk = {};` (R_TRIG/F_TRIG) and `final Map<String, List<num>> _pulse = {};` (`[et, running, prevIN]` for TP); clear both in `clear()` alongside `_elapsedMs`/`_pid`/`_counters`. Add the three `case`s in `_evalBlock`:
    - `R_TRIG`: `final clk = inputs.isNotEmpty ? _truthy(inputs[0]) ?? false : false; final prev = rt._prevClk[b.id] ?? false; final q = clk && !prev; rt._prevClk[b.id] = clk; return {'Q': q};`
    - `F_TRIG`: same but `final q = !clk && prev;`. (Use a distinct state key per block id — R_TRIG and F_TRIG never share an id, so one `_prevClk` map is fine.)
    - `TP`: read `inVal = _truthy(inputs[0]) ?? false` and `pt = _asNum(inputs.length>1?inputs[1]:null)`. Load `[et, running, prevIN]` (default `[0,0,0]`). Detect the start edge `inVal && prevIN==0`. Logic: if not running and a start edge occurs and `pt > 0` → running=1, et=0 (begin). If running → `et += dtMs`; if `et >= pt` → `et = pt`, running=0, and Q is false this scan (pulse ended) — decide the exact boundary so total Q-true duration ≈ PT (Q true while running before ET reaches PT). `Q` = running==1 (true during the pulse). When not running and `inVal` false → `et = 0` (re-arm/idle). Store `[et, running, inVal?1:0]`. Return `{'Q': q, 'ET': et}`. Keep it pure/never-throw; single-pass; use `dtMs` only here.
    - NOTE: make the boundary precise and covered by the "fixed-width" test (e.g. with PT=300, dtMs=100: Q true on the trigger scan and the next two, ET progresses 0→100→200→300, Q drops the scan ET reaches 300 — a ~300ms pulse). Whatever exact convention you pick, encode it in the test assertions.

- [ ] **Step 4: Tests → PASS. `serialization_roundtrip_test.dart` still green (no data change yet). `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(fbd): R_TRIG/F_TRIG edge detectors + TP pulse timer`.

---

### Task 2: Palette entries + one-shot Pulse Output demo

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart` (palette), `mobile/lib/data/default_projects.dart` (new project)
- Test: `mobile/test/pulse_loop_integration_test.dart`

- [ ] **Step 1: Add `R_TRIG`, `F_TRIG`, `TP` to the FBD editor palette** (`fbd_editor_screen.dart`), following the existing palette-item pattern the `TON`/`PID`/counter entries use (read it, match the signature). Labels "Rising Edge (R_TRIG)", "Falling Edge (F_TRIG)", "Pulse Timer (TP)" and sensible icons. Pins render automatically from `fbd_pins.dart`.

- [ ] **Step 2: Add the "Pulse Output" default project** in `default_projects.dart` (mirror the structure of an existing FBD project — read the WS11 `Batch Counter` project or the WS10 `Tank Level PID Control` project and copy its shape: tags, one FBD program, sim rules, an HMI, tasks; add it to what `DefaultProjects.all()` returns). Content:
  - Tags: `Start_Btn` (BOOL, SimulatedInput, init false), `Pulse_Out` (BOOL, SimulatedOutput, init false), `Pulse_ET` (INT, SimulatedOutput/Internal, init 0), `Pulse_Time` (INT, Internal, e.g. 3000).
  - FBD `PulseOut_FBD`: `TAG_INPUT Start_Btn`→R_TRIG.CLK; `R_TRIG.Q`→TP.IN; `TAG_INPUT Pulse_Time` (or `CONST '3000'`)→TP.PT; `TP.Q`→`TAG_OUTPUT Pulse_Out`; `TP.ET`→`TAG_OUTPUT Pulse_ET`. Pin-addressed `FbdWire`s.
  - Sim rule: `Start_Btn` driven by a `pulse` behaviour with an on-phase LONGER than `Pulse_Time` (so the output pulse width is visibly set by TP, not the button hold).
  - HMI dashboard: `Start_Btn` (indicator), `Pulse_Out` (indicator/lamp), `Pulse_ET` (numeric) — match existing HMI component constructors.
  - Continuous `PlcTask` running `PulseOut_FBD`.

- [ ] **Step 3: Write `mobile/test/pulse_loop_integration_test.dart`** — load the new project; run the full scan pipeline (sim → LD → FBD → SFC → ST) for enough scans; assert (a) a button rising edge produces a `Pulse_Out` pulse of ~`Pulse_Time` width, (b) `Pulse_Out` drops after `Pulse_Time` EVEN WHILE `Start_Btn` is still held (the falsifiable heart of the demo — drive `Start_Btn` explicitly with a long hold, or use the shipped pulse rule and observe), and (c) a later button press produces another pulse. Confirm `serialization_roundtrip_test.dart` stays green with the new project.

- [ ] **Step 4: Verify.** `flutter analyze` → clean; `flutter test` → all pass (299 + new); `flutter build web --release` → succeeds. Discard regenerated plugin-registrant churn (`git checkout -- linux/flutter macos/Flutter windows/flutter` from `mobile/`) before finishing.
- [ ] **Step 5: Commit** `feat(fbd): one-shot Pulse Output demo (R_TRIG-gated TP) + palette`.

---

### Task 3: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user can place `R_TRIG`/`F_TRIG`/`TP`, wire them, and the Pulse Output project emits a fixed-width pulse per button edge.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** R_TRIG/F_TRIG/TP pins + stateful executor with correct edge + non-retriggerable pulse semantics (Task 1) ✓; palette entries + edge-gated pulse demo project + closed-loop test (Task 2) ✓; validation (Task 3) ✓.
- **Additivity/guard:** the three are new block types (existing FBD unchanged); the new demo project is additive; WS6 round-trip stays green (new project self-consistent, no new persisted field). Engine stays never-throws/hangs.
- **Type consistency:** pins match between `fbd_pins.dart`, the executor output maps (`{'Q'}` for edges, `{'Q','ET'}` for TP), and the demo wiring; `FbdRuntime` edge/pulse state cleared alongside `_elapsedMs`/`_pid`/`_counters`.
- **Deferred:** ST/IL variants; retriggerable pulse; SR/RS bistables.
