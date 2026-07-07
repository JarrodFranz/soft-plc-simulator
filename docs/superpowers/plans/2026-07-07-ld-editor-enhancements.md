# Ladder Editor Enhancements Implementation Plan (WS21)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ladder editor gains multiple stacked output coils, per-rung delete/reorder, and a full block set (timers TON/TOF/TP, counters CTU/CTD/CTUD, compare GT/LT/GE/LE/EQ/NE, math ADD/SUB/MUL/DIV/MOVE) that the in-app LD engine actually executes.

**Architecture:** Pure graph helpers in `ld_graph.dart` (`deleteRung`/`moveRung`/`addOutputCoil`), pure execution in `ld_exec.dart` (new `case LdKind.block` sub-branches), an additive model change in `project_model.dart` (`LdNode.operandA/operandB`; `presetMs` reused as a generic preset int), and editor UI in `ld_editor_screen.dart` (rung header actions, Coil-mode "＋ add output", a block-type picker replacing the hardcoded TON, and a two-operand data-block widget + edit dialog fields).

**Tech Stack:** Dart, Flutter, `flutter_test`. No new dependencies.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix") in strings/identifiers/comments. IEC block mnemonics (TON, CTU, GT, ADD, …) are IEC 61131-3 terms and ARE allowed.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400 px; dark theme; braces always; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Additive persistence ONLY: new JSON keys `operand_a`/`operand_b` are omitted from `toJson` when empty; `preset_ms` key unchanged (meaning generalized to a preset int). The WS6 lossless round-trip guard MUST stay green.
- Pure logic files (`ld_graph.dart`, `ld_layout.dart`, `ld_exec.dart`, `project_model.dart`) stay free of Flutter imports.
- LD writes remain force-aware: all engine writes go through the `write` callback passed to `executeRung` (which is `_forceAwareWrite`) — never call `writePath` directly from a block case.
- Run flutter in the FOREGROUND with bounded timeouts; discard plugin-registrant churn before commits (`git checkout -- mobile/linux/flutter mobile/macos/Flutter mobile/windows/flutter`).

## Current-state facts (verified this session — build on these, do not re-derive)

- `LdNode` (`project_model.dart:131`): fields `id, kind (LdKind), variable, modifier, blockType, presetMs (default 5000), comment, col, row`; `fromJson`/`toJson` use keys `id/kind/variable/modifier/block_type/preset_ms/comment/col/row`.
- `enum LdKind { leftRail, rightRail, contact, coil, block }` (`project_model.dart:129`).
- `executeRung(PlcProject p, String progName, LdRung rung, int dtMs, LdExecRuntime rt, void Function(String,dynamic) write)` (`ld_exec.dart:49`): builds `col = colAssignment(rung)`, orders nodes by column, computes `power` map; `inputPower(n)` = OR of inbound wire source powers; `case LdKind.block` (`ld_exec.dart:126`) currently handles TON/TOF only, writes `$base.EN/.PRE/.ACC/.DN/.TT` and sets `power[n.id] = dn`. Edge state via `rt.prevBool['$progName|${rung.rungIndex}|${n.id}']`.
- `addParallelBranch(LdRung rung, LdNode spanStart, LdNode spanEnd) -> LdBranchView` (`ld_graph.dart:171`): allocates `lane = maxLane(rung)+1`, re-wires around the span. Use its wiring approach as the reference for `addOutputCoil`.
- `newNodeId(LdRung)` (`ld_graph.dart:25`) is monotonic (never reuses ids). `maxLane(rung)` (`ld_graph.dart:38`).
- Editor (`ld_editor_screen.dart`): `_editMode` string `'select'|'contact'|'coil'|'block'|'branch'` (line 40); toolbar `modeBtn(...)` (line ~230) + `addRungBtn` (line 255) calling `_addRung` (line 303); `_buildRungCanvas(rung, index)` (line 317) draws the header `Text('RUNG $index   ${rung.comment}')` (line 333) and coil insert targets gated by `_editMode == 'coil'` + `canInsertCoilOnWire` (lines 363-366); `_insertOnWire` (line 457) hardcodes `blockType: 'TON'`; `_showEditNodeDialog` (line 611) has `contactMods`/`coilMods` dropdowns + a preset TextField for blocks; `_buildBlock` (line ~720) renders header `blockType` + `variable` + `_BlockPinRow(left:'IN',right:'Q')` + `PT ${presetMs}ms` + `_BlockPinRow(left:'PT',right:'ET')`.
- `canInsertCoilOnWire(rung, w)` (`ld_layout.dart:53`): `toId.kind == rightRail && fromId.kind != coil`.

