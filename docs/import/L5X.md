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

## FBD routines translate

A `<Routine Type="FBD">` now becomes a real, executing `FunctionBlockDiagram`
program — its `<FBDContent><Sheet>` elements parse into the neutral
`GraphBody` (multi-sheet merge, `ICon`/`OCon` connector resolution, Rockwell
type + pin aliasing), then translate through the same `translateFbdBody`
PLCopen uses, per-network, faithful-or-stub. Element mapping, the type/pin
alias tables, and the full stub-reason list live in
`docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md`'s "L5X (Rockwell) FBD import"
section.

## FBD-Logic AOIs execute

An `<AddOnInstructionDefinition>` whose `Logic` routine is `Type="FBD"` now
imports as an **FBD-bodied function block**: its sheets parse and translate
the same way an FBD routine does, and the result lands in
`FbDefinition.fbdBlocks`/`fbdWires`/`fbdNetworks`, so every AOI-typed tag
runs the AOI's FBD logic per instance (see
`docs/iec61131/FUNCTION_BLOCKS.md`'s "FBD-bodied FBs").

`EnableIn`/`EnableOut` are **retained as internal BOOLs** for FBD-Logic AOIs
exactly as for RLL-Logic AOIs (`EnableIn` defaults `true`, `EnableOut`
`false`), since Rockwell FBD sheets commonly wire them as sheet pins.
`EnableIn` is **re-asserted `true` on every call**, immediately before the
body's networks run, for the same reason as the ladder case (see "RLL-Logic
AOIs execute" above). As with RLL, an AOI's FBD logic calling an AOI defined
*later* in the same file stubs that reference — the callee must precede the
caller.

If **nothing** in an AOI's FBD sheets translates, the FB falls back to the
previous interface-only no-op plus a warning naming the AOI, same as the RLL
case. Only the `Logic` routine runs. Proven end-to-end (parse → map →
translate → execute) in
`mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart`.

## SFC routines translate

A `<Routine Type="SFC">`'s `<SFCContent>` parses into the neutral SFC IR and
runs through the **same** whole-POU translator PLCopen SFC input goes through
(`translateSfcBody`), producing a real, executing `SequentialFunctionChart`
program. Translation is **faithful-or-stub for the whole chart**: structure and
transition conditions either all resolve or the entire POU stays a stub (a
half-translated sequence executes wrong logic, which is worse than not
executing). Step **actions** degrade individually, so one unsupported action
never costs the chart.

| L5X source | Native mapping |
| --- | --- |
| `<Step Operand InitialStep X Y>` | `SfcStep` (name, `isInitial`, position) |
| `<Action Qualifier="N">` inside a `<Step>` | that step's `actionSt`, in document order |
| a `<Step>` with a direct `<Body><STContent>` and no `<Action>` | one implicit `N` action |
| `<Transition><Condition><STContent>` | `conditionSt` (a single trailing `;` is stripped) |
| `<Branch BranchType="Selection">` + `<Leg>`s | a divergence/convergence connector pair → multiple `single` transitions from one step (first-true-wins) |
| `<Branch BranchType="Simultaneous">` + `<Leg>`s | a divergence/convergence connector pair → `parallelFork` / `parallelJoin` |
| `<DirectedLink FromID ToID>` | a chart edge; a link naming a `<Leg>` resolves to that branch's divergence or convergence by direction |
| a loop-back link to an earlier element | an ordinary edge (Logix has no jump element) |
| `<TextBox>` / `<Attachment>` | dropped, counted, one info warning per routine |

**Nesting.** A branch whose leg contains a step which then opens a second
branch — the ordinary way real charts nest — translates. Only
*connector-adjacent* branches (a leg head or tail that is itself a `<Branch>`,
with no step or transition between the two connectors) are unrepresentable.

**Stubbed (whole POU)**, with the `sfcStubReasons` key: an unmappable element
(`<Stop>`, `<SbrRet>`, `<JSR>`, an unknown tag), a structurally broken branch
(unrecognized `BranchType`, a leg head or tail of the wrong kind, more than one
trunk in or out, a branch no link touches, connector-adjacent nesting), a
dangling `<DirectedLink>`, a malformed or duplicate element `ID`, or a
step wired directly to a step (`complex-topology`); a transition with no
condition (`unresolved-condition`); a chart with no steps (`no-initial`).
Every one of these also emits an info breadcrumb naming the offending element,
so the stub is never a mystery.

**Degraded (chart still translates)**, each with an info warning:
- **non-`N` action qualifiers** (`S`, `R`, `P`, `L`, `D`, `SD`, `DS`, `SL`) —
  the action is skipped.
