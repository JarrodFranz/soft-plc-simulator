# Editor / HMI / Inspector Fixes & DUT Tooling Implementation Plan (WS23)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three UI bugs (HMI edit-chrome-in-run-mode, tag-autocomplete selection, LD add-output ＋ misplacement) and add three capabilities (rename FBD/LD-compare blocks, expand DUT tags in the Tag Inspector, full CRUD on struct definitions).

**Architecture:** Mostly surgical edits to existing screens/widgets, plus small pure helpers in `tag_resolver.dart` for struct-def integrity (`structDefInUse`, `renameStructDef`). No model schema changes — reuses `FbdBlock.title`, `LdNode.variable`, `PlcStructDef`/`StructFieldDef`. Tag-inspector expansion reuses the existing `childrenOf`/`readPath` resolver helpers and the Memory Manager's expandable-row pattern.

**Tech Stack:** Dart, Flutter, `flutter_test`. No new dependencies.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); IEC terms fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400 px; dark theme; braces; `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Additive/lossless persistence: struct-def edits use existing `PlcStructDef`/`StructFieldDef` serialization; the WS6 round-trip guard stays green. No new model fields.
- Pure logic (`tag_resolver.dart`, `project_model.dart`) stays Flutter-free; force-aware behavior unchanged (inspector child rows are display-only).
- Foreground flutter with bounded timeouts; discard plugin-registrant churn before commits (`git checkout -- mobile/linux/flutter mobile/macos/Flutter mobile/windows/flutter`).

## Current-state facts (verified this session)

- HMI wide-card branch: `hmi_dashboard_builder_screen.dart:513-531` (`if (actualWidth >= 360) Row(children: [ ... ..._componentHeaderControls(comp, index, components) ])`) appends the controls UNCONDITIONALLY; the narrow branch at `:546-553` wraps the same call in `if (isEditMode) ...[...]`. `isEditMode` is in scope in both.
- `tag_autocomplete_field.dart`: hand-rolled `TextField` (`:161`) + `OverlayEntry` (`_showOverlay`, `:102-150`); suggestion is an `InkWell` (`:130`, `onTap: () => _onSelect(option)`); `_onSelect` (`:92-100`) correctly sets `_controller` + calls `widget.onChanged`; `_onFocusChanged` (`:66-70`) removes the overlay on focus loss. No `TextFieldTapRegion` anywhere.
- LD editor: `_buildRungCanvas(rung, index)` (`ld_editor_screen.dart:466`) sets `height = _editMode == 'coil' ? _rungHeight(rung) + _kContactH + _kLaneGap : _rungHeight(rung)`; header row with WS21 ▲/▼/trash `IconButton`s at `:485-511`; `_addOutputTarget(rung, width)` (`:769-777`) Positions the ＋ at phantom lane `maxLane+1`; compact `contentHeight += _rungHeight(r) + rungExtra + 44 + _kRungGap` (`:239`) with `rungExtra = _editMode=='coil' ? _kContactH+_kLaneGap : 0` (`:238`). `addOutputCoil(rung)` exists in `ld_graph.dart`. `_kContactH=54`, `_kLaneGap=10`, `_kRungGap=8` (`:11-15`).
- FBD: `_showConfigureBlockDialog` (`fbd_editor_screen.dart:356-428`) shows read-only `Text('Block Type: ${block.type}')` (`:372`), a tag-binding field (`:374-386`), input-count stepper (`:387-404`); Save (`:416-423`) writes `block.tagBinding` only. `FbdBlock.title` is a persisted field (`project_model.dart:251-268`). Block face renders `block.title` (`:681-694`) + `Block Function: ${block.type}` (`:748`).
- LD Compare dialog: `_showEditNodeDialog` (`ld_editor_screen.dart:981-1132`); data blocks (`isDataBlock`) skip the "Tag / literal" field (`:1064` guard); `_buildDataBlock` renders operands + a math-only `→ variable` line.
- Tag Inspector: `tag_inspector_dock.dart` renders a flat `ListView.separated` of top-level `PlcTag`s; value via `Text('$effectiveVal ${tag.engineeringUnits}')` (`:202-212`); no expand. Used from `workspace_shell.dart:955,1032`.
- Resolver helpers (`tag_resolver.dart`): `childrenOf(PlcProject, String path) -> List<TagChild>` (`:265-334`; each has `label`, dotted `path`, `dataType`, `arrayLength`, `value`, `hasChildren`); `readPath`/`writePath` (`:159-261`); `lookupComposite` (`:44-56`); `builtinCompositeNames()`; `_builtinComposites` = TIMER, COUNTER. Memory Manager reference pattern: `memory_manager_screen.dart` `_expandedTagKeys`/`_buildRowData`/`_childRowData`/`_toggleExpand` (`:356-431`).
- Memory Manager struct tab: `_buildStructDefsTab` (`memory_manager_screen.dart:518-545`) — read-only `ListView.builder` of `ExpansionTile`s, no FAB/edit/delete. `PlcStructDef{String name, List<StructFieldDef> fields}` (`project_model.dart:102`); `StructFieldDef{String name, String dataType, int arrayLength, dynamic defaultValue}` (`:72`). `PlcTag.dataType` exists; `PlcProject.tags`/`.structDefs`.

**Sequencing:** T1 (three bug fixes) → T2 (block naming) → T3 (inspector DUT expand) → T4 (struct-def CRUD) → T5 (validation + round-trip + final review).

---

### Task 1: Bug sweep — HMI run-mode gate + autocomplete selection + LD ＋ placement

**Files:**
- Modify: `mobile/lib/screens/hmi_dashboard_builder_screen.dart`, `mobile/lib/widgets/tag_autocomplete_field.dart`, `mobile/lib/screens/ld_editor_screen.dart`
- Test: `mobile/test/hmi_dashboard_builder_test.dart` (or the existing HMI widget test — grep), `mobile/test/tag_autocomplete_field_test.dart`, `mobile/test/ld_editor_test.dart`

**1A — HMI: gate wide-card controls on edit mode.**
- [ ] **Step 1: Failing test** (`hmi_dashboard_builder_test.dart`): pump the builder with a component that has `gridSpanWidth: 2` (the status pill / `tmpl_pill`) in RUN mode; assert the resize/gear/delete controls are absent (e.g. `find.byIcon(Icons.settings)` / the col-span "+"/"−" / `Icons.delete` `findsNothing`); pump in EDIT mode and assert they're present. Run → FAIL (controls show in run mode).
- [ ] **Step 2: Fix** at `hmi_dashboard_builder_screen.dart:529`: change the unconditional `..._componentHeaderControls(comp, index, components)` in the wide-card `Row` to `if (isEditMode) ..._componentHeaderControls(comp, index, components)` (collection-`if` spread), mirroring the narrow-card branch at `:546-553`. → PASS.

**1B — Autocomplete: keep the overlay in the text-field tap group.**
- [ ] **Step 1: Failing test** (`tag_autocomplete_field_test.dart`): pump a `TagAutocompleteField` with `options: ['Motor_Run','Motor_Latch']`, capture `onChanged`; enter text 'Mo' to open the overlay, tap the 'Motor_Run' suggestion; assert the field's text is now 'Motor_Run' AND `onChanged` last fired with 'Motor_Run'. Run → FAIL (tap dismisses overlay, text unchanged).
- [ ] **Step 2: Fix** in `tag_autocomplete_field.dart` `_showOverlay`: wrap the overlay's `Material(...)` (`:118-144`) in a `TextFieldTapRegion` so a tap on a suggestion is treated as part of the text field's tap group and does NOT drop focus / tear down the overlay before `_onSelect` runs:

```dart
child: TextFieldTapRegion(
  child: Material(
    elevation: 4,
    color: const Color(0xFF1E293B),
    borderRadius: BorderRadius.circular(6),
    child: ConstrainedBox( /* ...unchanged... */ ),
  ),
),
```
`TextFieldTapRegion` is in `package:flutter/material.dart` (already imported). Leave `_onSelect` unchanged (it already sets `_controller` + calls `onChanged`). → PASS.

**1C — LD: relocate the add-output ＋ into the rung header; drop the phantom-lane reservation; fix compact height.**
- [ ] **Step 1: Failing test** (`ld_editor_test.dart`): pump `LdEditorScreen` with a 2-rung program in Coil mode; assert there is NO add-output ＋ positioned in reserved space below a rung's content (the old `_addOutputTarget`), and that an "Add output" affordance exists in the rung header; tapping it adds an output coil to that rung (`addOutputCoil` result — node count grows, a coil `Output_Coil` appears) and opens the edit dialog; assert no RenderFlex overflow at 320 and 1400. Run → FAIL.
- [ ] **Step 2: Fix:**
  - In `_buildRungCanvas` header `Row` (near the ▲/▼/trash `IconButton`s, `:485-511`), add a small `IconButton(icon: const Icon(Icons.add, size: 18, color: Colors.cyanAccent), tooltip: 'Add output', onPressed: () { setState(() { final c = addOutputCoil(rung); _editMode = 'select'; }); widget.onProgramUpdated(); _showEditNodeDialog(rung, c); })`. (Available always — adding an output no longer requires Coil mode.)
  - Remove `_addOutputTarget` and its Stack usage (the phantom-lane `Positioned`); remove the coil-mode height reservation so `height = _rungHeight(rung)` unconditionally (`:466-473`); remove the `rungExtra` coil term at `:238` (set to `0` / drop it).
  - Fix the compact chrome constant at `:239`: replace `+ 44` with `+ 58` (container `vertical:10`×2 = 20 + header row ~28 + `bottom:6` + slack ≈ 58) so the pannable `SizedBox` isn't undersized.
  - Keep the Coil-mode wire-insert targets (placing a coil on a genuinely open terminal) unchanged.
- [ ] **Step 3: Gates + commit.** `cd mobile && flutter test` (all green) · `flutter analyze` ZERO. Commit `fix(ui): HMI run-mode chrome gate + autocomplete selection (TapRegion) + LD add-output in rung header`.

---

### Task 2: Block naming — FBD title + LD Compare name

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart` (`_showConfigureBlockDialog`), `mobile/lib/screens/ld_editor_screen.dart` (`_showEditNodeDialog` + `_buildDataBlock`)
- Test: `mobile/test/fbd_editor_test.dart` (or existing FBD test), `mobile/test/ld_editor_test.dart`