**Sequencing:** Phase 1 (T1 rung mechanics + coil stacking) → Phase 2 (T2 model fields, T3 single-power block engine, T4 block edit-dialog+render for timers/counters) → Phase 3 (T5 data-block engine, T6 data-block widget+dialog+block-picker) → T7 validation+round-trip+final review.

---

### Task 1: Rung delete/reorder + stacked output coil (pure helpers + editor UI)

**Files:**
- Modify: `mobile/lib/models/ld_graph.dart` (add `deleteRung`, `moveRung`, `addOutputCoil`)
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (rung header action row; Coil-mode "＋ add output" target)
- Test: `mobile/test/ld_graph_test.dart` (or the existing LD graph test file — grep for it; create if absent), `mobile/test/ld_editor_responsive_test.dart (existing widget-test home) or a new ld_editor_test.dart` (widget; create if absent)

**Interfaces produced (used by later tasks / callers):**
- `void deleteRung(PlcProgram program, int index)` — removes `program.rungs[index]` if `0 <= index < length`, else no-op.
- `void moveRung(PlcProgram program, int from, int to)` — if both in range and `from != to`: remove at `from`, insert at `to` (after removal, clamp `to` into `[0, length]`).
- `LdNode addOutputCoil(LdRung rung)` — allocates `lane = maxLane(rung)+1`, creates `LdNode(id: newNodeId(rung), kind: LdKind.coil, variable: 'Output_Coil', row: lane)`, wires left-rail→coil→right-rail on that lane (mirror `addParallelBranch`'s left-rail-to-first and last-to-right-rail wiring, spanning the full width), returns the new coil node.

- [ ] **Step 1: Write failing tests** for the three helpers.

```dart
// ld_graph_test.dart
test('deleteRung removes the rung and is a no-op out of range', () {
  final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
    buildRung(index: 0, main: [LdNode(id: '', kind: LdKind.contact, variable: 'A'), LdNode(id: '', kind: LdKind.coil, variable: 'Q')]),
    buildRung(index: 1, main: [LdNode(id: '', kind: LdKind.contact, variable: 'B'), LdNode(id: '', kind: LdKind.coil, variable: 'R')]),
  ]);
  deleteRung(prog, 0);
  expect(prog.rungs.length, 1);
  expect(prog.rungs.first.nodes.any((n) => n.variable == 'B'), isTrue);
  deleteRung(prog, 5); // out of range
  expect(prog.rungs.length, 1);
  deleteRung(prog, 0);
  expect(prog.rungs, isEmpty); // may go to zero
});

test('moveRung reorders and clamps', () {
  final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [
    buildRung(index: 0, main: [LdNode(id: '', kind: LdKind.coil, variable: 'A')]),
    buildRung(index: 1, main: [LdNode(id: '', kind: LdKind.coil, variable: 'B')]),
    buildRung(index: 2, main: [LdNode(id: '', kind: LdKind.coil, variable: 'C')]),
  ]);
  moveRung(prog, 0, 2); // A to the end
  expect(prog.rungs.map((r) => r.nodes.firstWhere((n) => n.kind == LdKind.coil).variable).toList(), ['B', 'C', 'A']);
  moveRung(prog, 2, 2); // no-op
  expect(prog.rungs.last.nodes.first.variable, 'B'); // unchanged order tail
});

test('addOutputCoil adds a new terminal coil lane', () {
  final rung = buildRung(index: 0, main: [
    LdNode(id: '', kind: LdKind.contact, variable: 'A'),
    LdNode(id: '', kind: LdKind.coil, variable: 'Q1'),
  ]);
  final before = maxLane(rung);
  final coil = addOutputCoil(rung);
  expect(coil.kind, LdKind.coil);
  expect(coil.row, before + 1);
  // the new coil feeds the right rail (terminal) and is fed from the left rail
  expect(rung.wires.any((w) => w.fromId == coil.id && w.toId == kRightRailId), isTrue);
  expect(rung.wires.any((w) => w.toId == coil.id), isTrue);
});
```

- [ ] **Step 2: Run → FAIL.** `cd mobile && flutter test test/ld_graph_test.dart` (symbols missing).
- [ ] **Step 3: Implement the three helpers** in `ld_graph.dart`. `deleteRung`/`moveRung` are list ops with bounds guards. For `addOutputCoil`, follow `addParallelBranch`'s wiring pattern but span the whole rung (left rail → new coil → right rail) on a fresh lane; do NOT reuse a deleted id (`newNodeId`). Keep pure (no Flutter import).
- [ ] **Step 4: Editor UI.** In `_buildRungCanvas`'s header row (`ld_editor_screen.dart:331`), add a trailing `Row` of `IconButton`s: up (`Icons.arrow_upward`, `onPressed: index == 0 ? null : () { setState(() => moveRung(widget.program, index, index-1)); widget.onProgramUpdated(); }`), down (`Icons.arrow_downward`, disabled when `index == widget.program.rungs.length-1`, moves to `index+1`), delete (`Icons.delete_outline`, red) that first shows a confirm dialog via `showAdaptiveWidthDialog` returning bool, then `setState(() => deleteRung(widget.program, index)); widget.onProgramUpdated();`. Use `touchable`/`IconButton` sized for touch; wrap the header in a `Row` with the title `Expanded` so the actions pin right without overflow at 320 px. In the Coil-mode target block (lines 363-366), ADD a single always-present "＋ add output" affordance near the right rail: a `Positioned` cyan `＋` button (reuse the `_wireInsertTarget` visual) placed at the right rail, `onTap: () { setState(() { final c = addOutputCoil(rung); _editMode='select'; }); widget.onProgramUpdated(); _showEditNodeDialog(rung, c); }`. Keep the existing wire-based coil targets too.
- [ ] **Step 5: Widget test** (`ld_editor_test.dart`): pump `LdEditorScreen` with a 2-rung program at 1400 and 320 px; assert up-arrow on rung 0 is disabled and down on the last rung is disabled; tapping down on rung 0 reorders (the header text order swaps); entering Coil mode shows the "＋ add output" affordance and tapping it adds a coil (node count grows, dialog opens); `tester.takeException()` isNull at both widths.
- [ ] **Step 6: Gates + commit.** `flutter test` (full) green; `flutter analyze` ZERO. Commit `feat(ld): rung delete/reorder + stacked output coils`.

---

### Task 2: LdNode model fields for data blocks (additive, round-trip-safe)

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`LdNode`)
- Test: `mobile/test/serialization_roundtrip_test.dart` (or the existing serialization test — grep `preset_ms`/`LdNode.fromJson`; extend it)

