# Ladder Correctness (WS1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ladder rungs visibly connect to the right (L2) power rail with output coils pinned to the rightmost column, hard-enforce the IEC rule that coils are terminal, and remove the redundant ST program from the Basic Motor project.

**Architecture:** Extract horizontal layout math and insert-eligibility rules into a pure Dart module (`ld_layout.dart`) so they're unit-testable without a `BuildContext`. The LD editor sizes each rung canvas to the full available width via `LayoutBuilder`, right-anchors coil nodes against the rail, and shows element-insert "＋" targets only where the coil-terminal invariant permits.

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`, Chrome preview extension.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` must report **zero** issues. Use `withValues(alpha:)` (not `withOpacity`), `initialValue:` (not `value:`) on `DropdownButtonFormField`, braces on all flow-control bodies, prefer `const`, `x.isNotEmpty` not `x.length >= 1`.
- No RenderFlex overflow.
- All shell commands run from `mobile/`.

---

### Task 1: Pure layout + insert-eligibility helpers

**Files:**
- Create: `mobile/lib/models/ld_layout.dart`
- Test: `mobile/test/ld_layout_test.dart`

**Interfaces:**
- Consumes: `LdNode`, `LdKind`, `LdWire`, `LdRung` from `project_model.dart`; `colAssignment`, `buildRung`, `BranchSpec` from `ld_graph.dart`.
- Produces (used by Task 2 & 3):
  - `const double kLdColW`, `kLdCellW`, `kLdCoilRailGap`
  - `double ldColX(int col)`
  - `double ldNodeX(LdNode n, int col, double width)`
  - `double ldMinContentWidth(LdRung rung, Map<String,int> col)`
  - `bool canInsertContactOnWire(LdRung rung, LdWire w)`
  - `bool canInsertCoilOnWire(LdRung rung, LdWire w)`

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/ld_layout_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_layout.dart';

LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

void main() {
  test('ldNodeX left-anchors non-coils and right-anchors coils', () {
    final c = LdNode(id: 'x', kind: LdKind.contact, variable: 'A');
    final k = LdNode(id: 'y', kind: LdKind.coil, variable: 'Y');
    expect(ldNodeX(c, 2, 1000), equals(ldColX(2)));
    expect(ldNodeX(k, 4, 1000), equals(1000 - kLdCellW - kLdCoilRailGap));
    // a coil sits to the right of a left-anchored contact on a wide canvas
    expect(ldNodeX(k, 4, 1000) > ldNodeX(c, 2, 1000), isTrue);
  });

  test('ldMinContentWidth leaves room for inputs plus the pinned coil', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Y')]);
    final col = colAssignment(r);
    final w = ldMinContentWidth(r, col);
    // at the minimum width, the coil is still right of the last input element
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final k = r.nodes.firstWhere((n) => n.variable == 'Y');
    final bRight = ldColX(col[b.id]!) + kLdCellW;
    expect(ldNodeX(k, col[k.id]!, w) >= bRight, isTrue);
  });

  test('canInsertContactOnWire forbids inserting after a coil', () {
    final r = buildRung(index: 0, main: [contact('A'), coil('Y')]);
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final y = r.nodes.firstWhere((n) => n.variable == 'Y');
    final left = r.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    final beforeCoil = r.wires.firstWhere((w) => w.toId == y.id);   // A -> Y
    final afterCoil = r.wires.firstWhere((w) => w.fromId == y.id);  // Y -> rightRail
    final firstWire = r.wires.firstWhere((w) => w.fromId == left.id); // L -> A
    expect(canInsertContactOnWire(r, firstWire), isTrue);
    expect(canInsertContactOnWire(r, beforeCoil), isTrue);   // before the coil is fine
    expect(canInsertContactOnWire(r, afterCoil), isFalse);   // after the coil is not
    expect(a, isNotNull);
  });

  test('canInsertCoilOnWire allows only terminal, non-post-coil segments', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B')]); // no coil yet
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final terminal = r.wires.firstWhere((w) => w.fromId == b.id); // B -> rightRail
    final a = r.nodes.firstWhere((n) => n.variable == 'A');
    final midWire = r.wires.firstWhere((w) => w.fromId == a.id && w.toId == b.id);
    expect(canInsertCoilOnWire(r, terminal), isTrue);
    expect(canInsertCoilOnWire(r, midWire), isFalse); // not a terminal segment
  });
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `flutter test test/ld_layout_test.dart`
Expected: FAIL — `ld_layout.dart` does not exist.

- [ ] **Step 3: Implement `ld_layout.dart`**

Create `mobile/lib/models/ld_layout.dart`:

