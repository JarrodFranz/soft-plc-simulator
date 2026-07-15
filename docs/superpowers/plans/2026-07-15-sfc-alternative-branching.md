# SFC Alternative (OR/Selection) Branching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each SFC step own multiple ordered outgoing transitions (editable target + condition, top-to-bottom = if/else-if priority), rendered as a per-step branch list with GOTO chips and flow-order layout, keeping a single active token.

**Architecture:** The model (`SfcStep`/`SfcTransition` with `from/to`) and engine (`executeSfcPrograms`, first-true single-token routing) already support this — so **no model/engine change and no data migration**. Work = a pure `sfc_layout.dart` helper (flow-order + inline-vs-GOTO) plus an editor rewrite in `sfc_editor_screen.dart` (branch-list UI, target picker, reorder, add/delete branch, delete-step cleanup), a couple of pure helpers for id-generation/reorder, and regression tests.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package name is `soft_plc_mobile` (imports `package:soft_plc_mobile/...`).

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at widths 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` (incl. the new `models/sfc_layout.dart`).
- Additive persistence: no new serialized fields; a linear/legacy chart round-trips byte-identically.
- Single active step preserved; exactly one `isInitial` step.
- No changes to `mobile/lib/models/sfc_exec.dart` or `mobile/lib/models/project_model.dart`.

## Key facts (verified against the code)

- `mobile/lib/models/project_model.dart`: `class SfcStep { String id; String name; bool isInitial; String actionSt; }` and `class SfcTransition { String id; String fromStepId; String toStepId; String conditionSt; }`. Both mutable, fully serialized. A `PlcProgram` has `List<SfcStep> sfcSteps` and `List<SfcTransition> sfcTransitions`.
- `mobile/lib/models/sfc_exec.dart` `executeSfcPrograms`: one active step per program; each scan runs the active step's `actionSt`, then iterates `prog.sfcTransitions` in list order and the **first** transition with `fromStepId == active.id` **and** a true condition switches the token to `toStepId` (skipping a `toStepId` that matches no step). Priority = order within `sfcTransitions`.
- `mobile/lib/screens/sfc_editor_screen.dart` (277 lines): `SfcEditorScreen {currentProject, program, onProgramUpdated}`. Renders a linear `ListView.builder` over `sfcSteps`, pairing `step[i]` with `transition[i]` positionally (`_buildCenterWorkspace`). `_addNewStep()` appends a step (id `s_$idx`, no transition). `_buildSfcStepCard(step,index,width)` draws the step card (INITIAL STEP/STEP badge, name, delete, an `actionSt` `TextField` with `onSubmitted`). `_buildSfcTransitionGraphic(transition,width)` draws a transition card with a `conditionSt` `TextField`. A right-dock/bottom-sheet tag palette (`_buildTagPaletteDock`, `_openTagPaletteSheet`) is unchanged. `build()` uses `context.isExpanded` to choose 3-pane vs single-pane and `context.isShort` for a compact app bar.
- Existing SFC tests live in `mobile/test/` (search `sfc`). The engine test file is `mobile/test/sfc_exec_test.dart` (create if absent).

---

### Task 1: Pure flow-order layout helper

**Files:**
- Create: `mobile/lib/models/sfc_layout.dart`
- Test: `mobile/test/sfc_layout_test.dart`

**Interfaces:**
- Produces:
  - `class SfcOutgoing { final SfcTransition transition; final SfcStep? target; final bool inline; }`
  - `class SfcLayoutRow { final SfcStep step; final List<SfcOutgoing> outgoing; }`
  - `List<SfcLayoutRow> layoutSfc(List<SfcStep> steps, List<SfcTransition> transitions)`

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sfc_layout_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_layout.dart';

SfcStep _s(String id, {bool init = false}) => SfcStep(id: id, name: id.toUpperCase(), isInitial: init);
SfcTransition _t(String id, String from, String to) =>
    SfcTransition(id: id, fromStepId: from, toStepId: to, conditionSt: 'TRUE');

void main() {
  test('linear chart lays out in flow order with the tail loop as a GOTO', () {
    final steps = [_s('a', init: true), _s('b'), _s('c')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'b', 'c'), _t('t2', 'c', 'a')];
    final rows = layoutSfc(steps, trans);
    expect(rows.map((r) => r.step.id).toList(), ['a', 'b', 'c']);
    // a->b and b->c are inline; c->a loops back to an already-placed step (GOTO).
    expect(rows[0].outgoing.single.inline, isTrue);
    expect(rows[1].outgoing.single.inline, isTrue);
    expect(rows[2].outgoing.single.inline, isFalse); // loop-back GOTO
    expect(rows[2].outgoing.single.target!.id, 'a');
  });

  test('a 2-way branch: first target inline, second is a GOTO', () {
    final steps = [_s('a', init: true), _s('x'), _s('y')];
    final trans = [_t('t0', 'a', 'x'), _t('t1', 'a', 'y')];
    final rows = layoutSfc(steps, trans);
    // a placed first; its first outgoing (->x) inline places x next; ->y GOTO.
    expect(rows.first.step.id, 'a');
    expect(rows.first.outgoing.length, 2);
    expect(rows.first.outgoing[0].inline, isTrue);
    expect(rows.first.outgoing[0].target!.id, 'x');
    expect(rows.first.outgoing[1].inline, isFalse);
    expect(rows.first.outgoing[1].target!.id, 'y');
    // both x and y appear as rows (y is branch-reachable, placed after).
    expect(rows.map((r) => r.step.id).toSet(), {'a', 'x', 'y'});
  });

  test('convergence: two steps target one merge step, placed once', () {
    final steps = [_s('a', init: true), _s('b'), _s('m')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'a', 'm'), _t('t2', 'b', 'm')];
    final rows = layoutSfc(steps, trans);
    expect(rows.where((r) => r.step.id == 'm').length, 1); // placed once
  });

  test('unreachable step lands last; dangling target yields null', () {
    final steps = [_s('a', init: true), _s('b'), _s('orphan')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'b', 'ghost')];
    final rows = layoutSfc(steps, trans);
    expect(rows.last.step.id, 'orphan'); // unreachable, last
    expect(rows[1].outgoing.single.target, isNull); // 'ghost' does not exist
  });

  test('self-loop and mutual loop terminate (cycle-safe)', () {
    final steps = [_s('a', init: true), _s('b')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'b', 'a'), _t('t2', 'a', 'a')];
    final rows = layoutSfc(steps, trans); // must not hang
    expect(rows.map((r) => r.step.id).toSet(), {'a', 'b'});
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/sfc_layout_test.dart`
Expected: FAIL — `sfc_layout.dart` / `layoutSfc` undefined.