**Interfaces produced:** `LdNode.operandA` (String, default `''`) and `LdNode.operandB` (String, default `''`); JSON keys `operand_a`/`operand_b`, **omitted when empty**.

- [ ] **Step 1: Write failing test.**

```dart
test('LdNode operand fields round-trip and are omitted when empty', () {
  final bare = LdNode(id: 'n1', kind: LdKind.contact, variable: 'A');
  expect(bare.toJson().containsKey('operand_a'), isFalse); // additive: absent when empty
  final data = LdNode(id: 'n2', kind: LdKind.block, blockType: 'GT', operandA: 'Level', operandB: '80');
  final j = data.toJson();
  expect(j['operand_a'], 'Level');
  expect(j['operand_b'], '80');
  final back = LdNode.fromJson(j);
  expect(back.operandA, 'Level');
  expect(back.operandB, '80');
  // legacy JSON without the keys still loads
  final legacy = LdNode.fromJson({'id': 'n3', 'kind': 'block', 'block_type': 'TON', 'preset_ms': 3000});
  expect(legacy.operandA, '');
});
```

- [ ] **Step 2: Run → FAIL. Step 3: Implement.** Add `String operandA` / `String operandB` (default `''`) to the constructor; in `fromJson` read `json['operand_a'] ?? ''` / `json['operand_b'] ?? ''`; in `toJson` conditionally add the keys only when non-empty:

