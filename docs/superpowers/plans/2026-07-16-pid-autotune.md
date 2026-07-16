# PID Auto-Tune (Relay Feedback) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dedicated Auto-Tune panel that runs a deterministic relay-feedback (Åström-Hägglund) experiment on the app's simulated PID loop, computes ultimate gain Ku / period Pu, offers gain suggestions from several tuning rules, and applies the chosen one to the loop's gain sources.

**Architecture:** A pure `pid_autotune.dart` (relay experiment + oscillation detection + tuning rules + loop introspection) driving `applySimRules` on a deep copy of the project, plus a panel wired into the shell nav. No persisted schema change; "Apply" mutates existing CONST/tag gain sources.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `models/pid_autotune.dart`.
- Deterministic/pure: no clock, no `Math.random`; identical project + params → identical result; the experiment runs on a deep copy and never mutates live tags.
- Additive/backward-compatible: no persisted schema change; default-projects 20-scan scan-equivalence stays green.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Key facts (verified)

- PID FBD block: input pins `SP, PV, KP, KI, KD` → output `CV` (`fbd_pins.dart`). Engine `fbd_exec.dart:285` parallel form `raw = kp*e + ki*integral + kd*deriv`; the sim integrates in **seconds** (`dt = dtMs/1000`).
- `FbdBlock { String type; String tagBinding; String id; ... }` — a `CONST` block's literal lives in `tagBinding` (parsed by `_parseConst`); a `TAG_INPUT`'s `tagBinding` is a tag path. `FbdWire { String fromBlockId, fromPin, toBlockId, toPin; }`. `PlcProgram.fbdBlocks` / `.fbdWires` (confirm the exact list names in `project_model.dart`).
- `applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)` — deterministic; `SimRuntime()` default ctor. `dynamic readPath(PlcProject p, String path)` / `void writePath(PlcProject p, String path, dynamic value)` in `tag_resolver.dart`.
- `PlcProject` round-trips via `toJson`/`fromJson` (deep copy = `PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())))`). `PlcTag { String name, path, dataType; dynamic value; String engineeringUnits; }`. `SimRule.minValue`/`.maxValue`.
- Shell nav uses a `String _activeViewId` (`'MEMORY'`, `'HMI:<id>'`, `'PROGRAM:<name>'`); the center workspace switches on it and renders `SimulatedIoScreen(...)` (~`workspace_shell.dart:2699`). Add a new id (e.g. `'PID_AUTOTUNE'`), a nav entry, and a center-view case — mirror how Simulated I/O / `'MEMORY'` are wired.
- The "Tank Level PID Control" default project (`_fbdPidTankLevelProject`): PID block id `p_pid`, gain CONST blocks `p_kp`/`p_ki`/`p_kd`, CV tag `Valve_CV`, PV tag `Level_PV`, SP tag `Level_SP`. The showcase for tests.
- Existing trend chart: reuse the historian/Trends chart widget if easily fed a point list (grep `TrendChart`); otherwise a lightweight `CustomPaint` PV/CV plot inside the panel is acceptable.

---

### Task 1: Pure relay engine + oscillation detection

**Files:**
- Create: `mobile/lib/models/pid_autotune.dart` (relay part)
- Test: `mobile/test/pid_autotune_test.dart` (relay cases)

