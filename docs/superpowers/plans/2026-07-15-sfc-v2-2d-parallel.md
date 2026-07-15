# SFC v2 — 2D Structured Layout + Parallel/AND + Go-Online — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the SFC editor as a 2D "textbook" chart (step boxes, transition blocks, side-by-side alternative branches, double-line parallel fork/join with nesting, GOTO refs) backed by a multi-token engine, with live Go-Online highlighting.

**Architecture:** Additive `SfcTransition` fields (`kind`/`toStepIds`/`fromStepIds`) express fork/join. A multi-token engine (active-step **set**) runs parallel branches and joins when all are complete. Two pure helpers — `sfc_region.dart` (parse the well-structured graph into a Seq/Alt/Par region tree) and `sfc_layout2.dart` (region tree → 2D positions + connector geometry) — feed a `CustomPainter` + `Positioned` canvas in a pan/zoom `InteractiveViewer`. Structure-preserving authoring helpers extend `sfc_edit.dart`. Go-Online reuses the LD monitor pattern (read `SfcRuntime.active` + `scanRunning`, repaint via `LiveTick`).

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400 (canvas pans/zooms; chrome must not overflow).
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `sfc_region.dart`, `sfc_layout2.dart`, and the `sfc_edit.dart` helpers.
- Additive persistence: legacy charts (all `single` transitions) load & render unchanged; new fields default; default projects' 20-scan scan-equivalence stays green.
- Deterministic engine (scan-tick clock only). Go-Online toggle is transient (session-only), not persisted.
- Structured + GOTO only (no free-form wires).

## Key facts (verified)

- `mobile/lib/models/project_model.dart`: `SfcStep {String id; String name; bool isInitial; String actionSt;}`; `SfcTransition {String id; String fromStepId; String toStepId; String conditionSt;}` (json `id`/`from_step_id`/`to_step_id`/`condition_st`). `PlcProgram.sfcSteps`, `.sfcTransitions`.
- `mobile/lib/models/sfc_exec.dart`: `class SfcRuntime { Map<String,String> activeStepId; Map<String,int> stepElapsedMs; void clear(); }`; `void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt, {Set<String>? only, Set<String>? readOnly})`. Uses `runStatements(p, actionSt, write, extraVars: {'STEP_T': elapsed})` for actions and `evalStCondition(p, conditionSt, extraVars: {...})` for transition conditions (from `st_expr.dart`). Force-aware `_forceAwareWrite`.
- `mobile/lib/screens/scan_tick.dart`: `ScanTickRuntime` has `final SfcRuntime sfc = SfcRuntime();`; `runScanTick` calls `executeSfcPrograms(p, dtMs, rt.sfc, only: only, readOnly: readOnly);`.
- `mobile/lib/screens/sfc_editor_screen.dart`: `SfcEditorScreen {PlcProject currentProject; PlcProgram program; VoidCallback onProgramUpdated;}`. Current body renders via `sfc_layout.dart` (`layoutSfc`) as a vertical list with `_buildOutgoing`/`_branchControls`/GOTO chips; `_ensureDefaultSfc` seeds steps/transitions. `sfc_edit.dart` has `newSfcStepId`/`newSfcTransitionId`/`addSfcStep`/`addSfcBranch`/`deleteSfcTransition`/`deleteSfcStep`/`reorderSfcBranch`.
- `mobile/lib/screens/workspace_shell.dart`: `final ScanTickRuntime _scan`; `bool isRunning`; `bool _faulted`; body wrapped in `LiveTickScope(notifier: _liveTick, ...)`. `SfcEditorScreen(...)` constructed alongside the LD/FBD editors (grep `SfcEditorScreen(`). The LD editor is already passed `monitor: _scan.ldMonitor, scanRunning: isRunning && !_faulted` — mirror that for SFC.
- FBD/LD editors use `InteractiveViewer` + `CustomPaint` + `Positioned` for their pan/zoom canvases (`ld_editor_screen.dart`, `fbd_editor_screen.dart`) — follow those patterns.

---

### Task 1: Model — SfcTransition fork/join fields

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`SfcTransition`)
- Test: `mobile/test/sfc_transition_kind_test.dart` (create)

