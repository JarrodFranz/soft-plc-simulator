# Ladder Editor Guided Blank Branches Implementation Plan (WS22)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blind two-element branch tap with a guided junction-anchor flow that creates an EMPTY parallel branch (open / no logical effect until filled), including branches that merge at the right rail, then let the user fill it with any element.

**Architecture:** A new `LdKind.link` node models an empty branch slot; the executor treats it as open (contributes no power). Pure graph helpers (`addEmptyBranch`/`fillLink`/`emptyBranch`/`collapseLink`) build/convert/remove branches. The editor's Branch mode overlays junction dots (one per lane-0 wire) and drives a two-step start→end pick; a `link` renders as a ghosted ＋ slot that element tools REPLACE in place.

**Tech Stack:** Dart, Flutter, `flutter_test`. No new dependencies.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); IEC terms fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400 px; dark theme; braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Pure logic files (`ld_graph.dart`, `ld_layout.dart`, `ld_exec.dart`, `project_model.dart`) stay free of Flutter imports.
- LD writes remain force-aware — a `link` writes nothing; no engine write path changes.
- Additive persistence: only the new `LdKind.link` enum value; existing projects have no `link` nodes and round-trip byte-identically (WS6 guard stays green).
- Foreground flutter with bounded timeouts; discard plugin-registrant churn before commits (`git checkout -- mobile/linux/flutter mobile/macos/Flutter mobile/windows/flutter`).

## Current-state facts (verified this session — build on these)

- `enum LdKind { leftRail, rightRail, contact, coil, block }` (`project_model.dart:129`). `LdNode.fromJson` maps `kind` by name with `orElse: () => LdKind.contact`; `toJson` emits `kind.name`.
- `buildRung` (`ld_graph.dart:57`) wires the main line in series: `L → m0 → m1 → … → m(N-1) → R`, all lane 0. A branch on lane `k` is `source → …nodes… → dest` where source is the node LEFT of the span and dest the node RIGHT of it.
- `colAssignment(rung)` (`ld_graph.dart:103`) = longest-path column per node id; right rail forced to max column. `findBranches(rung)` (`ld_graph.dart:142`) = every lane > 0, first/last node by column. `maxLane` (`:38`), `newNodeId` (`:25`, monotonic), `kLeftRailId`='L', `kRightRailId`='R'.
- `addParallelBranch(rung, spanStart, spanEnd)` (`ld_graph.dart:171`) is the existing element-based branch creator (seeds a `New_Contact`). It is NOT removed — the new `addEmptyBranch` is the guided path; `addParallelBranch` may remain for any internal caller (grep shows only the branch-tap flow calls it; that call is replaced in Task 2).
- Executor (`ld_exec.dart:49` `executeRung`): switch on `n.kind` with cases `leftRail`(:88), `rightRail`(:91), `contact`(:94), `coil`(:116), `block`(:146). `inputPower(n)` ORs inbound wire source powers; branch merge is automatic via that OR. `power[n.id]` holds each node's output.
- Editor (`ld_editor_screen.dart`): `_editMode` incl. `'branch'` (line 87 area); `_branchStart` field; Branch mode tap flow in `_onNodeTap` (`:583-603`) currently: tap element → tap element → `addParallelBranch` → reset to select. `branchHint` (`:308`). Positioned nodes are filtered by `.where((n) => n.kind == LdKind.contact || n.kind == LdKind.coil || n.kind == LdKind.block)` (grep `n.kind == LdKind.contact ||` — ~line 530s) then mapped through `_positionedNode`. Branch drag handles: `findBranches(rung).expand((br) => _branchHandles(...))` (~:540). `_wireInsertTarget`/`_insertOnWire` add elements on wires; `_showEditNodeDialog` edits a node; `_showBlockTypePicker` sets `_pendingBlockType`.

**Junction model (the key idea):** A **junction** is a lane-0 wire. Order the lane-0 wires left→right by `col(fromId)`. Picking start junction index `i` and end junction index `j` with **`j > i`** creates a branch `source = wire[i].fromId → link → dest = wire[j].toId`, paralleling the `j - i` main-line elements between them. `j` may index the final wire (…→ right rail) — that is the "branch to the end". `j == i` is invalid (would parallel a bare wire).

