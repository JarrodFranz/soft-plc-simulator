---
id: knowledge:industry/plc-formats/rockwell-l5x
title: Rockwell L5X
domain: industry/plc-formats
version: "2026-08"
topics: [rockwell, l5x, rslogix5000, studio-5000, aoi, rll, add-on-instruction, import]
summary: Documents the Rockwell L5X (RSLogix5000Content) project-exchange schema's structure alongside this app's exact import support matrix - the RLL compile instruction set, real shipped AOI/RLL-Logic-AOI execution, real shipped FBD routine and FBD-Logic-AOI execution, real shipped SFC routine translation with its asserted-and-fixture-pinned <SFCContent> schema and branch-pair synthesis rule, a sheet-merge identity-collision import pitfall, and Rockwell FBD interop specifics (Operand/Function elements, SEL/CTUD name collisions, connector name reuse, OSRI/OSFI mapping).
related:
  - knowledge:industry/plc-formats/index
  - knowledge:industry/plc-formats/plcopen-tc6-xml
  - knowledge:industry/iec61131/ladder-diagram
  - knowledge:industry/iec61131/custom-function-blocks
  - knowledge:industry/iec61131/function-block-diagram
  - knowledge:industry/iec61131/sequential-function-chart
learnings: [CL-17, CL-19, CL-22]
---

# Rockwell L5X

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** the Rockwell L5X (`RSLogix5000Content`) project-exchange schema as exported by
> Studio 5000 / RSLogix 5000, distilled against this app's parser
> (`mobile/lib/import/l5x_parser.dart`), RLL compiler (`mobile/lib/import/rll_compile.dart`),
> FBD translator (`mobile/lib/import/fbd_translate.dart`, shared with the PLCopen path), and FB
> mapper (`mobile/lib/import/fb_import.dart`).
> **Read this before:** importing a Studio 5000 L5X export, extending RLL, FBD or SFC
> translation, or checking which L5X body kinds execute for real (all four - ST, RLL, FBD and
> SFC - do, as of this version; §5's `<SFCContent>` structure is asserted from format knowledge
> and pinned by synthetic fixtures rather than by a real corpus export, so treat the SCHEMA, not
> the support status, as the thing to verify against a real file).

---

## 1. The headline rule

**L5X's `<RSLogix5000Content>` root carries controller-scoped DataTypes/AOIs/Tags plus
per-program Routines, and this app's parser walks a fixed direct-child path for each (unlike
PLCopen's document-wide descendant search) - because L5X, being a single-vendor export format, has
one consistent nesting shape to rely on.**

This is the structural contrast with [plcopen-tc6-xml.md](./plcopen-tc6-xml.md): TC6 tolerates
exporter variance with descendant search; L5X's parser can afford a fixed schema path
(`Controller/DataTypes/DataType`, `Controller/AddOnInstructionDefinitions/AddOnInstructionDefinition`,
`Controller/Tags/Tag` and `Controller/Programs/Program/Tags/Tag`,
`Controller/Programs/Program/Routines/Routine`) because Rockwell's own tooling is the only real
producer of this format.

---

## 2. Document structure and dialect detection

Root must be literally `<RSLogix5000Content>`, checked in the same first-4096-characters sniff
that also detects PLCopen (see [plcopen-tc6-xml.md](./plcopen-tc6-xml.md) §2) - the presence of
`<rslogix5000content>` (case-insensitive) in the leading markup routes to L5X; failing that, a
`<project` root with `plcopen`/`tc6` in the head routes to PLCopen; anything else is unrecognized.

**CL-17, confirmed on the L5X side too**: routing is off the document root, never the filename -
an `.xml`-extensioned file with an `<RSLogix5000Content>` root is still recognized as L5X.

Project name resolves from `Controller/@Name`, falling back to the root's `TargetName` attribute,
falling back to a generic default. A malformed document or a root that genuinely isn't
`<RSLogix5000Content>` fails cleanly with "not a valid L5X document" - mirroring PLCopen's dead-end
behavior exactly (no partially-applied project, ever).

---

## 3. RLL (ladder) compile - exact support matrix

Each `<Routine Type="RLL">`'s neutral-text rungs compile per-rung through a hand-written
recursive-descent tokenizer, with branch nesting capped at a fixed depth to bound recursion against
adversarial input.

**Supported instructions:**