```dart
Map<String, dynamic> toJson() {
  final m = <String, dynamic>{
    'id': id, 'kind': kind.name, 'variable': variable, 'modifier': modifier,
    'block_type': blockType, 'preset_ms': presetMs, 'comment': comment, 'col': col, 'row': row,
  };
  if (operandA.isNotEmpty) m['operand_a'] = operandA;
  if (operandB.isNotEmpty) m['operand_b'] = operandB;
  return m;
}
```

- [ ] **Step 4: Tests → PASS**; the WS6 lossless round-trip guard still green (existing projects have no operand keys → unchanged output). `flutter analyze` ZERO.
- [ ] **Step 5: Commit** `feat(ld): additive LdNode operand fields for data blocks`.

---

### Task 3: Single-power block engine — TP, CTU, CTD, CTUD

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart` (`case LdKind.block`)
- Test: `mobile/test/ld_exec_test.dart` (or the existing LD exec test — grep `executeRung`/`TOF`; extend)

**Interfaces consumed:** `executeRung`/`inputPower`/`write`/`rt.prevBool` keying (Current-state facts). `n.presetMs` is the preset int (ms for timers, count for counters). CTUD down-input tag = `n.operandA` (Task 2).

Behaviour (add branches BEFORE the existing TON/TOF logic, dispatch on `n.blockType`; leave TON/TOF as the `else`/default):
- **TP**: edge-key `key='$progName|${rung.rungIndex}|${n.id}'`; `prevIn = rt.prevBool[key] ?? inP; rt.prevBool[key]=inP`. Hold state in `.ACC`. On rising `inP` (`inP && !prevIn`) when not already timing (`acc<=0` or `acc>=pre`... use a running flag: treat `acc>0 && acc<pre` as "timing"), start: `acc = dtMs`. While `0<acc<pre` (timing) and regardless of IN, `acc += dtMs` each scan (pulse is non-retriggerable until complete). Q (`.DN`) = `acc>0 && acc<pre` OR the just-started scan; when `acc>=pre` → Q false and reset `acc=0` so it can retrigger on the next rising edge. Write `.EN=inP, .PRE=pre, .ACC=acc, .DN=q, .TT=q`; `power[n.id]=q`.
- **CTU**: edge on `inP`; `cv=(readPath(p,'$base.CV') as num?)?.toInt() ?? 0`. On rising edge, `cv = math.min(cv+1, 32767)`. If `readPath(p,'$base.R')==true` → `cv=0`. `qu = cv >= pre`. Write `.CU=inP, .PV=pre, .CV=cv, .QU=qu, .R=(readPath ...==true)`; `power[n.id]=qu`.
- **CTD**: `cv` initialised to `pre` when absent (`readPath null → pre`). On rising edge of `inP`, `cv = math.max(cv-1, 0)`. Reset `$base.R==true` → `cv=pre`. `qd = cv <= 0`. Write `.CD=inP, .PV=pre, .CV=cv, .QD=qd, .R=...`; `power[n.id]=qd`.
- **CTUD**: up-edge on `inP` (+1), down-edge on `readPath(p, n.operandA)==true` (its own prevBool sub-key `'$key|dn'`), −1; `cv = cv.clamp(0, pre)`. Reset `$base.R==true` → `cv=0`. `qu = cv>=pre`, `qd = cv<=0`. Write `.CU=inP, .CD=(down input), .PV=pre, .CV=cv, .QU=qu, .QD=qd, .R=...`; `power[n.id]=qu`.

Add `import 'dart:math' as math;` to `ld_exec.dart` if not present.

- [ ] **Step 1: Write failing tests** (deterministic, driving `executeRung` directly with a hand-built rung + `LdExecRuntime`, `dtMs` fixed). Cover: TP emits Q for exactly `ceil(pre/dt)` scans after a rising edge then drops, and a mid-pulse IN drop does NOT cut it short; CTU increments once per rising edge (a held-high input counts ONCE, not every scan), `.QU` at `cv>=PV`, `$base.R` resets to 0; CTD reloads to PV and decrements, `.QD` at 0; CTUD up then down nets correctly and clamps at `[0,PV]`. Assert via `readPath(p, 'Cnt.CV')` etc. Example skeleton:

```dart
test('CTU counts one per rising edge and resets', () {
  final p = _projectWithTags(['PB BOOL', 'RST BOOL', 'Cnt.CV INT', 'Cnt.QU BOOL']); // helper builds tags
  final rung = buildRung(index: 0, main: [
    LdNode(id: '', kind: LdKind.contact, variable: 'PB'),
    LdNode(id: '', kind: LdKind.block, blockType: 'CTU', variable: 'Cnt', presetMs: 2),
    LdNode(id: '', kind: LdKind.coil, variable: 'Done'),
  ]);
  final rt = LdExecRuntime();
  void scan() => executeRung(p, 'P', rung, 100, rt, (path, v) => writePath(p, path, v));
  writePath(p, 'PB', true); scan();  // edge 1 -> CV 1
  scan();                            // held high, no new edge -> CV still 1
  writePath(p, 'PB', false); scan();
  writePath(p, 'PB', true); scan();  // edge 2 -> CV 2, QU true (PV 2)
  expect(readPath(p, 'Cnt.CV'), 2);
  expect(readPath(p, 'Cnt.QU'), true);
  writePath(p, 'Cnt.R', true); scan();
  expect(readPath(p, 'Cnt.CV'), 0);
});
```
(Adapt `_projectWithTags` to the existing test helpers in the LD exec test file; if none, build a `PlcProject` with the needed `PlcTag`s inline.)

- [ ] **Step 2: Run → FAIL. Step 3: Implement** the four branches. Keep the TON/TOF path intact as the default.
- [ ] **Step 4: Tests → PASS**; full `flutter test` green; `flutter analyze` ZERO.
- [ ] **Step 5: Commit** `feat(ld): TP pulse + CTU/CTD/CTUD counter execution`.

---

### Task 4: Block edit dialog + rendering for timers & counters

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (`_showEditNodeDialog`, `_buildBlock`)
- Test: `mobile/test/ld_editor_responsive_test.dart (existing widget-test home) or a new ld_editor_test.dart` (extend)

**Interfaces consumed:** blockTypes from Task 3; `n.presetMs`, `n.operandA` (CTUD down-tag).

- [ ] **Step 1: Write failing widget tests**: opening the edit dialog on a CTU block shows a "Preset Count (PV)" field (not "Preset Time (PT) ms") bound to `presetMs`; on a CTUD block additionally shows a "Count-down tag" field bound to `operandA`; a CTU block renders its `blockType` label and `CV/PV` pins (assert the `CU`/`Q` pin text) without overflow at 320 px.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.** In `_showEditNodeDialog`, when `isBlock`, branch on `n.blockType`: for timers (`TON/TOF/TP`) keep the ms preset field labelled "Preset Time (PT) ms"; for counters (`CTU/CTD/CTUD`) label the same preset field "Preset Count (PV)"; for `CTUD` add a `TagAutocompleteField` bound to `operandA` labelled "Count-down tag". In `_buildBlock`, choose pin labels by family: timers `IN/Q` + `PT/ET` + `PT ${presetMs}ms`; counters `CU/QU` (CTD: `CD/QD`, CTUD: `CU/QU`) + `PV ${presetMs}` + a `CV` readout line. Keep block height `_kBlockH`; use `maxLines:1`+`ellipsis` so nothing overflows at 320.
- [ ] **Step 4: Tests → PASS**; analyze ZERO; full suite green.
- [ ] **Step 5: Commit** `feat(ld): counter/timer block edit dialog + rendering`.

---

### Task 5: Data-block engine — Compare & Math

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart` (`case LdKind.block`)
- Test: `mobile/test/ld_exec_test.dart` (extend)