**Sequencing:** T1 (model + engine + graph helpers) → T2 (guided anchor UI) → T3 (link rendering + fill/empty interactions + validation + final review).

---

### Task 1: `LdKind.link` + open executor case + branch graph helpers (pure)

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`enum LdKind` + no other model change), `mobile/lib/models/ld_exec.dart` (link case), `mobile/lib/models/ld_graph.dart` (helpers)
- Test: `mobile/test/ld_graph_test.dart`, `mobile/test/ld_exec_test.dart`, `mobile/test/serialization_roundtrip_test.dart`

**Interfaces produced (consumed by T2/T3):**
- `LdNode addEmptyBranch(LdRung rung, String sourceId, String destId)` — new lane `maxLane+1`; adds a `LdKind.link` node; wires `sourceId → link → destId`; returns the link.
- `LdNode fillLink(LdRung rung, LdNode link, LdNode replacement)` — replaces `link` in-place (reuses `link.id` and `row` so existing wires stay valid); returns `replacement`.
- `LdNode emptyBranch(LdRung rung, LdNode element)` — inverse of fill: replaces a real branch node with a fresh `LdKind.link` (same id/row); returns the new link. (Used by delete-to-revert.)
- `void collapseLink(LdRung rung, LdNode link)` — removes a `link` node and its two branch wires (the parallel path disappears; the main line is untouched).

- [ ] **Step 1: Write failing tests.**

```dart
// ld_graph_test.dart
test('addEmptyBranch creates an open link lane wired source->link->dest', () {
  final rung = buildRung(index: 0, main: [contact('A'), contact('B'), coil('Q')]);
  final before = maxLane(rung);
  // parallel element B: source = the node before B (m0='A'... use ids), dest = right of B
  final link = addEmptyBranch(rung, 'm0', 'm2'); // A -> link -> Q-node, parallels 'B' (m1)
  expect(link.kind, LdKind.link);
  expect(link.row, before + 1);
  expect(rung.wires.any((w) => w.fromId == 'm0' && w.toId == link.id), isTrue);
  expect(rung.wires.any((w) => w.fromId == link.id && w.toId == 'm2'), isTrue);
});

test('fillLink swaps kind in place, preserving id/row/wires', () {
  final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
  final link = addEmptyBranch(rung, kLeftRailId, 'm1'); // parallels A
  final wiresBefore = rung.wires.length;
  final filled = fillLink(rung, link, LdNode(id: 'IGNORED', kind: LdKind.contact, variable: 'Seal'));
  expect(filled.id, link.id);           // id preserved so wires stay valid
  expect(filled.row, link.row);
  expect(rung.nodes.any((n) => n.kind == LdKind.link), isFalse);
  expect(rung.nodes.firstWhere((n) => n.id == link.id).variable, 'Seal');
  expect(rung.wires.length, wiresBefore); // no wires added/removed
});

test('emptyBranch reverts a real node to a link (same id/row)', () {
  final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
  final link = addEmptyBranch(rung, kLeftRailId, 'm1');
  final filled = fillLink(rung, link, LdNode(id: 'x', kind: LdKind.contact, variable: 'Seal'));
  final back = emptyBranch(rung, filled);
  expect(back.kind, LdKind.link);
  expect(back.id, filled.id);
  expect(back.row, filled.row);
});

test('collapseLink removes the link and its two branch wires', () {
  final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
  final link = addEmptyBranch(rung, kLeftRailId, 'm1');
  final n0 = rung.nodes.length, w0 = rung.wires.length;
  collapseLink(rung, link);
  expect(rung.nodes.length, n0 - 1);
  expect(rung.wires.length, w0 - 2);
  expect(rung.wires.any((w) => w.fromId == link.id || w.toId == link.id), isFalse);
});
```