| Category | Mnemonics | Native mapping |
|---|---|---|
| Contacts | `XIC`, `XIO`, `ONS` | normal, negated, rising-edge |
| Coils | `OTE`, `OTL`, `OTU` | normal, set, reset |
| Timers/counters | `TON`, `TOF`, `CTU`, `CTD`, `CTUD` | direct - note `RTO` (retentive timer) is **not** in this set |
| Compares | `EQU`, `NEQ`, `LEQ`, `GEQ`, `LES`, `GRT` | `EQ`, `NE`, `LE`, `GE`, `LT`, `GT` |
| Math | `ADD`, `SUB`, `MUL`, `DIV` | direct |
| Move | `MOV` / `MOVE` | direct |
| AOI calls | any mnemonic matching a registered AOI (post rename-mapping) | strict positional-arity binding against the AOI's non-internal interface vars |
| Branches | `[leg1, leg2, ...]` | single-level only - a branch nested inside a branch leg is a stub condition, not supported |
| `NOP()` | at top level only | true no-op, doesn't even add a node |

**Stub conditions (a rung degrades to a commented rail-to-rail placeholder carrying the original
source text, never a silent drop):** `parse-error` (unbalanced brackets, missing paren, empty
instruction, excessive branch nesting); `complex-topology` (nested branch, empty branch leg);
`unresolved-operand` (wrong operand count for a contact/coil/compare/math/move, missing AOI-instance
operand for a timer/counter); `unsupported-instruction` (mnemonic not in the table and not a
registered AOI); `aoi-mismatch` (AOI call operand count doesn't match the AOI's interface).

**Deferred, confirmed absent from the compiler**: nested branches beyond one level, `RTO`
retentive timers, exact timer/counter preset fidelity when the preset isn't a literal, and any
unmapped instruction (`CPT`, `JSR`, `PID`, `SQO`, file/array instructions, and others).

---

## 4. AOI import and RLL-Logic AOI execution - real, shipped

Each `<AddOnInstructionDefinition>` becomes an `FbDefinition`: its `Parameters` (excluding the
implicit `EnableIn`/`EnableOut`) become input/output/internal vars, its `LocalTags` become internal
vars, and - when its `Logic` routine (or the routine literally named `Logic`) is `Type="RLL"` - that
routine's rungs compile through the **same** `compileRllRungs` path as ordinary program routines
and land in `FbDefinition.ladderRungs`. **This means an AOI-typed tag actually runs the AOI's real
logic per instance**, with independent timers/counters/edge state per instance - not a stub, not an
interface-only no-op. See [../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md)
for the general instance-execution model this plugs into.

`EnableIn`/`EnableOut` are retained as **internal** vars for RLL-Logic AND FBD-Logic AOIs alike
(`EnableIn` defaults `true`, `EnableOut` defaults `false`) - only ST/SFC-logic AOIs keep the
historic skip of these two params. `EnableIn` is **re-asserted `true` on every call**, immediately
before the body's rungs (or FBD networks - see §5) run, so a body containing `OTU(EnableIn)`
(Rockwell RLL commonly gates on `XIC(EnableIn)`; FBD sheets wire it as a pin) doesn't permanently
latch the instance off across calls - this mechanism lives in the general FB executor, not the
importer; see
[../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md) §3.

If **no** rung of an AOI's ladder compiles, the FB falls back to an interface-only no-op plus a
warning naming the AOI - never a partial/wrong-behaving body. Only the `Logic` routine executes;
`Prescan`/`Postscan`/`EnableInFalse` are never run. An AOI ladder calling an AOI defined *later* in
the same file stubs that call (unknown mnemonic) - the compiler only resolves against the registry
built so far, so forward references across AOI definitions are unsupported (Rockwell's own export
convention lists dependencies first, so this is rare in practice).

---

## 5. FBD and SFC both ship

**FBD routine, FBD-Logic AOI and SFC routine translation are all real and shipped, each reusing
the same translator PLCopen input goes through (see [plcopen-tc6-xml.md](./plcopen-tc6-xml.md)
§7). Every L5X body kind - ST, RLL, FBD, SFC - now produces real executing logic.**

