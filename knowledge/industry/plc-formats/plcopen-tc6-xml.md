---
id: knowledge:industry/plc-formats/plcopen-tc6-xml
title: PLCopen TC6 XML
domain: industry/plc-formats
version: "2026-08"
topics: [plcopen, tc6, xml, project-exchange-format, iec-61131-3, import]
summary: Documents the PLCopen TC6 XML project-exchange schema's structure and dialect variance alongside this app's exact import support matrix - dialect-agnostic descendant parsing, the authoritative elementary-type table, and the confirmed finding that FBD/SFC bodies translate for real today, not as an empty stub (docs/import/plcopen.md corrected 2026-08-07 to match).
related:
  - knowledge:industry/plc-formats/index
  - knowledge:industry/plc-formats/rockwell-l5x
  - knowledge:industry/iec61131/ladder-diagram
  - knowledge:industry/iec61131/function-block-diagram
  - knowledge:industry/iec61131/sequential-function-chart
learnings: [CL-17]
---

# PLCopen TC6 XML

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** the PLCopen TC6 XML schema as a vendor-neutral PLC project exchange format, distilled
> against this app's parser (`mobile/lib/import/plcopen_parser.dart`), type normalizer
> (`mobile/lib/import/type_normalize.dart`), per-language translators
> (`mobile/lib/import/{ld,fbd,sfc}_translate.dart`), and project mapper
> (`mobile/lib/import/ir_to_project.dart`).
> **Read this before:** importing a PLCopen TC6 export, extending any of the graphical translators,
> or debugging why an imported program landed as a stub.

---

## 1. The headline rule

**PLCopen TC6 is an XML dialect written by many independent vendor exporters (CODESYS, Beckhoff,
Schneider, and others), so a faithful parser must be structure-tolerant about *where* things sit
in the document, and must dispatch behavior off the document root and per-POU language tags, never
off the filename or a fixed schema path.**

This is a portable lesson beyond this repo: any TC6-consuming tool has to treat the schema's
nesting (`<types>`, `<instances>`, `<configurations>`) as advisory rather than load-bearing,
because exporters vary in how deeply they nest `<dataType>`/`<globalVars>`/`<pou>` elements.

---

## 2. Document structure and dialect detection

The root element must be literally `<project>`. Dialect detection (shared with L5X detection, see
[rockwell-l5x.md](./rockwell-l5x.md)) sniffs only the first 4096 characters of the file,
lowercased: if a `<project` open tag is found and the substring `plcopen` or `tc6` appears anywhere
in that head, the file is classified PLCopen TC6. This is a substring sniff, not a namespace-URI
parse - deliberately cheap and tolerant of exporter variance in namespace declaration style.

**CL-17, confirmed**: dialect is routed off the **document root**, never off the filename - a
`<project>` root containing `plcopen`/`tc6` in its opening markup is PLCopen regardless of what the
file is named; an `<RSLogix5000Content>` root is L5X regardless of extension.

Top-level sections are found by **document-wide descendant search**, not a fixed schema path:
`<dataType>`, `<globalVars>`, and `<pou>` elements are matched wherever they appear under
`<project>`, at any depth. This is a deliberate design choice: it tolerates exporters that nest
global variables under `<instances><configurations><resource>` as well as exporters that place them
at the top level, without needing per-exporter special cases.

If the root isn't `<project>` at all, or the XML is malformed, the import fails cleanly with "not a
valid PLCopen document" - no project is created or modified.

---

## 3. DUTs (derived data types) -> structs

Each `<dataType>` with a `<struct>` body becomes a struct definition. Struct fields come from the
`<struct>` element's **direct children** named `variable` (not a descendant search - this
deliberately prevents a nested type's fields from being dragged into the wrong struct). A field's
type name is read raw at parse time (a `<derived name="X"/>` name verbatim, or the array/elementary
base type); **normalization to the app's type set, and dependency-ordered resolution of
struct-referencing-struct defaults, both happen downstream**, not in the parser itself.

**Struct-in-struct / array-of-struct resolution order** is a topological sort performed in
`ir_to_project.dart`: types are built incrementally, each new struct's field defaults resolved
against a throwaway project containing every struct built so far, so a struct referencing another
DUT gets that DUT's real nested default value, not a placeholder. A dependency cycle or an
unresolvable reference falls back to input document order rather than failing the import.