- **`IsBoolean="true"` actions** — skipped. Logix holds the named BOOL true
  while the step is active and clears it on deactivation; the native action
  model has no deactivation hook, so assigning `TRUE` would leave the bit
  latched forever.
- **`<Action>` with an empty or absent body** — skipped.
- **step timing** (`Preset`, `LimitHigh`, `LimitLow`, and their `*UsesExpr`
  companions) — dropped, because `SfcStep` has no timer. Recover a dropped
  `Preset="5000"` by hand as `STEP_T >= 5000` on the step's outgoing
  transition; `STEP_T` (elapsed time in the active step, ms) is available in
  every transition condition. A `Preset="0"` — which Logix writes on nearly
  every step — is dropped silently, so the warnings you do see are the real
  ones.

Proven end-to-end (parse → map → translate → execute), including a selection
branch and a simultaneous fork/join, in
`mobile/test/import/import_l5x_sfc_e2e_test.dart`.

## What's captured but not yet translated

- **SFC AOI logic.** Studio 5000 does not permit SFC as an Add-On Instruction
  `Logic` language — AOIs accept Ladder, FBD or Structured Text only — so
  there is nothing to translate. The importer keeps a defensive
  interface-only path (parameters + local tags become a real `FbDefinition`,
  with an info warning naming the AOI) should such a file ever appear.
  (RLL and FBD AOI logic execute — see above.)

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

- **AOI auxiliary routines** — only the main `Logic` routine executes;
  `Prescan`/`Postscan`/`EnableInFalse` are ignored.
- **AOI-in-AOI forward references** — the callee must precede the caller in
  the file.
- **Real-corpus SFC validation** — the `<SFCContent>` schema this importer
  targets is asserted from Rockwell-format domain knowledge and pinned only by
  synthetic fixtures; no SFC-bearing `.L5X` exists in the local corpus. The
  highest-value follow-up.
- **`<Stop>` elements** — stub the POU today. Mapping one onto a terminal step
  needs a real export showing how Logix wires and resets it.
- **Step `Preset`/`LimitHigh`/`LimitLow`** — dropped with a warning;
  auto-synthesizing `STEP_T >= <preset>` would silently rewrite a transition
  the user did not author.
- **`IsBoolean` actions** — skipped; they need a set-on-activate /
  reset-on-deactivate action model `SfcStep` does not have.
- **Connector-adjacent / chained branches** — a leg head or tail that is itself
  a `<Branch>` stubs. (Step-separated nesting already translates.)
- **Recursive `<SFCContent>` walk** — a `<Branch>` nested *inside* a `<Leg>`
  element is unregistered, so a link naming it stubs the POU visibly.
- **AB FBD block synthesis** — unmapped Rockwell FBD blocks (`SCL`, `PIDE`,
  `MOV`, `MOD`, `ESEL`, …) stub their network rather than synthesizing onto a
  native equivalent.
- **`TONR`/`TOFR` fidelity** — mapped best-effort to `TON`/`TOF`; retentive
  accumulation and the `Reset` pin are not modeled.
- **`<TextBox>`/`<Attachment>` FBD annotations** — dropped at parse, not
  imported as documentation.
- **`EnableIn`/`EnableOut` pass-through on wired pins** — a *wired*
  `EnableIn`/`EnableOut` pin on a Rockwell FBD block stubs its network; no
  IEC-side enable/condition semantics are synthesized.
- **FB editor support for FBD bodies** — an FBD-bodied `FbDefinition` shows
  its (empty) ST source; there is no view/edit UI for `fbdBlocks` (same gap
  as ladder bodies).
- **FB-body online monitoring** — scoped ladder and FBD bodies pass
  `monitor: null`, so imported AOI bodies have no live pin/element values.
- **PLCopen FBD-bodied `functionBlock` POUs** — the executor supports them;
  only the dialect gate withholds them, pending PLCopen-specific validation.
- **Dotted/member operands in FBD refs** — an `IRef`/`ORef` naming
  `Timer1.DN` stubs.
- **Backing-tag fidelity for FBD `Block` elements** — a
  `<Block Type="TONR" Operand="T1">`'s state lives in the translator-managed
  `FbdRuntime`, not in the `T1` TIMER tag.
- **Full 1:1 `ICon`/`OCon` pairing** — connector matching is name-based and
  routine-wide; an export that reuses one connector name for two independent
  producer/consumer pairs cross-products instead of pairing 1:1.
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
