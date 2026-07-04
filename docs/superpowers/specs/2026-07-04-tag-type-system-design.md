# Tag & Type System (WS2) — Design Spec

**Date:** 2026-07-04
**Status:** Draft for review
**Author:** Claude (pairing with Jarrod)

Workstream 2 of the editor-improvement effort. WS1 (ladder correctness) is done
and merged. WS3 (simulated-inputs engine) is a later, separate spec.

## Problem

The tag/type system is flat and partly faked:

- `PlcTag.value` is a single `dynamic`. There is no real storage for structured
  values. The `TONTimer` tag's value is the literal **string**
  `"Struct [PRE: 5000, ACC: 0]"` — its members (`EN`, `TT`, `DN`, `PRE`, `ACC`)
  don't exist as data.
- Struct/member expansion in the Memory Manager is **hardcoded for `TIMER`
  only** (`memory_manager_screen.dart` `_ensureTimerParentTags`,
  `isTimer && isParentExpanded`). Top-level integer tags don't expand to bits;
  only integer *children of a timer* do.
- There are **no array tags**.
- **DUTs and Data Blocks are separate**: `PlcStructDef` defines a type,
  `PlcDataBlock` is an instance in its own tab. The user wants an instance to
  simply be a **tag whose datatype is a DUT**.