- [ ] **Step 3: Implement the helper**

Create `mobile/lib/models/sfc_layout.dart`:

```dart
import 'project_model.dart';

/// One outgoing transition of a step in the laid-out chart.
class SfcOutgoing {
  final SfcTransition transition;

  /// The transition's target step, or null if `toStepId` matches no step
  /// (a dangling/deleted target).
  final SfcStep? target;

  /// True for the one outgoing whose target is drawn as the card directly
  /// below this step (the inline connector). All others are GOTO chips.
  final bool inline;

  const SfcOutgoing({required this.transition, required this.target, required this.inline});
}

/// A step plus its outgoing transitions (in priority order).
class SfcLayoutRow {
  final SfcStep step;
  final List<SfcOutgoing> outgoing;
  const SfcLayoutRow({required this.step, required this.outgoing});
}

/// Orders steps by flow from the initial step: depth-first following each
/// step's FIRST not-yet-placed outgoing target. A target is placed the first
/// time it is reached; additional branches and already-placed targets become
/// GOTO chips (inline == false). Branch-reachable steps follow the main path;
/// steps that are never reached come last, in `steps` list order. Cycle-safe.
List<SfcLayoutRow> layoutSfc(List<SfcStep> steps, List<SfcTransition> transitions) {
  SfcStep? byId(String id) {
    for (final s in steps) {
      if (s.id == id) {
        return s;
      }
    }
    return null;
  }

  List<SfcTransition> outOf(String id) =>
      transitions.where((t) => t.fromStepId == id).toList(growable: false);

  final placedOrder = <SfcStep>[];
  final placed = <String>{};

  // Depth-first placement following the first not-yet-placed target.
  void place(SfcStep step) {
    if (placed.contains(step.id)) {
      return;
    }
    placed.add(step.id);
    placedOrder.add(step);
    for (final t in outOf(step.id)) {
      final target = byId(t.toStepId);
      if (target != null && !placed.contains(target.id)) {
        place(target); // first not-yet-placed target continues the main line
      }
    }
  }

  // Root: the initial step (fallback: first step), mirroring the engine.
  SfcStep? root;
  for (final s in steps) {
    if (s.isInitial) {
      root = s;
      break;
    }
  }
  root ??= steps.isNotEmpty ? steps.first : null;
  if (root != null) {
    place(root);
  }
  // Any steps never reached (unreachable) come last, in list order.
  for (final s in steps) {
    if (!placed.contains(s.id)) {
      placedOrder.add(s);
      placed.add(s.id);
    }
  }

  // Build rows; mark the FIRST outgoing whose target is the card immediately
  // below this step as inline, everything else as GOTO.
  final rowIndexOf = <String, int>{
    for (var i = 0; i < placedOrder.length; i++) placedOrder[i].id: i,
  };
  final rows = <SfcLayoutRow>[];
  for (var i = 0; i < placedOrder.length; i++) {
    final step = placedOrder[i];
    final outs = outOf(step.id);
    var inlineTaken = false;
    final outgoing = <SfcOutgoing>[];
    for (final t in outs) {
      final target = byId(t.toStepId);
      // Inline iff this target is the very next placed card and no earlier
      // outgoing already claimed the inline slot.
      final isNextCard =
          target != null && rowIndexOf[target.id] == i + 1;
      final inline = !inlineTaken && isNextCard;
      if (inline) {
        inlineTaken = true;
      }
      outgoing.add(SfcOutgoing(transition: t, target: target, inline: inline));
    }
    rows.add(SfcLayoutRow(step: step, outgoing: outgoing));
  }
  return rows;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/sfc_layout_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/sfc_layout.dart mobile/test/sfc_layout_test.dart
git commit -m "feat(sfc): pure flow-order layout helper (inline-vs-GOTO decision)"
```