- [ ] **Step 1: Failing tests.**
  - FBD (`fbd_editor_test.dart`): open the config dialog on a block; assert a "Block name" field exists seeded with `block.title`; change it and Save; assert `block.title` updated and the block face shows the new name. Run → FAIL (no name field).
  - LD (`ld_editor_test.dart`): open the edit dialog on a `GT` compare block; assert a "Name" field exists bound to `variable`; set it and Apply; assert `n.variable` updated and the compare block face shows it. Run → FAIL.
- [ ] **Step 2: Implement.**
  - FBD `_showConfigureBlockDialog` (`:356-428`): add a `String pendingTitle = block.title;` and a `TextFormField`(label 'Block name', initialValue `block.title`, `onChanged: (v) => pendingTitle = v`) right after the `Block Type` text (`:372`); in Save (`:416-423`) add `block.title = pendingTitle.trim().isEmpty ? block.title : pendingTitle.trim();`.
  - LD `_showEditNodeDialog`: for compare blocks (`isCompare`/`GT|LT|GE|LE|EQ|NE`), add a "Name" `TagAutocompleteField`/`TextField` bound to `n.variable` (persist on Apply). `_buildDataBlock`: when `isCompare` and `n.variable.isNotEmpty`, render a small label line with `n.variable` (mirror the existing math `→ variable` line's style/guarding so it fits `_kBlockH` at 320).
- [ ] **Step 3: Gates + commit.** Tests green; analyze ZERO. Commit `feat(editor): rename FBD blocks (title) + name LD compare blocks`.

---

### Task 3: Tag Inspector — expand DUT/composite tags to child values

**Files:**
- Modify: `mobile/lib/widgets/tag_inspector_dock.dart`
- Test: `mobile/test/tag_inspector_dock_test.dart` (create if absent)

**Interfaces consumed:** `childrenOf(PlcProject, String) -> List<TagChild>` (`.label`, `.path`, `.value`, `.hasChildren`), `readPath`, from `tag_resolver.dart`.

- [ ] **Step 1: Failing test**: build a project with a composite tag (e.g. a `TIMER` tag `T1`) and a scalar tag (`Flag BOOL`); pump `TagInspectorDock`; assert the composite row shows an expand chevron and the scalar does not; tap the chevron; assert child rows appear (e.g. `.EN`, `.DN`) with their values (via `readPath`); assert no overflow 320/1400. Run → FAIL.
- [ ] **Step 2: Implement**: add `final Set<String> _expandedTags = {}` to the dock state. For each top-level tag, compute `final kids = childrenOf(project, tag.name)`. If `kids.isNotEmpty`, render an expand/collapse `IconButton`(`Icons.expand_more`/`Icons.chevron_right`) toggling `_expandedTags`, and when expanded render indented child rows (label + live `readPath(project, child.path)` value, recursing via `child.hasChildren` mirroring `memory_manager_screen.dart`'s `_childRowData`/`_toggleExpand` at `:356-431`) BELOW the tag's card/row. Child rows are read-only (no force button); the existing whole-tag Force control on the parent row is unchanged. If `kids.isEmpty`, render exactly as today (scalar value `Text`, no chevron).
- [ ] **Step 3: Gates + commit.** Tests green; analyze ZERO; no overflow. Commit `feat(inspector): expand DUT/composite tags to view child values`.

---

### Task 4: Struct Definitions CRUD (helpers + Add/Edit/Delete UI)

**Files:**
- Modify: `mobile/lib/models/tag_resolver.dart` (pure helpers), `mobile/lib/screens/memory_manager_screen.dart` (`_buildStructDefsTab` + dialogs)
- Test: `mobile/test/tag_resolver_test.dart`, `mobile/test/memory_manager_test.dart` (or existing)

**Interfaces produced (pure, `tag_resolver.dart`):**
- `bool structDefInUse(PlcProject p, String name)` — true if any `p.tags.any((t) => t.dataType == name)` OR any `p.structDefs.any((s) => s.fields.any((f) => f.dataType == name))`.
- `void renameStructDef(PlcProject p, String oldName, String newName)` — for every `PlcTag` with `dataType == oldName` set `dataType = newName`; for every `StructFieldDef` (across all `p.structDefs`) with `dataType == oldName` set `dataType = newName`; then set the matching `PlcStructDef.name = newName`. No-op if `oldName == newName` or no def named `oldName`.

- [ ] **Step 1: Failing unit tests** (`tag_resolver_test.dart`):

```dart
test('structDefInUse detects tag and nested-field references', () {
  final p = PlcProject(/* … */ tags: [PlcTag(name:'P1', dataType:'PumpStatusDUT', /*…*/)],
    structDefs: [
      PlcStructDef(name:'PumpStatusDUT', fields:[StructFieldDef(name:'Running', dataType:'BOOL', defaultValue:false)]),
      PlcStructDef(name:'Skid', fields:[StructFieldDef(name:'Pump', dataType:'PumpStatusDUT', defaultValue:null)]),
    ]);
  expect(structDefInUse(p, 'PumpStatusDUT'), isTrue);  // used by tag P1 and by Skid.Pump
  expect(structDefInUse(p, 'Skid'), isFalse);
});

test('renameStructDef cascades to tags and nested fields', () {
  final p = /* as above */;
  renameStructDef(p, 'PumpStatusDUT', 'PumpDUT');
  expect(p.structDefs.any((s) => s.name == 'PumpDUT'), isTrue);
  expect(p.tags.firstWhere((t) => t.name=='P1').dataType, 'PumpDUT');
  expect(p.structDefs.firstWhere((s)=>s.name=='Skid').fields.first.dataType, 'PumpDUT');
});
```
Run → FAIL (symbols missing).
- [ ] **Step 2: Implement the two helpers** in `tag_resolver.dart` (pure). → PASS.
- [ ] **Step 3: UI failing tests** (`memory_manager_test.dart`): the Struct Definitions tab has an "Add DUT" FAB; invoking it + entering a name appends a `PlcStructDef`; each DUT card has edit + delete icons; delete of an IN-USE DUT shows a blocking message and does NOT remove it; delete of an unused DUT removes it; the edit dialog renames the DUT and can add/remove a field. Run → FAIL.
- [ ] **Step 4: Implement UI** in `_buildStructDefsTab` (`memory_manager_screen.dart:518-545`):
  - Wrap in a `Scaffold` with a `FloatingActionButton.extended(icon: Icons.add, label: 'Add DUT', onPressed: _showAddStructDialog)` (mirror the Tags tab FAB at `:211-216`).
  - `_showAddStructDialog`: dialog with a name `TextField` (validate non-empty, unique vs existing `structDefs` names AND `builtinCompositeNames()`); on confirm `setState(() => widget.currentProject.structDefs.add(PlcStructDef(name: name, fields: [])))` + the screen's project-update/persist call.
  - On each DUT card, add trailing `edit` and `delete` `IconButton`s.
    - `delete`: if `structDefInUse(project, s.name)` → show an `AlertDialog` naming the referencers and return; else confirm + `structDefs.remove(s)` + persist.
    - `edit` → `_showEditStructDialog(s)`: a stateful dialog to rename (via `renameStructDef` on confirm if changed) and manage fields — a list of field rows each with name `TextField`, dataType `DropdownButton` (scalar types + existing DUT names + `TIMER`/`COUNTER`, matching the Add-Tag dialog's type list), optional array-length field; add-field button appends a `StructFieldDef(name:'Field${n}', dataType:'BOOL', defaultValue:false)`; remove-field button drops it. On confirm, write the edited fields back to `s.fields` + persist.
  - All mutations go through the screen's existing project-update/autosave path.
- [ ] **Step 5: Gates + commit.** Tests green; analyze ZERO; no overflow. Commit `feat(memory): struct definition CRUD (add/edit/delete DUTs + fields, in-use guard, rename cascade)`.

---

### Task 5: Validation, round-trip & final review

**Files:**
- Test: `mobile/test/serialization_roundtrip_test.dart`

- [ ] **Step 1: Round-trip test**: build a project, add a user DUT with 2 fields via the helpers, rename it (cascade), bind a tag to it; `toJson` → `fromJson` → assert the struct def (name + fields) and the tag's `dataType` survive deep-equal.
- [ ] **Step 2: Full gates.** `cd mobile && flutter test` (ALL green), `flutter analyze` ZERO, `flutter build web --release` compiles, branding grep `grep -riE "openplc|beremiz|codesys|rslogix" mobile/lib mobile/test` clean, no RenderFlex overflow in the responsive suite at 320/1400. Discard plugin churn.
- [ ] **Step 3: Commit** `test(ws23): struct-def round-trip + validation`, then hand the branch to the final whole-branch review (superpowers:requesting-code-review) and merge via superpowers:finishing-a-development-branch.

---

## Self-review notes
- **Spec coverage:** §A HMI gate → T1A; §B autocomplete → T1B; §C LD ＋ → T1C; §D FBD title + LD compare name → T2; §E inspector expand → T3; §F struct CRUD (helpers + UI + in-use guard + rename cascade) → T4; round-trip/gates → T5.
- **Type consistency:** `structDefInUse(PlcProject, String) -> bool`, `renameStructDef(PlcProject, String, String) -> void`, `childrenOf`/`readPath` (existing), `FbdBlock.title`, `LdNode.variable`, `addOutputCoil(rung)` (existing) used consistently.
- **No schema change:** reuses existing model fields + serialization; WS6 round-trip guard asserted in T5.
- **YAGNI:** per-child forcing deferred (display-only inspector rows); add-output moved to header rather than a new phantom-lane widget; no LD/FBD engine changes.