```dart
// ld_exec_test.dart — an empty branch is a no-op; filled, it ORs power.
test('empty link branch is a no-op; filling with a closed contact ORs power', () {
  // Rung: L - Enable(contact) - Q(coil). Enable drives Q.
  final p = _projectWithTags(['Enable BOOL', 'Seal BOOL', 'Q BOOL']); // adapt to existing helper
  final rung = buildRung(index: 0, main: [
    LdNode(id: '', kind: LdKind.contact, variable: 'Enable'),
    LdNode(id: '', kind: LdKind.coil, variable: 'Q'),
  ]);
  final rt = LdExecRuntime();
  void scan() => executeRung(p, 'P', rung, 100, rt, (path, v) => writePath(p, path, v));
  // Empty branch paralleling 'Enable' (source L, dest the coil node m1):
  addEmptyBranch(rung, kLeftRailId, 'm1');
  writePath(p, 'Enable', false); scan();
  expect(readPath(p, 'Q'), false); // link is OPEN -> no power, Enable false -> Q false
  // Fill the link with a normally-open 'Seal' contact and close it:
  final link = rung.nodes.firstWhere((n) => n.kind == LdKind.link);
  fillLink(rung, link, LdNode(id: 'x', kind: LdKind.contact, variable: 'Seal'));
  writePath(p, 'Seal', true); scan();
  expect(readPath(p, 'Q'), true); // seal branch ORs power around the open Enable
});
```

```dart
// serialization_roundtrip_test.dart
test('a link (empty branch) round-trips', () {
  final rung = buildRung(index: 0, main: [contact('A'), coil('Q')]);
  addEmptyBranch(rung, kLeftRailId, 'm1');
  final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [rung]);
  final back = PlcProgram.fromJson(prog.toJson());
  final r = back.rungs.single;
  expect(r.nodes.any((n) => n.kind == LdKind.link), isTrue);
  expect(r.wires.length, rung.wires.length);
});
```

