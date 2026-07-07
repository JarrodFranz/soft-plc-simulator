# Editor / HMI / Inspector Fixes & DUT Tooling (WS23) Design

**Date:** 2026-07-07
**Status:** Approved by user (chat, 2026-07-07): all recommended defaults + the LD Compare-block name field.
**Area:** `hmi_dashboard_builder_screen.dart`, `tag_autocomplete_field.dart`, `ld_editor_screen.dart`, `fbd_editor_screen.dart`, `tag_inspector_dock.dart`, `memory_manager_screen.dart`, `project_model.dart` / `tag_resolver.dart` helpers.

## Problem

Six issues reported from the running app:

1. **HMI edit chrome leaks into Run Mode.** The wide-card (≥360px) layout branch in `hmi_dashboard_builder_screen.dart` appends `_componentHeaderControls(...)` (the −/N Col/+/gear/trash row) **unconditionally**, unlike the narrow-card branch which wraps it in `if (isEditMode)`. Any 2-column-span widget (the status pill / label defaults to `gridSpanWidth: 2`) hits the wide branch and shows edit controls in Run Mode.
2. **Tag autocomplete: clicking a suggestion doesn't fill the field.** In `tag_autocomplete_field.dart`, the suggestion overlay is a separate subtree; tapping it drops focus from the field, whose `_onFocusChanged` listener calls `_removeOverlay()` synchronously, tearing down the suggestion `InkWell` before its `onTap`/`_onSelect` fires. The typed text is left unchanged.
3. **LD "add output" ＋ is mispositioned.** `_addOutputTarget` positions the ＋ on a phantom lane `maxLane+1` that lives in reserved empty space *below* the rung's real content (a coil-mode `_rungHeight + _kContactH + _kLaneGap` reservation). It sits inside the rung's border but visually reads as belonging to the gap / next rung. Separately, the compact/mobile pan path under-counts per-rung chrome as `44` px (real ~54–58), clipping content near the list bottom.
4. **Can't rename function blocks.** FBD blocks have a persisted `FbdBlock.title`, but `_showConfigureBlockDialog` never exposes it (only shows read-only `Block Type` + a tag-binding field). LD **Compare** data blocks likewise have no instance-name field.
5. **Tag Inspector can't expand DUTs.** `tag_inspector_dock.dart` renders a composite tag's value as a raw `Map.toString()` (`{EN: false, …}`) with no expand affordance, even though `childrenOf`/`readPath` exist and the Memory Manager already has an expandable-row pattern.
6. **Struct Definitions (DUT) tab is read-only.** `_buildStructDefsTab` is a view-only `ExpansionTile` list; there is no add / edit / delete for DUTs or their fields (the Tags tab has an "Add Tag" FAB; this tab has none).

## Goal

Fix the three bugs and add three contained capabilities: rename FBD/LD-compare blocks, expand DUT tags in the inspector to see child values, and full CRUD on struct definitions.

## Decisions (locked)

- **(3)** Reposition the add-output ＋, not remove it.
- **(4)** Include the LD Compare-block name field.
- **(5)** v1 shows child values (read-only display in the inspector); per-child *forcing* is deferred (whole-tag force stays on the parent — a per-child force set is a model change out of scope here).
- **(6)** Deleting an in-use DUT is blocked with a message; renaming a DUT cascades to referencing tags (and nested struct fields).

## A. HMI run-mode chrome (bug 1)

`hmi_dashboard_builder_screen.dart`, wide-card branch (~line 529): wrap the `..._componentHeaderControls(comp, index, components)` spread in `if (isEditMode) ...[ ... ]`, exactly mirroring the narrow-card branch (~lines 546–553). No other change; buttons/toggles/LED already render clean. Result: in Run Mode no component (any span) shows the resize/gear/trash row.

## B. Tag autocomplete selection (bug 2)

`tag_autocomplete_field.dart`: wrap **both** the visible `TextField` (build, ~line 161) and the overlay content (`_showOverlay`, the `Material`/`ListView` of suggestions) in a `TextFieldTapRegion` sharing one `groupId` (or the default), so a tap on a suggestion is not treated as a tap "outside" the field — focus is retained, the overlay is not torn down, and `_onSelect` runs (setting `_controller.text` + calling `widget.onChanged(value)`). Keep the existing `_onSelect` body. This fixes selection for every consumer (LD/FBD dialogs, HMI config, Memory Manager add-tag).

## C. LD add-output ＋ placement (bug 3)