**Interfaces:**
- Produces: `RelayTuneParams`, `TunePoint`, `RelayTuneResult`, `RelayTuneResult relayAutoTune(PlcProject project, {required String pvPath, required String cvPath, required RelayTuneParams params})`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/pid_autotune_test.dart` (relay group). Build a small project with a `firstOrderLag` + `deadTime` process (self-regulating) and, separately, an `integrate` process, both driven by a CV tag, and assert:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/pid_autotune.dart';

PlcProject _lagProcess() {
  // CV (0..100) drives PV via a first-order lag toward CV, plus a small dead time.
  final tags = [
    PlcTag(name: 'CV', path: 'CV', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    PlcTag(name: 'PV', path: 'PV', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
  ];
  final rules = [
    SimRule(id: 's0', name: 'lag', targetPath: 'PV', behavior: 'firstOrderLag',
        sourcePath: 'CV', tauSec: 2.0, minValue: -1000, maxValue: 1000,
        condition: const []),
  ];
  return PlcProject(id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules);
}

RelayTuneParams _params() => RelayTuneParams(
    relayHigh: 100, relayLow: 0, hysteresis: 0.5, setpoint: 50,
    dtMs: 100, maxScans: 4000, settleCycles: 3);

void main() {
  test('relay produces a sustained limit cycle on a lag process', () {
    final r = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(r.converged, isTrue, reason: r.warning);
    expect(r.ku, greaterThan(0));
    expect(r.pu, greaterThan(0));
    expect(r.trace.length, greaterThan(10));
  });

  test('experiment does not mutate the source project', () {
    final p = _lagProcess();
    final beforePv = p.tags.firstWhere((t) => t.name == 'PV').value;
    relayAutoTune(p, pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(p.tags.firstWhere((t) => t.name == 'PV').value, beforePv);
  });

  test('deterministic: same project + params -> identical Ku/Pu', () {
    final a = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV', params: _params());
    final b = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(a.ku, b.ku);
    expect(a.pu, b.pu);
  });

  test('integrating process also converges', () {
    final tags = [
      PlcTag(name: 'CV', path: 'CV', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal'),
      PlcTag(name: 'PV', path: 'PV', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal'),
    ];
    // PV integrates (CV-50): above 50 fills, below 50 drains -> relay makes it oscillate.
    final rules = [
      SimRule(id: 's0', name: 'int', targetPath: 'PV', behavior: 'integrate',
          sourcePath: 'CV', refValue: 50.0, ratePerSec: 5.0, minValue: -1000, maxValue: 1000,
          condition: const []),
    ];
    final proj = PlcProject(id: 'p', name: 'P', controllerName: 'C',
        tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules);
    final r = relayAutoTune(proj, pvPath: 'PV', cvPath: 'CV', params: _params());
    expect(r.converged, isTrue, reason: r.warning);
  });

  test('no oscillation -> converged false with warning', () {
    // hysteresis larger than any achievable PV swing about SP given a tiny relay.
    final r = relayAutoTune(_lagProcess(), pvPath: 'PV', cvPath: 'CV',
        params: RelayTuneParams(relayHigh: 50.1, relayLow: 49.9, hysteresis: 40,
            setpoint: 50, dtMs: 100, maxScans: 500, settleCycles: 3));
    expect(r.converged, isFalse);
    expect(r.warning, isNotNull);
  });
}
```

Note for the implementer: adjust `SimRule`/`PlcTag`/`PlcProject` constructor arg names to the real ones (mirror `mobile/test/pid_loop_integration_test.dart` / `noise_measurement_integration_test.dart`). The `integrate` gain uses `sourcePath`/`refValue` (rate scaled by `source/refValue` — see `sim_engine.dart _gain`), so `refValue: 50` makes CV=50 the null point. Keep the ASSERTIONS.

- [ ] **Step 2: Run — expect FAIL** (`pid_autotune.dart` missing).

Run: `cd mobile && flutter test test/pid_autotune_test.dart`

- [ ] **Step 3: Implement the relay engine**