```dart
import 'project_model.dart';

/// Horizontal column pitch (cell + wire).
const double kLdColW = 116.0;

/// Element cell width.
const double kLdCellW = 66.0;

/// Gap between a right-pinned coil's right edge and the right rail.
const double kLdCoilRailGap = 40.0;

/// Left-anchored x for a grid column.
double ldColX(int col) => col * kLdColW;

/// Left-x of a node. Coils right-anchor against the rail; everything else
/// left-anchors from L1 at its assigned column.
double ldNodeX(LdNode n, int col, double width) {
  if (n.kind == LdKind.coil) {
    return width - kLdCellW - kLdCoilRailGap;
  }
  return ldColX(col);
}

/// Minimum canvas width so left-anchored input elements never overlap the
/// right-pinned coil zone.
double ldMinContentWidth(LdRung rung, Map<String, int> col) {
  double maxInputRight = kLdColW;
  for (final n in rung.nodes) {
    if (n.kind == LdKind.coil ||
        n.kind == LdKind.leftRail ||
        n.kind == LdKind.rightRail) {
      continue;
    }
    final right = ldColX(col[n.id] ?? 0) + kLdCellW;
    if (right > maxInputRight) {
      maxInputRight = right;
    }
  }
  return maxInputRight + kLdCoilRailGap + kLdCellW + 16.0;
}

LdNode _nodeById(LdRung rung, String id) =>
    rung.nodes.firstWhere((n) => n.id == id);

/// A contact/block may be inserted on a wire only if it would not follow a
/// coil (coils are terminal).
bool canInsertContactOnWire(LdRung rung, LdWire w) =>
    _nodeById(rung, w.fromId).kind != LdKind.coil;

/// A coil may be inserted only on a terminal segment (into the right rail)
/// whose path does not already end in a coil — keeping coils terminal and
/// rightmost.
bool canInsertCoilOnWire(LdRung rung, LdWire w) =>
    _nodeById(rung, w.toId).kind == LdKind.rightRail &&
    _nodeById(rung, w.fromId).kind != LdKind.coil;
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `flutter test test/ld_layout_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/ld_layout.dart mobile/test/ld_layout_test.dart
git commit -m "feat(ld): add pure layout + coil-terminal insert-eligibility helpers"
```

---

### Task 2: Full-width rungs with right-pinned coils

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart`

**Interfaces:**
- Consumes: `kLdColW`, `kLdCellW`, `kLdCoilRailGap`, `ldColX`, `ldNodeX`, `ldMinContentWidth` from Task 1.
- Produces: rung canvas fills available width; coils render right-pinned; the right-rail node's in-port is at `x == width`.

- [ ] **Step 1: Import the layout module and drop duplicated constants**

At the top of `mobile/lib/screens/ld_editor_screen.dart`, add:

```dart
import '../models/ld_layout.dart';
```

Then delete the two now-shared constants from the top-of-file block (lines ~5-6):

```dart
const double _kColW = 116.0; // column pitch (cell + wire)
const double _kCellW = 66.0; // element cell width
```

Keep `_kContactH`, `_kBlockH`, `_kLaneGap`, `_kRailW`, `_kRungGap`. Throughout the file, replace every `_kColW` with `kLdColW` and every `_kCellW` with `kLdCellW` (there are uses in `_colX`, `_positionedNode`, `_buildContactCoil`/`_buildBlock` sizing via `_kCellW`, `_outPort`, `_inPort`, and `_LadderPainter`). Then replace the private `_colX` helper body to delegate:

```dart
  double _colX(int col) => ldColX(col);
```

(Leaving `_colX` as a thin delegate avoids editing every call site; or replace call sites with `ldColX` directly — either is fine as long as `flutter analyze` is clean and `_kColW`/`_kCellW` no longer exist.)

- [ ] **Step 2: Make the rung canvas full-width and node-aware**

Replace the `_buildRungCanvas` body (currently computes `width = _rungWidth(rung, col)` and a fixed-width `SizedBox`) so the canvas fills the available width. Replace the method (from `Widget _buildRungCanvas(...)` through its closing brace) with:

```dart
  Widget _buildRungCanvas(LdRung rung, int index) {
    final col = colAssignment(rung);
    final height = _rungHeight(rung);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111C30),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Text('RUNG $index   ${rung.comment}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final minW = ldMinContentWidth(rung, col);
              final width = constraints.maxWidth > minW ? constraints.maxWidth : minW;
              return SizedBox(
                height: height,
                width: width,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _LadderPainter(this, rung, col, width)),
                    ),
                    ...rung.nodes
                        .where((n) => n.kind == LdKind.contact ||
                            n.kind == LdKind.coil ||
                            n.kind == LdKind.block)
                        .map((n) => _positionedNode(rung, n, col, width)),
                    if (_editMode == 'contact' || _editMode == 'block')
                      ...rung.wires
                          .where((w) => canInsertContactOnWire(rung, w))
                          .map((w) => _wireInsertTarget(rung, w, col, width)),
                    if (_editMode == 'coil')
                      ...rung.wires
                          .where((w) => canInsertCoilOnWire(rung, w))
                          .map((w) => _wireInsertTarget(rung, w, col, width)),
                    ...findBranches(rung).expand((br) => _branchHandles(rung, br, col, width)),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
```