Relocate the "add output coil" affordance out of the phantom lane into the **rung header action cluster** (next to the WS21 ▲/▼/trash icons in `_buildRungCanvas`'s header row): a small `IconButton` (e.g. `Icons.add`, cyan, tooltip "Add output") that calls the existing `addOutputCoil(rung)` + opens the edit dialog. Remove `_addOutputTarget` (the phantom-lane `Positioned`) and the coil-mode height reservation (`_editMode == 'coil' ? _rungHeight + _kContactH + _kLaneGap : _rungHeight` → just `_rungHeight`), and the matching `rungExtra` term in the compact `contentHeight` estimate. This makes the affordance unambiguously part of its own rung, needs no reservation, and cannot bleed into an adjacent rung at any pane width. Also fix the compact-path chrome constant: replace the hard-coded `44` in the `contentHeight` accumulation with the actual per-rung chrome height (container `vertical: 10`×2 + header row ≈ 28 + `bottom: 6` ⇒ use `58`, or compute it), so the pannable `SizedBox` isn't undersized. Coil-mode wire-insert targets (placing a coil on a genuinely open terminal) are unchanged.

**Binding requirement:** the add-output ＋ must render visually within its own rung and never overlap or appear to belong to an adjacent rung, at 320/360/1400 px.

## D. Block naming (feature 4)

**FBD** (`fbd_editor_screen.dart` `_showConfigureBlockDialog`, ~line 372): add a "Block name" `TextFormField` bound to a `pendingTitle` seeded from `block.title`; on Save, `block.title = pendingTitle` (alongside the existing `tagBinding` write). The block face already renders `block.title`, so the rename shows immediately.

**LD Compare blocks** (`ld_editor_screen.dart` `_showEditNodeDialog`): Compare (`GT/LT/GE/LE/EQ/NE`) currently shows only operand A / operator / operand B. Add a "Name" `TextField` bound to `n.variable` (cosmetic label; the compare engine writes nothing, so `variable` is a display label). `_buildDataBlock` renders `n.variable` on the compare block face when non-empty (a small line, same treatment as the math output line, guarded so it fits `_kBlockH` at 320 px).

## E. Tag Inspector DUT expansion (feature 5)

`tag_inspector_dock.dart`: for a tag whose value is composite/structured (detect via `childrenOf(project, tag.name).isNotEmpty`, reusing the resolver), replace the raw map-string value with an **expand chevron**. Track expanded tag names in a `Set<String> _expandedTags`. When expanded, render indented child rows (each: member label e.g. `.EN`, and its live value via `readPath(project, child.path)`), recursively for nested composites/arrays/integer-bit children — mirroring `memory_manager_screen.dart`'s `_buildRowData`/`_childRowData`/`_toggleExpand` pattern. Child rows are **read-only display** (monitoring); the whole-tag Force control stays on the parent row unchanged. Scalar tags render exactly as today (no chevron).

## F. Struct Definitions CRUD (feature 6)

Make `_buildStructDefsTab` a real editor:
- **Add DUT** FAB (mirroring the Tags tab's "Add Tag" FAB) → a dialog to enter a DUT name (unique, non-empty, not a built-in composite name) → appends an empty `PlcStructDef` to `project.structDefs`.
- Per-DUT **edit** (an edit icon on the card): a dialog to rename the DUT and manage its fields — each field row = name + data type (dropdown of scalar types + existing DUT names + `TIMER`/`COUNTER`; matches how the Add-Tag dialog picks types) + optional array length; add-field / remove-field / reorder within the dialog.
- Per-DUT **delete** (trash icon): **blocked** if the DUT is in use — a `structDefInUse(project, name)` helper checks any `PlcTag.dataType == name` or any `StructFieldDef.dataType == name` across all structs; if in use, show a dialog listing referencers and cancel. If unused, remove it.
- **Rename cascade:** a `renameStructDef(project, oldName, newName)` pure helper updates every `PlcTag.dataType` and `StructFieldDef.dataType` equal to `oldName` → `newName`, then renames the def. Built-in composites (TIMER/COUNTER) never appear here (they live in `_builtinComposites`, not `structDefs`), so they can't be edited/deleted.

Pure helpers (`structDefInUse`, `renameStructDef`, and an `addStructField`/`updateStructField`/`removeStructField` set or direct list ops) live in `tag_resolver.dart` (or `project_model` helpers) and are unit-tested. All mutations call the screen's existing project-update/autosave path so changes persist and are undoable where the shell already wraps edits.

## Testing

- **Pure unit** (`tag_resolver_test.dart` or a new file): `structDefInUse` true/false across tag + nested-field references; `renameStructDef` updates all referencers and the def; add/remove/update field ops; `childrenOf` already covered.
- **Widget:**
  - HMI: a 2-col status-pill component in **Run Mode** shows NO gear/trash/col controls; in Edit Mode it does (`hmi` builder test).
  - Autocomplete: typing then tapping a suggestion sets the field text AND fires `onChanged` with that value (`tag_autocomplete_field_test.dart`).
  - LD: the add-output ＋ lives in the rung header, tapping it adds an output coil; NO ＋ sits in reserved space below the rung; no overflow 320/1400; compact content height accommodates all rungs.
  - FBD: the config dialog has a "Block name" field; editing + Save renames the block face. LD Compare dialog has a Name field bound to `variable`, shown on the block face.
  - Inspector: a composite tag shows a chevron and expands to child rows with values; a scalar tag has no chevron.
  - Memory Manager: Add DUT appends a def; edit renames + adds/removes fields; delete of an in-use DUT is blocked with a message; delete of an unused DUT removes it; rename cascades to a referencing tag's dataType.
- **Round-trip:** a project with a user DUT (added/renamed with fields) survives `toJson`/`fromJson`.
- Full `flutter test` green, `flutter analyze` ZERO, `flutter build web --release` compiles, no branding, dark mode, no RenderFlex overflow at 320/360/1400.

## Global constraints

- No vendor branding; IEC terms fine. Zero analyze warnings; no overflow 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- Additive/lossless persistence: struct-def edits use existing `PlcStructDef`/`StructFieldDef` serialization (no schema change); the WS6 round-trip guard stays green. No LD/FBD model schema changes beyond using existing fields (`FbdBlock.title`, `LdNode.variable`).
- Pure logic (`tag_resolver`, `project_model`) stays Flutter-free; force-aware behavior unchanged (inspector child rows are display-only).

## Phasing (one spec → plan tasks)

1. **Bug sweep** — HMI run-mode gate (A), autocomplete tap region (B), LD add-output relocation + height fixes (C). Independently shippable, high-value, low-risk.
2. **Block naming** — FBD title field + LD Compare name field + compare-face render (D).
3. **Inspector DUT expansion** — chevron + child rows in the tag inspector (E).
4. **Struct Definitions CRUD** — helpers (`structDefInUse`/`renameStructDef`/field ops) + Add/Edit/Delete UI + in-use guard + rename cascade (F).
5. **Validation + round-trip + final review.**