In `mobile/lib/models/pid_autotune.dart` (import `project_model.dart`, `tag_resolver.dart`, `dart:convert`, `dart:math`):
- `RelayTuneParams` (fields per the spec: `relayHigh, relayLow, hysteresis, setpoint, dtMs, maxScans, settleCycles`), `TunePoint { double tMs, pv, cv; }`, `RelayTuneResult { bool converged; double ku, pu, amplitude; List<TunePoint> trace; String? warning; }`.
- `relayAutoTune`: deep-copy the project; `final rt = SimRuntime();` (import `sim_engine.dart`); start relay output at `relayHigh`; each scan up to `maxScans`: read PV via `readPath`; switch output to `relayHigh` if `pv < setpoint - hysteresis`, to `relayLow` if `pv > setpoint + hysteresis`, else hold; `writePath(copy, cvPath, out)`; append `TunePoint(t, pv, out)`; `applySimRules(copy, copy.simRules, dtMs, rt)`. Track relay switch times and the PV extremum reached within each half-cycle. Compute `amplitude a` = mean half-peak-to-peak over the last `settleCycles`, `pu` = mean rising-switch interval over the last `settleCycles`. Converged when the last `settleCycles` amplitudes and periods are each within 5% relative spread AND at least `settleCycles+1` full cycles occurred. `d = (relayHigh - relayLow)/2`; `ku = 4*d/(pi*a)` (guard `a>0`, else converged=false). Return the full `trace` always; on non-convergence set `warning`.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/pid_autotune.dart test/pid_autotune_test.dart` (zero warnings; a pure-Dart model — no Flutter import).

```bash
git add mobile/lib/models/pid_autotune.dart mobile/test/pid_autotune_test.dart
git commit -m "feat(pid): relay-feedback auto-tune experiment (Ku/Pu via limit-cycle detection)"
```

---

### Task 2: Pure tuning rules

**Files:**
- Modify: `mobile/lib/models/pid_autotune.dart` (add rules)
- Test: `mobile/test/pid_autotune_test.dart` (add a rules group)

**Interfaces:**
- Produces: `TuningSuggestion { String name; String form; double kp, ki, kd; }`, `List<TuningSuggestion> tuningRules(double ku, double pu)`.

- [ ] **Step 1: Write the failing tests**

Add a `group('tuningRules', ...)` to `pid_autotune_test.dart` asserting the golden numbers for a fixed `(ku, pu)`, e.g. `ku = 10.0`, `pu = 4000.0` (ms → `puS = 4.0`):

```dart
test('tuningRules golden numbers', () {
  final s = tuningRules(10.0, 4000.0); // puS = 4.0
  TuningSuggestion row(String name, String form) =>
      s.firstWhere((x) => x.name == name && x.form == form);
  // ZN PID: Kp=6.0, Ti=2.0 -> Ki=3.0, Td=0.5 -> Kd=3.0
  final zn = row('Ziegler-Nichols', 'PID');
  expect(zn.kp, closeTo(6.0, 1e-9));
  expect(zn.ki, closeTo(3.0, 1e-9));
  expect(zn.kd, closeTo(3.0, 1e-9));
  // ZN PI: Kp=4.5, Ti=3.332 -> Ki=1.3506..., Kd=0
  final znpi = row('Ziegler-Nichols', 'PI');
  expect(znpi.kp, closeTo(4.5, 1e-9));
  expect(znpi.kd, 0);
  // Tyreus-Luyben PID: Kp=10/2.2=4.5454..., Ti=8.8 -> Ki=0.5165..., Td=4/6.3=0.6349 -> Kd=2.886...
  final tl = row('Tyreus-Luyben', 'PID');
  expect(tl.kp, closeTo(10 / 2.2, 1e-9));
  expect(tl.kd, closeTo((10 / 2.2) * (4.0 / 6.3), 1e-9));
  // ZN no-overshoot PID: Kp=2.0, Ti=2.0 -> Ki=1.0, Td=4/3 -> Kd=2.666...
  final no = row('ZN no-overshoot', 'PID');
  expect(no.kp, closeTo(2.0, 1e-9));
  expect(no.kd, closeTo(2.0 * (4.0 / 3.0), 1e-9));
  // all PI rows have kd == 0; all Ki == kp/Ti (Ti>0)
  for (final x in s.where((x) => x.form == 'PI')) {
    expect(x.kd, 0);
  }
  expect(s.length, 6);
});
```

- [ ] **Step 2: Run — expect FAIL** (`tuningRules` undefined).

- [ ] **Step 3: Implement `tuningRules`**

Return six `TuningSuggestion`s (ZN PID/PI, Tyreus-Luyben PID/PI, ZN no-overshoot PID/PI) using `puS = pu / 1000`, `Ki = Kp/Ti` (guard `Ti>0` else 0), `Kd = Kp*Td` (0 for PI). Formulas exactly per the spec table.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/pid_autotune.dart test/pid_autotune_test.dart`.

```bash
git add mobile/lib/models/pid_autotune.dart mobile/test/pid_autotune_test.dart
git commit -m "feat(pid): tuning rules (ZN / Tyreus-Luyben / no-overshoot, PID + PI)"
```

---

### Task 3: Loop introspection (`resolvePidLoop`)

**Files:**
- Modify: `mobile/lib/models/pid_autotune.dart` (add resolver)
- Test: `mobile/test/pid_autotune_test.dart` (add a resolver group, using the Tank Level PID default project)

**Interfaces:**
- Produces: `PidLoopBinding { String pidBlockId; String? pvPath, cvPath; double? setpoint; String? kpSourceBlockId, kiSourceBlockId, kdSourceBlockId; }`, `PidLoopBinding resolvePidLoop(PlcProgram program, PlcProject project, String pidBlockId)`.

