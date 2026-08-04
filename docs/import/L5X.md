# Importing a PLC Program (Rockwell L5X)

The app can also import an existing PLC program from a **Rockwell L5X**
export (Studio 5000 / RSLogix 5000's `<RSLogix5000Content>` XML format) and
turn it into a brand-new Soft PLC project — this is the foundation delivery
of the L5X import program (sub-project 1 of several; see "Deferred" below).
Like the PLCopen import path, this is an **in-app, pure-Dart import**: no
companion service, no upload to a server.

```
Rockwell L5X .L5X file  --detect--> parseL5x --> map -->  preview  -->  NEW project
 (Studio 5000 / Logix                                     (review        (the
  Designer export)                                         name/counts/    active
                                                             warnings)      project
                                                                            is left
                                                                            untouched)
```

## What's supported (foundation)

- **User DataTypes → structs.** Each controller-scoped `<DataType Class="User">`
  becomes a `PlcStructDef`, with member types normalized to the app's tag type
  set and member default values (from `<DefaultData Format="Decorated">`)
  carried over.
- **AOIs (Add-On Instructions) → function blocks.** Each
  `<AddOnInstructionDefinition>` becomes an `FbDefinition`: its `Parameters`
  (excluding the implicit `EnableIn`/`EnableOut`) become the FB's input/
  output/internal vars, its `LocalTags` become internal vars, and — when its
  `Logic` routine (or the routine named `Logic`) is Structured Text — that ST
  body becomes the FB's executable logic. An AOI-typed controller or program
  tag resolves to that FB's composite (struct-shaped) default value, exactly
  like a struct-typed tag.
- **Controller + program tags → tags.** Every controller-scoped and
  program-scoped `<Tag>` becomes a flat-namespace `PlcTag` (program scoping is
  not preserved — cross-program name collisions are dedup-renamed the same
  way the PLCopen importer handles collisions). Scalar tags hydrate their
  initial value from a `Decorated` `<DataValue>`, honoring `Radix` (Hex,
  Binary, Octal, Decimal, Float/Exponential) and the `<base>#<digits>`
  radix-prefixed literal form.
- **ST routines → ST programs.** Each `<Routine Type="ST">` under a
  `<Program>` becomes a `PlcProgram` named `ProgramName_RoutineName` with its
  `<STContent>` lines concatenated as the program's Structured Text source.

## RLL (ladder) compile

Imported RLL routines compile to native ladder, per rung. Supported: contacts
`XIC`/`XIO`/`ONS`; coils `OTE`/`OTL`/`OTU`; compares `EQU`/`NEQ`/`LEQ`/`GEQ`/`LES`/
`GRT`; math `ADD`/`SUB`/`MUL`/`DIV`; `MOV`; timers `TON`/`TOF` + counters
`CTU`/`CTD`/`CTUD` (preset best-effort — exact when a literal, else defaulted +
warning); AOI calls (positional binding to the AOI interface, strict); single-
level `[…]` branches. A rung with an unsupported instruction, an AOI arity
mismatch, a nested branch, or malformed text degrades to a commented placeholder
rung + an unsupported-instruction inventory. Deferred: nested branches, `RTO`
retentive timers, exact timer/counter preset fidelity, and unmapped instructions
(`CPT`/`JSR`/`PID`/`SQO`/file-array/…).

## RLL-Logic AOIs execute

An `<AddOnInstructionDefinition>` whose `Logic` routine is `Type="RLL"` now
imports as a **ladder-bodied function block**: its rungs go through the same
`compileRllRungs` compiler as program routines and land in
`FbDefinition.ladderRungs`, so every AOI-typed tag actually runs the AOI's
logic — per instance, with independent timers, counters, and edge state (see
`docs/iec61131/FUNCTION_BLOCKS.md`). Its rung counts, unsupported-instruction
inventory, and stub reasons fold into the same RLL fields of the import
preview as program rungs.

`EnableIn`/`EnableOut` are **retained as internal vars** for RLL-Logic AOIs
only (`EnableIn` defaults `true`, `EnableOut` `false`): Rockwell RLL AOI logic
commonly does `XIC(EnableIn)`, and since the body only runs when the call
executes, `EnableIn = true` during execution is the faithful mapping. Keeping
them as vars makes those references resolve per instance instead of falling
through to absent globals. `EnableIn` is **re-asserted `true` on every call**,
just before the body's rungs run — Rockwell re-evaluates it per call, so a body
containing `OTU(EnableIn)` must not latch the instance off forever. The
re-assert is data-driven (an *internal* `BOOL` var named `EnableIn` on a
**ladder** body) and never touches an `EnableIn` that is a real interface pin,
nor an ST body. ST-Logic AOIs keep the historic skip. Call sites are
unaffected — neutral text passes the instance tag plus the AOI's *interface*
parameters, so internal vars (LocalTags, `EnableIn`/`EnableOut`) take no part
in AOI-call arity or binding.

If **no** rung of an AOI's ladder compiles, the FB falls back to the previous
interface-only no-op plus a warning naming the AOI. An AOI ladder that calls an
AOI defined *later* in the same file stubs that rung (unknown mnemonic,
inventoried) — Rockwell exports list dependencies first, so this is rare.
Only the `Logic` routine runs; `Prescan`/`Postscan`/`EnableInFalse` are not
executed. Proven end-to-end in
`mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart`.

## What's captured but not yet translated

- **FBD and SFC routines** are captured as a whole-POU stub (same shape as
  the PLCopen importer's graphical-POU stub) with a warning naming the
  routine. Re-importing once each L5X-specific graphical translator ships
  will turn these into real programs.
- **FBD/SFC AOI logic** (an AOI whose `Logic` routine is FBD or SFC) imports
  the AOI's *interface* (parameters + local tags) as a real `FbDefinition`,
  but the logic itself is not translated — a warning names the AOI and its
  logic language. (RLL AOI logic now executes — see below.)

## Autodetect (no format picker)

The importer sniffs the file's leading markup: a `<RSLogix5000Content>` root
is recognized as L5X, a PLCopen-namespaced `<project>` root as PLCopen TC6.
Anything else gets the same friendly "not recognized" snackbar the PLCopen
path uses. If the file *is* detected as L5X but isn't well-formed XML (or its
root genuinely isn't `<RSLogix5000Content>`), you get:

> Couldn't import: not a valid L5X document

exactly mirroring the PLCopen "not a valid PLCopen document" dead end — never
a crash, never a partially-applied project.

## Where it lands / how to run it

Identical to the PLCopen import flow (see `docs/import/plcopen.md`): the
project ⋮ menu's **Import PLC Program (XML)** action, a preview screen with
an editable name and the same counts/warnings summary, and **Create**/
**Cancel**. A successful import always creates a **new** project; your
currently open project is never modified.

## Deferred (not in this release)

Tracked in `docs/DEFERRED.md`'s **L5X import** section:

- **FBD-bodied AOI logic** — blocked on the L5X FBD front-end (sub-project 4);
  it will reuse the same scoped-FB infrastructure with a scoped FBD executor.
  (The RLL half shipped — see "RLL-Logic AOIs execute" above.)
- **AOI auxiliary routines** — only the main `Logic` routine executes;
  `Prescan`/`Postscan`/`EnableInFalse` are ignored.
- **AOI-in-AOI forward references** — the callee must precede the caller in
  the file.
- **L5X FBD routine translation** — sub-project 4.
- **L5X SFC routine translation** — sub-project 5.
- **BIT-overlay member aliasing** — a UDT member that overlays a bit of
  another member (`Target`/`BitNumber`) imports as a plain `BOOL`, not a live
  alias of that bit.
- **Per-instance composite tag values** — a `<Structure>`/`<ArrayMember>`
  tag's per-instance member values are not read; the tag gets its type's
  structural default instead.
- **Predefined AB/CIP module datatypes** — module-defined I/O datatypes
  (e.g. `AB:1756_MODULE:...`) are treated as any other unresolved type name
  (falls back to `INT16`), not specially modeled.
- **Multi-dimensional arrays** — only the first dimension of a
  multi-dimensional `Dimensions` attribute is imported; the rest are
  flattened away (with an info warning).
