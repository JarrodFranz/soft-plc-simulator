---
id: knowledge:app/tag-model
title: Tag Model
domain: app
version: "2026-08"
topics: [tag-resolver, tag-paths, write-gate, forcing, struct-fields, function-block-instances, system-tags, hmi-layout]
summary: The dotted/indexed tag-path grammar and its recursive Map/List resolver, the two-tier default value model, forcing semantics, and the two write-gate predicates (defaultsExternallyWritable vs isExternallyWritable) every protocol handler must consult independently of a mutated map.
related:
  - knowledge:app/index
  - knowledge:app/scan-engine
  - knowledge:app/protocol-hosting
  - knowledge:industry/iec61131/custom-function-blocks
learnings: [CL-13, CL-14]
---

# Tag Model

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/models/tag_resolver.dart`, `tag_write_gate.dart`,
> `system_tags.dart`, `project_model.dart` (`PlcTag`, `HmiComponent`), and
> `docs/task-scheduling.md`'s `System` UDT section.
> **Read this before:** writing or parsing a tag path, adding a protocol map or write handler,
> changing struct/array/function-block default-value behavior, or working with the reserved
> `System` tag.

---

## 1. The headline rule

**A tag's `value` is a real Dart tree (`Map` for structs, `List` for arrays, `int` for a
bit-holder), addressed by a dotted/indexed path string and walked on demand by one pure
resolver - there is no separate "Data Block" concept and no static value type.**

Per `DECISIONS.md` ADR-007, a struct-typed tag **is** its own instance: `PlcTag.value` holds
`bool | int | double | String | Map<String,dynamic> | List<dynamic>`, and `dataType`/
`arrayLength` declare what shape that value is *supposed* to be, without Dart statically
enforcing it. Every read, write, and UI-expansion of a tag - struct field, array element,
function-block instance member, or integer bit - goes through the same three functions:
`readPath`, `writePath`, `childrenOf` (`mobile/lib/models/tag_resolver.dart`).

---

## 2. Path grammar and the resolver

The tokenizer, `_segments` (`tag_resolver.dart:365-400`), recognizes three segment kinds:

| Syntax | Meaning | Example |
|---|---|---|
| `.name` | struct/FB-instance field access | `Tank.Level` |
| `[N]` | array index | `Recipe_Steps[0]` |
| `.N` (bare digit, on an integer-typed non-array node) | integer bit access | `Word.2` |

`readPath`/`writePath` (`tag_resolver.dart:457-508`, `:512-569`) walk a path's segments against
the root tag's declared type, recursing into `Map` (struct), `List` (array), or testing/setting
a single bit of an `int`, at every level. **A function-block instance is not a separate code
path.** An FB instance tag's `dataType` equals its `FbDefinition`'s name, and `lookupComposite`
(`tag_resolver.dart:170-201`) synthesizes a `PlcStructDef` from `FbDefinition.vars` whenever no
real struct or built-in composite matches that name - so `Instance.LocalVar` resolves exactly
like `Struct.Field`, with struct/built-in lookups taking priority ("an FB definition never
shadows a struct"). Built-in composites - `TIMER`, `COUNTER`, `SYSTEM` - are hardcoded
(`tag_resolver.dart:22-60`) and never need to be declared in a project's `structDefs`.

## 3. Value model and defaults

`PlcTag.value` is untyped (`dynamic`); its runtime shape must agree with `dataType`/
`arrayLength` by convention, not by the type system. Defaults are two-tiered:

- `PlcTag.defaultValue` (nullable) - the user-declared default, if any.
- `PlcTag.effectiveDefault(p)` = `defaultValue ?? defaultValueFor(p, dataType, arrayLength)` -
  falls back to the **structural** default, computed recursively by `defaultValueFor`/
  `_defaultValueFor` (`tag_resolver.dart:227-265`): `false`/`0.0`/`''`/`0` for scalars, a
  zero-valued `Map`/`List` built field-by-field for a struct/array. The recursion is
  cycle-safe (a `visiting` set bails out to an empty struct on a self-referencing or mutually
  recursive DUT graph, rather than stack-overflowing on malformed project JSON).

**Every declared composite default is deep-cloned per instance** (`_cloneDefault`,
`tag_resolver.dart:276-286`). This matters because `writePath` mutates containers *in place*:
handing the same `Map`/`List` object to every instance built from one declared default would
alias their state - two instances of the same function block, or two array elements of a
struct type, would silently share one nested timer/struct rather than owning independent copies.

## 4. Forcing

A forced **scalar** root tag resolves to `forcedValue` on every read, not just in the UI:
`readPath` seeds its walk from `root.forcedValue` whenever `root.isForced && root.value is!
Map && root.value is! List` (`tag_resolver.dart:466-476`). This makes forcing authoritative
everywhere a value is read - logic executors, and every protocol handler, since they all read
through `readPath`. A composite (struct/array) tag's `isForced` is always `false` in practice
(the force UI only ever offers the toggle for scalar tags); the `Map`/`List` guard in the code
is defensive, not the primary gate.

## 5. The write-gate: two predicates, not one (CL-14)

**CL-14: The write path has two distinct predicates: `defaultsExternallyWritable` governs what
map auto-generation exposes as writable; `isExternallyWritable` is the hard per-write backstop
every protocol handler must also consult. System tags refuse writes even under a mutated map.**

Both live in `mobile/lib/models/tag_write_gate.dart` and both judge the **root** tag via
`rootTagOf` - a member path like `Tank.Level` is judged by `Tank`, never by the member itself.

```dart
// Auto-generation default only.
bool defaultsExternallyWritable(PlcProject project, String leafPath) {
  final root = rootTagOf(project, leafPath);
  return root != null &&
      root.name != kSystemTagName &&
      root.ioType != 'SimulatedOutput' &&
      root.access != 'ReadOnly';
}