A `<Routine Type="FBD">`'s `<FBDContent><Sheet>` elements parse into the neutral `GraphBody` IR
(`_l5xFbdBody` in `l5x_parser.dart`): every `<Sheet>` merges into one body in ascending `<Sheet
Number>` order (each sheet after the first gets its element ids and Y coordinate offset, so
network numbering reads sheet-by-sheet); `ICon`/`OCon` connectors resolve to their matching
producer/consumer by name, routine-wide, at parse time; and Rockwell mnemonics/pins alias onto
their IEC equivalents (`EQU`->`EQ`, `SourceA`/`SourceB`/`Dest`->`IN1`/`IN2`/`OUT`, and more - see
[../iec61131/function-block-diagram.md](../iec61131/function-block-diagram.md) §6 and
`docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md`'s L5X subsection for the full tables). That `GraphBody`
then runs through the **same** `translateFbdBody` the PLCopen path uses, per-network,
faithful-or-stub - producing a real, executing `FunctionBlockDiagram` program.

**Sheet-merge identity collisions (CL-19).** The multi-sheet merge above indexes parsed elements by
their L5X `ID` to build the component graph. An early version of this index was a plain node-list
comprehension (`{for (n in nodes) n.localId: n}`): when two elements on one sheet legitimately share
a raw `ID`, that pattern silently keeps only the LAST one, deletes the earlier element outright,
re-points its wires onto the survivor, and the merged component then translates cleanly as the WRONG
logic - no error, no stub, just wrong. The fix demotes a duplicate `ID` to a synthetic negative id
before indexing (never re-registering the raw id), which trips the translator's `localId < 0` stub
gate, so the duplicate's component visibly stubs with a warning-severity "duplicate ID"
`ImportWarning` instead of silently overwriting real logic. The general lesson - any graphical-import
merge algorithm must treat an identity collision as a stub-worthy defect, never silent
last-write-wins - applies to every id-indexed merge step in this file and in the shared
`weaklyConnectedComponents` machinery (`graph_segment.dart`), not just this one call site. Pinned by
the duplicate-ID case in `mobile/test/import/l5x_parser_fbd_test.dart`.

**Rockwell FBD interop specifics worth keeping as settled facts (CL-22):**
- Logix emits `<Block Operand="...">` for ordinary instructions and a distinct `<Function>` element
  for bit functions - both feed the same alias/translate pipeline (`_kL5xFbdTypeAliases`/
  `_kL5xFbdPinAliases`) but are structurally different elements, not the same tag with different
  attributes.
- `SEL` and `CTUD` are Rockwell mnemonics that COLLIDE with IEC built-in block names, so they pass
  the built-in allowlist without needing a type alias at all, and then die at pin assertion unless
  their pins are ALSO aliased (`SelectorIn` -> `G`, etc. for `SEL`) - the type name matching an IEC
  built-in is not evidence the pins line up.
- Connector (`ICon`/`OCon`) names are unique within one Logix routine by construction, and
  `_resolveL5xFbdConnectors` matches them the same way (name-based, routine-wide). A malformed
  export that reuses one connector name for two independent producer/consumer pairs is out of spec
  for Logix but not rejected on import: every producer of that name splices onto every consumer (a
  cross-product), and the fused component then stubs deterministically at the translator's
  `unresolved-pin` gate rather than silently wiring the wrong signal. Full 1:1 pairing (by sheet
  proximity or declaration order) is deferred, tracked in `docs/DEFERRED.md`.
- `OSRI`/`OSFI` map onto the IEC `R_TRIG`/`F_TRIG` blocks, with `InputBit` -> `CLK` and `OutputBit`
  -> `Q` pin aliases - both are best-effort (Logix's separate storage/output bits have no 1:1 IEC
  equivalent), flagged with a warning-severity breadcrumb rather than a silent lossy translation.

One level down, `mapImportedFbs` now maps an AOI whose `Logic` routine is `Type="FBD"` the same
way: its sheets translate into `FbDefinition.fbdBlocks`/`fbdWires`/`fbdNetworks` (a new triple that
did not exist on `FbDefinition` before this shipped), and the FB executor
(`mobile/lib/models/fb_exec.dart`'s `executeFbInstance`) runs that body per instance via the
scoped FBD executor `runScopedFbdBody` (`fbd_exec.dart`), keying stateful-block runtime state
`'fb:<instancePath>|<blockId>'` - see
[../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md) §1/§4 for the
general three-way body-precedence model this plugs into. `EnableIn`/`EnableOut` are retained as
internal vars for FBD-Logic AOIs exactly as for RLL-Logic AOIs (§4), and `EnableIn` is
re-asserted `true` before every call.

A `<Routine Type="SFC">`'s `<SFCContent>` parses into the neutral `SfcBody` IR (`_l5xSfcBody` in
`l5x_parser.dart`) and runs through the same `translateSfcBody` the PLCopen path uses, whole-POU
faithful-or-stub. Steps carry their nested `<Action Qualifier="N">` children (association is by XML
NESTING, not by a link - the opposite of PLCopen's sibling `<actionBlock>`), transitions carry an
inline ST `<Condition>`, and `<DirectedLink FromID ToID>` is a flat routine-wide edge list rather
than PLCopen's per-target `connectionPointIn`.

**Branch-pair synthesis is the crux.** L5X models a branch as ONE `<Branch BranchType>` element
carrying `<Leg>` children; the neutral IR, IEC 61131-3 and `sfc_exec` all model it as TWO connector
nodes, an opening divergence and a closing convergence. The importer therefore synthesizes the pair
and derives its wiring from link topology alone, through one unified endpoint rule with no mode
switch:

- a link naming a `<Leg>` resolves BY DIRECTION - out of a leg means the divergence feeds that
  leg's head, into a leg means that leg's tail feeds the convergence;
- a link naming the `<Branch>` resolves BY THE OTHER ENDPOINT'S KIND - selection diverges into
  TRANSITIONS and converges out to a STEP, simultaneous is the mirror, so the neighbour's kind
  alone says whether the link is a trunk role or a leg role.

The kind rule matters: the naive direction rule agrees on every trunk link but reads a leg-head
link expressed through the branch id as a convergence outlet, wiring conv -> T1, a silently wrong
chart that still passes every shape check. Emission is then a total function of four booleans (is
each of divIn/divOut/convIn/convOut non-empty): a side is emitted whenever either of its bits is
set, dropped when both are clear, and a side with exactly one bit set is a defect with its own
named cause. Every paired branch legitimately MIXES both link forms - trunk links must name the
`<Branch>` id while leg links name `<Leg>` ids - so a "mixed convention" rule would stub the common
case, which is why there is no such rule.

**Never silent.** Any unmappable element (`<Stop>`, `<SbrRet>`, `<JSR>`, an unknown tag), any
structurally broken branch, any dangling link and any malformed/duplicate `ID` sets a routine-level
flag that appends a POISON NODE - a step carrying a self-edge. `translateSfcBody`'s step-to-step
edge scan is unconditional over the edge list and sits above every warning-emitting statement, so a
poisoned body always stubs `complex-topology` with exactly one warning and no stray infos, with
ZERO changes to the translator (it carries one coupling comment naming the dependency, and a
dialect-neutral test in `sfc_translate_test.dart` fails if `_build` is ever reordered). A raw
`ID` is accepted only when non-negative and within range, which is what keeps a `<Step ID="-1">`
out of the same namespace as the synthetic negative ids branch connectors and the poison node draw
from - without that gate the step's id collides with the first branch's divergence and the chart
translates cleanly AS THE WRONG LOGIC with zero warnings, the same failure shape as CL-19 above.

> **ASSERTED, NOT CORPUS-VERIFIED.** The `<SFCContent>` element set and attribute names above are
> stated from Rockwell-format domain knowledge; this repo contains no SFC-bearing L5X (no corpus
> file, no vendored schema manual). They are pinned by synthetic, schema-faithful fixtures in
> `mobile/test/import/l5x_parser_sfc_test.dart`, exactly the precedent the FBD sub-project set for
> `<FBDContent>`. The branch rules above are written to absorb BOTH plausible encodings of
> `<Branch>` (paired element, or separate Diverge/Converge elements) without a mode switch, but a
> THIRD encoding would invalidate them. Acquiring one real SFC export and running it through
> `corpus_import_test.dart` is the tracked near-term follow-up (`docs/DEFERRED.md`).

| L5X body kind | Support |
|---|---|
| `RLL` routine | Real, per-rung compile (§3) |
| `ST` routine | Real, verbatim text carry |
| `FBD` routine | Real, per-network translate via the shared `translateFbdBody` (this section) |
| `SFC` routine | Real, whole-POU translate via the shared `translateSfcBody` (this section) |
| `RLL`-Logic AOI | Real, per-instance execution (§4) |
| `ST`-Logic AOI | Real, ST body carried, `EnableIn`/`EnableOut` historic skip |
| `FBD`-Logic AOI | Real, per-instance execution via the FBD-bodied `FbDefinition` (this section) |
| `SFC`-Logic AOI | Not possible in Studio 5000 (AOIs accept Ladder/FBD/ST only) - a Rockwell product restriction, asserted from format knowledge and not verified against a repo artifact; the defensive interface-only path stands either way |

Proven end-to-end (parse -> map -> translate -> execute) in
`mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart` (FBD routine + FBD-Logic AOI) and
`mobile/test/import/import_l5x_sfc_e2e_test.dart` (SFC routine, selection branch and
simultaneous fork/join).

---

## 6. Radix and literal parsing

A `<base>#<digits>` literal (e.g. `16#ffff_0000`, `2#1010`) is parsed by finding the `#`, reading
the base (2-36), stripping underscores from the digit group, and parsing with that radix. Absent an
explicit `#`-prefixed base, the `Radix` attribute drives parsing: `Hex` (base 16), `Binary` (base
2), `Octal` (base 8), `Float`/`Exponential` (floating-point), default (try integer, then float).
Underscore digit-group separators are stripped in every numeric-radix path. `BOOL` literal `"1"`/`"0"`
pass through as plain integers - coercion to boolean happens downstream by the field/var's declared
type, not in the literal parser itself.

---

## 7. Multi-dimensional arrays - only the first dimension imports

Confirmed across all three array-bearing sites (tag `Dimensions`, UDT member `Dimension`, AOI
parameter/local-tag `Dimensions`): only the **first** whitespace-separated dimension token is used
to size the array; any additional dimension tokens are dropped, flattening a multi-dimensional
array to one dimension. The tag path specifically emits an info warning naming the flattened size
when more than one dimension token is present; the UDT-member and AOI-parameter paths share the
same single-dimension-only helper but don't call out the flattening with a warning at those two
sites. All three share a 65535-element clamp-with-warning, mirroring PLCopen's array-length cap.

---

## What this means practically

### "I imported an L5X file with FBD routines - do they translate for real now, same as PLCopen?"
Yes - as of this version, an L5X `FBD` routine parses and translates through the same
`translateFbdBody` the PLCopen path uses, faithful-or-stub per network (§5). A network still stubs
(with an explanatory comment plus a warning) when it hits an unmapped block/pin, a wired
`EnableIn`/`EnableOut`, a dotted operand, or one of the other stub reasons in
[../iec61131/function-block-diagram.md](../iec61131/function-block-diagram.md) - that is normal
faithful-or-stub degradation, not a sign FBD import is unshipped.

### "My AOI's RLL logic runs, and now its FBD logic runs too - what about SFC?"
SFC ROUTINES translate for real as of this version (§5) - the whole chart, including selection and
simultaneous branches, becomes an executing `SequentialFunctionChart` program, or the whole POU
stubs with a named reason. SFC-Logic AOIs are a different question and the answer is that they do
not exist: Studio 5000 does not permit SFC as an AOI `Logic` language (Ladder, FBD or ST only), so
the importer keeps only a defensive interface-only path for one (a Rockwell product restriction,
asserted from format knowledge and not verified against a repo artifact; the defensive
interface-only path stands either way).

### "My SFC routine imported as a stub - what did I do wrong?"
Probably nothing. SFC is whole-POU faithful-or-stub, so ONE unmappable thing takes down the chart:
a `<Stop>` element, a structurally broken branch, a dangling `<DirectedLink>`, a duplicate or
malformed element `ID`, or a transition with no condition. Every one of them also emits an
info-severity breadcrumb naming the offending element and id, so read the info warnings, not just
the two loud ones (§5).

### "Why did my multi-dimensional array tag collapse to one dimension?"
By design - only the first dimension token imports; the rest are dropped, with an info warning on
tags (not on UDT members or AOI parameters, though the same limitation applies there) (§7).

### "An AOI call inside another AOI's ladder didn't resolve."
Check definition order in the source file - the compiler only resolves an AOI call against AOIs
already registered from earlier in the file; a forward reference to a later-defined AOI stubs (§4).

---

## Related

- [plcopen-tc6-xml.md](./plcopen-tc6-xml.md) - the other supported dialect; both now translate ST/RLL-or-LD/FBD/SFC for real, and share the `translateFbdBody`/`translateSfcBody` translators plus the type-normalization table.
- [../iec61131/ladder-diagram.md](../iec61131/ladder-diagram.md) - the native rung model RLL compiles into.
- [../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md) - the general FB instance-execution model AOIs plug into, including the `EnableIn` re-assertion mechanism and the ladder/FBD body precedence.
- [../iec61131/function-block-diagram.md](../iec61131/function-block-diagram.md) - the native network model L5X FBD now targets.
- [../iec61131/sequential-function-chart.md](../iec61131/sequential-function-chart.md) - the native chart model L5X SFC now targets.
- [index.md](./index.md) - domain hub.