- [ ] **Step 1: Write the failing test**

```dart
test('resolvePidLoop resolves the Tank Level PID demo', () {
  final proj = DefaultProjects.all().firstWhere((p) => p.id == 'proj_pid_tank'); // confirm the real id
  final prog = proj.programs.firstWhere((pr) => pr.language == 'FunctionBlockDiagram');
  final b = resolvePidLoop(prog, proj, 'p_pid');
  expect(b.pvPath, 'Level_PV');
  expect(b.cvPath, 'Valve_CV');
  expect(b.kpSourceBlockId, 'p_kp');
  expect(b.kiSourceBlockId, 'p_ki');
  expect(b.kdSourceBlockId, 'p_kd');
});
```

(Confirm the demo project's real `id` and the exact PV/CV/SP tag names + gain block ids by reading `_fbdPidTankLevelProject` in `default_projects.dart`; adjust the literals to match. Keep the assertion intent: the resolver finds PV/CV and the three gain sources by walking the wires.)

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `resolvePidLoop`**

For each input pin `P` in `{PV, SP, KP, KI, KD}`: find the `FbdWire` with `toBlockId == pidBlockId && toPin == P`; its `fromBlockId` is the source block. For `PV`/`SP`, if that source is a `TAG_INPUT`, its `tagBinding` is the path (SP may also be a `CONST` → a numeric setpoint). For the gain pins, keep the source block id if the source block is a writable `CONST` or `TAG_INPUT`. For `CV`: find the wire with `fromBlockId == pidBlockId && fromPin == 'CV'`; the destination block (a `TAG_OUTPUT`) `tagBinding` is `cvPath`. Missing → null. Read `program.fbdBlocks`/`.fbdWires` (confirm names).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/models/pid_autotune.dart mobile/test/pid_autotune_test.dart
git commit -m "feat(pid): resolve PID loop PV/CV/SP + writable gain sources from FBD wiring"
```

---

### Task 4: Auto-Tune panel + nav + apply

**Files:**
- Create: `mobile/lib/screens/pid_autotune_screen.dart`
- Modify: `mobile/lib/screens/workspace_shell.dart` (nav entry + center-view case)
- Test: `mobile/test/pid_autotune_screen_test.dart` (create)

**Interfaces:**
- Consumes: `relayAutoTune`, `tuningRules`, `resolvePidLoop`, `PidLoopBinding` (Tasks 1-3).

**Context:** New center-workspace section reached via a nav entry (add a `_activeViewId` value like `'PID_AUTOTUNE'`; mirror how `'MEMORY'` / `SimulatedIoScreen` are wired at ~`workspace_shell.dart:2699`). The screen takes the active `PlcProject` + an `onProjectUpdated`/dirty callback (match the signature the shell passes to `SimulatedIoScreen`).

- [ ] **Step 1: Write the failing widget test**

Create `mobile/test/pid_autotune_screen_test.dart`: pump `PidAutoTuneScreen` with the Tank Level PID project; assert it renders, a PID-loop selector prefills PV=`Level_PV`/CV=`Valve_CV`; tapping **Run Auto-Tune** produces a suggestions table (find at least one rule row, e.g. text `Ziegler-Nichols`) and Ku/Pu text; tapping a row's **Apply** changes the `p_kp` CONST block's `tagBinding` (assert it differs from its pre-apply value). Assert no exception / no overflow at 320 and 1400. FAIL first (screen doesn't exist).

- [ ] **Step 2: Run — expect FAIL.**

Run: `cd mobile && flutter test test/pid_autotune_screen_test.dart`

- [ ] **Step 3: Build the panel + wire the nav**

`PidAutoTuneScreen`:
- Loop selector: dropdown of PID blocks across the project's FBD programs (label by block title/id). On select → `resolvePidLoop` → prefill PV/CV (editable tag-autocomplete) + SP.
- Relay param fields: relay high/low (default from the CV tag's sensible range or 0/100), hysteresis, setpoint (default SP), max duration. Use the existing numeric-field helper idiom.
- **Run Auto-Tune** → `relayAutoTune(...)` synchronously → store the result. Render: the PV/CV trend (reuse the trend chart widget if easily fed `trace`; else a compact `CustomPaint` of PV & CV vs time in the app's chart colors), the Ku/Pu (or the `warning` if not converged), and a horizontally-scrollable table of `tuningRules(ku,pu)` (name, form, Kp, Ki, Kd) each with **Apply**.
- **Apply(row)** → for each of Kp/Ki/Kd with a resolved writable source: if the source block is `CONST`, set its `tagBinding = value.toString()` (format compactly); if `TAG_INPUT`, `writePath(project, sourceBlock.tagBinding, value)`. Skip + snackbar/message for any gain with no writable source. Call the dirty/autosave callback. Dark theme; `withValues(alpha:)`; no overflow at 320/360/1400.
- Wire the shell: add the nav entry (Icons.tune or similar) + the `'PID_AUTOTUNE'` center-view case returning `PidAutoTuneScreen(currentProject: _activeProject, onProjectUpdated: _markDirtyAndAutosave)` (match the real callback name Simulated I/O uses).

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/pid_autotune_screen_test.dart`. `flutter analyze` on the two files clean.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/pid_autotune_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/pid_autotune_screen_test.dart
git commit -m "feat(pid): Auto-Tune panel — run relay experiment, show trend + gains, apply to loop"
```

---

### Task 5: Validation + docs

**Files:**
- Create: `docs/pid-autotune.md`
- Modify: `ROADMAP.md`, `README.md`

- [ ] **Step 1: Full green gate**

Run: `cd mobile && flutter analyze` (whole project, zero warnings); `cd mobile && flutter test` (ALL pass — record the count; `gateway_screen_test.dart`'s "Start hosting..." is known-flaky — pre-existing only if it passes in isolation); `cd mobile && flutter build web --release` (builds). Report failures verbatim.

- [ ] **Step 2: Docs**

- `docs/pid-autotune.md`: the relay-feedback method (limit cycle → Ku=4d/(πa), Pu), the rule sets offered, how to run it on the Tank Level PID demo, and that gains apply to the CONST/tag sources. Note it runs on a deep copy (never disturbs the live loop) and is deterministic.
- `ROADMAP.md`: Phase 9 feature 3 (PID auto-tune) done.
- `README.md`: add an Auto-Tune bullet.
- No forbidden branding / reverse-engineering wording.

- [ ] **Step 3: Commit**

```bash
git add docs/pid-autotune.md ROADMAP.md README.md
git commit -m "docs(pid): document relay-feedback PID auto-tune"
```

---

## Self-Review

**Spec coverage:**
- Component 1 relay engine + detection → Task 1. ✓
- Component 2 tuning rules → Task 2. ✓
- Component 3 loop introspection → Task 3. ✓
- Component 4 panel + nav + apply → Task 4. ✓
- Determinism / no-mutation / no-oscillation / golden rules / resolver / widget → Tasks 1-4 tests. ✓
- Full gate + docs → Task 5. ✓

**Placeholder scan:** Tasks 1-3 carry concrete test code + algorithm; the implementer adjusts constructor arg names and the demo's real ids/tag names to match the codebase (explicitly flagged), never weakening assertions. Task 4's UI is described against existing screen idioms (SimulatedIoScreen wiring, numeric-field helper, trend chart) with a stated fallback (CustomPaint) if the trend widget isn't easily reusable.

**Type consistency:** `RelayTuneParams`/`RelayTuneResult`/`relayAutoTune` (Task 1), `TuningSuggestion`/`tuningRules` (Task 2), `PidLoopBinding`/`resolvePidLoop` (Task 3) all live in `pid_autotune.dart` and are consumed by the panel (Task 4). `Pu` is in ms in the engine; `tuningRules` converts `puS = pu/1000` (seconds) to match the engine's second-based integration. Gains are the parallel form (`Ki=Kp/Ti`, `Kd=Kp·Td`) matching `fbd_exec.dart:285`.

**Note for the executor:** the relay experiment + rules are pure and deterministic — keep them so (deep copy, no clock). The binding correctness properties: the experiment must not mutate the source project; `tuningRules` golden numbers; the resolver finds the demo's PV/CV/gain sources; Apply actually writes the CONST `tagBinding`s. A manual on-device run against the Tank Level PID demo (oscillation trend → Ku/Pu → apply ZN gains → watch the loop settle) is worthwhile before merge.