// The write-time hard backstop.
bool isExternallyWritable(PlcProject project, String leafPath) {
  final root = rootTagOf(project, leafPath);
  return root != null && root.name != kSystemTagName && root.access != 'ReadOnly';
}
```

- **`defaultsExternallyWritable`** is consulted only when a protocol map is (re)built from a
  project's tags - one call site per protocol map file (`modbus_map.dart`, `opcua_map.dart`,
  `cip_map.dart`, `s7_map.dart`, `fins_map.dart`, `slmp_map.dart`, `dnp3_map.dart`,
  `bacnet_map.dart`, `mqtt_map.dart`). It additionally excludes `SimulatedOutput` tags, so a
  tag driven by the local simulation engine defaults to non-writable from an external client.
- **`isExternallyWritable`** is the **write-time** check every protocol write handler consults
  *in addition to*, never instead of, its own map entry - confirmed at the write sites in
  `modbus_pdu.dart` (FC05/FC06), `bacnet_object_image.dart`, `cip_tags.dart`, `s7_area_image.dart`,
  `opcua_services.dart`, `fins_area_image.dart`, `slmp_device_image.dart`, `dnp3_outstation.dart`,
  and `mqtt_publisher.dart`. It deliberately **omits** the `ioType != 'SimulatedOutput'` check -
  a user may hand-edit a `SimulatedOutput` tag's map entry to `ReadWrite` to drive that
  simulated field device from an external test harness, and that deliberate choice must still
  work. What it can never be overridden on is the reserved `System` tag (checked by **name**,
  `root.name != kSystemTagName`, independent of `System`'s own `access` field - "so this holds
  even if `System`'s own `access` were ever left at its default") and any tag the user declared
  `access: 'ReadOnly'` on the tag itself.

```
Wrong:  trust a protocol map entry's ReadWrite flag as sufficient authorization for a write.
Correct: every write handler must also pass the write through isExternallyWritable - the map
        entry and the hard backstop are two independent gates, and only both together
        authorize a write.
