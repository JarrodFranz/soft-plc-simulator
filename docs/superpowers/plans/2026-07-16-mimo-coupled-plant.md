# MIMO Coupled Plant + Interaction Analysis (RGA) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Two-Zone coupled thermal plant (2×2, from stacked SimRules) with two PID loops and a static decoupler, plus an Interaction Analysis panel that identifies the plant's steady-state gain matrix by step tests, computes the RGA, and recommends loop pairing.

**Architecture:** A pure `interaction_analysis.dart` (step-test gain-matrix identification + RGA) reusing the auto-tune deep-copy experiment pattern, a panel wired into the shell nav, and a new default project whose FBD program has two PID loops + a static decoupler. No engine/model change; no persisted schema change.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `models/interaction_analysis.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical project + params → identical result; experiments run on a deep copy and never mutate live tags.
- Additive/backward-compatible: no persisted schema change; the new default project appends to `DefaultProjects.all()`; no existing project altered; default-projects round-trip/scan-equivalence stays green.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Key facts (verified)

- `applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)` runs ALL rules in order, each mutating its target in place; multiple rules can target one tag. `integrate`: `cur += ratePerSec·dt·(source/refValue)` (clamped min/max). `firstOrderLag`: `cur += (source − cur)·(dt/tauSec)` when `sourcePath` set — an exact difference/conduction term. `SimRuntime()` default ctor.
- `SimRule` ctor style: `SimRule(id:, name:, targetPath:, behavior:, ratePerSec:, sourcePath:, refValue:, tauSec:, minValue:, maxValue:, condition: const [])` (mirror `_cascadeTanksProject` / `_stReactorProject` in `default_projects.dart`).
- Deep copy: `PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())))`. `dynamic readPath(PlcProject, String)` / `void writePath(PlcProject, String, dynamic)` (`tag_resolver.dart`) resolve by tag NAME.
- FBD pins (`fbd_pins.dart`): `MUL` inputs `IN1,IN2,…` output `OUT`; `SUB` inputs `IN1,IN2` output `OUT`; `LIMIT` inputs `MN,IN,MX` output `OUT`; `PID` inputs `SP,PV,KP,KI,KD` output `CV`; `CONST` literal in `tagBinding` (`_parseConst`); `TAG_INPUT`/`TAG_OUTPUT` `tagBinding` = tag path (name). `FbdBlock{String id,type,tagBinding,title; double x,y;}`, `FbdWire{String fromBlockId,fromPin,toBlockId,toPin;}`. `PlcProgram.fbdBlocks`/`.fbdWires`; `PlcProgram(name:, language:'FunctionBlockDiagram', fbdBlocks:[...], fbdWires:[...], description:)`.
- The auto-tune deep-copy experiment lives in `mobile/lib/models/pid_autotune.dart` (`relayAutoTune`) — mirror its copy/drive/read/applySimRules loop.
- Shell nav: `String _activeViewId`; PID auto-tune is `'PID_AUTOTUNE'` with a nav ListTile (~`workspace_shell.dart:2106`, `Icons.tune`) + center-view case (~`:2726`) returning `PidAutoTuneScreen(currentProject: _activeProject, onProjectUpdated: _markDirtyAndAutosave)`. Mirror this for `'INTERACTION'`.
- `DefaultProjects.all()` list — append the new project. No literal project-count assertion to bump (tests use `.all().length`).

---

### Task 1: RGA analysis engine (`interaction_analysis.dart`)

**Files:**
- Create: `mobile/lib/models/interaction_analysis.dart`
- Test: `mobile/test/interaction_analysis_test.dart`

**Interfaces:**
- Produces: `StepTestParams`, `GainMatrix{double k11,k12,k21,k22; bool converged; String? warning;}`, `RgaResult{double lambda11; String pairing; String? warning;}`, `GainMatrix identifyGainMatrix(PlcProject, {mv1Path, mv2Path, pv1Path, pv2Path, StepTestParams})`, `RgaResult computeRga(GainMatrix)`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/interaction_analysis_test.dart`. Build a coupled 2×2 plant fixture (two integrate-heated PVs with firstOrderLag cross-conduction), and assert:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';