- [ ] **Step 2: Run → FAIL** (`LdKind.link` and the helpers don't exist). `cd mobile && flutter test test/ld_graph_test.dart`.
- [ ] **Step 3: Implement.**
  - `project_model.dart`: `enum LdKind { leftRail, rightRail, contact, coil, block, link }`. No other change (fromJson `orElse` already tolerant; toJson emits `.name`).
  - `ld_exec.dart`: add `case LdKind.link: power[n.id] = false; break;` in the `executeRung` switch (open — contributes nothing to any merge OR; writes nothing, force-aware trivially).
  - `ld_graph.dart` helpers:

```dart
/// Adds an EMPTY parallel branch on a new lane: sourceId -> link -> destId.
/// The link is open (LdKind.link); it has no logical effect until filled.
LdNode addEmptyBranch(LdRung rung, String sourceId, String destId) {
  final lane = maxLane(rung) + 1;
  final link = LdNode(id: newNodeId(rung), kind: LdKind.link, row: lane);
  rung.nodes.add(link);
  rung.wires.add(LdWire(fromId: sourceId, toId: link.id));
  rung.wires.add(LdWire(fromId: link.id, toId: destId));
  return link;
}

/// Replaces [link] with [replacement] in place, reusing the link's id and lane
/// so the existing tap/merge wires stay valid. Filling REPLACES (does not
/// insert in series) — an open link left in series would keep the branch dead.
LdNode fillLink(LdRung rung, LdNode link, LdNode replacement) {
  assert(link.kind == LdKind.link);
  replacement.id = link.id;
  replacement.row = link.row;
  final i = rung.nodes.indexWhere((n) => n.id == link.id);
  rung.nodes[i] = replacement;
  return replacement;
}

/// Inverse of [fillLink]: turns a real branch node back into an open link
/// (same id/row), preserving the branch lane and wiring.
LdNode emptyBranch(LdRung rung, LdNode element) {
  final link = LdNode(id: element.id, kind: LdKind.link, row: element.row);
  final i = rung.nodes.indexWhere((n) => n.id == element.id);
  rung.nodes[i] = link;
  return link;
}

/// Removes an empty branch entirely: drops the link node and its two wires.
void collapseLink(LdRung rung, LdNode link) {
  rung.wires.removeWhere((w) => w.fromId == link.id || w.toId == link.id);
  rung.nodes.removeWhere((n) => n.id == link.id);
}
```

- [ ] **Step 4: Tests → PASS**; full `cd mobile && flutter test` green; `flutter analyze` ZERO; WS6 round-trip guard green (defaults have no link).
- [ ] **Step 5: Commit** `feat(ld): LdKind.link empty-branch model + open executor case + branch helpers`.

---

### Task 2: Guided junction-anchor Branch mode (two-step pick)

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (Branch-mode overlay + pick state; replace `_onNodeTap` branch path + `addParallelBranch` call)
- Test: `mobile/test/ld_editor_test.dart`

**Interfaces consumed:** `addEmptyBranch(rung, sourceId, destId)` (T1); `colAssignment`, `kLeftRailId`, `kRightRailId`.

**State + helpers to add:**
- Replace `_branchStart` (an `LdNode?`) with `String? _branchStartWireKey` (identifying the picked start junction). A junction is a lane-0 wire; key it by `'${w.fromId}>${w.toId}'`.
- `List<LdWire> _mainLineWires(LdRung rung)` — `rung.wires.where((w) => _isLaneZero(w, rung))` ordered by `col(fromId)`; a wire is lane-0 when both endpoints are on row 0 (rails count as row 0). Use `colAssignment` for ordering.
- Junction dot positions: for wire `w`, the dot sits at the midpoint between `outPort(fromId)` and `inPort(toId)` on lane 0 (reuse the existing `_outPort`/`_inPort` helpers used by `_wireInsertTarget`).

- [ ] **Step 1: Write failing widget tests.**
  - Entering Branch mode on a rung with N main elements shows exactly `N+1` junction dots (the lane-0 wires).
  - Tapping a start dot then a valid end dot to its right creates a new lane with a `link` node (assert `findBranches(rung).length` increased and the new lane's node `kind == LdKind.link`); the branch source/dest match the picked junctions.
  - Tapping the start dot again clears the selection (no branch created).
  - A right-rail end junction produces a branch whose merge dest is `kRightRailId`.
  - No RenderFlex overflow at 320/1400 while the overlay is shown.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - In `_buildRungCanvas`'s Stack, when `_editMode == 'branch'`, add `..._branchJunctionDots(rung, col, width)` (after the node widgets, before/after the drag handles). Each dot is a `Positioned` `GestureDetector` (reuse the `_wireInsertTarget` visual size ~22px, cyan) at the wire midpoint.
  - Dot state: if `_branchStartWireKey == null` → all dots active (cyan, filled-on-hover N/A; just tappable). If a start is picked → the start dot is highlighted (filled/teal) and only dots with `col(fromId) > col(startWire.fromId)` (strictly right) stay active; others render dimmed (`withValues(alpha: 0.3)`) and non-tappable.
  - Tap handler:
    - start null → set `_branchStartWireKey = key(w)` via `setState`.
    - start set, tapped the SAME dot → `setState(() => _branchStartWireKey = null)` (cancel).
    - start set, tapped a valid RIGHT dot `we` → `setState(() { addEmptyBranch(rung, startWire.fromId, we.toId); _branchStartWireKey = null; _editMode = 'select'; }); widget.onProgramUpdated();`.
    - start set, tapped an invalid (dimmed) dot → ignore.
  - Replace the old `_onNodeTap` branch path (`ld_editor_screen.dart:584-601`): remove the `addParallelBranch` two-element flow (element taps no longer create branches). Keep `_onNodeTap` for select mode.
  - Replace the `branchHint` text with a stateful prompt: `_branchStartWireKey == null ? 'Tap a start point' : 'Tap an end point (tap the start again to cancel)'`.
  - Clear `_branchStartWireKey` whenever `_editMode` changes (the mode-button `onPressed` already resets branch state — update it to reset the new field).
- [ ] **Step 4: Tests → PASS**; full suite green; `flutter analyze` ZERO; no overflow.
- [ ] **Step 5: Commit** `feat(ld): guided junction-anchor branch picking (start/end dots)`.

---

### Task 3: Link rendering + fill/empty interactions + validation + final review

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (`_buildLink` visual; include `link` in the positioned-node filter; fill-on-tap in element modes; delete→revert/collapse)
- Test: `mobile/test/ld_editor_test.dart`, `mobile/test/serialization_roundtrip_test.dart`

**Interfaces consumed:** `fillLink`, `emptyBranch`, `collapseLink` (T1); `_pendingBlockType`, `_showEditNodeDialog`, `deleteNode` (existing).

- [ ] **Step 1: Write failing widget tests.**
  - A `link` node renders a ghosted ＋ slot (find a distinct key/icon), no overflow at 320/1400.
  - In Contact mode, tapping a `link` slot REPLACES it with a contact (assert no `LdKind.link` remains on that lane and a `LdKind.contact` with the same node id exists); the edit dialog opens.
  - In Coil mode, tapping a `link` at a right-rail-merged branch fills it with a coil.
  - In Block mode (pending type e.g. `TON`), tapping a `link` fills it with that block.
  - Deleting the sole element of a branch reverts it to a `link` (branch lane still present); deleting a `link` removes the branch (`findBranches` count drops).
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - Add `LdKind.link` to the positioned-node filter (`.where((n) => … || n.kind == LdKind.link)`) and route it to a new `_buildLink(n)` in `_positionedNode` (alongside block/contact-coil). `_buildLink`: a `SizedBox(width: kLdCellW, height: _kContactH)` with a centered dashed/low-alpha container + a cyan `Icons.add` (the fill affordance), styled as an empty slot (`withValues(alpha:)`).
  - Fill interaction in `_onNodeTap` (or the node's `onTap`): when the tapped node is a `link` AND `_editMode` is an element mode:
    - `contact` → `fillLink(rung, n, LdNode(id: '', kind: LdKind.contact, variable: 'New_Contact'))`
    - `coil` → `fillLink(rung, n, LdNode(id: '', kind: LdKind.coil, variable: 'Output_Coil'))`
    - `block` → `fillLink(rung, n, LdNode(id: '', kind: LdKind.block, blockType: _pendingBlockType, variable: 'T1', presetMs: 5000))` (seed operands for data blocks like `_insertOnWire` does)
    then `setState(() => _editMode = 'select'); widget.onProgramUpdated(); _showEditNodeDialog(rung, filled);`. (`fillLink` reuses the link id; pass `id:''` in the replacement and let `fillLink` overwrite it with the link's id.)
  - Delete integration: in the node delete path (the edit dialog's Delete button / `deleteNode`), when the node being deleted is the SOLE node on a branch lane (row > 0 and only one node on that row), call `emptyBranch(rung, node)` instead of removing it (revert to link). When the node being deleted IS a `link`, call `collapseLink(rung, node)`. Otherwise fall through to existing `deleteNode`.
  - Ensure `fillLink`'s replacement `id:''` path works: adjust `fillLink` call sites to pass `id: ''`; `fillLink` sets `replacement.id = link.id` so the empty id is overwritten (no `newNodeId` needed since we reuse the link's id).
- [ ] **Step 4: Full gates.** `cd mobile && flutter test` (all green), `flutter analyze` ZERO, `flutter build web --release` compiles, branding grep `grep -riE "openplc|beremiz|codesys|rslogix" mobile/lib mobile/test` clean, no overflow 320/1400. Round-trip test (a program with an empty link branch + a filled branch) deep-equals. Discard plugin churn.
- [ ] **Step 5: Commit** `feat(ld): empty-branch link rendering + fill/replace + delete-to-empty`, then hand the branch to the final whole-branch review (superpowers:requesting-code-review) and merge via superpowers:finishing-a-development-branch.

---

## Self-review notes
- **Spec coverage:** §A `LdKind.link` + open executor + fill=replace → T1 (model/engine/helpers) + T3 (fill interaction). §B guided junction anchors + right-rail end + cancel → T2. Empty-branch rendering (ghost ＋) → T3. Delete revert/collapse → T3. Round-trip + gates → across T1/T3.
- **Type consistency:** `addEmptyBranch(rung, String sourceId, String destId) → LdNode`, `fillLink(rung, LdNode, LdNode) → LdNode`, `emptyBranch(rung, LdNode) → LdNode`, `collapseLink(rung, LdNode)` used consistently. `_branchStartWireKey` (String?) replaces `_branchStart`. Junction key format `'from>to'` used in T2 only.
- **Open/no-op guarantee:** executor `link` case = `power=false`; the no-op-until-filled property is asserted directly in the T1 executor test (Q stays false with an empty branch, true after fill).
- **Additive persistence:** only the enum value; defaults unchanged; round-trip asserted T1 + T3.
- **YAGNI:** no nested branches, no multi-element auto-fill, no change to series insertion / coil-terminal rules / drag handles.