```

## 6. System tags are read-only, by name (with a documented caveat)

`kSystemTagName = 'System'` (`system_tags.dart:4`). `ensureSystemTag` injects the reserved
`System` tag (type `SYSTEM`, `access: 'ReadOnly'`) into a project the first time it's opened if
missing, and back-fills any struct fields a project predates (`system_tags.dart:62-91`) - so an
older project never opens without the newest status fields. Because `isExternallyWritable`'s
refusal is **root-name-based**, it refuses *every* path under `System.*` from an external
protocol write - including `System.AlarmReset`, the one field described as writable.

**Corrected 2026-08-07:** `docs/task-scheduling.md`'s "Clearing a fault" section previously
claimed *"`System.AlarmReset` - the reserved `System` tag's one writable control field. Any
writer (HMI button, an external protocol write, or program logic) can set `System.AlarmReset`
to `true`."* The code does not support the "external protocol write" case: `isExternallyWritable`
is gated on the root tag name alone, with no per-field carve-out, so any protocol handler
consulting it (all of them, per §5) refuses a write to `System.AlarmReset` exactly as it would
`System.Fault`. Grepping every `AlarmReset`-writing call site (`tag_inspector_dock.dart`,
`memory_manager_screen.dart`, `workspace_shell.dart`) confirms `AlarmReset` is writable **only
from in-app UI code**, which calls `writePath` directly and bypasses the protocol write-gate
entirely - `system_tags.dart:76`'s own tag description, `'SoftPLC system status (read-only;
AlarmReset writable)'`, is consistent with UI/local writability, not external. The doc now
states this explicitly. Treat the code as authoritative: `System.AlarmReset` cannot be set from
any of the nine protocol hosts today.

## 7. `HmiComponent` has no position field (CL-13)

**CL-13: `HmiComponent` has no x/y - HMI layout is grid-flow (`gridSpanWidth` only), so
component overlap is structurally impossible.** `HmiComponent`
(`mobile/lib/models/project_model.dart:912-931`) declares `id, title, type, tagBinding,
gridSpanWidth, accentColor, trendPens, windowMs` - no coordinate fields anywhere in the class
or its `fromJson`/`toJson`. A screen's layout is therefore entirely a function of component
order plus each component's `gridSpanWidth` (an `int`, default `1`); two components cannot be
made to overlap at the data-model level, because there is nothing to position them at
conflicting coordinates with.

---

## What this means practically

### "My tag path resolves in the editor but reads null at runtime - why?"
`readPath`/`dataTypeOfPath` return `null` on any unresolved segment - an unknown root tag, an
unknown struct field name, an out-of-range array index, or an out-of-range bit index all fail
silently rather than throwing (`tag_resolver.dart:432-508`). Check each segment against the
live struct/array shape, not just against what the editor's picker offered at design time.

### "A SCADA client can read `Tank.Level` but its write to the same path is refused - why?"
Two different checks apply to reads and writes. Reads go through `readPath` alone (forcing
aside, always allowed at the resolver level - the protocol layer decides read exposure via its
own map). Writes must additionally clear `isExternallyWritable` (§5) - a read-exposed path is
not automatically write-exposed.

### "I need a tag that's writable via one protocol's hand-edited map but the write silently no-ops - why?"
Check whether the tag's root is the reserved `System` tag or has `access: 'ReadOnly'` set on
the tag itself (§5, §6) - `isExternallyWritable` refuses both unconditionally, and no map edit
can override either.

---

## Related

- [scan-engine.md](./scan-engine.md) - every executor reads/writes through this same resolver.
- [simulation.md](./simulation.md) - `SimRule`s write through `writePath` too, with forcing
  checked separately (`_write` in `sim_engine.dart`).
- [protocol-hosting.md](./protocol-hosting.md) - the nine write handlers that consult
  `isExternallyWritable`.
- [../industry/iec61131/custom-function-blocks.md](../industry/iec61131/custom-function-blocks.md) -
  how FB instance state maps onto this same path-resolution model.
- [index.md](./index.md) - domain hub.