Then delete the now-unused `_rungWidth` method.

- [ ] **Step 3: Right-anchor coils in `_positionedNode` and the ports**

Change `_positionedNode` to take `width` and use `ldNodeX`:

```dart
  Widget _positionedNode(LdRung rung, LdNode n, Map<String, int> col, double width) {
    final h = _nodeH(n);
    final top = _nodeCenterY(rung, n) - h / 2;
    return Positioned(
      left: ldNodeX(n, col[n.id] ?? 0, width),
      top: top,
      width: kLdCellW,
      height: h,
      child: GestureDetector(
        onTap: () => _onNodeTap(rung, n),
        onDoubleTap: () => _showEditNodeDialog(rung, n),
        child: n.kind == LdKind.block ? _buildBlock(n) : _buildContactCoil(n),
      ),
    );
  }
```

Update `_outPort` and `_inPort` to use `ldNodeX` for non-rail nodes:

```dart
  Offset _outPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.leftRail) {
      return Offset(0, _nodeCenterY(rung, n));
    }
    return Offset(ldNodeX(n, col[n.id] ?? 0, width) + kLdCellW, _nodeCenterY(rung, n));
  }

  Offset _inPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.rightRail) {
      return Offset(width, _nodeCenterY(rung, n));
    }
    return Offset(ldNodeX(n, col[n.id] ?? 0, width), _nodeCenterY(rung, n));
  }
```

- [ ] **Step 4: Make branch-drag snapping node-aware**

In `_nearestMainNode`, replace the `_colX(...)` used to measure a candidate node's position with its actual x so coils (right-anchored) snap correctly. Find the line computing the candidate x (currently `final nx = _colX(c);`) and change it to:

```dart
      final nx = ldNodeX(n, c, /* width */ 0) == ldColX(c)
          ? ldColX(c)
          : ldColX(c);
```

That is a no-op for left-anchored nodes; since branch endpoints only ever snap to lane-0 **contacts/rails** (never coils) in practice, keep it simple and leave `final nx = ldColX(c);` — just ensure it references `ldColX` (not the deleted `_kColW` path). If `_nearestMainNode` already calls `_colX`, and `_colX` now delegates to `ldColX`, no change is needed here beyond Step 1's delegation. Verify it compiles.

- [ ] **Step 5: Analyze, build, and visually verify**

Run: `flutter analyze`  → Expected: **No issues found!**
Run: `flutter build web --release`  → Expected: succeeds.

Controller performs Chrome verification (do not attempt preview here): each rung should run L1 → contacts → coil pinned against the blue L2 rail, with a continuous green fill wire between the last contact and the coil; no gap; TON rung still overflow-free.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart
git commit -m "feat(ld): full-width rungs with coils pinned against the right rail"
```

---

### Task 3: Enforce the coil-terminal invariant on insertion

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart`

**Interfaces:**
- Consumes: `canInsertContactOnWire`, `canInsertCoilOnWire` (already wired into `_buildRungCanvas` in Task 2 Step 2).
- Produces: coil insertion is terminal; no element can be inserted after a coil.

Task 2 already filters the "＋" insert targets by eligibility. This task verifies the insertion itself produces a terminal coil and adds a regression test.

- [ ] **Step 1: Confirm `_insertOnWire` yields a terminal coil**

Read `_insertOnWire`. It calls `insertContactOnWire(rung, w, node)` which splits `w` (`F → node → T`). Because coil "＋" targets now only appear on wires where `T` is the right rail (`canInsertCoilOnWire`), inserting a coil produces `F → coil → rightRail` — terminal. No code change needed if this holds; if `_insertOnWire` special-cases coils differently, adjust it to simply split the eligible wire like the other kinds:

```dart
  void _insertOnWire(LdRung rung, LdWire w) {
    final LdNode node;
    if (_editMode == 'coil') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.coil, variable: 'Output_Coil');
    } else if (_editMode == 'block') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.block, blockType: 'TON', variable: 'Timer', presetMs: 5000);
    } else {
      node = LdNode(id: newNodeId(rung), kind: LdKind.contact, variable: 'New_Contact');
    }
    setState(() {
      insertContactOnWire(rung, w, node);
      _editMode = 'select';
    });
    widget.onProgramUpdated();
    _showEditNodeDialog(rung, node);
  }
```

- [ ] **Step 2: Add a regression test for the terminal-coil invariant**

Append to `mobile/test/ld_layout_test.dart` (inside `main()`):

