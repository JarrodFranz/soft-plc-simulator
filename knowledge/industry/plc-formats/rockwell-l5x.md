---
id: knowledge:industry/plc-formats/rockwell-l5x
title: Rockwell L5X
domain: industry/plc-formats
version: "2026-08"
topics: [rockwell, l5x, rslogix5000, studio-5000, aoi, rll, add-on-instruction, import]
summary: Documents the Rockwell L5X (RSLogix5000Content) project-exchange schema's structure alongside this app's exact import support matrix - the RLL compile instruction set, real shipped AOI/RLL-Logic-AOI execution, and the confirmed still-unshipped state of L5X FBD and SFC routine translation.
related:
  - knowledge:industry/plc-formats/index
  - knowledge:industry/plc-formats/plcopen-tc6-xml
  - knowledge:industry/iec61131/ladder-diagram
  - knowledge:industry/iec61131/custom-function-blocks
  - knowledge:industry/iec61131/function-block-diagram
learnings: [CL-17]
---

# Rockwell L5X

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** the Rockwell L5X (`RSLogix5000Content`) project-exchange schema as exported by
> Studio 5000 / RSLogix 5000, distilled against this app's parser
> (`mobile/lib/import/l5x_parser.dart`), RLL compiler (`mobile/lib/import/rll_compile.dart`),
> FB mapper (`mobile/lib/import/fb_import.dart`), and the parked design spec
> `docs/superpowers/specs/2026-08-04-l5x-fbd-import-design.md` (design rationale only, not
> behavioral authority - see the note in §5).
> **Read this before:** importing a Studio 5000 L5X export, extending RLL compilation, or checking
> whether L5X FBD/SFC support has shipped (it has not, as of this version - verify against source
> before assuming otherwise, since this is exactly the kind of claim that goes stale fastest).

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

`EnableIn`/`EnableOut` are retained as **internal** vars specifically for RLL-Logic AOIs (`EnableIn`
defaults `true`, `EnableOut` defaults `false`) - ST/FBD/SFC-logic AOIs keep the historic skip of
these two params. `EnableIn` is **re-asserted `true` on every call**, immediately before the body's
rungs run, so a body containing `OTU(EnableIn)` (Rockwell RLL commonly gates on `XIC(EnableIn)`)
doesn't permanently latch the instance off across calls - this mechanism lives in the general FB
executor, not the importer; see
[../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md) §3.

If **no** rung of an AOI's ladder compiles, the FB falls back to an interface-only no-op plus a
warning naming the AOI - never a partial/wrong-behaving body. Only the `Logic` routine executes;
`Prescan`/`Postscan`/`EnableInFalse` are never run. An AOI ladder calling an AOI defined *later* in
the same file stubs that call (unknown mnemonic) - the compiler only resolves against the registry
built so far, so forward references across AOI definitions are unsupported (Rockwell's own export
convention lists dependencies first, so this is rare in practice).

---

## 5. FBD and SFC in L5X - confirmed still fully unshipped

**This is a finding worth stating plainly because it's easy to assume otherwise: the same
per-network FBD translator and whole-chart SFC translator that are proven and shipped for PLCopen
input (see [plcopen-tc6-xml.md](./plcopen-tc6-xml.md) §7) are NOT reachable from L5X input today.**
The L5X parser's `FBD` and `SFC` routine-type cases each construct a **permanently empty** graph
structure (no nodes, no connections) regardless of the routine's actual `<FBDContent>` or SFC
content in the source file, attach a warning naming the routine, and stop - the parser never reads
`<FBDContent>`, never reads a `<Sheet>` element, and has no L5X-specific SFC content reader at all.
Since the translator downstream sees zero nodes either way, the POU always falls through to the
description-only whole-POU stub.

The same is true one level down: an AOI whose `Logic` routine is FBD- or SFC-typed imports its
*interface* (parameters + local tags) as a real `FbDefinition`, but the logic itself is not
translated - a warning names the AOI and its logic language.

| L5X body kind | Support |
|---|---|
| `RLL` routine | Real, per-rung compile (§3) |
| `ST` routine | Real, verbatim text carry |
| `RLL`-Logic AOI | Real, per-instance execution (§4) |
| `ST`-Logic AOI | Real, ST body carried, `EnableIn`/`EnableOut` historic skip |
| `FBD` routine | **Whole-POU stub, always empty** - parser never reads `<FBDContent>` |
| `SFC` routine | **Whole-POU stub, always empty** - parser has no L5X SFC content reader |
| `FBD`-Logic AOI | Interface-only import, logic not translated |
| `SFC`-Logic AOI | Interface-only import, logic not translated |

**Design-rationale note, not behavioral authority**: a design spec exists
(`docs/superpowers/specs/2026-08-04-l5x-fbd-import-design.md`, status "Approved (brainstorm)")
proposing to add an `_l5xFbdBody` parser front-end that reuses the already-proven PLCopen
`translateFbdBody` verbatim (multi-sheet merge with per-sheet localId/y offsetting, `ICon`/`OCon`
connector resolution at parse time, Rockwell mnemonic and pin aliasing such as `EQU`->`EQ` and
`SourceA`->`IN1`), plus a scoped FBD executor and a new `fbdBlocks`/`fbdWires`/`fbdNetworks` triple
on `FbDefinition` (which does not exist on that class today - confirmed by direct inspection: it
currently has only `stSource` and `ladderRungs`). Treat this spec as a roadmap for what L5X FBD
import will look like when it ships, not as a description of current behavior - it explicitly
records its own local test corpus as containing **zero** real FBD content (every fixture would be
handcrafted), which is itself a sign this workstream hadn't started implementation as of the spec's
writing. L5X SFC routine translation is an even earlier-stage, separate deferred sub-project with
no design spec at all yet.

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

### "I imported an L5X file with FBD routines - why did they come in empty, when PLCopen FBD imports for real?"
This is expected, not a regression: L5X FBD is genuinely unshipped (§5), even though the underlying
translator that PLCopen uses is proven-capable. The two paths are not at parity - check the design
spec for the roadmap, but don't assume it reflects current behavior.

### "My AOI's RLL logic runs, but its FBD logic doesn't - is that inconsistent?"
No - RLL-Logic AOI execution is real and shipped (§4); FBD-Logic AOI execution is not (§5). This is
the same asymmetry as routine-level FBD import.

### "Why did my multi-dimensional array tag collapse to one dimension?"
By design - only the first dimension token imports; the rest are dropped, with an info warning on
tags (not on UDT members or AOI parameters, though the same limitation applies there) (§7).

### "An AOI call inside another AOI's ladder didn't resolve."
Check definition order in the source file - the compiler only resolves an AOI call against AOIs
already registered from earlier in the file; a forward reference to a later-defined AOI stubs (§4).

---

## Related

- [plcopen-tc6-xml.md](./plcopen-tc6-xml.md) - the other supported dialect; contrast the FBD/SFC support gap directly with §7 there, and see the shared type-normalization table.
- [../iec61131/ladder-diagram.md](../iec61131/ladder-diagram.md) - the native rung model RLL compiles into.
- [../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md) - the general FB instance-execution model AOIs plug into, including the `EnableIn` re-assertion mechanism.
- [../iec61131/function-block-diagram.md](../iec61131/function-block-diagram.md) - the native network model L5X FBD would target once it ships.
- [index.md](./index.md) - domain hub.