**Interfaces consumed:** `n.operandA`/`n.operandB` (operands, tag-or-literal), `n.variable` (math output tag), `write`, `inputPower`.

Operand resolution helper (add near the top of `ld_exec.dart`, pure): `double _operandValue(PlcProject p, String s)` — if `s` parses as `double`/`int` → that number; else `readPath(p, s)` coerced to double (bool→1/0, num→toDouble, else 0). Add branches to the block switch:
- **Compare** (`GT/LT/GE/LE/EQ/NE`): `a=_operandValue(p, n.operandA); b=_operandValue(p, n.operandB)`; `res` per operator (`GT:a>b`, `LT:a<b`, `GE:a>=b`, `LE:a<=b`, `EQ:a==b`, `NE:a!=b`); `power[n.id] = inP && res`. Writes nothing.
- **Math** (`ADD/SUB/MUL/DIV/MOVE`): only when `inP`: `r = ADD:a+b, SUB:a-b, MUL:a*b, DIV: b==0 ? 0 : a/b, MOVE:a`; `write(n.variable, r)` (the tag's declared type governs storage — writePath already coerces int tags by truncation; verify and, if not, truncate here when the root tag is INT). `power[n.id] = inP` (ENO passthrough). When `!inP`, do not write; `power[n.id]=false`.

- [ ] **Step 1: Write failing tests**: each compare operator at its boundary (`a==b` → GT false, GE true, EQ true, NE false, LE true, LT false); math ADD/SUB/MUL, MOVE copies A ignoring B, DIV by zero → result tag 0 and power still passes; math with `inP` false writes nothing (tag unchanged) and power-out false; operand as a literal vs a tag both resolve.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.** Never throw — a non-numeric/absent operand resolves to 0.
- [ ] **Step 4: Tests → PASS**; full suite green; analyze ZERO.
- [ ] **Step 5: Commit** `feat(ld): compare + math data-block execution`.

---

### Task 6: Data-block widget + edit dialog + block-type picker

**Files:**
- Modify: `mobile/lib/screens/ld_editor_screen.dart` (`_buildBlock` data-block visual; `_showEditNodeDialog` operand fields; the toolbar "Block" button → picker; `_insertOnWire` pending block-type)
- Test: `mobile/test/ld_editor_responsive_test.dart (existing widget-test home) or a new ld_editor_test.dart` (extend)

**Interfaces consumed:** `operandA/operandB`, blockTypes from Tasks 3+5.

- [ ] **Step 1: Write failing widget tests**: tapping the toolbar "Block" button opens a picker listing groups Timers/Counters/Compare/Math and each type; picking `GT` then tapping a wire insert-target inserts a block with `blockType=='GT'` and opens its dialog; the GT edit dialog shows operand A, an operator dropdown, operand B (no preset field); a Math (`ADD`) dialog shows an output-tag field + A + operator + B; a GT block renders A, the `>` glyph, and B without overflow at 320 px.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - Add a `String _pendingBlockType = 'TON';` field. Replace the `modeBtn('block', …)` behaviour so tapping "Block" opens a picker (`showAdaptiveWidthDialog` / bottom sheet) of grouped choices; on select, set `_pendingBlockType` and `_editMode='block'`. Groups: Timers [TON,TOF,TP], Counters [CTU,CTD,CTUD], Compare [GT,LT,GE,LE,EQ,NE], Math [ADD,SUB,MUL,DIV,MOVE].
  - In `_insertOnWire` (line 461-462) replace hardcoded `blockType:'TON'` with `_pendingBlockType`; seed sensible defaults (compare/math: `operandA:'0', operandB:'0'`; timers/counters: `presetMs` default).
  - `_showEditNodeDialog`: for compare (`GT/LT/GE/LE/EQ/NE`) show operand-A `TagAutocompleteField` (bound `operandA`), an operator `DropdownButtonFormField` that rewrites `blockType` among the compare set, operand-B field (`operandB`); for math (`ADD/SUB/MUL/DIV/MOVE`) show an output-tag field (`variable`), operand A, an operator dropdown across the math set, operand B. No preset field for data blocks.
  - `_buildBlock`: when `blockType` is compare/math, render a two-row body: operand A (top), operator glyph centre (`> < ≥ ≤ = ≠` / `+ − × ÷ MOVE`), operand B (bottom), with the left `EN` pin and right pin (`Q` compare / `ENO` math). `maxLines:1`+ellipsis; fits at 320.
- [ ] **Step 4: Tests → PASS**; analyze ZERO; full suite green; no overflow 320/1400.
- [ ] **Step 5: Commit** `feat(ld): data-block widget + operand dialog + block-type picker`.

---

### Task 7: Validation, round-trip demo & final review

**Files:**
- Modify: (only if a gap surfaces) any of the above; add a round-trip test asset if useful.
- Test: `mobile/test/serialization_roundtrip_test.dart` (extend)

- [ ] **Step 1: Round-trip test.** Build a program containing one of EACH new block (TP, CTU, CTD, CTUD, GT, ADD, MOVE) plus a stacked output coil; `toJson` → `fromJson` → assert deep-equal (ids, blockType, presetMs, operandA/B, wires, lanes). Confirms additive persistence + `addOutputCoil` wiring survive save/load.
- [ ] **Step 2: Full gates.** `cd mobile && flutter test` (ALL green) · `flutter analyze` → ZERO · `flutter build web --release` compiles · branding grep `grep -riE "openplc|beremiz|codesys|rslogix" mobile/lib mobile/test` → no hits in app/test code · no RenderFlex overflow in the responsive suite at 320/1400. Discard plugin churn.
- [ ] **Step 3: Commit** `test(ld): full-block round-trip + WS21 validation` and hand the branch to the final whole-branch review (superpowers:requesting-code-review), then merge via superpowers:finishing-a-development-branch.

---

## Self-review notes
- **Spec coverage:** §A rung delete/reorder → T1; §B coil stacking → T1; §C model + TP/CTU/CTD/CTUD engine → T2+T3, dialog/render → T4; §D compare/math engine → T5, widget+dialog+picker → T6; testing/round-trip → across tasks + T7.
- **Type consistency:** `deleteRung(PlcProgram,int)`, `moveRung(PlcProgram,int,int)`, `addOutputCoil(LdRung)→LdNode`, `LdNode.operandA/operandB`, `_pendingBlockType`, `_operandValue(PlcProject,String)→double` used consistently across tasks. `presetMs` = generic preset int (ms timers / count counters) everywhere.
- **Additive persistence:** only `operand_a`/`operand_b`, omitted when empty; `preset_ms` key unchanged; round-trip guard asserted in T2 and T7.
- **Force-aware:** all engine writes flow through the `write` callback; no direct `writePath` in block cases.
- **YAGNI:** no two-power-input shape (CTUD down = tag), no drag reorder (▲/▼), no PID/edge LD blocks.