---

### Task 2: Pure graph-edit helpers (ids, add/delete branch, delete step, reorder)

**Files:**
- Create: `mobile/lib/models/sfc_edit.dart`
- Test: `mobile/test/sfc_edit_test.dart`

**Interfaces:**
- Produces (all mutate the passed `PlcProgram` in place):
  - `String newSfcStepId(PlcProgram p)` / `String newSfcTransitionId(PlcProgram p)`
  - `SfcStep addSfcStep(PlcProgram p, {String? name})`
  - `SfcTransition addSfcBranch(PlcProgram p, String fromStepId)`
  - `void deleteSfcTransition(PlcProgram p, String transitionId)`
  - `void deleteSfcStep(PlcProgram p, String stepId)`
  - `void reorderSfcBranch(PlcProgram p, String transitionId, int delta)`

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sfc_edit_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_edit.dart';

PlcProgram _prog() {
  final p = PlcProgram(name: 'P', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'A', isInitial: true),
    SfcStep(id: 's1', name: 'B'),
    SfcStep(id: 's2', name: 'C'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'X'),
    SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Y'),
    SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's0', conditionSt: 'Z'),
  ]);
  return p;
}

void main() {
  test('id generators avoid collisions', () {
    final p = _prog();
    expect(p.sfcSteps.any((s) => s.id == newSfcStepId(p)), isFalse);
    expect(p.sfcTransitions.any((t) => t.id == newSfcTransitionId(p)), isFalse);
  });

  test('addSfcBranch appends an outgoing transition from the step', () {
    final p = _prog();
    final t = addSfcBranch(p, 's1');
    expect(t.fromStepId, 's1');
    expect(p.sfcTransitions.last.id, t.id);
  });

  test('deleteSfcStep removes the step and every transition touching it', () {
    final p = _prog();
    deleteSfcStep(p, 's0'); // s0 is from of t0,t1 and to of t2
    expect(p.sfcSteps.any((s) => s.id == 's0'), isFalse);
    expect(p.sfcTransitions.map((t) => t.id).toSet(), <String>{}); // all referenced s0
    // s0 was initial; a remaining step is promoted.
    expect(p.sfcSteps.where((s) => s.isInitial).length, 1);
  });

  test('reorderSfcBranch swaps priority within the same from-step group', () {
    final p = _prog();
    // s0 has t0 (index0) then t1 (index1). Move t1 up → t1 before t0.
    reorderSfcBranch(p, 't1', -1);
    final s0Trans = p.sfcTransitions.where((t) => t.fromStepId == 's0').map((t) => t.id).toList();
    expect(s0Trans, ['t1', 't0']);
    // t2 (different from-step) is undisturbed relative to the group.
  });

  test('reorder is a no-op at the group boundary', () {
    final p = _prog();
    reorderSfcBranch(p, 't0', -1); // already first in its group
    expect(p.sfcTransitions.where((t) => t.fromStepId == 's0').map((t) => t.id).toList(), ['t0', 't1']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/sfc_edit_test.dart`
Expected: FAIL — `sfc_edit.dart` undefined.

- [ ] **Step 3: Implement the helpers**

Create `mobile/lib/models/sfc_edit.dart`:

```dart
import 'project_model.dart';

int _maxSuffix(Iterable<String> ids, String prefix) {
  int m = -1;
  for (final id in ids) {
    if (id.startsWith(prefix)) {
      final n = int.tryParse(id.substring(prefix.length));
      if (n != null && n > m) {
        m = n;
      }
    }
  }
  return m;
}

/// A step id not present in [p] (monotonic 's<n>').
String newSfcStepId(PlcProgram p) => 's${_maxSuffix(p.sfcSteps.map((s) => s.id), 's') + 1}';

/// A transition id not present in [p] (monotonic 't<n>').
String newSfcTransitionId(PlcProgram p) =>
    't${_maxSuffix(p.sfcTransitions.map((t) => t.id), 't') + 1}';

/// Adds a new step (default name 'Step_<n>') and returns it.
SfcStep addSfcStep(PlcProgram p, {String? name}) {
  final id = newSfcStepId(p);
  final step = SfcStep(
    id: id,
    name: name ?? 'Step_${p.sfcSteps.length}',
    isInitial: p.sfcSteps.isEmpty, // first-ever step is initial
    actionSt: '',
  );
  p.sfcSteps.add(step);
  return step;
}

/// Appends a new outgoing transition from [fromStepId]. Default target is the
/// step's own id (a self-hold the user then retargets) and condition 'TRUE'.
SfcTransition addSfcBranch(PlcProgram p, String fromStepId) {
  final t = SfcTransition(
    id: newSfcTransitionId(p),
    fromStepId: fromStepId,
    toStepId: fromStepId,
    conditionSt: 'TRUE',
  );
  p.sfcTransitions.add(t);
  return t;
}

/// Removes a transition by id.
void deleteSfcTransition(PlcProgram p, String transitionId) {
  p.sfcTransitions.removeWhere((t) => t.id == transitionId);
}

/// Removes a step and every transition referencing it (either direction).
/// If the removed step was the initial step, promotes the first remaining
/// step to initial so the engine always has a start.
void deleteSfcStep(PlcProgram p, String stepId) {
  final wasInitial = p.sfcSteps.any((s) => s.id == stepId && s.isInitial);
  p.sfcSteps.removeWhere((s) => s.id == stepId);
  p.sfcTransitions.removeWhere((t) => t.fromStepId == stepId || t.toStepId == stepId);
  if (wasInitial && p.sfcSteps.isNotEmpty && !p.sfcSteps.any((s) => s.isInitial)) {
    p.sfcSteps.first.isInitial = true;
  }
}

/// Moves a transition earlier (delta<0) or later (delta>0) among the
/// transitions that share its `fromStepId` — i.e. changes if/else-if priority.
/// Reorders within the global `sfcTransitions` list so the engine (which reads
/// list order) sees the new priority. No-op at a group boundary.
void reorderSfcBranch(PlcProgram p, String transitionId, int delta) {
  final list = p.sfcTransitions;
  final idx = list.indexWhere((t) => t.id == transitionId);
  if (idx < 0 || delta == 0) {
    return;
  }
  final from = list[idx].fromStepId;
  // Indices (in the global list) of the same-from group, in order.
  final group = <int>[];
  for (var i = 0; i < list.length; i++) {
    if (list[i].fromStepId == from) {
      group.add(i);
    }
  }
  final pos = group.indexOf(idx);
  final newPos = pos + delta;
  if (newPos < 0 || newPos >= group.length) {
    return; // boundary
  }
  // Swap the two group members by swapping their global-list slots.
  final a = group[pos];
  final b = group[newPos];
  final tmp = list[a];
  list[a] = list[b];
  list[b] = tmp;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/sfc_edit_test.dart`
Expected: PASS (5 tests). If `PlcProgram`'s constructor differs, read `project_model.dart` for its required fields and adjust the test fixture only (not the assertions).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/sfc_edit.dart mobile/test/sfc_edit_test.dart
git commit -m "feat(sfc): pure graph-edit helpers (ids, add/delete branch, delete step, reorder)"
```

---

### Task 3: Editor renders via `layoutSfc` (branch list + GOTO chips)

**Files:**
- Modify: `mobile/lib/screens/sfc_editor_screen.dart` (`_buildCenterWorkspace` and the step/transition builders)
- Test: `mobile/test/sfc_editor_branch_render_test.dart`

**Interfaces:**
- Consumes: `layoutSfc`, `SfcLayoutRow`, `SfcOutgoing` (Task 1).

**Context:** Replace the positional `step[i]/transition[i]` `ListView.builder` with a `layoutSfc(program.sfcSteps, program.sfcTransitions)`-driven list. For each `SfcLayoutRow`: render the existing step card, then its `outgoing` list — each outgoing is a row with the editable condition ST field (unchanged `_buildSfcTransitionGraphic` body is fine for the condition editing) plus a target indicator: an **inline** outgoing draws the existing vertical connector down to the next card; a **non-inline** outgoing draws a `→ GOTO <TargetName>` chip (↺ prefix if the target is already placed above, i.e. a loop). A `null` target chips as `→ (deleted)`. Authoring controls (target dropdown, add/delete/reorder) come in Task 4 — this task only renders + keeps condition editing working.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sfc_editor_branch_render_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

PlcProgram _branchedProg() {
  final p = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'IDLE', isInitial: true),
    SfcStep(id: 's1', name: 'FILLING'),
    SfcStep(id: 's2', name: 'ABORTED'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Bottle_Present'),
    SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Abort_Cmd'),
    SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's0', conditionSt: 'TRUE'),
  ]);
  return p;
}

void main() {
  testWidgets('a branched SFC renders both branches + a GOTO chip, no overflow', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _branchedProg();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(
        currentProject: proj,
        program: prog,
        onProgramUpdated: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Both branch conditions render.
    expect(find.textContaining('Bottle_Present'), findsOneWidget);
    expect(find.textContaining('Abort_Cmd'), findsOneWidget);
    // The s1->s0 loop-back renders as a GOTO chip to IDLE.
    expect(find.textContaining('GOTO'), findsWidgets);
    expect(find.textContaining('IDLE'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/sfc_editor_branch_render_test.dart`
Expected: FAIL — with the current positional renderer, the second branch (`Abort_Cmd`) and the `GOTO` chip do not render (only `transition[i]` pairs show).

- [ ] **Step 3: Rewrite the center workspace to use `layoutSfc`**

In `mobile/lib/screens/sfc_editor_screen.dart`, add imports:

```dart
import '../models/sfc_layout.dart';
```

Replace the body of `_buildCenterWorkspace` (the `ListView.builder` that pairs `step[index]` with `transition[index]`) with a `layoutSfc`-driven build:

```dart
  Widget _buildCenterWorkspace(bool expanded) {
    return Container(
      color: const Color(0xFF0F172A),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = _cardWidth(constraints.maxWidth);
          final rows = layoutSfc(widget.program.sfcSteps, widget.program.sfcTransitions);
          return ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return Column(
                children: [
                  _buildSfcStepCard(row.step, cardWidth),
                  for (final o in row.outgoing) _buildOutgoing(o, cardWidth),
                ],
              );
            },
          );
        },
      ),
    );
  }
```

Change `_buildSfcStepCard(SfcStep step, int index, double width)` to `_buildSfcStepCard(SfcStep step, double width)` — it no longer needs a positional index; its delete button now calls a helper that deletes by id (added in Task 4; for THIS task keep the existing delete behaviour but switch it to remove by id):

```dart
              IconButton(
                icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
                onPressed: () {
                  setState(() {
                    widget.program.sfcSteps.removeWhere((s) => s.id == step.id);
                  });
                  widget.onProgramUpdated();
                },
              ),
```

Add a new `_buildOutgoing` that renders one outgoing transition — the inline case reuses the existing transition graphic (the condition editor + connector); the GOTO case renders the condition editor plus a chip:

```dart
  Widget _buildOutgoing(SfcOutgoing o, double width) {
    // The condition editor is the existing transition graphic body.
    final condition = _buildSfcTransitionGraphic(o.transition, width);
    if (o.inline) {
      return condition; // vertical connector flows into the next card below
    }
    // Non-inline: a GOTO reference chip to the target (or "(deleted)").
    final targetName = o.target?.name ?? '(deleted)';
    final isLoop = o.target != null; // any placed target reached again is a loop/merge
    return Column(
      children: [
        condition,
        Container(
          width: width,
          margin: const EdgeInsets.only(top: 2, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isLoop ? Icons.subdirectory_arrow_left : Icons.link_off,
                  size: 14, color: Colors.amberAccent),
              const SizedBox(width: 6),
              Text('GOTO $targetName',
                  style: const TextStyle(
                      color: Colors.amberAccent, fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
        ),
      ],
    );
  }
```

(If `_buildCenterWorkspace` previously passed `index` into `_buildSfcStepCard`/`_buildSfcTransitionGraphic`, update those call sites to the new signatures. Leave `_buildSfcTransitionGraphic`'s condition `TextField`/`onSubmitted` as-is.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/sfc_editor_branch_render_test.dart`
Expected: PASS. Also run existing SFC tests: `cd mobile && flutter test test/ -name '*sfc*'` (or `flutter test test/sfc_layout_test.dart test/sfc_edit_test.dart`) — Expected: PASS.

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/screens/sfc_editor_screen.dart mobile/test/sfc_editor_branch_render_test.dart
git commit -m "feat(sfc): editor renders the real transition graph (branches + GOTO chips)"
```

---

### Task 4: Branch authoring (target picker, add/delete/reorder, delete-step cleanup)

**Files:**
- Modify: `mobile/lib/screens/sfc_editor_screen.dart`
- Test: `mobile/test/sfc_editor_authoring_test.dart`

**Interfaces:**
- Consumes: `sfc_edit.dart` helpers (Task 2) — `addSfcStep`, `addSfcBranch`, `deleteSfcTransition`, `deleteSfcStep`, `reorderSfcBranch`.

**Context:** Wire the pure edit helpers into the UI. Each outgoing row gains: a **target dropdown** (all step names by id + a "＋ New step…" item that calls `addSfcStep` then targets it), **reorder** up/down (`reorderSfcBranch(..., -1/＋1)`), and **delete branch** (`deleteSfcTransition`). Each step gains a **＋ add branch** button (`addSfcBranch`). The step delete button now calls `deleteSfcStep` (cleans transitions + promotes initial). All mutations `setState` + `onProgramUpdated`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/sfc_editor_authoring_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

PlcProgram _prog() {
  final p = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'IDLE', isInitial: true),
    SfcStep(id: 's1', name: 'RUN'),
  ]);
  p.sfcTransitions.add(
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
  );
  return p;
}

void main() {
  testWidgets('add branch appends an outgoing transition to the step', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _prog();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // s0 starts with 1 outgoing.
    expect(prog.sfcTransitions.where((t) => t.fromStepId == 's0').length, 1);

    // Tap the first "add branch" affordance (tooltip 'Add branch').
    await tester.tap(find.byTooltip('Add branch').first);
    await tester.pumpAndSettle();

    expect(prog.sfcTransitions.where((t) => t.fromStepId == 's0').length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete step removes the step and its transitions', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = _prog();
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(currentProject: proj, program: prog, onProgramUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // Delete RUN (s1): the s0->s1 transition must go too.
    // The RUN card's delete button is the 2nd delete icon.
    final deletes = find.byIcon(Icons.delete);
    await tester.tap(deletes.at(1));
    await tester.pumpAndSettle();

    expect(prog.sfcSteps.any((s) => s.id == 's1'), isFalse);
    expect(prog.sfcTransitions.any((t) => t.toStepId == 's1'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/sfc_editor_authoring_test.dart`
Expected: FAIL — no 'Add branch' affordance; delete-step doesn't remove transitions.

- [ ] **Step 3: Wire the edit helpers into the UI**

In `mobile/lib/screens/sfc_editor_screen.dart` add:

```dart
import '../models/sfc_edit.dart';
```

Change the step card delete to `deleteSfcStep`, and add an "Add branch" button to the step card (in `_buildSfcStepCard`, in the header `Row` after the delete `IconButton`):

```dart
              IconButton(
                icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
                tooltip: 'Delete step',
                onPressed: () {
                  setState(() => deleteSfcStep(widget.program, step.id));
                  widget.onProgramUpdated();
                },
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 16, color: Colors.purpleAccent),
                tooltip: 'Add branch',
                onPressed: () {
                  setState(() => addSfcBranch(widget.program, step.id));
                  widget.onProgramUpdated();
                },
              ),
```

Extend the outgoing/transition row (in `_buildSfcTransitionGraphic`, or in `_buildOutgoing` before the condition editor) with a target dropdown + reorder + delete controls. Add this control strip above the condition field:

```dart
  Widget _branchControls(SfcTransition t, double width) {
    final steps = widget.program.sfcSteps;
    return Row(
      children: [
        const Text('→ ', style: TextStyle(color: Colors.amberAccent, fontFamily: 'monospace')),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            dropdownColor: const Color(0xFF1E293B),
            value: steps.any((s) => s.id == t.toStepId) ? t.toStepId : null,
            hint: const Text('(target)', style: TextStyle(color: Colors.grey, fontSize: 12)),
            items: [
              for (final s in steps)
                DropdownMenuItem(value: s.id, child: Text(s.name, style: const TextStyle(fontSize: 12))),
              const DropdownMenuItem(value: '__new__', child: Text('＋ New step…', style: TextStyle(fontSize: 12, color: Colors.cyanAccent))),
            ],
            onChanged: (v) {
              if (v == null) {
                return;
              }
              setState(() {
                if (v == '__new__') {
                  final s = addSfcStep(widget.program);
                  t.toStepId = s.id;
                } else {
                  t.toStepId = v;
                }
              });
              widget.onProgramUpdated();
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.cyanAccent),
          tooltip: 'Higher priority',
          onPressed: () {
            setState(() => reorderSfcBranch(widget.program, t.id, -1));
            widget.onProgramUpdated();
          },
        ),
        IconButton(
          icon: const Icon(Icons.arrow_downward, size: 16, color: Colors.cyanAccent),
          tooltip: 'Lower priority',
          onPressed: () {
            setState(() => reorderSfcBranch(widget.program, t.id, 1));
            widget.onProgramUpdated();
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
          tooltip: 'Delete branch',
          onPressed: () {
            setState(() => deleteSfcTransition(widget.program, t.id));
            widget.onProgramUpdated();
          },
        ),
      ],
    );
  }
```

Insert `_branchControls(o.transition, width)` at the top of the widget `_buildOutgoing` builds (both inline and GOTO cases show the same control strip above the condition), e.g. wrap:

```dart
  Widget _buildOutgoing(SfcOutgoing o, double width) {
    final controls = _branchControls(o.transition, width);
    final condition = _buildSfcTransitionGraphic(o.transition, width);
    final body = o.inline
        ? condition
        : Column(children: [
            condition,
            // ... the GOTO chip Container from Task 3 ...
          ]);
    return Column(children: [SizedBox(width: width, child: controls), body]);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/sfc_editor_authoring_test.dart`
Expected: PASS. Also `cd mobile && flutter test test/sfc_editor_branch_render_test.dart` — Expected: still PASS.

- [ ] **Step 5: Overflow guard + analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/screens/sfc_editor_screen.dart mobile/test/sfc_editor_authoring_test.dart
git commit -m "feat(sfc): branch authoring — target picker, add/delete/reorder, delete-step cleanup"
```

---

### Task 5: Engine priority guard + round-trip guard

**Files:**
- Create/Modify: `mobile/test/sfc_exec_test.dart` (add tests; no engine code change)
- Create: `mobile/test/sfc_branch_roundtrip_test.dart`

**Interfaces:**
- Consumes: `executeSfcPrograms` (`sfc_exec.dart`), `SfcRuntime`, `PlcProject.toJson/fromJson`.

- [ ] **Step 1: Write the failing/guard tests**

Add to `mobile/test/sfc_exec_test.dart` (create the file with this content if it does not exist; if it exists, append the two tests inside `main`):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';

PlcProject _proj(PlcProgram prog, List<PlcTag> tags) => PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

void main() {
  test('first-true outgoing transition wins by priority', () {
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'HOME', isInitial: true),
      SfcStep(id: 'sx', name: 'X'),
      SfcStep(id: 'sy', name: 'Y'),
      SfcStep(id: 'sz', name: 'Z'),
    ]);
    // Priority: A -> X, else B -> Y, else TRUE -> Z.
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 'sx', conditionSt: 'A'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 'sy', conditionSt: 'B'),
      SfcTransition(id: 't2', fromStepId: 's0', toStepId: 'sz', conditionSt: 'TRUE'),
    ]);
    final tags = [
      PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true, ioType: 'Internal'),
    ];
    final proj = _proj(prog, tags);
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt); // A false, B true -> should go to sy
    expect(rt.activeStepId['M'], 'sy');
  });

  test('A wins over B when both true (priority order)', () {
    final prog = PlcProgram(name: 'M', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'HOME', isInitial: true),
      SfcStep(id: 'sx', name: 'X'),
      SfcStep(id: 'sy', name: 'Y'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 'sx', conditionSt: 'A'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 'sy', conditionSt: 'B'),
    ]);
    final tags = [
      PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'),
      PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true, ioType: 'Internal'),
    ];
    final proj = _proj(prog, tags);
    final rt = SfcRuntime();
    executeSfcPrograms(proj, 100, rt);
    expect(rt.activeStepId['M'], 'sx'); // A (higher priority) wins
  });
}
```

Create `mobile/test/sfc_branch_roundtrip_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('a branched SFC round-trips with transition order (priority) preserved', () {
    final prog = PlcProgram(name: 'BR', language: 'SequentialFunctionChart', rungs: []);
    prog.sfcSteps.addAll([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true),
      SfcStep(id: 's1', name: 'FILL'),
      SfcStep(id: 's2', name: 'ABORT'),
    ]);
    prog.sfcTransitions.addAll([
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Bottle'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'Abort'),
      SfcTransition(id: 't2', fromStepId: 's1', toStepId: 's0', conditionSt: 'TRUE'),
    ]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );
    final round = PlcProject.fromJson(proj.toJson());
    final rp = round.programs.single;
    expect(rp.sfcTransitions.map((t) => '${t.fromStepId}->${t.toStepId}:${t.conditionSt}').toList(),
        ['s0->s1:Bottle', 's0->s2:Abort', 's1->s0:TRUE']);
    // Stable re-serialize.
    expect(round.toJson().toString(), proj.toJson().toString());
  });
}
```

- [ ] **Step 2: Run tests**

Run: `cd mobile && flutter test test/sfc_exec_test.dart test/sfc_branch_roundtrip_test.dart`
Expected: PASS. (The engine already routes by priority; these lock it. If `PlcTag`/`PlcProgram` constructor fields differ, read `project_model.dart` and fix the fixtures, not the assertions.)

- [ ] **Step 3: Commit**

```bash
git add mobile/test/sfc_exec_test.dart mobile/test/sfc_branch_roundtrip_test.dart
git commit -m "test(sfc): priority-routing engine guard + branched-chart round-trip"
```

---

### Task 6: Validation, docs, roadmap/readme

**Files:**
- Create: `docs/sfc-branching.md`
- Modify: `ROADMAP.md`, `README.md`

- [ ] **Step 1: Full green gate**

Run: `cd mobile && flutter analyze`
Expected: No issues.

Run: `cd mobile && flutter test`
Expected: All tests PASS (existing suite + the new SFC tests).

Run: `cd mobile && flutter build web --release`
Expected: Builds.

- [ ] **Step 2: Write `docs/sfc-branching.md`**

Create `docs/sfc-branching.md` documenting: single-token alternative branching; that a step can own multiple ordered outgoing transitions (priority = order = if/else-if); how the engine picks first-true; the editor's per-step branch list (target dropdown incl. New step…, reorder = priority, add/delete branch), flow-order layout, and GOTO chips (↺ for loops, "(deleted)" for dangling targets); delete-step cleanup + initial promotion; and that nothing new is persisted (the graph already round-tripped). Note the explicit non-goal: no parallel/AND branching.

- [ ] **Step 3: Update ROADMAP.md + README.md**

In `ROADMAP.md` add a Phase 3 post-ship note (match the existing "post-ship ✅" note style) describing SFC alternative branching. In `README.md`, update the SFC bullet (currently "State Machine Chart Editor with Initial Steps, Steps, Transitions, ST Actions, and Condition Autocomplete Palette") to mention **alternative branching (if/else-if via ordered targeted transitions)**. Keep the hard rule: no "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding, no reverse-engineering wording.

- [ ] **Step 4: Commit**

```bash
git add docs/sfc-branching.md ROADMAP.md README.md
git commit -m "docs(sfc): alternative-branching docs + roadmap/readme"
```

---

## Self-Review

**Spec coverage:**
- Pure layout helper (flow-order + inline-vs-GOTO) → Task 1. ✓
- Per-step ordered outgoing transitions, priority = list order → Tasks 2 (reorder helper) + 4 (UI). ✓
- Explicit editable target incl. "＋ New step…" → Task 4. ✓
- Add / delete branch → Tasks 2 + 4. ✓
- GOTO chips (loop ↺, dangling "(deleted)") → Task 3. ✓
- Flow-order step ordering → Task 1 + consumed in Task 3. ✓
- Delete step removes transitions both directions + promotes initial → Tasks 2 + 4. ✓
- No model/engine change; engine priority guard → Task 5. ✓
- No migration; round-trip guard → Task 5. ✓
- Testing (layout, edits, render, authoring, engine, round-trip, overflow) → Tasks 1–5. ✓
- Docs/roadmap/readme → Task 6. ✓
- Optional showcase branch in `BottleFill_SFC` → intentionally omitted (spec left it a plan-time call; kept out to avoid changing a default project's behaviour without a dedicated scan-equivalence proof). A reviewer wanting it can add it as a follow-up.

**Placeholder scan:** No TBD/TODO. Every code step shows code. The "read `project_model.dart` and fix the fixtures" notes are real instructions to reconcile test constructors, not logic placeholders.

**Type consistency:** `layoutSfc(List<SfcStep>, List<SfcTransition>) → List<SfcLayoutRow>`; `SfcOutgoing {transition, target, inline}`; `SfcLayoutRow {step, outgoing}` consistent across Tasks 1/3. `addSfcStep`, `addSfcBranch`, `deleteSfcTransition`, `deleteSfcStep`, `reorderSfcBranch`, `newSfcStepId`, `newSfcTransitionId` signatures consistent across Tasks 2/4. `_buildSfcStepCard(SfcStep, double)` and `_buildOutgoing(SfcOutgoing, double)` / `_branchControls(SfcTransition, double)` consistent across Tasks 3/4.
