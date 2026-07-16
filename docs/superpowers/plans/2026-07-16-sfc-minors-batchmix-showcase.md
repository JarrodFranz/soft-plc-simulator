# SFC v2 Minors + "Batch Mix & Dispatch" Showcase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five deferred SFC v2 Minors and add a default project ("SFC — Batch Mix & Dispatch") that demonstrates both parallel (AND) and alternative (conditional) SFC branches.

**Architecture:** Two correctness guards + one cosmetic layout fix + two DRY refactors across `sfc_edit.dart` / `sfc_layout2.dart` / `sfc_exec.dart`, then a new `_sfcBatchMixProject()` appended to `DefaultProjects.all()`, plus a targeted showcase test. All additive/backward-compatible.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `sfc_edit.dart`, `sfc_layout2.dart`, `sfc_exec.dart`.
- Additive/backward-compatible: no existing default project's serialized form or scan sequence changes. Fork/join invariant after every edit: a `parallelFork.toStepIds` = its branch heads; the paired `parallelJoin.fromStepIds` = its branch tails; every referenced id resolves.
- Deterministic engine (scan-tick clock only). No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Key facts (verified)

- `SfcTransition { String id; String fromStepId; String toStepId; String conditionSt; String kind; List<String> toStepIds; List<String> fromStepIds; }` — `kind` ∈ `'single'`|`'parallelFork'`|`'parallelJoin'`. Fork: `fromStepId`=source, `toStepIds`=branch heads. Join: `fromStepIds`=branch tails, `toStepId`=after.
- `mobile/lib/models/sfc_edit.dart` already has: `addParallelBranch(PlcProgram p, String afterStepId)`, `deleteParallelBranch(PlcProgram p, String forkTransitionId, String branchHeadId)`, `deleteSfcStepStructured(PlcProgram p, String stepId)`, private `_branchSubgraph(...)`, `_joinForFork(...)`, `_joinWithTail(...)`, `_firstSingleOut(...)`. `deleteParallelBranch` already has a safe no-op guard `if (join == null) { return; }`.
- `mobile/lib/models/sfc_layout2.dart` has `_parFrag(ParRegion)`, `_altFrag(AltRegion)` (which draws convergence connectors from each column's real exit-y), `_transFrag(TransRegion)`, `_guardFrag(SfcTransition)`. Metrics are named `_k*` consts. `_Frag(boxes, conns, w, h, entryX, exitX)`; fields `.w .h .entryX .exitX .boxes .conns`; `_shift(frag, dx, dy)`, `_max(a,b)`.
- `mobile/lib/models/sfc_exec.dart` builds `stepElapsedMs` keys as `'${prog.name}|$id'` inline at ~4 sites; `SfcRuntime.active: Map<String,Set<String>>`, `stepElapsedMs: Map<String,int>`. `executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt, {Set<String>? only, Set<String>? readOnly})`.
- `mobile/lib/models/st_expr.dart` supports `AND`/`OR`/`NOT`/`XOR`, comparisons, `TRUE`/`FALSE`, and `STEP_T` (via `extraVars`). `evalStCondition(p, conditionSt, extraVars: {...})`.
- `mobile/lib/data/default_projects.dart`: `static List<PlcProject> all() => [ _motorProject(), _tankProject(), ... _noisyLevelProject() ];` (12 projects). Each `_xProject()` returns a `PlcProject(id:, name:, controllerName:, scanPeriodMs:, tags:[PlcTag(...)], structDefs:[], simRules:[SimRule(...)], programs:[PlcProgram(...)], tasks:[PlcTask(...)], hmis:[HmiScreenDef(...)])`. The existing `_sfcFillingProject()` (id `proj_sfc_filling`, "SFC — Batch Bottle Filling", scanPeriodMs 200) is a good structural template — copy its shape. `SimRule(id:, name:, targetPath:, behavior:'integrate', ratePerSec:, minValue:, maxValue:, condition:[SimClause(leftPath:, comparator:'==', operand:'true')])`. HMI: `HmiComponent(id:, title:, type:, tagBinding:, gridSpanWidth:, accentColor:)`.
- Tests reference the default count as `DefaultProjects.all().length` (relative) — NO literal count to bump. Generic round-trip/scan tests iterate `all()`.

---

### Task 1: Fix A1 (addParallelBranch alt-head guard) + A2 (delete fork-source removes whole construct)

**Files:**
- Modify: `mobile/lib/models/sfc_edit.dart`
- Test: `mobile/test/sfc_edit_parallel_test.dart` (add cases)

**Interfaces:**
- Consumes/produces: same public signatures (`addParallelBranch`, `deleteSfcStepStructured`) — behaviour hardened only.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/sfc_edit_parallel_test.dart` (reuse the file's existing helpers/imports — it already imports `project_model.dart`, `sfc_edit.dart`, `sfc_region.dart`, and has a `_assertParseableNoDangling(p, program)` helper; if the helper name differs, use the file's existing parse-assertion helper):

```dart
test('A1: addParallelBranch on an alternative-divergence head is a safe no-op', () {
  final p = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
  final a = addSfcStep(p, name: 'A');            // initial
  final x = addSfcStep(p, name: 'X');
  final y = addSfcStep(p, name: 'Y');
  // Two alternative arms out of A -> alt-divergence head.
  final b1 = addSfcBranch(p, a.id)..toStepId = x.id..conditionSt = 'C1';
  final b2 = addSfcBranch(p, a.id)..toStepId = y.id..conditionSt = 'C2';
  final beforeSteps = p.sfcSteps.length;
  final beforeTrans = p.sfcTransitions.map((t) => '${t.id}:${t.kind}:${t.fromStepId}->${t.toStepId}').toList();
  addParallelBranch(p, a.id);                    // must NOT strip b1/b2
  expect(p.sfcSteps.length, beforeSteps, reason: 'no steps added/removed');
  expect(p.sfcTransitions.where((t) => t.kind == 'parallelFork'), isEmpty, reason: 'no fork created');
  expect(
    p.sfcTransitions.map((t) => '${t.id}:${t.kind}:${t.fromStepId}->${t.toStepId}').toList(),
    beforeTrans, reason: 'both alt arms intact, unchanged');
  // ignore: unused_local_variable
  final _ = [b1, b2];
  final region = parseSfc(p.sfcSteps, p.sfcTransitions);
  expect(region, isNotNull);
});

test('A2: deleting a fork-source step removes fork + branches + join (no orphans)', () {
  final p = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
  final src = addSfcStep(p, name: 'SRC');        // initial, will own the fork
  addParallelBranch(p, src.id);                  // fork SRC -> [b1,b2], join -> after
  // sanity: a fork now exists out of src
  expect(p.sfcTransitions.any((t) => t.kind == 'parallelFork' && t.fromStepId == src.id), isTrue);
  deleteSfcStepStructured(p, src.id);            // must remove the whole construct
  expect(p.sfcTransitions.any((t) => t.kind == 'parallelFork'), isFalse, reason: 'fork gone');
  expect(p.sfcTransitions.any((t) => t.kind == 'parallelJoin'), isFalse, reason: 'paired join gone (not orphaned)');
  // every remaining transition references an existing step (no dangling)
  final ids = p.sfcSteps.map((s) => s.id).toSet();
  for (final t in p.sfcTransitions) {
    if (t.kind == 'single') {
      expect(ids.contains(t.fromStepId) || t.fromStepId.isEmpty, isTrue);
    }
    for (final h in t.toStepIds) { expect(ids.contains(h), isTrue); }
    for (final tl in t.fromStepIds) { expect(ids.contains(tl), isTrue); }
  }
  final region = parseSfc(p.sfcSteps, p.sfcTransitions);
  expect(region, isNotNull);
});
```

Note for the implementer: the exact helper/field access above may need small adjustment to match the file's conventions (e.g. how `SfcTransition.toStepId`/`conditionSt` are set after `addSfcBranch`). Keep the ASSERTIONS (no-op on alt-head; no fork/join/orphans after fork-source delete; parse succeeds) — adjust only mechanics.

- [ ] **Step 2: Run — expect FAIL**

Run: `cd mobile && flutter test test/sfc_edit_parallel_test.dart`
Expected: the two new tests fail (A1: fork created / arms stripped; A2: orphaned join remains).

- [ ] **Step 3: Implement A1 guard**

In `addParallelBranch`, before stripping the anchor's `single` outgoings, count them: if the anchor has ≥2 `single` outgoing transitions (an alternative-divergence head), `return` without mutating (safe no-op). Add a doc comment explaining the guard (mirrors the existing `deleteParallelBranch` `join == null` no-op). A single successor (≤1 single out) proceeds as before.

- [ ] **Step 4: Implement A2 fork-source delete**

In `deleteSfcStepStructured`, before the ordinary step-delete path, detect whether the target step owns an outgoing `parallelFork` (a transition with `kind == 'parallelFork' && fromStepId == stepId`). If so:
- Find the paired join via the existing `_joinForFork(...)` helper. If it can't be reliably identified, degrade safely (fall through to the ordinary structured delete guard rather than corrupting — do NOT sweep across an unknown boundary).
- Otherwise gather the fork's whole branch subgraph (reuse `_branchSubgraph(...)` across all branch heads) plus the fork and join transitions, remove them all, and remove the branch/subgraph steps. Reconnect nothing (the source step itself is being deleted). If the source was `isInitial`, promote a remaining step to initial (reuse the existing `deleteSfcStep` initial-promotion logic).
- Ensure no transition or step referencing the removed ids survives (no dangling).

- [ ] **Step 5: Run — expect PASS**

Run: `cd mobile && flutter test test/sfc_edit_parallel_test.dart test/sfc_region_test.dart`
Expected: all pass (new A1/A2 cases green; existing authoring/region tests still green).

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/sfc_edit.dart test/sfc_edit_parallel_test.dart` (zero warnings).

```bash
git add mobile/lib/models/sfc_edit.dart mobile/test/sfc_edit_parallel_test.dart
git commit -m "fix(sfc): guard addParallelBranch on alt-head + delete fork-source removes whole construct"
```

---

### Task 2: Fix A3 (per-column parallel join connector) + A4/A5 (DRY refactors)

**Files:**
- Modify: `mobile/lib/models/sfc_layout2.dart` (A3, A5), `mobile/lib/models/sfc_exec.dart` (A4)
- Test: `mobile/test/sfc_layout2_test.dart` (add A3 case)

**Interfaces:**
- No signature changes. A4/A5 are pure refactors guarded by existing tests.

- [ ] **Step 1: Write the failing test (A3)**

Add to `mobile/test/sfc_layout2_test.dart` (reuse existing region-building helpers in that file). Build a parallel region whose two branches have DIFFERENT heights (e.g. branch 1 = one step; branch 2 = two steps), layout it, and assert the two join connectors do NOT share the same start-y:

```dart
test('A3: parallel join connectors start at each column real exit-y (uneven branches)', () {
  // Build: fork -> [ [b1] , [b2a -> b2b] ] -> join -> after
  // (construct SfcStep/SfcTransition directly or via the file's helper, mirroring
  //  the existing parallel layout test fixture but with unequal branch lengths)
  final layout = layoutSfcRegion(region); // region = the uneven ParRegion built above
  // Collect the join connectors: those whose doubleBar is true and that converge
  // toward the join bar. Their start-y values must differ (one per column exit),
  // NOT all equal to a single uniform bottom.
  final joinConnYs = <double>{
    for (final c in layout.conns.where((c) => c.doubleBar)) c.y1,
  };
  expect(joinConnYs.length, greaterThan(1),
      reason: 'uneven branches -> distinct per-column join start-y');
  // bounds still contain all boxes; no step overlap (reuse the file's helpers)
});
```

Note: match the file's existing fixture-construction style and its `doubleBar`/connector conventions; if the file distinguishes fork vs join connectors differently, assert on the JOIN side specifically. Keep the invariant: uneven parallel branches produce distinct per-column join connector start-y.

- [ ] **Step 2: Run — expect FAIL**

Run: `cd mobile && flutter test test/sfc_layout2_test.dart`
Expected: the A3 case fails (all join connectors share one uniform start-y).

- [ ] **Step 3: Implement A3**

In `_parFrag`, when emitting the join connectors, use each branch column's actual exit point (its placed `exitX`, and its real bottom-y = `branchTopY + col.h`) as the connector start, instead of a single uniform `branchBottomY` — mirroring how `_altFrag` records `exits.add([placed.exitX, branchTopY + col.h])` and draws from those. Keep the join bar / after-step geometry otherwise unchanged.

- [ ] **Step 4: Implement A5 (`_guardFrag` delegates)**

Refactor `_guardFrag(SfcTransition g)` to build its trans block via the same code path `_transFrag` uses for a non-goto transition (extract a shared private helper like `_transBlockFrag(SfcTransition t)` returning the bordered trans `_Frag`, and have both call it). No geometry change.

- [ ] **Step 5: Implement A4 (`_stepKey` helper)**

In `sfc_exec.dart`, add `String _stepKey(String prog, String stepId) => '$prog|$stepId';` and replace the ~4 inline `'${prog.name}|$id'` (and any `'${prog.name}|${step.id}'`) key constructions with `_stepKey(prog.name, id)`. No behaviour change.

- [ ] **Step 6: Run — expect PASS**

Run: `cd mobile && flutter test test/sfc_layout2_test.dart test/sfc_multitoken_test.dart test/sfc_canvas_render_test.dart`
Expected: A3 case passes; the multitoken engine tests (A4 guard) and layout/canvas tests (A5 guard) stay green.

- [ ] **Step 7: analyze + commit**

Run: `cd mobile && flutter analyze lib/models/sfc_layout2.dart lib/models/sfc_exec.dart test/sfc_layout2_test.dart` (zero warnings).

```bash
git add mobile/lib/models/sfc_layout2.dart mobile/lib/models/sfc_exec.dart mobile/test/sfc_layout2_test.dart
git commit -m "fix(sfc): per-column parallel join connectors; DRY _stepKey + _guardFrag"
```

---

### Task 3: New default project "SFC — Batch Mix & Dispatch"

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (add `_sfcBatchMixProject()` + register in `all()`)
- Test: `mobile/test/sfc_batchmix_showcase_test.dart` (create)

**Interfaces:**
- Produces: `DefaultProjects.all()` gains a 13th project with id `proj_sfc_batchmix`, name `'SFC — Batch Mix & Dispatch'`, one SFC program `BatchMix_SFC`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sfc_batchmix_showcase_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'dart:convert';

PlcProject _batchMix() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_sfc_batchmix');

void main() {
  test('batch-mix project is registered and round-trips losslessly', () {
    final p = _batchMix();
    expect(p.name, 'SFC — Batch Mix & Dispatch');
    final back = PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
  });

  test('chart parses to one parallel region (2 branches) + one alternative (2 arms)', () {
    final prog = _batchMix().programs.firstWhere((pr) => pr.language == 'SequentialFunctionChart');
    final region = parseSfc(prog.sfcSteps, prog.sfcTransitions);
    final pars = <ParRegion>[];
    final alts = <AltRegion>[];
    void walk(SfcRegion r) {
      if (r is ParRegion) { pars.add(r); for (final b in r.branches) { for (final x in b) { walk(x); } } }
      else if (r is AltRegion) { alts.add(r); for (final b in r.branches) { for (final x in b) { walk(x); } } }
      else if (r is SeqRegion) { for (final x in r.items) { walk(x); } }
    }
    walk(region);
    expect(pars.length, 1);
    expect(pars.first.branches.length, 2);
    expect(alts.length, 1);
    expect(alts.first.branches.length, 2);
  });

  test('multi-scan run: fork -> both branches -> join -> DISPATCH when Quality_OK', () {
    final p = _batchMix();
    final prog = p.programs.firstWhere((pr) => pr.language == 'SequentialFunctionChart');
    final rt = SfcRuntime();
    final sim = SimRuntime();
    void tick(int ms) {
      applySimRules(p, p.simRules, ms, sim);
      executeSfcPrograms(p, ms, rt);
    }
    // set inputs
    void setTag(String name, dynamic v) => p.tags.firstWhere((t) => t.name == name).value = v;
    setTag('Quality_OK', true);
    setTag('Start_Cmd', true);
    // run enough scans for both branches to complete, join, mix dwell, then dispatch
    Set<String> sawParallel = {};
    for (var i = 0; i < 120; i++) { // 120 * 200ms = 24s
      tick(200);
      final act = rt.active[prog.name] ?? {};
      if (act.length >= 2) { sawParallel = {...act}; }
    }
    // during the run we must have had two simultaneously-active steps (parallel)
    expect(sawParallel.length, greaterThanOrEqualTo(2));
    // Quality_OK true -> Dispatch pump fired at least once (Batch_Count advanced)
    final batch = p.tags.firstWhere((t) => t.name == 'Batch_Count').value as int;
    expect(batch, greaterThanOrEqualTo(1));
    final reject = p.tags.firstWhere((t) => t.name == 'Reject_Count').value as int;
    expect(reject, 0);
  });

  test('multi-scan run: REJECT arm when NOT Quality_OK', () {
    final p = _batchMix();
    final prog = p.programs.firstWhere((pr) => pr.language == 'SequentialFunctionChart');
    final rt = SfcRuntime();
    final sim = SimRuntime();
    void setTag(String name, dynamic v) => p.tags.firstWhere((t) => t.name == name).value = v;
    setTag('Quality_OK', false);
    setTag('Start_Cmd', true);
    for (var i = 0; i < 120; i++) {
      applySimRules(p, p.simRules, 200, sim);
      executeSfcPrograms(p, 200, rt);
    }
    expect(p.tags.firstWhere((t) => t.name == 'Reject_Count').value as int, greaterThanOrEqualTo(1));
    expect(p.tags.firstWhere((t) => t.name == 'Batch_Count').value as int, 0);
  });
}
```

Note for the implementer: verify the exact `SimRuntime`/`applySimRules` constructor + signature in `sim_engine.dart` and adjust the harness calls to match (the pattern above mirrors `sfc_exec_integration_test.dart`/`noise_measurement_integration_test.dart` — copy their proven harness). If `AltRegion.branches`/`ParRegion.branches` field access differs, match `sfc_region.dart`. Keep the ASSERTIONS: registered + round-trips; exactly one Par(2)/one Alt(2); parallel steps co-active; DISPATCH when Quality_OK, REJECT when not.

- [ ] **Step 2: Run — expect FAIL**

Run: `cd mobile && flutter test test/sfc_batchmix_showcase_test.dart`
Expected: FAIL — no project with id `proj_sfc_batchmix`.

- [ ] **Step 3: Add `_sfcBatchMixProject()`**

In `mobile/lib/data/default_projects.dart`, add the method (model it on `_sfcFillingProject()`'s structure) and register it in `all()` (append after `_sfcFillingProject()` or at the end of the list). Use exactly the chart from the spec:

Tags:
```dart
PlcTag(name: 'Start_Cmd', path: 'Inputs/Start_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Operator start command'),
PlcTag(name: 'Quality_OK', path: 'Inputs/Quality_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Batch quality accept (true = dispatch, false = reject)'),
PlcTag(name: 'Temp_PV', path: 'Inputs/Temp_PV', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Mix tank temperature'),
PlcTag(name: 'Fill_Level', path: 'Inputs/Fill_Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Mix tank fill level'),
PlcTag(name: 'Temp_SP', path: 'Internal/Temp_SP', dataType: 'FLOAT64', value: 70.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Target temperature'),
PlcTag(name: 'Fill_Target', path: 'Internal/Fill_Target', dataType: 'FLOAT64', value: 90.0, ioType: 'Internal', engineeringUnits: '%', description: 'Target fill level'),
PlcTag(name: 'Batch_Count', path: 'Internal/Batch_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Dispatched batches'),
PlcTag(name: 'Reject_Count', path: 'Internal/Reject_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Rejected batches'),
PlcTag(name: 'Heater', path: 'Outputs/Heater', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Tank heater'),
PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fill valve'),
PlcTag(name: 'Agitator', path: 'Outputs/Agitator', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Mixer agitator'),
PlcTag(name: 'Dispatch_Pump', path: 'Outputs/Dispatch_Pump', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Dispatch transfer pump'),
PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reject drain valve'),
```

Sim rules:
```dart
SimRule(id: 'sim0', name: 'Heating raises temp', targetPath: 'Temp_PV',
    behavior: 'integrate', ratePerSec: 12.0, minValue: 20, maxValue: 95,
    condition: [SimClause(leftPath: 'Heater', comparator: '==', operand: 'true')]),
SimRule(id: 'sim1', name: 'Filling raises level', targetPath: 'Fill_Level',
    behavior: 'integrate', ratePerSec: 30.0, minValue: 0, maxValue: 100,
    condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
```

SFC program `BatchMix_SFC` (language `'SequentialFunctionChart'`):
```dart
sfcSteps: [
  SfcStep(id: 's0', name: 'IDLE', isInitial: true,
    actionSt: 'Heater := FALSE;\nFill_Valve := FALSE;\nAgitator := FALSE;\nDispatch_Pump := FALSE;\nDrain_Valve := FALSE;\nTemp_PV := 20.0;\nFill_Level := 0.0;'),
  SfcStep(id: 's1', name: 'HEATING', actionSt: 'Heater := TRUE;'),
  SfcStep(id: 's2', name: 'HEAT_DONE', actionSt: 'Heater := FALSE;'),
  SfcStep(id: 's3', name: 'FILLING', actionSt: 'Fill_Valve := TRUE;'),
  SfcStep(id: 's4', name: 'FILL_DONE', actionSt: 'Fill_Valve := FALSE;'),
  SfcStep(id: 's5', name: 'MIXING', actionSt: 'Agitator := TRUE;'),
  SfcStep(id: 's6', name: 'DISPATCH', actionSt: 'Agitator := FALSE;\nDispatch_Pump := TRUE;\nBatch_Count := Batch_Count + 1;'),
  SfcStep(id: 's7', name: 'REJECT', actionSt: 'Agitator := FALSE;\nDrain_Valve := TRUE;\nReject_Count := Reject_Count + 1;'),
],
sfcTransitions: [
  SfcTransition(id: 't0', fromStepId: 's0', toStepId: '', conditionSt: 'Start_Cmd',
      kind: 'parallelFork', toStepIds: ['s1', 's3']),
  SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Temp_PV >= Temp_SP'),
  SfcTransition(id: 't2', fromStepId: 's3', toStepId: 's4', conditionSt: 'Fill_Level >= Fill_Target'),
  SfcTransition(id: 'tj', fromStepId: '', toStepId: 's5', conditionSt: 'TRUE',
      kind: 'parallelJoin', fromStepIds: ['s2', 's4']),
  SfcTransition(id: 't3', fromStepId: 's5', toStepId: 's6', conditionSt: 'STEP_T >= 3000 AND Quality_OK'),
  SfcTransition(id: 't4', fromStepId: 's5', toStepId: 's7', conditionSt: 'STEP_T >= 3000 AND NOT Quality_OK'),
  SfcTransition(id: 't5', fromStepId: 's6', toStepId: 's0', conditionSt: 'STEP_T >= 2000'),
  SfcTransition(id: 't6', fromStepId: 's7', toStepId: 's0', conditionSt: 'STEP_T >= 2000'),
],
```

Task: `PlcTask(name: 'BatchSequenceTask', type: 'Periodic', periodMs: 200, programNames: ['BatchMix_SFC'])`.

HMI (`GridDashboard`, model on `_sfcFillingProject`'s HMI):
```dart
HmiComponent(id: 'bm1', title: 'START Batch', type: 'PushbuttonSwitch', tagBinding: 'Start_Cmd', gridSpanWidth: 2, accentColor: 'green'),
HmiComponent(id: 'bm2', title: 'Quality OK', type: 'ToggleSwitch', tagBinding: 'Quality_OK', gridSpanWidth: 2, accentColor: 'cyan'),
HmiComponent(id: 'bm3', title: 'Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_PV', gridSpanWidth: 2, accentColor: 'amber'),
HmiComponent(id: 'bm4', title: 'Fill (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Fill_Level', gridSpanWidth: 2, accentColor: 'cyan'),
HmiComponent(id: 'bm5', title: 'Heater', type: 'LedIndicatorLight', tagBinding: 'Heater', gridSpanWidth: 1, accentColor: 'amber'),
HmiComponent(id: 'bm6', title: 'Fill Valve', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'cyan'),
HmiComponent(id: 'bm7', title: 'Agitator', type: 'LedIndicatorLight', tagBinding: 'Agitator', gridSpanWidth: 1, accentColor: 'teal'),
HmiComponent(id: 'bm8', title: 'Dispatch', type: 'LedIndicatorLight', tagBinding: 'Dispatch_Pump', gridSpanWidth: 1, accentColor: 'green'),
HmiComponent(id: 'bm9', title: 'Drain', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'red'),
HmiComponent(id: 'bm10', title: 'Dispatched', type: 'StatusPillDisplay', tagBinding: 'Batch_Count', gridSpanWidth: 2, accentColor: 'green'),
HmiComponent(id: 'bm11', title: 'Rejected', type: 'StatusPillDisplay', tagBinding: 'Reject_Count', gridSpanWidth: 2, accentColor: 'red'),
```

(Match the exact `HmiComponent`/`HmiScreenDef`/`PlcProject` field names the file already uses — copy `_sfcFillingProject()` and adapt.)

- [ ] **Step 4: Run — expect PASS**

Run: `cd mobile && flutter test test/sfc_batchmix_showcase_test.dart`
Expected: all 4 cases pass. If the DISPATCH/REJECT scan tests don't advance the count, tune the scan count / verify `STEP_T` reaches 3000 given 200 ms ticks (15 ticks per 3 s) and that the sim reaches SP/target within the loop — do NOT weaken the assertions; fix the chart/sim tuning so the arms actually fire.

- [ ] **Step 5: Regression — default-project round-trip/scan**

Run: `cd mobile && flutter test test/serialization_roundtrip_test.dart test/persistence_integration_test.dart test/project_repository_test.dart`
Expected: all pass (the new project round-trips and is counted via `DefaultProjects.all().length`).

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze lib/data/default_projects.dart test/sfc_batchmix_showcase_test.dart` (zero warnings).

```bash
git add mobile/lib/data/default_projects.dart mobile/test/sfc_batchmix_showcase_test.dart
git commit -m "feat(sfc): add 'Batch Mix & Dispatch' default project (parallel + alternative SFC)"
```

---

### Task 4: Full validation + docs

**Files:**
- Modify: `docs/sfc-branching.md`, `README.md`, `ROADMAP.md`

- [ ] **Step 1: Full green gate**

Run: `cd mobile && flutter analyze` (whole project — must be clean, zero warnings).
Run: `cd mobile && flutter test` (ALL pass — record the exact count).
Run: `cd mobile && flutter build web --release` (must build).
Report any failure verbatim; do not paper over.

- [ ] **Step 2: Docs**

- `docs/sfc-branching.md`: add a short "Showcase" note describing **SFC — Batch Mix & Dispatch** (parallel Heat+Fill, join-waits-for-all, alternative Quality_OK → Dispatch/Reject, Go-Online shows two lit steps during the parallel phase).
- `README.md`: extend the SFC bullet to mention the parallel/alternative showcase project.
- `ROADMAP.md`: add a one-line note that the SFC v2 Minors are fixed and a parallel+conditional showcase project shipped.
- HARD copy rules: NO "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

- [ ] **Step 3: Commit**

```bash
git add docs/sfc-branching.md README.md ROADMAP.md
git commit -m "docs(sfc): document Batch Mix & Dispatch showcase + Minors fixes"
```

---

## Self-Review

**Spec coverage:**
- A1 addParallelBranch alt-head guard → Task 1. ✓
- A2 delete fork-source removes whole construct → Task 1. ✓
- A3 per-column parallel join connector → Task 2. ✓
- A4 `_stepKey` DRY → Task 2. ✓
- A5 `_guardFrag` DRY → Task 2. ✓
- Component B batch-mix project + registration → Task 3. ✓
- Showcase test (round-trip, region shape, both arms) → Task 3. ✓
- Full gate + docs → Task 4. ✓
- No golden count to bump (verified) → covered by Task 3 Step 5 regression. ✓

**Placeholder scan:** Test snippets carry real assertions; the implementer is told to adjust only mechanics (helper names, sim harness signature) to match the files, never to weaken the stated assertions. The chart/tags/sim/HMI code for the new project is fully specified verbatim.

**Type consistency:** `parallelFork`/`parallelJoin` `kind` + `toStepIds`/`fromStepIds` usage matches the model and the SFC v2 engine/parser. `SfcRuntime`/`executeSfcPrograms`/`applySimRules`/`SimRuntime` names match the existing integration-test harnesses. `_stepKey` (Task 2) is internal to `sfc_exec.dart`. `_parFrag`/`_altFrag`/`_guardFrag`/`_transFrag` names match `sfc_layout2.dart`.

**Note for the executor:** Tasks 1–2 harden existing pure helpers (guarded by tests); Task 3 is the visible deliverable — the DISPATCH/REJECT scan assertions are the binding proof both branch types work, so tune chart/sim timing to make them fire rather than weakening the tests. A quick manual on-device look at the new project in the SFC editor (2D chart + Go-Online) before merge is worthwhile.