```dart
  test('inserting a coil on the terminal wire keeps it terminal', () {
    final r = buildRung(index: 0, main: [contact('A'), contact('B')]);
    final b = r.nodes.firstWhere((n) => n.variable == 'B');
    final right = r.nodes.firstWhere((n) => n.kind == LdKind.rightRail);
    final terminal = r.wires.firstWhere((w) => w.fromId == b.id && w.toId == right.id);
    expect(canInsertCoilOnWire(r, terminal), isTrue);
    final coilNode = LdNode(id: newNodeId(r), kind: LdKind.coil, variable: 'Y');
    insertContactOnWire(r, terminal, coilNode);
    // coil's only outgoing wire is to the right rail; nothing follows it
    final coilOut = r.wires.where((w) => w.fromId == coilNode.id).toList();
    expect(coilOut.length, equals(1));
    expect(coilOut.first.toId, equals(right.id));
    // and no wire now originates from the coil to a non-rail node
    expect(canInsertContactOnWire(r, coilOut.first), isFalse);
  });
```

- [ ] **Step 3: Run tests + analyze**

Run: `flutter test test/ld_layout_test.dart`  → Expected: PASS (5 tests).
Run: `flutter analyze`  → Expected: **No issues found!**

- [ ] **Step 4: Commit**

```bash
git add mobile/lib/screens/ld_editor_screen.dart mobile/test/ld_layout_test.dart
git commit -m "test(ld): verify coil insertion stays terminal; enforce via eligible targets"
```

---

### Task 4: Remove the redundant ST program from Basic Motor

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (`_motorProject`)

**Interfaces:**
- Consumes: nothing new.
- Produces: Basic Motor ships only `MotorControl_LD`.

- [ ] **Step 1: Remove the ST program and its task reference**

In `mobile/lib/data/default_projects.dart`, inside `_motorProject`:
- Delete the `PlcProgram(name: 'MotorControl_ST', ...)` entry from the `programs:` list.
- In the project's continuous `PlcTask`, remove `'MotorControl_ST'` from `programNames` so it reads `programNames: ['MotorControl_LD']`.

Leave `MotorControl_LD` and all tags/HMI untouched.

- [ ] **Step 2: Analyze and smoke-test**

Run: `flutter analyze`  → Expected: **No issues found!**
Run: `flutter test`  → Expected: all tests pass (the app smoke test still pumps the app; Basic Motor now has one program).

- [ ] **Step 3: Commit**

```bash
git add mobile/lib/data/default_projects.dart
git commit -m "chore(motor): keep LD only, drop redundant MotorControl_ST program"
```

---

### Task 5: Final validation

**Files:** none (verification; small fixes only if a regression surfaces).

- [ ] **Step 1: Full suite + analyze + build**

Run: `flutter test`  → Expected: all pass (ld_layout, ld_graph, widget tests).
Run: `flutter analyze`  → Expected: **No issues found!**
Run: `flutter build web --release`  → Expected: succeeds.

- [ ] **Step 2: Chrome walkthrough (controller)**

Open the LD editor for "LD — Conveyor Belt Control" and "Basic Motor Start Stop" and confirm:
1. Every rung runs unbroken L1 → contacts → coil, with the coil pinned against the blue L2 rail (no gap, wires continuous green).
2. In Contact/Block mode, no "＋" appears after a coil; in Coil mode, "＋" appears only on the terminal segment.
3. TON rung shows no overflow.
4. Basic Motor lists a single program (`MotorControl_LD`).

- [ ] **Step 3: Branding/theme check**

Run: `grep -riE "external brand names" mobile/lib/models/ld_layout.dart mobile/lib/screens/ld_editor_screen.dart mobile/lib/data/default_projects.dart`
Expected: no matches.

- [ ] **Step 4: Commit (only if fixes were made)**

```bash
git add -A
git commit -m "test(ld): validate ladder-correctness across projects"
```

---

## Self-review notes

- **Spec coverage:** full-width rungs + coil right-pinning (Task 2) ✓; rung reaches L2 (`_inPort` rightRail at `x==width`, Task 2 Step 3) ✓; coil-terminal hard-enforcement (Task 1 eligibility + Task 2 filters + Task 3 verification) ✓; remove `MotorControl_ST` (Task 4) ✓; wire rendering continuous green (Task 2, verified Task 5) ✓; testable position helpers without `BuildContext` (Task 1 `ld_layout.dart`) ✓.
- **Type consistency:** `ldNodeX`, `ldColX`, `ldMinContentWidth`, `canInsertContactOnWire`, `canInsertCoilOnWire`, and the `kLd*` constants are named identically across Tasks 1-3.
- **Known limitation (from spec):** rungs wider than the viewport compress rather than scroll; horizontal scrolling is deferred.