Array dimensions come from `<dimension lower=".." upper="..">`; a computed length of 65535 or
above is **clamped with a warning** rather than allocating unbounded memory. Initial values are
scalar-only at the parser level (`<initialValue><simpleValue value="...">`); if the target is an
array or a composite type, the raw initial-value text is **discarded** (with an info warning) in
favor of the type's own structural default - there is no structural-literal parsing for composite
initial values.

---

## 4. POU body dispatch

A POU's own `<body>` is found by **direct-child** search deliberately, not the descendant search
used for top-level sections - because SFC POUs also contain sibling `<actions>`/`<transitions>`
sections whose own `<action>`/`<transition>` elements can themselves contain `<body>`-shaped
elements, which a naive descendant search could match ahead of the POU's real body. Inside
`<body>`, the first direct child element named `ST`, `IL`, `LD`, `FBD`, or `SFC` determines the
language and routes dispatch:

| Body tag | Handling |
|---|---|
| (none recognized) | Empty ST program + info warning |
| `ST` / `IL` | Text carried verbatim into an ST program's source (IL is **not** translated to ST - a straight text carry, flagged with an info warning to verify against the app's ST subset) |
| `LD` / `FBD` | Both parse into the same generic graph structure (nodes + typed connections with pin identity) - the POU's language tag is what routes this graph to the LD translator or the FBD translator downstream |
| `SFC` | Parsed into a dedicated chart structure (steps, transitions, divergence/convergence nodes, actions) |

---

## 5. Global variables -> tags

The `retain` qualifier is read from the **container** (`<globalVars retain="true">`), never from
an individual `<variable>` - per the TC6 schema, retain is a variable-*list* attribute, and every
member of that list inherits it. Scope maps to I/O role: `input`-scoped variables become
`SimulatedInput` tags, `output`-scoped become `SimulatedOutput`; everything else (`local`, `temp`,
`external`, plain global) collapses to `Internal`.

**Authoritative elementary-type table** (the complete list; anything not in it and not a known DUT
name falls back to `INT16` with no warning - a silent narrowing, not an error):

| IEC type(s) | App tag type |
|---|---|
| `BOOL` | `BOOL` |
| `SINT`, `INT`, `USINT`, `UINT`, `BYTE`, `WORD` | `INT16` |
| `DINT`, `UDINT`, `DWORD` | `INT32` |
| `LINT`, `ULINT`, `LWORD` | `INT64` |
| `REAL`, `LREAL` | `FLOAT64` |
| `STRING`, `WSTRING`, `CHAR`, `WCHAR` | `STRING` |
| `TIME`, `TON`, `TOF`, `TP` | `TIMER` |
| `TIMER`, `COUNTER` (predefined structure names) | `TIMER`, `COUNTER` |

This table is shared verbatim by the L5X import path - see
[rockwell-l5x.md](./rockwell-l5x.md) §4.

---

## 6. Support matrix

| Body kind | Support | Mechanism |
|---|---|---|
| `ST` / `IL` POU | Real ST program | Verbatim text carry; IL is not translated, only flagged |
| `LD` POU | **Real, per-rung translation** | Contacts (`normal`/`negated`/`rising`/`falling`, single-modifier only), coils (`normal`/`set`/`reset`/`negated`/`rising`/`falling`), timers `TON`/`TOF`/`TP`, counters `CTU`/`CTD`/`CTUD`, compares `GT`/`LT`/`GE`/`LE`/`EQ`/`NE`, math `ADD`/`SUB`/`MUL`/`DIV`, `MOVE`, custom-FB calls, single-level parallel branches. A rung whose topology or block usage falls outside this set becomes a commented placeholder rung with a named reason, in the same program - never a silent drop. |
| `FBD` POU | **Real, per-network translation** (see correction below) | Weakly-connected components each become one `FbdNetwork`; `inVariable`->`CONST`/`TAG_INPUT`, `outVariable`->`TAG_OUTPUT`, recognized built-in block types, custom-FB call routing. A network that fails (unsupported element, unresolved/complex operand, unsupported block, ambiguous pin) stubs individually with a named reason; the POU still lands as a real, editable program as long as at least one network translated. |
| `SFC` POU | **Real, whole-chart translation** (see correction below) | Steps, N-qualified actions resolved to ST, single/fork/join transitions. Whole-POU faithful-or-stub (not per-element like LD/FBD): any unsupported topology or condition anywhere in the chart falls the *entire* POU back to a stub. |
| `functionBlock`-kind POU with a graphical (`LD`/`FBD`/`SFC`) body | **Not imported at all** | `fb_import.dart` skips any FB-kind POU whose body isn't plain text or neutral ladder - not even a stub `FbDefinition` is created; a warning names the POU. Only ST-bodied and ladder-bodied custom FBs import. See [../iec61131/custom-function-blocks.md](../iec61131/custom-function-blocks.md). |

