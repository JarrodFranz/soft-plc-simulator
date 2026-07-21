# Tag Value Editing — Design Spec

**Date:** 2026-07-21. **Status:** user-approved design, pre-plan.
**Scope:** three related UX capabilities around tag values — a default value on
tag creation, an edit-config path for an existing tag's type/default, and live
runtime-value editing from both the Tag Inspector and the "Tags & Structs"
(Memory Manager) view.

## Goal

Let a user (1) set a **default value** when adding a tag, (2) **open an
existing tag's config** to change its data type and/or default value, and (3)
edit a tag's **live runtime value** (e.g. `TEMP_SP` 70 → 80) from the Tag
Inspector and the Tags & Structs view — all while respecting the running scan
engine, the force mechanics, and the reserved-`System` rule.

## Context (verified on-branch)

- `PlcTag` (`mobile/lib/models/project_model.dart:11`) today has a **single**
  `dynamic value` field, serialized as `initial_value`, that is BOTH the
  load-time initial value AND the live value the scan mutates.
  `isForced`/`forcedValue` are the scalar-only force override.
- The **Add Tag dialog** (`memory_manager_screen.dart:394`) collects
  name/path/type/array-length/IO but **no value** — it seeds the tag via
  `defaultValueFor(project, dataType, arrayLength)`
  (`tag_resolver.dart:133`).
- There is **no edit-tag-config dialog**. A Memory Manager row taps to toggle
  BOOL / expand a composite / delete.
- **Live editing today is BOOL-only**: both the Tag Inspector
  (`widgets/tag_inspector_dock.dart`) and Memory Manager let you tap a BOOL
  pill to flip it, writing `forcedValue` when the tag is forced else `value`.
  A separate **Force** lock makes a value hold against logic. Analog/string
  values are not editable.
- Writes go through `writePath(project, path, value)`
  (`tag_resolver.dart:318`), which resolves nested paths. The protocol
  write-gate `isExternallyWritable` (`tag_write_gate.dart:53`) is the backstop
  for EXTERNAL (protocol) writes; local operator actions (BOOL toggle, force)
  write the model directly and are gated only by the reserved-`System` rule.

## Decisions taken (user-approved)

1. **Distinct persisted `defaultValue`** (not the single value). Motivated by
   a planned future PLCopen-XML import where variables declare an
   `<initialValue>`. `defaultValue` is the *declared* initial; `value` stays
   the live runtime value.
2. **Live edit = poke** (write the value; the scan overwrites it next cycle if
   logic/sim drives the tag), consistent with today's BOOL toggle. **Force**
   remains the separate, explicit "make it stick" lock — editing never
   auto-forces.
3. **Name/path stay immutable** in the edit dialog. Renaming/re-pathing would
   break logic and protocol-map references by path/name; it is a separate
   future feature with its own reference-rewrite pass.
4. One **shared scalar value-editor widget** renders the right control per
   data type and is reused across add-default, edit-default, and live-edit —
   DRY, one coercion path.

## Non-goals / YAGNI

- The PLCopen-XML import itself (this only lays the `defaultValue` foundation).
- Rename / re-path a tag (identity is immutable here).
- Editing a **composite/array** tag's default as a structured value —
  composites keep their existing struct-field defaults
  (`StructFieldDef.defaultValue`); the default-value UI is **scalar-only**.
- Resetting the live value to default on every scan start (that would wipe a
  running sim). Reset is an explicit per-tag action only.
- Bulk / multi-tag value editing.

## Global Constraints

- Pure Dart for the model + helper layers (no Flutter, no `dart:io`); UI in
  `screens/` + `widgets/`.
- **Additive / backward-compatible serialization**: a project JSON without
  `default_value` loads with `defaultValue` derived from the existing
  `initial_value`; existing projects round-trip byte-identically for `value`.
  The lossless round-trip suite stays green.