PlcProject _twoZone() {
  final tags = [
    PlcTag(name: 'HA', path: 'HA', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    PlcTag(name: 'HB', path: 'HB', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    PlcTag(name: 'TA', path: 'TA', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
    PlcTag(name: 'TB', path: 'TB', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
    PlcTag(name: 'AMB', path: 'AMB', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
  ];
  final rules = [
    // TA: heat from HA + conduction toward TB + loss toward AMB
    SimRule(id: 'a0', name: 'TA heat', targetPath: 'TA', behavior: 'integrate',
        ratePerSec: 3.0, sourcePath: 'HA', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'a1', name: 'TA<->TB', targetPath: 'TA', behavior: 'firstOrderLag',
        sourcePath: 'TB', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'a2', name: 'TA loss', targetPath: 'TA', behavior: 'firstOrderLag',
        sourcePath: 'AMB', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
    // TB: heat from HB + conduction toward TA + loss toward AMB
    SimRule(id: 'b0', name: 'TB heat', targetPath: 'TB', behavior: 'integrate',
        ratePerSec: 3.0, sourcePath: 'HB', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'b1', name: 'TB<->TA', targetPath: 'TB', behavior: 'firstOrderLag',
        sourcePath: 'TA', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
    SimRule(id: 'b2', name: 'TB loss', targetPath: 'TB', behavior: 'firstOrderLag',
        sourcePath: 'AMB', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
  ];
  return PlcProject(id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules);
}

StepTestParams _params() => StepTestParams(
    baseMv: 30, stepDelta: 20, dtMs: 100, maxScans: 20000, settleEps: 1e-4, settleWindow: 20);

void main() {
  test('identifyGainMatrix finds a coupled 2x2 with non-zero off-diagonal', () {
    final g = identifyGainMatrix(_twoZone(),
        mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    expect(g.converged, isTrue, reason: g.warning);
    expect(g.k11.abs(), greaterThan(0));
    expect(g.k22.abs(), greaterThan(0));
    expect(g.k12.abs(), greaterThan(0), reason: 'HB affects TA via conduction');
    expect(g.k21.abs(), greaterThan(0), reason: 'HA affects TB via conduction');
  });

  test('identifyGainMatrix does not mutate the source project', () {
    final p = _twoZone();
    final before = p.tags.firstWhere((t) => t.name == 'TA').value;
    identifyGainMatrix(p, mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    expect(p.tags.firstWhere((t) => t.name == 'TA').value, before);
  });

  test('identifyGainMatrix is deterministic', () {
    final a = identifyGainMatrix(_twoZone(), mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    final b = identifyGainMatrix(_twoZone(), mv1Path: 'HA', mv2Path: 'HB', pv1Path: 'TA', pv2Path: 'TB', params: _params());
    expect(a.k11, b.k11);
    expect(a.k12, b.k12);
    expect(a.k21, b.k21);
    expect(a.k22, b.k22);
  });

  test('computeRga golden + pairing bands', () {
    // Diagonal-dominant, low interaction: K = [[2,0.2],[0.2,2]] -> det=3.96, lambda11=4/3.96=1.0101
    final low = computeRga(const GainMatrix(k11: 2, k12: 0.2, k21: 0.2, k22: 2, converged: true));
    expect(low.lambda11, closeTo(4 / 3.96, 1e-9));
    expect(low.pairing.toLowerCase(), contains('diagonal'));
    // Strong interaction: K = [[1,0.9],[0.9,1]] -> det=0.19, lambda11=1/0.19=5.26... actually pick one in (0.33,0.67):
    // K=[[1,0.8],[0.8,1]] det=0.36 lambda11=1/0.36=2.77 (still >0.67). Use K=[[1,1.2],[0.8,1]] det=1-0.96=0.04 lambda=1/0.04=25 -> high.
    // For a mid-band lambda: K=[[1,2],[2,1]] det=1-4=-3 lambda11=1/-3=-0.333 -> off-diagonal / negative.
    final off = computeRga(const GainMatrix(k11: 1, k12: 2, k21: 2, k22: 1, converged: true));
    expect(off.lambda11, closeTo(1 / -3, 1e-9));
    expect(off.pairing.toLowerCase(), anyOf(contains('off-diagonal'), contains('ill-conditioned')));
  });

  test('computeRga singular matrix warns and returns NaN lambda', () {
    final s = computeRga(const GainMatrix(k11: 1, k12: 1, k21: 1, k22: 1, converged: true)); // det=0
    expect(s.warning, isNotNull);
    expect(s.lambda11.isNaN, isTrue);
  });
}
```

Note for the implementer: adjust `SimRule`/`PlcTag`/`PlcProject`/`GainMatrix` constructor arg names to the real ones if any differ (mirror `pid_autotune.dart`'s experiment + the existing sim tests). If the mid-band pairing example doesn't land where intended, keep the ASSERTIONS about non-zero off-diagonal, determinism, golden `λ11`, band strings, and the singular case — the exact numeric fixtures may be tuned so long as they exercise each band.

- [ ] **Step 2: Run — expect FAIL** (`interaction_analysis.dart` missing).

Run: `cd mobile && flutter test test/interaction_analysis_test.dart`

- [ ] **Step 3: Implement**

Create `mobile/lib/models/interaction_analysis.dart` (imports: `dart:convert`, `dart:math`, `project_model.dart`, `tag_resolver.dart`, `sim_engine.dart`):
- `StepTestParams` (fields per spec), `GainMatrix` (const ctor, fields + `converged` + `warning`), `RgaResult`.
- `identifyGainMatrix`: a helper `double _settle(PlcProject copy, SimRuntime rt, {required double mv1, required double mv2, required String mv1Path, mv2Path, pvPath, params})` that writes both MVs, runs `applySimRules` until both PVs' per-scan |Δ| < `settleEps` for `settleWindow` scans (or `maxScans`), returns the final PV. Do it on ONE fresh deep copy: settle at base → record p10,p20; step MV1 → record; make a SECOND fresh deep copy for the MV2 test (or re-settle at base then step MV2) → record; compute the four gains. Set `converged=false`+warning if any settle hit `maxScans`.
- `computeRga`: `det = k11*k22 - k12*k21`; if `det.abs() < 1e-9` → `RgaResult(lambda11: double.nan, pairing: 'N/A', warning: 'ill-conditioned (near-singular gain matrix)')`; else `lambda11 = (k11*k22)/det` and pairing per the spec bands (≥0.67 diagonal/low; 0.33–0.67 strong-interaction/diagonal+decouple; ≤0.33 off-diagonal; <0 or >1 append ill-conditioned note).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/interaction_analysis.dart test/interaction_analysis_test.dart` (zero warnings; pure Dart).

```bash
git add mobile/lib/models/interaction_analysis.dart mobile/test/interaction_analysis_test.dart
git commit -m "feat(mimo): gain-matrix step-test identification + RGA analysis (pure)"
```

---

### Task 2: Two-Zone MIMO default project (plant + PID loops + decoupler)

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (add `_mimoTwoZoneProject()` + register in `all()`)
- Test: `mobile/test/mimo_project_test.dart` (create)

**Interfaces:**
- Produces: a default project (suggested id `proj_mimo_two_zone`, name `"MIMO — Two Thermal Zones"`) with plant SimRules, a `TwoZone_FBD` program (PID_A/PID_B + decoupler), and an HMI.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/mimo_project_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';

PlcProject _mimo() => DefaultProjects.all().firstWhere((p) => p.id == 'proj_mimo_two_zone');

void main() {
  test('MIMO project registered and round-trips', () {
    final p = _mimo();
    expect(p.name, 'MIMO — Two Thermal Zones');
    final back = PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
  });

  test('plant is genuinely coupled (RGA off-diagonal non-zero)', () {
    final g = identifyGainMatrix(_mimo(),
        mv1Path: 'Heater_A', mv2Path: 'Heater_B', pv1Path: 'Temp_A', pv2Path: 'Temp_B',
        params: const StepTestParams(baseMv: 30, stepDelta: 20, dtMs: 100, maxScans: 20000, settleEps: 1e-4, settleWindow: 20));
    expect(g.converged, isTrue, reason: g.warning);
    expect(g.k12.abs(), greaterThan(0));
    expect(g.k21.abs(), greaterThan(0));
  });
}
```

(Confirm the real MV/PV tag names — `Heater_A`/`Heater_B`/`Temp_A`/`Temp_B` — match what you author in the project.)

- [ ] **Step 2: Run — expect FAIL** (no `proj_mimo_two_zone`).

- [ ] **Step 3: Add `_mimoTwoZoneProject()`**

Model on `_fbdPidTankLevelProject` (structure) + `_cascadeTanksProject` (stacked SimRules). Register in `all()`.

Tags: `Heater_A`,`Heater_B` (SimulatedOutput, 0), `Temp_A`,`Temp_B` (SimulatedInput, 20 °C), `SP_A`,`SP_B` (Internal, e.g. 50/40 °C), `Amb` (Internal, 20 °C), `u_A`,`u_B` (Internal, PID outputs), plus decoupler CONST feed handled in the FBD (`d12`/`d21` as CONST blocks default '0').

Plant SimRules (stacked; the coupling MUST yield clearly non-zero off-diagonal gains — tune tauCouple so `k12`,`k21` are a meaningful fraction of `k11`,`k22`):
```dart
// Temp_A
SimRule(id:'sa0', name:'Zone A heater', targetPath:'Temp_A', behavior:'integrate',
    ratePerSec: 3.0, sourcePath:'Heater_A', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
SimRule(id:'sa1', name:'A<->B conduction', targetPath:'Temp_A', behavior:'firstOrderLag',
    sourcePath:'Temp_B', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
SimRule(id:'sa2', name:'Zone A heat loss', targetPath:'Temp_A', behavior:'firstOrderLag',
    sourcePath:'Amb', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
// Temp_B (symmetric)
SimRule(id:'sb0', name:'Zone B heater', targetPath:'Temp_B', behavior:'integrate',
    ratePerSec: 3.0, sourcePath:'Heater_B', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
SimRule(id:'sb1', name:'B<->A conduction', targetPath:'Temp_B', behavior:'firstOrderLag',
    sourcePath:'Temp_A', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
SimRule(id:'sb2', name:'Zone B heat loss', targetPath:'Temp_B', behavior:'firstOrderLag',
    sourcePath:'Amb', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
```

FBD program `TwoZone_FBD` (blocks + wires), reproducing the PID + decoupler wiring:
- Loop A: `TAG_INPUT SP_A`, `TAG_INPUT Temp_A`, `CONST Kp_A/Ki_A/Kd_A`, `PID pidA` → `TAG_OUTPUT u_A` (write `u_A`).
- Loop B: symmetric → `u_B`.
- Decoupler A: `TAG_INPUT u_A`, `TAG_INPUT u_B`, `CONST d12 ('0')`, `MUL(d12,u_B)→mA`, `SUB(u_A,mA)→sA`, `CONST c0 ('0')`, `CONST c100 ('100')`, `LIMIT(MN=c0,IN=sA,MX=c100)→ TAG_OUTPUT Heater_A`.
- Decoupler B: symmetric with `CONST d21 ('0')`, `MUL(d21,u_A)`, `SUB(u_B,mB)`, `LIMIT→ Heater_B`.
- One `PlcTask(type:'Continuous', periodMs: 200, programNames:['TwoZone_FBD'])`.

Give the PID blocks sensible starting gains (e.g. Kp 4, Ki 0.3, Kd 0). Set decoupler CONST `d12`/`d21` = `'0'` (coupled by default). Positions (`x`,`y`) laid out readably.

HMI (`GridDashboard`): SP_A/SP_B sliders or numeric, Temp_A/Temp_B gauges, Heater_A/Heater_B gauges, u_A/u_B readouts. No overflow.

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/mimo_project_test.dart`. If `k12`/`k21` come out ~0, strengthen the conduction (lower `tauCouple`) until clearly non-zero — do NOT weaken the assertion.

- [ ] **Step 5: Regression + analyze + commit**

Run: `cd mobile && flutter test test/serialization_roundtrip_test.dart test/project_repository_test.dart` (round-trip + count-relative tests green). `cd mobile && flutter analyze lib/data/default_projects.dart test/mimo_project_test.dart`.

```bash
git add mobile/lib/data/default_projects.dart mobile/test/mimo_project_test.dart
git commit -m "feat(mimo): 'Two Thermal Zones' default project (coupled plant + 2 PID loops + static decoupler)"
```

---

### Task 3: Decoupling demonstration test

**Files:**
- Test: `mobile/test/mimo_project_test.dart` (extend)

**Context:** Prove the decoupler works: with `d12`/`d21` = 0 an `SP_A` step disturbs `Temp_B`; with them set to the decoupling gains that cross-disturbance shrinks. This runs the CLOSED loop (FBD program + sim rules) via the scan-tick runtime (mirror how `pid_loop_integration_test.dart` runs a closed FBD loop).

- [ ] **Step 1: Write the failing/【characterization】 test**

Extend `mimo_project_test.dart` with a closed-loop run. Use the same scan harness the existing PID loop integration test uses (`runScanTick` / the FBD executor + `applySimRules` per tick — read `mobile/test/pid_loop_integration_test.dart` and mirror it). Steps:
- Load the MIMO project; run to near-steady with both SPs held; record `Temp_B`.
- Apply a step to `SP_A`; run N ticks; record the **max deviation** of `Temp_B` from its pre-step value → `coupledDisturbance`.
- Reset the project; set the decoupler CONST blocks `d12`/`d21` to the decoupling gains (compute from `identifyGainMatrix`: `d12 = K12/K11`, `d21 = K21/K22`, written into the `d12`/`d21` CONST blocks' `tagBinding`); repeat the `SP_A` step; record `decoupledDisturbance`.
- Assert `decoupledDisturbance < coupledDisturbance` (decoupling reduces the cross-effect). Deterministic.

If wiring a full closed-loop scan in a unit test is heavy, an acceptable alternative is to drive the loop via the same executor entry point the app's scan uses; keep the ASSERTION (decoupled cross-disturbance is strictly smaller than coupled).

- [ ] **Step 2: Run — expect it to demonstrate the effect** (fails if the decoupler is mis-wired or ineffective).

Run: `cd mobile && flutter test test/mimo_project_test.dart`

- [ ] **Step 3: Fix wiring if needed**

If `decoupledDisturbance` is not smaller, the decoupler wiring/sign is wrong — fix the FBD (`Heater_A = u_A − d12·u_B` sign, `d12 = K12/K11` sign) in `default_projects.dart` until decoupling genuinely reduces the cross-disturbance. (This may require touching Task 2's project — allowed; note it.)

- [ ] **Step 4: analyze + commit**

```bash
git add mobile/test/mimo_project_test.dart mobile/lib/data/default_projects.dart
git commit -m "test(mimo): decoupler reduces cross-loop disturbance vs coupled"
```

---

### Task 4: Interaction Analysis panel + nav

**Files:**
- Create: `mobile/lib/screens/interaction_analysis_screen.dart`
- Modify: `mobile/lib/screens/workspace_shell.dart` (nav entry + center-view case)
- Test: `mobile/test/interaction_analysis_screen_test.dart` (create)

**Interfaces:**
- Consumes: `identifyGainMatrix`, `computeRga`, `GainMatrix`, `RgaResult`, `StepTestParams` (Task 1).

**Context:** Mirror `PidAutoTuneScreen` + its nav wiring (`_activeViewId == 'PID_AUTOTUNE'` ListTile ~`workspace_shell.dart:2106`, center-view ~`:2726`). Add `'INTERACTION'` (Icons.grain / Icons.blur_on).

- [ ] **Step 1: Write the failing widget test**

Create `mobile/test/interaction_analysis_screen_test.dart`: pump `InteractionAnalysisScreen` with the MIMO project; assert it renders; MV1/MV2/PV1/PV2 prefill `Heater_A`/`Heater_B`/`Temp_A`/`Temp_B`; tapping **Run** shows a gain-matrix grid (find the K values / a `Gain matrix` label), an RGA / `λ` readout, and a pairing recommendation text. Assert no exception / no overflow at 320×568 and 1400×900. FAIL first.

- [ ] **Step 2: Run — expect FAIL.**

Run: `cd mobile && flutter test test/interaction_analysis_screen_test.dart`

- [ ] **Step 3: Build the panel + wire nav**

`InteractionAnalysisScreen({required PlcProject currentProject, required VoidCallback onProjectUpdated})`:
- MV1/MV2/PV1/PV2 tag fields (default to `Heater_A`/`Heater_B`/`Temp_A`/`Temp_B` when present in the project; else first tags). Step-test params (base MV, step delta, max duration) with sensible defaults.
- **Run** → `identifyGainMatrix(...)` then `computeRga(...)` synchronously → render: a 2×2 **gain matrix** grid (K11..K22), the **RGA** (λ11, 1−λ11 grid), the **pairing** text, any `warning` in a warning style, and the suggested decoupler gains `d12=K12/K11`, `d21=K21/K22`. If `!converged`, show the warning instead of the matrix.
- Dark theme; `withValues(alpha:)`; wrap the body in a scroll view; the matrix grids in fixed-size containers; no overflow at 320/360/1400.
- Wire the shell: nav ListTile (mirror the PID_AUTOTUNE block, `Icons.grain`) + center-view `else if (_activeViewId == 'INTERACTION') return InteractionAnalysisScreen(currentProject: _activeProject, onProjectUpdated: _markDirtyAndAutosave);`.

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/interaction_analysis_screen_test.dart`. `flutter analyze` on the two files clean.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/interaction_analysis_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/interaction_analysis_screen_test.dart
git commit -m "feat(mimo): Interaction Analysis panel — gain matrix + RGA + loop pairing"
```

---

### Task 5: Validation + docs

**Files:**
- Create: `docs/mimo-coupled-plant.md`
- Modify: `ROADMAP.md`, `README.md`

- [ ] **Step 1: Full green gate**

Run: `cd mobile && flutter analyze` (whole project, zero warnings); `cd mobile && flutter test` (ALL pass — record the count; `gateway_screen_test.dart`'s "Start hosting..." is known-flaky — pre-existing only if it passes in isolation); `cd mobile && flutter build web --release` (builds). Report failures verbatim.

- [ ] **Step 2: Docs**

- `docs/mimo-coupled-plant.md`: the Two-Zone plant (heat + conduction coupling via stacked SimRules), how loop interaction shows up (step SP_A, watch Temp_B), the Interaction Analysis panel (step-test gain matrix → RGA → pairing), how to read λ11, and the static decoupler (`Heater = u − d·u_other`, set `d12`/`d21` from the RGA gains to decouple). Note determinism + deep-copy.
- `ROADMAP.md`: mark Phase 9 feature 4 (MIMO) done — **Phase 9 complete**.
- `README.md`: add a MIMO / interaction-analysis bullet.
- No forbidden branding / reverse-engineering wording.

- [ ] **Step 3: Commit**

```bash
git add docs/mimo-coupled-plant.md ROADMAP.md README.md
git commit -m "docs(mimo): document the two-zone coupled plant + interaction analysis"
```

---

## Self-Review

**Spec coverage:**
- Component 1 RGA engine → Task 1. ✓
- Component 2 Interaction panel + nav → Task 4. ✓
- Component 3 Two-Zone plant → Task 2. ✓
- Component 4 PID loops + decoupler → Task 2 (built), Task 3 (proven). ✓
- Determinism / no-mutation / coupled-gains / RGA golden+bands / singular / decoupling-reduces-disturbance / widget → Tasks 1-4 tests. ✓
- Full gate + docs → Task 5. ✓

**Placeholder scan:** Tasks 1-2 carry concrete fixtures + the full project data; the implementer tunes coupling constants so off-diagonal gains are clearly non-zero and adjusts constructor arg names to match — never weakening the stated assertions. Task 3's closed-loop harness is described against the existing `pid_loop_integration_test.dart` pattern.

**Type consistency:** `identifyGainMatrix`/`computeRga`/`GainMatrix`/`RgaResult`/`StepTestParams` (Task 1) consumed by the panel (Task 4) and the project test (Task 2/3). Deep-copy experiment mirrors `pid_autotune.dart`. FBD decoupler uses the confirmed `MUL/SUB/LIMIT` pins. New default project appends to `all()`; nav id `'INTERACTION'` mirrors `'PID_AUTOTUNE'`.

**Note for the executor:** the binding correctness properties are (a) the plant has genuinely non-zero off-diagonal gains (real coupling), (b) `identifyGainMatrix` doesn't mutate the source + is deterministic, (c) `computeRga` golden λ11 + correct band strings + singular guard, and (d) the decoupler strictly reduces cross-loop disturbance vs coupled. A manual on-device check (open the MIMO project, step SP_A and watch Temp_B move; run Interaction Analysis; set d12/d21 and see the interaction shrink) is worthwhile before merge.