### Stub conditions for `LD` (exact)

`complex-topology` (unsupported element type, a value variable feeding a power pin, a block using
a non-primary timer/counter power pin, nested/ambiguous branch structure, or - critically - a
faithfulness check that reconstructs the exact wiring the chosen layout implies and compares it
against the component's real edges, stubbing on **any** mismatch rather than emitting
approximately-right logic); `no-coil` (zero coils and zero blocks in the component); `unsupported-block`
(a block type outside the supported set and not a registered custom FB); `unresolved-operand` (an
empty/absent literal, an unparseable timer/counter preset, a math/MOVE block with no output
destination, an FB-call input pin unresolved or off the interface).

---

## 7. FBD and SFC translate for real today, not as an empty stub (corrected 2026-08-07)

`ir_to_project.dart`'s FBD arm calls the real per-network translator and adds a genuine
`FunctionBlockDiagram` program (with populated blocks/wires/networks) whenever
`translatedNetworkCount > 0` - only a POU where *every* network fails to translate falls into the
description-only empty-stub path. The SFC arm behaves the same way at the whole-chart level: a
genuine `SequentialFunctionChart` program is added whenever the chart translates at all; only a
fully-untranslatable chart stubs.

**Net effect**: for PLCopen input specifically, FBD/SFC graphical bodies are materially more
capable than a blanket "not translated yet" claim would suggest - most real-world FBD/SFC content,
not just LD, comes in as an editable native program. `docs/import/plcopen.md` was corrected
2026-08-07 to describe this per-network/per-chart faithful-or-stub behavior (matching how LD is
already documented) instead of the earlier, stale "always an empty stub" description.

This does **not** extend to the Rockwell L5X import path, where FBD/SFC genuinely are still an
empty stub today - see [rockwell-l5x.md](./rockwell-l5x.md) §5 for why the same underlying
translator being proven-capable here doesn't mean L5X gets it for free yet.

---

## What this means practically

### "I imported a PLCopen file and my FBD program came in empty - is that expected?"
Only if *every* network in that POU failed to translate (check the import warnings for named
per-network stub reasons). If even one network succeeded, the program should be real and editable
- if it looks empty despite that, treat it as a bug, not expected behavior (§7).

### "Why did my ladder rung with a bridge/bypass wire come in as a commented placeholder?"
The translator's faithfulness check reconstructs the exact wiring implied by its chosen
main-line/branch layout and compares it against the rung's real edges - any topology that a
strict series-parallel layout can't represent exactly (rather than approximately) stubs the whole
rung with a `complex-topology` reason (§6).

### "My struct field's initial value from the source file didn't carry over."
Only scalar initial values import; an array or composite-typed field's initial value is discarded
in favor of the type's own structural default (§3).

### "An unrecognized IEC type in my source file mapped to something wrong, silently."
Any elementary type name not in the authoritative table (§5), and not a known DUT name, falls back
to `INT16` with no warning - check the type name against the table if a mapped field looks wrong.

---

## Related

- [rockwell-l5x.md](./rockwell-l5x.md) - the other supported import dialect; shares the type-normalization table and the root-based dialect-detection rule (CL-17).
- [../iec61131/ladder-diagram.md](../iec61131/ladder-diagram.md) - the native rung model LD POUs translate into.
- [../iec61131/function-block-diagram.md](../iec61131/function-block-diagram.md) - the native network model FBD POUs translate into.
- [../iec61131/sequential-function-chart.md](../iec61131/sequential-function-chart.md) - the native chart model SFC POUs translate into.
- [index.md](./index.md) - domain hub.