- Reserved-`System` tag is never renamable, and its live value / default are
  not user-editable (matches today's exclusion in the inspector/toggle).
- Deterministic; no clock/RNG in the coercion or model logic.
- Dark theme; `withValues(alpha:)` not `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320 / 360 / 1400.

## Component 1 — Model: the `defaultValue` field

`PlcTag` gains `dynamic defaultValue`.

- **Constructor**: `this.defaultValue` (optional). When omitted at
  construction the field is left null and treated as "same as the type
  default" by consumers (see `effectiveDefault` below).
- **`fromJson`**: `defaultValue: json['default_value'] ?? json['initial_value']
  ?? json['value']` — an old project (no `default_value`) adopts its saved
  `initial_value` as the declared default, so nothing regresses.
- **`toJson`**: emit `'default_value': defaultValue` alongside the existing
  `'initial_value': value` (unchanged). Both persist; `value` continues to be
  the live value restored on load, `defaultValue` the declared initial.
- A small **`PlcTag` method** `dynamic effectiveDefault(PlcProject p)` returns
  `defaultValue ?? defaultValueFor(p, dataType, arrayLength)` so callers never
  have to special-case null (it reads the tag's own
  `dataType`/`arrayLength`/`defaultValue` and only needs the project to
  resolve a composite's structural default).

Composite/array tags: `defaultValue` is only written for scalars; a composite
tag's `defaultValue` stays null and `effectiveDefault` falls through to the
existing structural default.

## Component 2 — Pure helper: scalar value coercion

New pure function in `tag_resolver.dart` (beside `defaultValueFor`):

```
dynamic coerceScalarValue(String dataType, String input)
```

Parses a user-typed string into the runtime type the tag expects, mirroring
`defaultValueFor`'s type table:

- `BOOL` → `true`/`false` (accepts `true/false/1/0/on/off`, case-insensitive).
- `INT16` / `INT32` / `INT64` → `int` (`int.tryParse`; on failure, the
  type default `0`).
- `FLOAT64` → `double` (`double.tryParse`; on failure `0.0`).
- `STRING` → the string verbatim.
- Any composite/unknown → the type's structural default via
  `defaultValueFor` (the caller should not offer scalar editing for these).

A companion `dynamic coerceValueToType(PlcProject p, dynamic current, String
newDataType, int arrayLength)` re-coerces an EXISTING value when a tag's type
changes (Component 4): BOOL↔number↔string best-effort, else the new type's
`defaultValueFor`. Both are pure and unit-tested with literal cases.

## Component 3 — Shared scalar value-editor widget

A reusable widget `ScalarValueField` (`widgets/scalar_value_field.dart`):

- **Input**: `dataType`, current value, `onChanged(dynamic)`.
- **Renders** per type: BOOL → a `Switch` (or true/false dropdown); numeric →
  a numeric `TextField`; STRING → a text `TextField`. Non-scalar types render
  a disabled "structured default (edit fields in the struct editor)" note.
- **Emits** a coerced value (via Component 2) on change.
- Dark-theme styled, dense, `Key`-ed for tests.

Used by the Add dialog (Component 4a), Edit dialog (4b), and the live-edit
inline editor (Component 5).

## Component 4 — Add + Edit tag config dialogs (Memory Manager)

**4a. Add Tag dialog** (`_showAddTagDialog`, `memory_manager_screen.dart:394`)
gains a **Default value** row rendered by `ScalarValueField`, shown only when
the selected type is scalar and array length is 0. On "Add Tag":
`defaultValue` = the entered value; the initial live `value` = the same entered
value (so the tag starts where declared). For composite/array types the row is
hidden and behavior is unchanged (`defaultValueFor`).

**4b. Edit Tag Config dialog** (new, `_showEditTagDialog(PlcTag)`), opened from
a per-row **edit (pencil) affordance** in the Memory Manager tag list (beside
the existing delete). Fields:

- Name / Path — shown **read-only** (identity is immutable; a helper caption
  says renaming is not supported yet).
- **Data type** dropdown — same list as Add. Changing it re-coerces BOTH
  `defaultValue` and the live `value` via `coerceValueToType`.
- **Default value** — `ScalarValueField` for the (possibly new) scalar type.
- **Access** (ReadWrite/ReadOnly), **Description**, **Engineering units** —
  plain fields (safe, non-identity).
- A **"Reset live value → default"** button that sets `value =
  effectiveDefault`, so an operator can snap a poked/forced tag back to its
  declared default. (If forced, it also clears the force — resetting to
  default implies releasing the hold; documented in the button's tooltip.)
- Save applies the edits and calls `onProjectUpdated()`. The reserved `System`
  tag's row shows no edit affordance.

The Add and Edit dialogs share the same field-rendering helpers where they
overlap (type dropdown + `ScalarValueField`), so the two stay visually and
behaviorally consistent.

## Component 5 — Live value editing (Inspector + Tags & Structs)

The value pill in both surfaces becomes editable for **scalar** tags and
**scalar leaves** of composites:

- **BOOL** keeps its current tap-to-toggle (no change).
- **Numeric / STRING**: tapping the pill opens a compact inline editor (a small
  popover/dialog with a single `ScalarValueField` + OK/Cancel). On OK, coerce
  the input and write with the **exact existing rule**:
  - if the (root) tag `isForced` → write `forcedValue` (the held value),
  - else → `writePath(project, path, coercedValue)` (a poke; scan may
    overwrite).
- The reserved `System` tag is excluded (as today). Nested scalar leaves work
  because `writePath` resolves nested paths (the BOOL toggle already relies on
  this).
- Repaints ride the existing `LiveTick` (both surfaces already rebuild their
  value pills on the tick), so an edited value shows immediately and continues
  to reflect scan updates.

Force is untouched: the Force/Unforce lock still exists separately; editing a
forced tag edits the value it holds.

## Data flow

Add/Edit dialog → sets `PlcTag.defaultValue` / `dataType` / `value` in the
model → `onProjectUpdated()` (autosave + rebuild). Live edit → `ScalarValueField`
→ coerce → `writePath` (or `forcedValue`) → `LiveTick` repaints. Serialization
round-trips `default_value` + `initial_value`. Nothing touches the protocol
hosts or the scan engine's contract — the scan keeps reading/writing `value`
exactly as before.

## Error handling / edge cases

- Non-parseable numeric input coerces to the type default (never throws); the
  field can show a subtle "using 0" hint but must not block.
- Type change on a tag referenced by logic/protocol maps: the value is
  re-coerced; references resolve by path (unchanged), so they keep working —
  a type the referencing logic doesn't expect is the user's responsibility
  (same posture as the existing struct-field type change).
- Editing while the scan runs: a poke that logic overwrites next cycle is
  expected and correct (documented in the inline editor's helper text:
  "Force to hold").
- `System` tag: no edit affordance, no live-edit, no rename — enforced in the
  UI, matching the model-layer reserved rule.
- Array/composite tags: no scalar default/live editor; their leaves (scalars)
  are individually editable where shown.

## Testing

- **Model**: `defaultValue` round-trip; backward-compat (`default_value`
  absent → adopts `initial_value`); `toJson` emits both keys; lossless suite
  stays green.
- **Coercion**: `coerceScalarValue` and `coerceValueToType` unit tests with
  literal cases per type incl. bad input → type default, and BOOL↔number↔string
  conversions.
- **Widget**: `ScalarValueField` renders the right control per type and emits
  coerced values; Add dialog writes `defaultValue` + initial `value`; Edit
  dialog changes type (with re-coercion) and default, and "Reset live →
  default" works; live-edit writes `value` when unforced and `forcedValue`
  when forced (both Inspector and Tags & Structs); `System` shows no editor;
  no overflow at 320/360/1400.

## Files

- Modify: `models/project_model.dart` (`defaultValue` + `effectiveDefault`
  method), `models/tag_resolver.dart` (`coerceScalarValue`, `coerceValueToType`),
  `screens/memory_manager_screen.dart` (Add default field + Edit dialog + row
  edit affordance + live scalar edit), `widgets/tag_inspector_dock.dart` (live
  scalar edit).
- Create: `widgets/scalar_value_field.dart`.
- Tests: `test/tag_value_model_test.dart`, `test/tag_value_coercion_test.dart`,
  `test/scalar_value_field_test.dart`, additions to
  `test/memory_manager_*_test.dart` and `test/tag_inspector_*_test.dart`.

## Risks

- **Serialization drift**: mitigated by the additive fallback and the lossless
  round-trip suite.
- **Type-change value corruption**: mitigated by the coercion helper + tests;
  worst case a value falls back to the new type's default.
- **Live-edit vs scan race** is by-design (poke); the "Force to hold" hint sets
  the expectation.

## Decomposition (plan-time)

Likely four tasks:
1. Model `defaultValue` (+ `effectiveDefault`) with backward-compat serialization.
2. Pure coercion helpers (`coerceScalarValue`, `coerceValueToType`) +
   `ScalarValueField` widget.
3. Add default field + Edit Tag Config dialog + row edit affordance
   (Memory Manager).
4. Live scalar value editing in the Tag Inspector and Tags & Structs +
   whole-feature validation.