**Interfaces:**
- Produces: `SfcTransition.kind` (String, default `'single'`), `.toStepIds` (List<String>, default `[]`), `.fromStepIds` (List<String>, default `[]`); json `kind`/`to_step_ids`/`from_step_ids`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sfc_transition_kind_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('new kind/fork/join fields default and round-trip', () {
    final t = SfcTransition(
      id: 't', fromStepId: 's0', toStepId: 's1', conditionSt: 'X',
      kind: 'parallelFork', toStepIds: ['s1', 's2']);
    final r = SfcTransition.fromJson(t.toJson());
    expect(r.kind, 'parallelFork');
    expect(r.toStepIds, ['s1', 's2']);
    expect(r.fromStepIds, isEmpty);
  });

  test('legacy transition JSON (no new keys) loads as single', () {
    final legacy = {
      'id': 't', 'from_step_id': 's0', 'to_step_id': 's1', 'condition_st': 'X',
    };
    final r = SfcTransition.fromJson(legacy);
    expect(r.kind, 'single');
    expect(r.toStepIds, isEmpty);
    expect(r.fromStepIds, isEmpty);
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`SfcTransition` has no `kind`).

Run: `cd mobile && flutter test test/sfc_transition_kind_test.dart`

- [ ] **Step 3: Add the fields**

In `SfcTransition`: add fields `String kind; List<String> toStepIds; List<String> fromStepIds;`; constructor `this.kind = 'single', List<String>? toStepIds, List<String>? fromStepIds` with `toStepIds = toStepIds ?? []`, `fromStepIds = fromStepIds ?? []`; `fromJson` add `kind: j['kind'] ?? 'single'`, `toStepIds: (j['to_step_ids'] as List? ?? []).map((e) => e.toString()).toList()`, `fromStepIds: (j['from_step_ids'] as List? ?? []).map((e) => e.toString()).toList()`; `toJson` add `'kind': kind, 'to_step_ids': toStepIds, 'from_step_ids': fromStepIds`.

- [ ] **Step 4: Run — expect PASS.** Also run `flutter test test/serialization_roundtrip_test.dart` (stays green; additive).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/test/sfc_transition_kind_test.dart
git commit -m "feat(sfc): additive SfcTransition kind/toStepIds/fromStepIds for parallel"
```

---

### Task 2: Multi-token engine (active-step set + fork/join)

**Files:**
- Modify: `mobile/lib/models/sfc_exec.dart` (`SfcRuntime`, `executeSfcPrograms`)
- Test: `mobile/test/sfc_multitoken_test.dart` (create)

**Interfaces:**
- Produces: `SfcRuntime { Map<String, Set<String>> active; Map<String,int> stepElapsedMs; void clear(); }` (`activeStepId` REMOVED). `stepElapsedMs` keyed `'<prog>|<stepId>'`.
- Consumes: `SfcTransition.kind`/`toStepIds`/`fromStepIds` (Task 1).

**Context:** Replace the single active step with a set. Any code reading `SfcRuntime.activeStepId` (grep `activeStepId` across `lib/` and `test/`) must be updated to `active`. `scan_tick.dart`'s call is unchanged (same params). The old editor doesn't read `activeStepId`. A single-token/legacy chart with one active step reproduces the previous behaviour exactly.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/sfc_multitoken_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';

PlcProject _proj(PlcProgram prog, {List<PlcTag>? tags}) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: tags ?? [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
SfcStep _s(String id, {bool init = false, String action = ''}) =>
    SfcStep(id: id, name: id, isInitial: init, actionSt: action);

void main() {
  test('single-token chart advances first-true, one at a time (unchanged)', () {
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([_s('a', init: true), _s('b'), _s('c')]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 'a', toStepId: 'b', conditionSt: 'TRUE'),
      SfcTransition(id: 't1', fromStepId: 'b', toStepId: 'c', conditionSt: 'TRUE'),
    ]);
    final proj = _proj(prog);
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt); // a -> b
    expect(rt.active['M'], {'b'});
    executeSfcPrograms(proj, 100, rt); // b -> c
    expect(rt.active['M'], {'c'});
  });

  test('parallel fork activates all branch heads; join waits for all', () {
    // a --[fork T]--> {p1, q1};  p1 --[TRUE]--> p2 ; q1 --[TRUE]--> q2 ;
    // join {p2, q2} --[TRUE]--> done
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      _s('a', init: true), _s('p1'), _s('p2'), _s('q1'), _s('q2'), _s('done'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 'f', fromStepId: 'a', toStepId: '', conditionSt: 'TRUE',
          kind: 'parallelFork', toStepIds: ['p1', 'q1']),
      SfcTransition(id: 'tp', fromStepId: 'p1', toStepId: 'p2', conditionSt: 'Pgo'),
      SfcTransition(id: 'tq', fromStepId: 'q1', toStepId: 'q2', conditionSt: 'Qgo'),
      SfcTransition(id: 'j', fromStepId: '', toStepId: 'done', conditionSt: 'TRUE',
          kind: 'parallelJoin', fromStepIds: ['p2', 'q2']),
    ]);
    final tags = [
      PlcTag(name: 'Pgo', path: 'Pgo', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'Qgo', path: 'Qgo', dataType: 'BOOL', value: false, ioType: 'Internal'),
    ];
    final proj = _proj(prog, tags: tags);
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt);            // a fork -> {p1,q1}
    expect(rt.active['M'], {'p1', 'q1'});
    proj.tags.firstWhere((t) => t.name == 'Pgo').value = true;
    executeSfcPrograms(proj, 100, rt);            // p1 -> p2 ; q1 stays
    expect(rt.active['M'], {'p2', 'q1'});
    executeSfcPrograms(proj, 100, rt);            // join not satisfied (q not done)
    expect(rt.active['M'], {'p2', 'q1'});
    proj.tags.firstWhere((t) => t.name == 'Qgo').value = true;
    executeSfcPrograms(proj, 100, rt);            // q1 -> q2
    expect(rt.active['M'], {'p2', 'q2'});
    executeSfcPrograms(proj, 100, rt);            // join fires -> done
    expect(rt.active['M'], {'done'});
  });

  test('alternative divergence still first-true (priority order)', () {
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([_s('a', init: true), _s('x'), _s('y')]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 'a', toStepId: 'x', conditionSt: 'A'),
      SfcTransition(id: 't1', fromStepId: 'a', toStepId: 'y', conditionSt: 'B'),
    ]);
    final tags = [
      PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'),
      PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true, ioType: 'Internal'),
    ];
    final rt = SfcRuntime();
    executeSfcPrograms(_proj(prog, tags: tags), 100, rt);
    expect(rt.active['M'], {'x'}); // A wins (list order)
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`rt.active` undefined; fork/join not handled).

- [ ] **Step 3: Rewrite `SfcRuntime` + `executeSfcPrograms`**

```dart
class SfcRuntime {
  final Map<String, Set<String>> active = {};   // progName -> active step ids
  final Map<String, int> stepElapsedMs = {};     // '<prog>|<stepId>' -> STEP_T ms
  void clear() {
    active.clear();
    stepElapsedMs.clear();
  }
}
```

Rewrite `executeSfcPrograms` per program:

```dart
void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt, {Set<String>? only, Set<String>? readOnly}) {
  for (final prog in p.programs) {
    if (prog.language != 'SequentialFunctionChart' || prog.sfcSteps.isEmpty) {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    SfcStep? stepById(String id) {
      for (final s in prog.sfcSteps) {
        if (s.id == id) {
          return s;
        }
      }
      return null;
    }

    // Init the active set (initial step, else first).
    var activeSet = rt.active[prog.name];
    if (activeSet == null || activeSet.isEmpty) {
      final initial = prog.sfcSteps.firstWhere((s) => s.isInitial, orElse: () => prog.sfcSteps.first);
      activeSet = {initial.id};
      rt.active[prog.name] = activeSet;
      rt.stepElapsedMs['${prog.name}|${initial.id}'] = 0;
    }

    // Advance elapsed + run actions for each active step.
    for (final id in activeSet) {
      final key = '${prog.name}|$id';
      final elapsed = (rt.stepElapsedMs[key] ?? 0) + dtMs;
      rt.stepElapsedMs[key] = elapsed;
      final step = stepById(id);
      if (step != null) {
        runStatements(p, step.actionSt, (path, v) {
          if (readOnly == null || !readOnly.contains(path)) {
            _forceAwareWrite(p, path, v);
          }
        }, extraVars: {'STEP_T': elapsed});
      }
    }

    // Compute firings against the START-OF-SCAN snapshot.
    final snapshot = Set<String>.from(activeSet);
    final consumed = <String>{};
    final toAdd = <String>{};
    for (final t in prog.sfcTransitions) {
      // sources / eligibility per kind
      List<String> sources;
      List<String> targets;
      if (t.kind == 'parallelFork') {
        sources = [t.fromStepId];
        targets = t.toStepIds;
      } else if (t.kind == 'parallelJoin') {
        sources = t.fromStepIds;
        targets = [t.toStepId];
      } else {
        sources = [t.fromStepId];
        targets = [t.toStepId];
      }
      // eligible iff all sources are in the snapshot and none already consumed
      final eligible = sources.isNotEmpty &&
          sources.every((s) => snapshot.contains(s)) &&
          sources.every((s) => !consumed.contains(s));
      if (!eligible) {
        continue;
      }
      final elapsed = rt.stepElapsedMs['${prog.name}|${sources.first}'] ?? 0;
      if (!evalStCondition(p, t.conditionSt, extraVars: {'STEP_T': elapsed})) {
        continue;
      }
      // commit
      consumed.addAll(sources);
      for (final tgt in targets) {
        if (stepById(tgt) != null) {
          toAdd.add(tgt);
        }
      }
    }

    // Apply.
    final next = Set<String>.from(activeSet)..removeAll(consumed)..addAll(toAdd);
    for (final id in toAdd) {
      if (!activeSet.contains(id)) {
        rt.stepElapsedMs['${prog.name}|$id'] = 0; // (re)activated -> reset STEP_T
      }
    }
    rt.active[prog.name] = next;
  }
}
```

Notes: `evalStCondition('TRUE', ...)` is truthy (as today). The commit order = `sfcTransitions` list order, so an alternative divergence's first-true wins. A step already consumed cannot be consumed again (guards double-firing). Targets added this scan are not in `snapshot`, so their transitions don't fire until next scan.

- [ ] **Step 4: Update any `activeStepId` readers**

Run `grep -rn "activeStepId" mobile/lib mobile/test`. Update each to the new `active` set API (there should be none in `lib` outside the old engine; fix any tests — e.g. an old `rt.activeStepId['M'] == 'x'` becomes `rt.active['M'] == {'x'}`). The prior `sfc_exec_test.dart`/`sfc_branch_roundtrip_test.dart` from earlier assert `rt.activeStepId[...]` — migrate them to `rt.active[...]` set equality (keep their intent: priority routing, loop).

- [ ] **Step 5: Run — expect PASS.** Then `flutter test test/sfc_exec_test.dart test/sfc_branch_roundtrip_test.dart test/serialization_roundtrip_test.dart` (migrated + still green) and a broad `flutter test` (scan_tick unaffected).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/sfc_exec.dart mobile/test/
git commit -m "feat(sfc): multi-token engine (active-step set, parallel fork/join)"
```

---

### Task 3: Pure region parse (`sfc_region.dart`)

**Files:**
- Create: `mobile/lib/models/sfc_region.dart`
- Test: `mobile/test/sfc_region_test.dart`

**Interfaces:**
- Produces the region types + `SfcRegion parseSfc(List<SfcStep> steps, List<SfcTransition> transitions)`.

**Context:** Parse the well-structured graph into a tree for 2D layout. Dart lacks `sealed` on the installed SDK for some setups — use a base class with a `type` discriminant if needed; the tests below use `is` checks so any subclass encoding works.

Region types:
```dart
abstract class SfcRegion {}
class StepRegion extends SfcRegion { final SfcStep step; StepRegion(this.step); }
class TransRegion extends SfcRegion {
  final SfcTransition transition;
  final SfcStep? target;     // resolved target step (null if dangling)
  final bool isGoto;         // true when target is an already-placed step (loop/merge)
  TransRegion(this.transition, this.target, this.isGoto);
}
class SeqRegion extends SfcRegion { final List<SfcRegion> items; SeqRegion(this.items); }
class AltRegion extends SfcRegion {
  final SfcStep head;                 // the diverging step
  final List<List<SfcRegion>> branches; // each branch is a sequence of regions
  final List<SfcTransition> guards;   // the guard transition of each branch (parallel to `branches`)
  final SfcStep? merge;               // convergence step (null if branches GOTO out)
  AltRegion(this.head, this.branches, this.guards, this.merge);
}
class ParRegion extends SfcRegion {
  final SfcTransition fork;           // the parallelFork transition
  final List<List<SfcRegion>> branches;
  final SfcTransition join;           // the parallelJoin transition
  final SfcStep? after;               // join.toStepId step
  ParRegion(this.fork, this.branches, this.join, this.after);
}
```

Parse algorithm (from the initial step, `visited` set):
- Maintain `visited`. Walk from a step `cur`:
  - Record `StepRegion(cur)`; mark visited.
  - Outgoing = transitions with `fromStepId == cur.id`, in list order, that are `single` or `parallelFork`. (`parallelJoin` transitions are consumed when their branches end, not walked from a single step.)
  - **0 outgoing** → sequence ends.
  - **1 `parallelFork`** → build a `ParRegion`: for each head in `fork.toStepIds`, walk a branch until it reaches a step that is a member of the matching `parallelJoin.fromStepIds` (the join whose `fromStepIds` are exactly this fork's branch tails — locate it by matching membership); then continue from `join.toStepId`.
  - **1 `single`** (target not yet visited) → append `TransRegion(single, target, false)` then continue from `target`.
  - **≥2 `single`** → `AltRegion`: each outgoing is a branch guarded by its transition; walk each branch until branches reach a common convergence step (first step reached by all branches) or GOTO; `merge` = that convergence; continue from `merge`.
  - A `single`/fork target that IS visited → `TransRegion(t, target, isGoto:true)` leaf; do not recurse.
  - Dangling target (no step) → `TransRegion(t, null, false)`.
- Return the top-level as a `SeqRegion` (or the single region if only one).

For a partly-built/unparseable chart, degrade: emit the steps as a `SeqRegion` with GOTO/plain `TransRegion` leaves rather than throwing.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/sfc_region_test.dart` with cases:
- linear (a→b→c): a `SeqRegion` of Step/Trans/Step/Trans/Step; no Alt/Par.
- alternative (a→x via A, a→y via B, both → m): an `AltRegion` with 2 branches, `merge == m`.
- parallel (a fork→{p1,q1}, p1→p2, q1→q2, join{p2,q2}→done): a `ParRegion` with 2 branches, `join.toStepId == 'done'`, `after.id == 'done'`.
- nested parallel (a branch of a ParRegion itself contains a ParRegion): assert the inner `ParRegion` is present inside a branch.
- loop-back (c→a): the `c` step's outgoing is a `TransRegion(isGoto:true, target:a)`.
- cycle-safety: a self/mutual loop terminates.

(Write concrete fixtures + `is`/field assertions for each; assert structure, not pixel positions.)

- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement `parseSfc`** per the algorithm above (pure Dart, only `project_model.dart` import). Provide the branch-walk + join-matching + convergence-finding helpers.
- [ ] **Step 4: Run — expect PASS** (all region cases).
- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/sfc_region.dart mobile/test/sfc_region_test.dart
git commit -m "feat(sfc): pure region-tree parser (seq/alt/parallel, nested, GOTO)"
```

---

### Task 4: Pure 2D layout (`sfc_layout2.dart`)

**Files:**
- Create: `mobile/lib/models/sfc_layout2.dart`
- Test: `mobile/test/sfc_layout2_test.dart`

**Interfaces:**
- Consumes: the region tree (Task 3).
- Produces:
  - `class SfcBox { final String kind; /* 'step'|'trans'|'goto'|'forkBar'|'joinBar' */ final SfcStep? step; final SfcTransition? transition; final double x, y, w, h; }`
  - `class SfcConn { final double x1, y1, x2, y2; final bool doubleBar; }`
  - `class SfcLayout { final List<SfcBox> boxes; final List<SfcConn> conns; final double width, height; }`
  - `SfcLayout layoutSfcRegion(SfcRegion root)`.

**Context:** Assign each region a `(w,h)` bottom-up, then absolute `(x,y)` top-down, centering children. Fixed metrics (e.g. step box 140×64, transition block 160×40, vertical gap 28, branch column gap 32, bar height 10). Side-by-side branches occupy adjacent columns; a region's width = max(sum of child widths + gaps, own content width). Nesting recurses. Emit fork/join `forkBar`/`joinBar` boxes (full width of their branch span) as the double-line bars; connectors link boxes vertically and to the bars.

- [ ] **Step 1: Write the failing tests** (`sfc_layout2_test.dart`): for a linear region the boxes are vertically stacked (increasing y, same x); for an alternative region the two branch step boxes have **different x** and overlapping y-range (side-by-side), and a convergence connector; for a parallel region there is a `forkBar` and a `joinBar` box spanning the branches and two side-by-side branch columns; for nested parallel the inner branch column width ≥ its content; total `width`/`height` bound all boxes; no two step boxes overlap.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement `layoutSfcRegion`** (pure; recursive size then place). Keep metrics as named consts.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/sfc_layout2.dart mobile/test/sfc_layout2_test.dart
git commit -m "feat(sfc): pure 2D region layout (positions + connectors + fork/join bars)"
```

---

### Task 5: 2D canvas rendering (editor rewrite, read/edit of existing elements)

**Files:**
- Modify: `mobile/lib/screens/sfc_editor_screen.dart`
- Test: `mobile/test/sfc_canvas_render_test.dart` (create)

**Context:** Replace the list body with a pan/zoom canvas built from `parseSfc` → `layoutSfcRegion`. Keep `_ensureDefaultSfc`, the tag palette dock/sheet, and the app-bar. Follow the FBD editor's `InteractiveViewer` + `Stack(CustomPaint + Positioned...)` pattern.

Body:
```dart
final region = parseSfc(widget.program.sfcSteps, widget.program.sfcTransitions);
final layout = layoutSfcRegion(region);
return InteractiveViewer(
  constrained: false,
  minScale: 0.4, maxScale: 2.5,
  boundaryMargin: const EdgeInsets.all(200),
  child: SizedBox(
    width: layout.width, height: layout.height,
    child: Stack(children: [
      Positioned.fill(child: CustomPaint(painter: _SfcPainter(layout))),
      for (final b in layout.boxes) _positionedBox(b),   // step boxes, transition blocks, GOTO chips
    ]),
  ),
);
```
- `_SfcPainter` draws `conns` — a normal line, or a **double line** when `conn.doubleBar` (two parallel strokes) for fork/join bars.
- `_positionedBox(b)`:
  - `'step'` → a rounded `Container` (INITIAL/STEP badge, `step.name`, the N-action ST field — reuse the existing action editor), tappable to edit/delete.
  - `'trans'` → a **bordered block** `Container` holding the condition ST field (with autocomplete) — the "make it a block" requirement.
  - `'goto'` → the amber `↺ GOTO <name>` chip.
  - `'forkBar'`/`'joinBar'` → thin double-line bar (or draw purely in the painter and skip a box).

- [ ] **Step 1: Write the failing widget test** (`sfc_canvas_render_test.dart`): pump `SfcEditorScreen` with a project containing a chart that has an alternative branch and a parallel fork/join (built via the model directly); assert (a) step names render, (b) transition conditions render inside bordered blocks (find the condition text), (c) no exception / no overflow at 1400 and 360. It should FAIL against the current list renderer's structure (e.g. asserting an `InteractiveViewer` is present, or two branch steps at different x via `tester.getTopLeft`).
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement the canvas** (painter + positioned boxes + transition blocks + GOTO chips + InteractiveViewer). Remove the old `layoutSfc`-list body and `_buildOutgoing`/`_branchControls` list rendering (authoring returns in Task 6).
- [ ] **Step 4: Run — expect PASS.** `flutter analyze` clean. Run the earlier SFC widget tests — update/replace those asserting the old list structure to the new canvas structure (their intent: chart renders, conditions edit).
- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/sfc_editor_screen.dart mobile/test/sfc_canvas_render_test.dart
git commit -m "feat(sfc): 2D canvas editor (step boxes, transition blocks, bars, GOTO) via region layout"
```

---

### Task 6: Structured authoring (fork/join/alt/nest) + canvas affordances

**Files:**
- Modify: `mobile/lib/models/sfc_edit.dart` (new helpers), `mobile/lib/screens/sfc_editor_screen.dart` (affordances)
- Test: `mobile/test/sfc_edit_parallel_test.dart` (create), extend `mobile/test/sfc_canvas_render_test.dart`

**Interfaces:**
- Produces pure helpers (mutate the `PlcProgram`): `addAlternativeBranch(p, program, atStepId)`, `addParallelBranch(p, program, afterStepId)` (creates/extends a fork/join around the segment; adds a branch), `deleteParallelBranch(...)` (collapses fork/join to a sequence if one branch remains), plus target-set helpers keeping `toStepIds`/`fromStepIds` consistent. (Names final at implementation; keep them structure-preserving.)

- [ ] **Step 1: Write failing pure tests** (`sfc_edit_parallel_test.dart`): starting from a linear chart, `addParallelBranch` yields a `parallelFork` + `parallelJoin` pair with 2 branches and consistent `toStepIds`/`fromStepIds`; adding another parallel branch inside a branch nests (a second fork/join whose steps are within the first branch); `deleteParallelBranch` down to one branch collapses (removes fork/join, rejoins the sequence); the result always parses (`parseSfc` succeeds, no dangling).
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement the helpers** (structure-preserving; reuse `newSfcStepId`/`newSfcTransitionId`). Wire canvas affordances: a step box's menu gets **＋Add step after**, **＋Add alternative branch**, **＋Add parallel branch**; a transition block gets **edit condition / set target (existing/New step/GOTO) / delete**; delete-step uses the collapse-aware cleanup.
- [ ] **Step 4: Run — expect PASS.** Extend `sfc_canvas_render_test.dart` with a widget test: tapping **＋Add parallel branch** adds a fork/join and re-renders two side-by-side branch columns with a double bar; no overflow.
- [ ] **Step 5: `flutter analyze` + commit**

```bash
git add mobile/lib/models/sfc_edit.dart mobile/lib/screens/sfc_editor_screen.dart mobile/test/sfc_edit_parallel_test.dart mobile/test/sfc_canvas_render_test.dart
git commit -m "feat(sfc): structured authoring — add alternative/parallel/nested + collapse"
```

---

### Task 7: Live Go-Online highlighting

**Files:**
- Modify: `mobile/lib/screens/sfc_editor_screen.dart` (params, toggle, highlight), `mobile/lib/screens/workspace_shell.dart` (pass runtime)
- Test: `mobile/test/sfc_online_test.dart` (create)

**Interfaces:**
- Produces: `SfcEditorScreen({..., required SfcRuntime sfcRuntime, required bool scanRunning})`.
- Consumes: `SfcRuntime.active` (Task 2), `LiveTickScope.of(context)`.

**Context:** Mirror the LD Go-Online monitor. `_online` session bool + `Icons.sensors` toggle (LIVE/FROZEN from `scanRunning`), default off. When `_online`, an **active** step box (`sfcRuntime.active[widget.program.name]?.contains(step.id)`) glows energized (multiple lit for parallel), others dim; show the active step's `STEP_T` (from `sfcRuntime.stepElapsedMs['${program.name}|${step.id}']`); repaint the canvas on the `LiveTick` pulse only while `_online` (wrap the canvas in a `ListenableBuilder(listenable: LiveTickScope.of(context))`). Off/stopped → plain view; paused → frozen (the active set stops updating). The shell passes `sfcRuntime: _scan.sfc, scanRunning: isRunning && !_faulted` at the `SfcEditorScreen(...)` call (grep it) — mirroring the LD `monitor`/`scanRunning` wiring; update every `SfcEditorScreen(...)` construction site (shell + tests).

- [ ] **Step 1: Write the failing test** (`sfc_online_test.dart`): build a project + `SfcRuntime` whose `active['prog']` is `{'p1','q1'}` (two parallel steps); pump `SfcEditorScreen` with `sfcRuntime`, `scanRunning:true`; tap **Go Online**; assert no exception and that the two active step boxes render with the energized style (e.g. find them and check they are distinguishable from inactive — assert both `p1` and `q1` names present and a `LIVE` label shows). FAIL first (no `sfcRuntime` param / no toggle).
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** the params + toggle + active-step highlight + `STEP_T` + LiveTick wrapper; update the shell call and every test construction site (`grep -rn "SfcEditorScreen(" mobile/lib mobile/test`).
- [ ] **Step 4: Run — expect PASS.** `flutter analyze` clean; broad `flutter test` compiles (all construction sites updated).
- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/sfc_editor_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/
git commit -m "feat(sfc): Go-Online highlight of the active-step set (parallel-aware, LiveTick)"
```

---

### Task 8: Validation, retire old layout, docs

**Files:**
- Delete (if unused): `mobile/lib/models/sfc_layout.dart` (+ its test) — superseded by `sfc_region`/`sfc_layout2`.
- Create: `mobile/test/sfc_v2_roundtrip_test.dart`
- Modify: `docs/sfc-branching.md` (rewrite → SFC v2), `ROADMAP.md`, `README.md`

- [ ] **Step 1: No-persist / round-trip guard** — `sfc_v2_roundtrip_test.dart`: a chart with a `parallelFork`/`parallelJoin` round-trips (`kind`/`to_step_ids`/`from_step_ids` preserved, order stable); a legacy single-token default project round-trips unchanged; the Go-Online toggle adds nothing to JSON.
- [ ] **Step 2: Retire `sfc_layout.dart`** — grep for remaining imports of `sfc_layout.dart`/`layoutSfc`; if none outside its own test, delete the file + `sfc_layout_test.dart`. (If still referenced, leave and note.)
- [ ] **Step 3: Full green gate** — `cd mobile && flutter analyze` (clean); `flutter test` (all pass); `flutter build web --release` (builds). Report the test count.
- [ ] **Step 4: Docs** — rewrite `docs/sfc-branching.md` into an SFC v2 doc: 2D layout, step boxes / transition blocks, alternative side-by-side, parallel fork/join + nesting, GOTO refs, the multi-token engine (active set, join-when-all), Go-Online highlight, structured-only constraint, additive persistence. Update `ROADMAP.md` (Phase 3 post-ship note) and the `README.md` SFC bullet. No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding, no reverse-engineering wording.
- [ ] **Step 5: Commit**

```bash
git add -A mobile/lib mobile/test docs ROADMAP.md README.md
git commit -m "test+docs(sfc): SFC v2 round-trip guard, retire old list layout, docs/roadmap"
```

---

## Self-Review

**Spec coverage:**
- Additive model (kind/toStepIds/fromStepIds) → Task 1. ✓
- Multi-token engine (fork activates all, join waits-all, alternative first-true, single-token identical, nesting) → Task 2. ✓
- Pure region parse (seq/alt/par, nested, GOTO, cycle-safe) → Task 3. ✓
- Pure 2D layout (positions, side-by-side columns, double bars, nesting) → Task 4. ✓
- 2D canvas (step boxes, transition BLOCKS, bars, GOTO, pan/zoom) → Task 5. ✓
- Structured authoring (alt/parallel/nest/collapse) → Task 6. ✓
- Go-Online highlight (active-step set, parallel-aware, STEP_T, LiveTick, shell wiring) → Task 7. ✓
- Migration (legacy single-token unchanged; scan-equivalence) → Tasks 2/8. ✓
- Retire old layout, docs/roadmap → Task 8. ✓

**Placeholder scan:** Tasks 1/2/7 carry complete code. Tasks 3/4/5/6 carry the data structures, the algorithm, and comprehensive TDD test cases that pin the contract (region structure, layout geometry invariants, authoring outcomes) — the harder algorithmic pieces (region parse, 2D layout) are specified by contract + tests rather than fully-inlined final code, which is appropriate for their complexity; the review loop verifies the contract. No "TBD"/"handle later" vagueness.

**Type consistency:** `SfcTransition.kind`/`toStepIds`/`fromStepIds` (Task 1) used by the engine (Task 2), parser (Task 3), authoring (Task 6). `SfcRuntime.active: Map<String,Set<String>>` + `stepElapsedMs` keyed `'<prog>|<stepId>'` (Task 2) consumed by Go-Online (Task 7). `parseSfc → SfcRegion` (Task 3) → `layoutSfcRegion → SfcLayout{boxes,conns,width,height}` (Task 4) → canvas (Task 5). `SfcEditorScreen({..., sfcRuntime, scanRunning})` (Task 7) matches the shell call.

**Note for the executor:** this is a large plan; Tasks 3-6 are algorithmically heavy. Treat their TDD test cases as the binding contract, expand them if the implementer finds gaps, and lean on the per-task review + the final whole-branch review for the layout/rendering correctness that a text diff can't fully prove (a manual on-device check of the 2D canvas is worthwhile before merge).