- Ladder/other references like `TONTimer.DN` are **unresolved literals** — the
  edit dialog offers no real member to bind to ("tag/literal but no actual tag
  configured").

## Decisions (confirmed with user)

1. **Value model:** derived / path-resolved. Each parent tag holds one
   structured value; members/bits/elements are addressed by path and resolved on
   demand (not materialized as separate tag rows).
2. **Nesting:** recursive. A DUT field or array element may itself be a struct,
   array, or composite (e.g. `Motors[2].Timer.DN`; a struct with an `INT16[8]`
   field whose bits expand).
3. **Data Blocks:** retire the Data Blocks tab; a struct-typed tag *is* the
   instance; migrate existing instances to tags. **DUTs are still defined in the
   Struct Definitions editor.**
4. **Scan integration:** route `_getTag*`/`_setTag*` through the resolver so a
   tag "address" can be a path; existing flat-name physics keep working.
5. **Path syntax:** `.field` for struct/DUT/composite members, `.N` (numeric)
   for integer bits, `[i]` for array elements. Example: `Motors[2].Timer.DN`,
   `StatusWord.5`, `Recipe[3]`.
6. **Bit expansion:** `INT16` → 16 bits, `INT32` → 32, `INT64` → 64. Not
   `BOOL`/`FLOAT64`/`STRING`.
7. **Array creation:** pick a base/DUT type + an array length.

## Architecture

### Type model (`project_model.dart`)

- `PlcTag` gains `int arrayLength` (0 = scalar/composite; >0 = array of the base
  type). `dataType` becomes the **base type**: a scalar (`BOOL`, `INT16`,
  `INT32`, `INT64`, `FLOAT64`, `STRING`), a **composite** (`TIMER`), or a **DUT
  name**.
- `StructFieldDef` gains `int arrayLength` so a DUT field can be an array, a
  composite, or another DUT (recursive nesting).
- **Built-in composites** are implicit DUTs from a registry, not special cases:
  `TIMER = { EN:BOOL, TT:BOOL, DN:BOOL, PRE:INT32, ACC:INT32 }`. The resolver
  treats a composite type name like a DUT by looking it up in
  `builtinComposites ∪ project.structDefs`. (Registry is structured so `TOF`,
  `CTU`, etc. can be added later; only `TIMER` ships now.)
- `PlcDataBlock` and `PlcProject.dataBlocks` are **removed** (migrated to tags).

### Structured value storage

`PlcTag.value` (and nested values) hold real structure:

- scalar → `bool` / `int` / `double` / `String`
- composite / DUT (arrayLength 0) → `Map<String, dynamic>` keyed by field name,
  values initialized recursively
- array (arrayLength > 0) → `List<dynamic>` of length `arrayLength`, elements
  initialized recursively to the base type's default

All of these are JSON-serializable, so `PlcTag.toJson`/`fromJson` continue to
work for save/load (round-trip verified in tests).

### Path resolver (`mobile/lib/models/tag_resolver.dart` — new, pure Dart)

The core new unit. No Flutter imports; unit-tested in isolation. Public API:

- `PlcStructDef? lookupComposite(PlcProject p, String typeName)` — DUT def for a
  DUT/built-in composite name, else `null` (scalar).
- `bool isIntegerType(String base)` and `int bitWidth(String base)` (16/32/64).
- `dynamic defaultValueFor(PlcProject p, String base, int arrayLength)` —
  recursive default initializer (scalar default, map of field defaults, or list
  of element defaults).
- `dynamic readPath(PlcProject p, String path)` — walk: first segment = tag
  name; then `.field` into a map, `[i]` into a list, `.N` into a bit (returns
  `bool`). Returns the leaf value (or `null` if the path is invalid).
- `void writePath(PlcProject p, String path, dynamic value)` — walk and set,
  including bit set/clear on the parent integer.
- `List<TagChild> childrenOf(PlcProject p, String path)` — for expansion. Given a
  path to a composite/array/integer, returns children:
  `TagChild { String label; String path; String dataType; int arrayLength;
  dynamic value; bool hasChildren; }`. Composite → field children; array → index
  children (`[0]…`); integer scalar → bit children (`.0…`).
- `List<String> leafAndNodePaths(PlcProject p)` — addressable paths for editor
  tag pickers: tags plus composite members and array elements, recursively.
  Integers are treated as **leaves** here (individual bits are addressable via
  `writePath` and expandable in the Memory Manager tree, but are **not**
  enumerated in this flat list, to avoid exploding the picker). Pickers may also
  expand lazily via `childrenOf`.

Path parsing splits on `.` and `[`. A numeric segment under an integer is a bit;
a named segment under a composite is a field; `[i]` indexes an array. Invalid
paths resolve to `null` (callers guard).

### Memory Manager UI (`memory_manager_screen.dart`)

- **Tabs reduced to two:** *Tags* and *Struct Definitions (DUT)*. The Data Blocks
  tab and `_buildDataBlocksTab` are removed; `_ensureTimerParentTags` and the
  hardcoded TIMER expansion are removed.
- **Generic recursive expansion:** each tag row asks the resolver whether it has
  children (composite/array/integer). If so it shows an expand toggle; expanding
  renders `childrenOf(...)` rows, each itself expandable, to arbitrary depth,
  using the existing `_expandedTagKeys` set keyed by full path.
- **Tag-create dialog:** a type picker (scalars + `TIMER` + DUT names) and an
  array-length field (0 = scalar). On create, `value` is initialized via
  `defaultValueFor`.
- **Struct Definitions editor:** extended so a field's type may be a scalar,
  `TIMER`, another DUT, or an array (base type + array length).
- **Leaf editing/forcing:** value edit, bit toggle, and force act on the leaf via
  `writePath` (replacing `_toggleBitValue`'s direct int mutation with the
  resolver's bit write).

### Consumer integration

- **Scan engine** (`workspace_shell.dart`): `_getTagBool/_getTagDouble/
  _getTagInt/_setTag*` route through `readPath`/`writePath`. A flat name is just a
  one-segment path, so existing per-project physics are unchanged; member/bit/
  element addresses now also work.
- **Editor tag pickers** (LD edit dialog, and the ST/FBD/SFC autocomplete
  palettes that list `project.tags`): offer resolvable paths from
  `leafAndNodePaths` (a searchable, expandable list), so a contact can bind a
  real `TONTimer.DN`. This closes the "tag/literal with no actual tag" gap.
- **Tag inspector dock:** unchanged for top-level tags; may show composite tags
  with an expand affordance (reusing the resolver) — nice-to-have, not required.

### Migration (`default_projects.dart` + a one-time in-memory convert)

- Convert every existing `PlcDataBlock` into a struct-typed `PlcTag`
  (`dataType = structTypeName`, `value` = map built from `fieldValues` merged
  over DUT field defaults).
- Replace the faked string `TONTimer` with a real `TIMER`-typed tag (value =
  `{EN:false, TT:false, DN:false, PRE:5000, ACC:0}`); ensure `JamTimer`/
  `BackwashTimer` are `TIMER`-typed too.
- **Showcase:** add one array tag (e.g. `Recipe_Steps : INT16[8]`) and one
  user DUT + a DUT-typed tag to a default project so the features are visible out
  of the box.

## Testing

- `mobile/test/tag_resolver_test.dart` (pure): `readPath`/`writePath` for a
  scalar, a struct member, a nested array-of-struct member, and an integer bit;
  `childrenOf` for composite / array / integer; `defaultValueFor` recursion;
  JSON round-trip of a struct-typed and an array tag.
- `mobile/test/widget_test.dart`: Memory Manager pumps without overflow with a
  struct-typed tag expanded; existing app smoke + LD gates still pass.
- Chrome: create a DUT, make a DUT-typed tag and an array tag, expand a TIMER to
  its members and an INT16 to bits, force a member, and pick `TONTimer.DN` in the
  LD edit dialog.

## Global constraints (unchanged)

- No third-party / reference-editor branding in any user-facing string, label,
  comment, or identifier.
- Dark theme preserved. `flutter analyze` **zero** issues (`withValues(alpha:)`,
  `initialValue:` on dropdowns, braces on flow-control, prefer `const`).
- No RenderFlex overflow.

## Out of scope (deferred)

- **Timer/block execution.** `TONTimer.DN`/`ACC` become real addressable,
  forceable, referenceable values, but nothing auto-counts them until the
  simulated-logic engine (WS3) drives them; for now they are static/forceable.
- Executing LD/FBD/SFC graphs generally (still hardcoded per-project physics).
- Persisting projects to disk beyond the existing in-memory + JSON model.
