# L5X SFC routine import (L5X sub-project 5 — the last import gap) — Design Spec

**Status:** design complete, ready to plan
**Date:** 2026-08-07
**Branch base:** `main` @ `9a0338a`
**Predecessors:** `2026-07-26-sfc-import-translator-design.md` (the neutral SFC
translator), `2026-07-26-l5x-import-foundation-design.md`,
`2026-08-04-l5x-fbd-import-design.md` (the immediately preceding sub-project,
whose conventions this one mirrors).

## Changelog

- 2026-08-07 — initial design.
- 2026-08-07 — updated after design review: unified endpoint classifier
  (the "mixed convention" rule is **deleted**, not amended — §3), FBD-parity ID
  gate rejecting negative/out-of-range raw `ID`s (§2), connector-adjacent
  vs. step-separated nesting corrected (step-separated nesting **translates**
  — §3/§9/§11), empty-body action degrade (§6), implementable pass order
  1 → 2a → 3 → 2b → 4 (§2), 4-bit branch-emission decision table with cause
  clauses on every `branch shape not representable` message (§3/§8), a
  dialect-neutral poison-ordering invariant test plus a one-line coupling
  comment in `sfc_translate.dart` (§9/§12), and assorted citation fixes.

---

## Goal

Make `<Routine Type="SFC">` in a Rockwell L5X export translate into a real,
executing native `SequentialFunctionChart` program, closing the last L5X import
gap (ST ✔, RLL ✔, FBD ✔, SFC ✘ → ✔).

The work is **a parser front-end only**. The neutral SFC IR
(`SfcBody`/`SfcNode`/`SfcEdge`/`SfcActionAssoc`/`SfcCond*`,
`import/import_ir.dart:106-151`), the whole-POU translator
(`translateSfcBody`, `import/sfc_translate.dart`) and the mapper arm that
consumes it (`import/ir_to_project.dart:386-407`, `body is SfcBody`) already
exist, already ship for PLCopen input, and are **used unchanged**. The only new
code is an L5X-dialect builder, `_l5xSfcBody`, that turns `<SFCContent>` into
that IR — the exact analog of `_l5xFbdBody` for `<FBDContent>`.

**Today's behaviour being replaced.** `l5x_parser.dart:914-921` handles
`case 'SFC':` by emitting an *empty* `SfcBody` **plus its own**
`WarningSeverity.warning` (`Routine "$name" (SFC): graphical body not yet
translated.`). The empty body then also trips `translateSfcBody`'s
`no-initial` bail-out, so the user sees the parser's warning *and* the
translator's *and* the mapper's — a three-message placeholder where the
PLCopen path emits two. The new arm **replaces that case entirely** and
**deletes the parser-level warning**, restoring exact parity with the PLCopen
SFC path (see §7).

---

## Scope

**In scope**

- `<Routine Type="SFC">` inside `Controller/Programs/Program/Routines`.
- `<SFCContent>` → `SfcBody`: steps, actions, transitions, selection and
  simultaneous branches, directed links, annotations.
- Removal of the parser-level SFC warning (double/triple-warning fix).
- Docs + deferred-registry updates.

**Out of scope (deliberately)**

- **AOI SFC logic.** Studio 5000 does not permit SFC as an Add-On Instruction
  `Logic` language (AOIs accept Ladder / FBD / Structured Text only). L5X SFC
  translation therefore targets **routines only**. `_l5xAois`' existing `else`
  arm — whose literal message is `AOI "$name" logic is ${logicType ?? '?'} —
  interface imported, logic not yet translated.` — is **kept as defensive
  dead-path handling** and gets no SFC branch. `keepsEnableParams` stays `false` for a non-RLL/non-FBD AOI, so
  `EnableIn`/`EnableOut` keep their historic skip. `docs/import/L5X.md`'s
  "SFC AOI logic" bullet is **corrected** to state the Studio 5000 restriction
  rather than implying the feature is merely unshipped (§10).
  *(Confidence note: the restriction is external product knowledge; nothing in
  this repo confirms or denies it. It is safe either way — if a real export
  ever carries an SFC-bodied AOI, the dead path still produces a clean
  interface-only FB + info warning, exactly as today.)*
- Any **behavioural** change to `sfc_translate.dart`, and any change at all to
  `import_ir.dart`, `ir_to_project.dart`, `models/sfc_exec.dart`, or
  `models/project_model.dart`. The single edit to `sfc_translate.dart` is a
  **one-line comment** above the step→step edge scan recording that import
  builders depend on it preceding every warning emission (§9/§12) — zero
  behaviour change, zero signature change.
- New `ImportReport` fields. `translatedSfcCount`, `stubbedSfcCount` and
  `sfcStubReasons` already exist, are dialect-agnostic, and are already
  rendered by `screens/import_xml_preview.dart:106-108`.

---

## North-star decisions (binding)

1. **Faithful-or-stub, at the granularity the translator already enforces.**
   Structure and transition conditions are **whole-POU**: anything the chart
   contains that cannot be represented faithfully stubs the entire POU rather
   than translating a partial chart (a half-translated sequence executes wrong
   logic, which is worse than not executing). Step **actions** degrade
   per-action to a no-op + warning, so an unsupported action qualifier does not
   cost the whole chart. This is `translateSfcBody`'s existing contract,
   inherited verbatim — the builder adds no new policy.
2. **Zero-change reuse.** `_l5xSfcBody` emits exactly the IR shapes
   `plcopen_parser.dart`'s `_sfcBody` emits. `translateSfcBody` and
   `ir_to_project`'s `body is SfcBody` arm are not touched. This is the same
   "one translator, two dialects" rule sub-project 4 established for FBD.
3. **Never silent.** Any ID-bearing `<SFCContent>` element the builder cannot
   map, any structurally broken branch, any dangling link, and any ID collision
   leads to a **visible whole-POU stub**, never to a dropped node or edge. The
   mechanism is the poison node of §4 — chosen specifically because it needs no
   translator change (CL-19's general lesson: an identity/topology defect in a
   graphical-import merge must be stub-worthy, never silent last-write-wins).
4. **Builder warnings are breadcrumbs, not verdicts.** Every warning
   `_l5xSfcBody` emits is `WarningSeverity.info` and names the offending
   element. The single unit-level verdict is the existing
   `translateSfcBody` + mapper pair — identical to the PLCopen path, and the
   reason the parser's own warning-severity message is deleted (§7).
5. **Annotations are dropped and counted.** `<TextBox>` / `<Attachment>` carry
   no logic; they are ignored at parse with one info warning per routine.
   The existing FBD constant `_kL5xFbdAnnotationElements` is **renamed to
   `_kL5xAnnotationElements`** and shared by both builders (pure rename, no
   member change), and the SFC builder **reuses the FBD message shape
   verbatim** — `'$ownerLabel: $ignoredCount element(s) ignored
   (${ignoredKinds.join(', ')}).'` (`l5x_parser.dart:741-745`) — so the
   assertable substring is `element(s) ignored`, identical across dialects.
6. **Synthetic ids are routine-wide, negative, and unique.** Malformed,
   out-of-range, duplicate and absent L5X `ID`s, the synthesized branch
   connectors (§3) and the poison node (§4) all draw from **one** descending
   counter per routine, starting at `-1` — mirroring `_l5xFbdBody`'s
   routine-wide `malformedId` counter. Because a raw `ID` is only ever
   accepted when it is **non-negative and ≤ `_kMaxL5xElementId`** (§2), no
   synthetic id can collide with a real one, and because there is exactly one
   counter, no two synthetic ids can collide with each other.
7. **Pure, deterministic, never-throws.** The builder returns a body for every
   input, including malformed XML fragments. Document order is the tiebreaker
   everywhere, so two runs over one file produce byte-identical IR.

---

## §1 — The L5X `<SFCContent>` schema

> **⚠ ASSERTED, UNVERIFIED IN-REPO.** This repository contains **no**
> SFC-bearing L5X: no corpus fixture, no vendored schema manual, no prior doc.
> The structure below is stated from Rockwell-format domain knowledge and is
> **pinned by synthetic, schema-faithful fixtures** written to this section —
> exactly the precedent set by the FBD sub-project for `<FBDContent>`. If a
> real export disagrees, the fixtures are what changes; §2–§4's algorithms are
> written to be tolerant of the two plausible encodings of the `<Branch>`
> element (§3) rather than betting on one.
>
> **Validation follow-up (recommended, tracked in `docs/DEFERRED.md`):**
> acquire one real SFC-bearing `.L5X` export from Studio 5000, add it to the
> local corpus, and run it through `corpus_import_test.dart`. That is the only
> thing that converts this section from asserted to verified.

`<Routine Name="Seq" Type="SFC">` carries one `<SFCContent>` child (the builder
tolerates more than one — see §2). Its children:

| Element | Asserted attributes / children | → neutral IR |
|---|---|---|
| `<Step>` | `ID`, `X`, `Y`, `Operand` (the step name, e.g. `Step_000`), `InitialStep` (`true`/`false`), `Preset`, `PresetUsesExpr`, `LimitHigh`, `LimitHighUsesExpr`, `LimitLow`, `LimitLowUsesExpr`, `ShowActions`; child `<Action>`s and/or a direct `<Body><STContent><Line>` | `SfcNode(kind: step, localId: ID, name: Operand, initial: InitialStep, x, y)`. Timing attributes **dropped** with an info warning (§5). |
| `<Action>` (child of `<Step>`) | `ID`, `Operand` (action name), `Qualifier` (`N`, `S`, `R`, `P`, `L`, `D`, …), `IsBoolean`, `Preset`, `PresetUsesExpr`; child `<Body><STContent><Line>` | `SfcActionAssoc(stepLocalId: <owning step ID>, qualifier: Qualifier ?? 'N', source: SfcActInline(<joined Line text>))`. Association comes from XML *nesting*, not from a link (contrast PLCopen's `<actionBlock>` + `connectionPointIn`). |
| `<Transition>` | `ID`, `X`, `Y`, `Operand` (transition name); child `<Condition><STContent><Line>` holding a BOOL ST expression | `SfcNode(kind: transition, localId: ID, name: Operand, condition: SfcCondInline(<expr>))`; empty/absent condition → `SfcCondNone()` (translator then stubs `unresolved-condition`). |
| `<Branch>` | `ID`, `X`, `Y`, `BranchType` = `Selection` \| `Simultaneous`; optional `BranchFlow` = `Diverge` \| `Converge`; child `<Leg ID="…">` elements | **No 1:1 IR node.** Synthesized into a *pair* of connector nodes (`selDiv`+`selConv`, or `simDiv`+`simConv`) — see §3. This is the design's crux. |
| `<Leg>` | `ID` | Not a node. Its `ID` is a **link endpoint** that resolves to the owning branch's div or conv node (§3). |
| `<DirectedLink>` | `FromID`, `ToID` | `SfcEdge(fromLocalId, toLocalId)` after endpoint resolution (§3). An endpoint naming no element → dangling link → poison (§4). |
| `<Stop>` | `ID`, `X`, `Y`, `Operand` | **No representable equivalent** in the native model → poison (§4) + info warning. Deferred: map to a terminal step. |
| `<TextBox>`, `<Attachment>` | `ID`, text/anchor | **Dropped** + counted; one info warning per routine. Not nodes, not link endpoints. |
| `<SbrRet>`, `<JSR>`, and any other ID-bearing child | — | Unknown → poison (§4) + info warning naming the raw tag and `ID`. |

**Two structural contrasts with PLCopen worth naming**, because they are why
`_sfcBody` cannot simply be pointed at L5X:

- **Actions nest inside their step**; PLCopen wires a sibling `<actionBlock>`
  to the step with a `connectionPointIn`. So on the L5X path
  `SfcActionAssoc.stepLocalId` is always a real step id and the translator's
  "action associated with unknown step" degrade is structurally unreachable
  (kept as defence, asserted absent by test).
- **Links are a flat `<DirectedLink FromID ToID>` list**; PLCopen carries the
  edge on the *target* element's `connectionPointIn`. So the L5X builder must
  resolve endpoints itself, which is what makes §3's branch synthesis possible
  at all.

**Never used on the L5X path.** Logix SFC has no external action/transition
POUs and no graphically-wired transition condition, so `SfcBody.refBodies` and
`SfcBody.graphicalRefs` stay **empty**, and `SfcCondRef`/`SfcActRef`/
`SfcCondWired` are never constructed. The translator's `unresolved-condition
(transition references …)`, `wired-condition`, and `action … not resolvable to
ST` paths are therefore dead for L5X input — kept in the translator (PLCopen
needs them), asserted unreachable by an L5X test.

**`SfcNodeKind.jump` is likewise never emitted.** Logix expresses a loop-back
as an ordinary `<DirectedLink>` to an earlier element, not as a distinct jump
element, so the builder has nothing to map onto it and the translator's
`jump to unknown step` path is dead for L5X input. This is an §8 invariant
(`no node of kind jump appears in an L5X-built `SfcBody``) precisely because a
future "unknown element → jump with an impossible name" shortcut is the
tempting-but-wrong alternative §4 rejects.

---

## §2 — The builder: `_l5xSfcBody`

```dart
/// Parses one `<Routine Type="SFC">`'s `<SFCContent>` into the neutral
/// `SfcBody` the shared `translateSfcBody` consumes. Pure, deterministic,
/// never throws. [ownerLabel] is `'Routine "<Program>_<Routine>"'`.
SfcBody _l5xSfcBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel)
```

Signature and `ownerLabel` convention mirror `_l5xFbdBody`
(`l5x_parser.dart:444`) exactly.

**Container handling.** Iterate **all** `<SFCContent>` children in document
order and merge their elements into one body. Unlike FBD's `<Sheet>` merge,
there is **no id offsetting and no y offsetting**: an SFC routine is a single
chart with routine-unique `ID`s, and offsetting would break the `<DirectedLink>`
ids, which are absolute. A duplicate `ID` across containers is therefore a
defect, handled by the duplicate-ID rule below rather than papered over — the
direct application of CL-19 to this file.

### The ID gate (mirrors `_l5xFbdBody` verbatim)

Every element's raw `ID` runs through the **same four-way rejection** the FBD
builder uses at `l5x_parser.dart:528-536`:

```dart
final parsed = int.tryParse(el.getAttribute('ID') ?? '');
final duplicate =
    parsed != null && parsed >= 0 && assignedByRawId.containsKey(parsed);
final int localId;
if (parsed == null || parsed < 0 || parsed > _kMaxL5xElementId || duplicate) {
  localId = malformedId--;          // synthetic, negative, unique
  // + info warning (`malformed ID` / `duplicate ID`) + POISON
} else {
  localId = parsed;
  assignedByRawId[parsed] = localId;
}
```

`_kMaxL5xFbdId` (`l5x_parser.dart:182`, `1 << 31`) is **renamed to
`_kMaxL5xElementId`** and shared by both builders (pure rename).

**Why `parsed < 0` is not optional here, and is in fact a correctness gate
rather than hygiene.** A `<Step ID="-1">` would otherwise register `localId ==
-1` in the *same* namespace as the descending synthetic counter that §3's
branch connectors and §4's poison node draw from. With one valid branch in the
chart, `-1` is exactly `divId` of the first branch, and the collision does
**not** poison anything: `_build`'s `byId` map is last-write-wins (the
connector shadows the step), while `stepNodes` is built by filtering
`body.nodes` (so **both** survive), and `succ`/`pred` merge the two nodes'
edges under one key. The result is a chart that translates **cleanly, with zero
warnings, as the wrong logic** — the precise CL-19 failure mode this file is
supposed to be immune to. The gate is what makes north-star 6's uniqueness
claim true.

**Duplicate-ID severity — deviation from the FBD table, deliberate.** FBD
raises duplicate-ID to `WarningSeverity.warning` because there the stub is
per-network and the routine may still translate, so the collision needs its own
loud message. Here the stub is whole-POU and the loud message already exists
twice (translator + mapper), so the breadcrumb stays `info` per north-star 4.

### Pass structure

Branch-incident link classification (§3) needs **both** a complete element/kind
table **and** the full link list before it can decide anything, and connector
edges must be emitted before the remaining edges so a single ordered edge list
falls out. So the builder runs five phases, not four. Within every phase,
**document order** (of elements, then of the `<DirectedLink>` list) is the sole
tiebreaker, which is what makes the output byte-identical run to run.

**Pass 1 — register elements.** For each child element of each `<SFCContent>`:

1. `<TextBox>` / `<Attachment>` (`_kL5xAnnotationElements`) → increment
   `ignoredCount`, record the tag in `ignoredKinds`, record the raw `ID` in
   `annotationIds`, `continue`. Registering the id is what lets pass 2a
   distinguish an annotation anchor from a dangling link.
2. Run the ID gate above.
3. Dispatch on tag:
   - `<Step>` → `SfcNode(kind: step, …)`; collect its actions (§6); check its
     timing attributes (§5).
   - `<Transition>` → `SfcNode(kind: transition, condition: …)` (§6).
   - `<Branch>` → **no node yet**; register `ID` in `branchById` (with its
     `BranchType`/`BranchFlow`) and each direct `<Leg ID>` child in
     `legToBranch`, running the ID gate on each leg id too.
   - `<Leg>` appearing as a *top-level* `<SFCContent>` child (i.e. not under a
     `<Branch>`) → **poison** + info warning `no representable equivalent`.
   - anything else ID-bearing → **poison** + info warning
     `no representable equivalent`, naming the raw tag and id.
4. Record `kindById[localId]` (`step` / `transition` / `branch` / `leg` /
   `annotation`) — pass 2a's classifier reads it.

Nodes are appended in document order; `initial`, `name`, `x`, `y` are read as
per §1. `name` prefers `Operand`, falls back to `Name`, else `''` (the
translator then synthesizes `s<localId>`).

**Recursion policy — flat, one level.** Pass 1 walks the **direct** children of
each `<SFCContent>`, plus the direct `<Leg>` children of a `<Branch>`. It does
**not** descend further. A `<Branch>` nested as a child of a `<Leg>` element
(rather than as a sibling wired by links) is therefore never registered, so any
link naming it resolves to nothing → `dangling link` → **poison**. That is an
acceptable outcome (visible stub, never silent), and it is stated here rather
than left implicit because "does the walk recurse?" is the first question an
implementer asks. Recursive registration is a §11 deferred row, gated on a real
export showing Logix actually nests that way.

**Pass 2a — collect and classify links.** Read every `<DirectedLink>` into a
list in document order. For each, resolve both endpoints through §3's unified
classifier. Links **incident to a branch or leg id** are bucketed into that
branch's `divIn` / `divOut` / `convIn` / `convOut` sets and held back; all
others are kept as ordinary pending edges. An endpoint that resolves to nothing
→ info warning `dangling link` + **poison**, with the edge **still emitted**
against a fresh synthetic id so nothing is silently dropped.

**One exception, deliberate:** a link whose endpoint names a **dropped
annotation** (its id is in `annotationIds`) is discarded whole, with **no**
`dangling link` warning and **no** poison. Logix anchors an annotation to the
element it comments on, and that anchor is a documentation relationship, not a
control-flow edge — poisoning a chart because it is well commented would be
absurd.

**Pass 3 — synthesize branch connectors** (§3): decide emission per side from
the bucketed sets, run shape validation, append the connector `SfcNode`s and
the edges that touch them.

**Pass 2b — emit remaining edges.** Append the pending non-branch edges from
pass 2a, in their original document order. (Numbered `2b` because it is the
back half of pass 2, deferred only so connector edges lead the list; nothing
in `translateSfcBody` depends on edge order, so this is presentation and
determinism, not semantics.)

**Pass 4 — finalize.** Emit the annotation info warning if `ignoredCount > 0`;
if the poison flag is set, append the poison node + its self-edge (§4). Return
`SfcBody(nodes:, edges:, actions:, refBodies: const {}, graphicalRefs: const {})`.

---

## §3 — Branch → divergence/convergence synthesis (the crux)

### The mismatch

The neutral IR (and IEC 61131-3, and the app's `sfc_exec`) models a branch as
**two connector nodes** — an opening divergence and a closing convergence —
with ordinary edges between them and the elements on each leg. L5X models it as
**one `<Branch>` element carrying `<Leg>` children**, with the actual wiring
expressed as `<DirectedLink>`s. The builder must therefore *synthesize* the
IR's node pair, and it must place them where `translateSfcBody` expects them.

### What the translator expects (read off `sfc_translate.dart:107-180`)

`upstreamSteps` / `downstreamSteps` accept connectors only in these four
positions, and stub `complex-topology` otherwise:

| Connector | Predecessors | Successors | Reached from |
|---|---|---|---|
| `selDiv` | exactly one `step` | `transition`s | a transition's `pred` |
| `selConv` | `transition`s | `step`s (one, for a `single` transition) | a transition's `succ` |
| `simDiv` | one `transition` | `step`s | a transition's `succ` → `parallelFork` |
| `simConv` | `step`s | one `transition` | a transition's `pred` → `parallelJoin` |

So a **Selection** branch sits *between a step and the leg-opening
transitions* (divergence) and *between the leg-closing transitions and a step*
(convergence); a **Simultaneous** branch sits *between a transition and the leg
steps* and *between the leg steps and a transition*. That asymmetry — selection
diverges into transitions, simultaneous diverges into steps — is the single
fact the synthesis must get right.

### Allocation

For each `<Branch ID=B BranchType=T>`, reserve **two** synthetic negative ids
from the routine-wide counter (north-star 6): `divId(B)` and `convId(B)`.
Kinds:

- `T == "Selection"` → `selDiv` / `selConv`
- `T == "Simultaneous"` → `simDiv` / `simConv`
- absent, empty, or any other value → **poison** + info warning
  `branch type "<value>" not recognized`; no nodes synthesized.

`BranchFlow`, if present, is **read but not trusted**: emission is derived from
link topology (below), so an export that splits a branch into separate
`Diverge` and `Converge` elements and one that emits a single paired element
both work without a mode switch. A `BranchFlow` that contradicts the derived
topology is recorded as an info warning (`branch flow mismatch`) and the
derived topology wins — it is the thing the links actually say.

### The unified endpoint classifier

There is **one** rule, applied always. There is deliberately **no** "primary
encoding vs. fallback encoding" mode switch and **no** mixed-convention
detection — those were an earlier design and are wrong, because in the paired
encoding a branch's *trunk* links must name the `<Branch>` id while its *leg*
links name `<Leg>` ids, so **every paired branch mixes both forms by
construction** and a mixed-convention poison rule would stub the common case
(including this spec's own headline fixture).

For a `<DirectedLink FromID="f" ToID="t">`, each endpoint is classified
independently:

| Endpoint names… | Role |
|---|---|
| a `<Step>` or `<Transition>` | that node's `localId`; the link is an ordinary edge on that side |
| a `<Leg>` of branch `B`, as `FromID` | `divId(B)` — the divergence feeds this leg's head |
| a `<Leg>` of branch `B`, as `ToID` | `convId(B)` — this leg's tail feeds the convergence |
| a `<Branch>` `B` | **the other endpoint's node kind decides** — see the kind table below |
| an annotation | link discarded whole (§2), no warning, no poison |
| nothing | `dangling link` → **poison** |

**Leg endpoints resolve by direction** (rows 2–3). This is unambiguous: a leg
id can only ever mean "the branch-side end of this leg", and which end is
fixed by the arrow.

**Branch endpoints resolve by the other endpoint's kind** (row 4), using the
branch type's expected pattern from the translator table:

| Branch type | link direction | other endpoint is a… | Role |
|---|---|---|---|
| Selection | `ToID == B` | `Step` | trunk-in → `divIn` |
| Selection | `ToID == B` | `Transition` | leg tail → `convIn` |
| Selection | `FromID == B` | `Transition` | leg head → `divOut` |
| Selection | `FromID == B` | `Step` | trunk-out → `convOut` |
| Simultaneous | `ToID == B` | `Transition` | trunk-in → `divIn` |
| Simultaneous | `ToID == B` | `Step` | leg tail → `convIn` |
| Simultaneous | `FromID == B` | `Step` | leg head → `divOut` |
| Simultaneous | `FromID == B` | `Transition` | trunk-out → `convOut` |
| either | either | another `<Branch>` or `<Leg>` id — i.e. connector-adjacent nesting, since both sides resolve to connectors with nothing between | **poison**, cause `branch is directly adjacent to another branch` |
| either | either | unresolvable | `dangling link` → **poison** |

**Why the kind rule and not a direction rule for `<Branch>` endpoints.** The
naive alternative — "`ToID == B` means div, `FromID == B` means conv", the
mirror of the leg rule — agrees with the kind rule on **every trunk link in
both encodings**, so it costs nothing there. But it is strictly worse on a
**leg-role link expressed via the branch id** (a converge-only `<Branch>` with
no `<Leg>` children, or any exporter that wires leg tails to `B` directly):
there the direction rule would classify a leg tail as `convIn`… and a leg
*head* link `FromID == B → T1` as `convOut`, wiring `conv → T1` — a silently
wrong chart that still passes every shape check. The kind rule reads
`FromID == B → Transition` as a **leg head** and yields `div → T1`, which is
right. Since the kind rule dominates everywhere and ties nowhere, it is the
only rule.

The kinds are unambiguous in both branch types (selection diverges into
transitions and converges out to a step; simultaneous is the mirror), which is
what makes this a decision rather than a guess.

**Leg membership is never computed.** Only each leg's head and tail matter, and
both fall straight out of the table. The builder has no notion of "the elements
inside leg 2".

### Emission — the 4-bit decision table

Pass 2a leaves each branch with four booleans: `divIn`, `divOut`, `convIn`,
`convOut` (each "is this set non-empty"). Emission is a total function of
those 4 bits — every one of the 16 combinations is named, so there is no
"provided the other side was emitted" hand-waving:

| `divIn` | `divOut` | `convIn` | `convOut` | Shape | Outcome |
|:-:|:-:|:-:|:-:|---|---|
| 1 | 1 | 1 | 1 | paired diverge + converge (the common case) | emit **both** connectors |
| 1 | 1 | 0 | 0 | diverge-only `<Branch>` (`BranchFlow="Diverge"`, or legs that never re-merge) | emit **div only**; conv dropped |
| 0 | 0 | 1 | 1 | converge-only `<Branch>` (`BranchFlow="Converge"`) | emit **conv only**; div dropped |
| 1 | 1 | 1 | 0 | legs re-merge but the merge goes nowhere | emit both, **poison**, cause `convergence has no outlet` |
| 1 | 1 | 0 | 1 | a merge outlet with nothing merging into it | emit both, **poison**, cause `convergence has no inlet` |
| 1 | 0 | 1 | 1 | divergence with no legs | emit both, **poison**, cause `divergence has no legs` |
| 0 | 1 | 1 | 1 | legs with no source | emit both, **poison**, cause `divergence has no inlet` |
| 1 | 0 | 0 | 0 | trunk enters, nothing leaves | emit div, **poison**, cause `divergence has no legs` |
| 0 | 1 | 0 | 0 | legs with no source | emit div, **poison**, cause `divergence has no inlet` |
| 0 | 0 | 1 | 0 | legs merge into nothing | emit conv, **poison**, cause `convergence has no outlet` |
| 0 | 0 | 0 | 1 | outlet with nothing merging | emit conv, **poison**, cause `convergence has no inlet` |
| 1 | 0 | 1 | 0 | both sides half-wired | emit both, **poison**, cause `divergence has no legs` |
| 1 | 0 | 0 | 1 | both sides half-wired | emit both, **poison**, cause `divergence has no legs` |
| 0 | 1 | 1 | 0 | both sides half-wired | emit both, **poison**, cause `divergence has no inlet` |
| 0 | 1 | 0 | 1 | both sides half-wired | emit both, **poison**, cause `divergence has no inlet` |
| 0 | 0 | 0 | 0 | a `<Branch>` no link touches | emit **neither**, **poison**, cause `branch has no links` |

Reading of the table: a side is **emitted** whenever either of its bits is set,
**dropped** when both are clear *and* the other side is well-formed, and any
side with exactly one bit set is a defect. Poisoned branches still emit their
connectors so the element count stays honest. Where two causes could apply, the
**divergence-side cause wins** (deterministic, and it is the upstream defect —
the one a user fixes first).

**Loop-back leg** (a leg tail wired to an upstream step instead of back into
the branch) is not a special case: that link never touches a branch/leg id, so
it is an ordinary edge, and the branch's own bits land on row 2 (diverge-only)
if no leg closes, or row 1 if some do.

### Shape validation (before emission)

For each **emitted** connector, assert the neighbour kinds from the translator
table; violations → **poison** + info warning naming the branch `ID`, the
offending neighbour, and the cause:

| Connector | Assertion | Cause clause on failure |
|---|---|---|
| `selDiv` | exactly one inflow, a `step` | `selection divergence inlet is a <kind>, expected step` / `selection divergence has N inlets, expected 1` |
| `selDiv` | every outflow is a `transition` | `selection leg head is a <kind>, expected transition` |
| `selConv` | every inflow is a `transition` | `selection leg tail is a <kind>, expected transition` |
| `selConv` | exactly one outflow, a `step` | `selection convergence outlet is a <kind>, expected step` |
| `simDiv` | exactly one inflow, a `transition` | `simultaneous divergence inlet is a <kind>, expected transition` |
| `simDiv` | every outflow is a `step` | `simultaneous leg head is a <kind>, expected step` |
| `simConv` | every inflow is a `step` | `simultaneous leg tail is a <kind>, expected step` |
| `simConv` | exactly one outflow, a `transition` | `simultaneous convergence outlet is a <kind>, expected transition` |

Every message is `branch shape not representable (<cause>)`, so the stable
substring stays assertable while each §9 case pins its own cause and one defect
can never be mistaken for another.

Why validate here rather than letting `translateSfcBody` catch it: the
translator's gates are reached **only from a transition's pred/succ walk**. A
malformed connector that is not on any transition's walk — e.g. a `selDiv`
whose successors are steps rather than transitions — would be *ignored*, and
the steps behind it would become unreachable islands that vanish without a
word. Validating the shape at synthesis time is what makes north-star 3 total
for branches. The translator's own gates remain as a backstop.

### Cases that are explicitly fine (they translate)

- **Single-leg branch.** A `selDiv` with one outflow transition, or a `simDiv`
  with one outflow step, translates as an ordinary linear path (`upstreamSteps`
  /`downstreamSteps` see through the connector). No warning, no stub — it is a
  faithful, if pointless, chart.
- **Selection branch with unequal leg lengths.** Irrelevant: only heads and
  tails are used.
- **Step-separated nested branches — these TRANSLATE, and correctly.** A branch
  whose leg contains a step which then opens a second branch is the ordinary
  way real charts nest, and the IR handles it with no special support: the
  inner branch's `selDiv` sees that intervening step as its single inflow,
  every shape check passes, and `upstreamSteps`/`downstreamSteps` resolve each
  transition through exactly one connector to exactly one step. Nothing about
  nesting per se is unsupported. §9 pins this with a happy-path test precisely
  because "nested branches stub" is the intuitive-but-false claim.
- **Loop-back leg.** See the emission table.

### Cases that stub (visibly)

**Connector-adjacent** branches — a leg head or tail that is *itself* a
`<Branch>`, producing a `div→div`, `conv→conv` or `div→conv` edge with no step
or transition between the two connectors. `upstreamSteps`/`downstreamSteps`
only see through **one** connector (their `selDiv`/`simConv` arms require every
predecessor to be a `step`, and a connector is not), so a connector chain has
no representable resolution. Caught by the classifier's connector row and by
shape validation; cause `branch is directly adjacent to another branch`.

Also stubbing: a leg head or tail of the wrong kind, more than one trunk-in or
trunk-out, an unrecognized `BranchType`, any of the defect rows of the emission
table, and a `<Branch>` no link touches.

---

## §4 — Unrepresentable elements: the poison-node rule

**Requirement.** Any ID-bearing element the builder cannot map — `<Stop>`,
`<SbrRet>`, `<JSR>`, an unknown future tag — plus every structural defect above
(malformed id, duplicate id, dangling link, broken branch) must produce a
**visible whole-POU stub**, never a silently dropped node or edge. And it must
do so **without modifying `sfc_translate.dart`**.

**Mechanism chosen: one poison node carrying a self-edge.**

The builder keeps a routine-level `bool unrepresentable` flag. Any defect sets
it and emits its own `info` breadcrumb naming the element. In pass 4, if the
flag is set, the builder appends:

```dart
final pid = malformedId--;                       // synthetic negative
nodes.add(SfcNode(localId: pid, kind: SfcNodeKind.step, name: '#unrepresentable'));
edges.add(SfcEdge(fromLocalId: pid, toLocalId: pid));   // step -> step
```

`malformedId` is the **one** routine-wide counter of north-star 6, initialised
to `-1` and post-decremented — exactly `_l5xFbdBody`'s `var malformedId = -1;`
(`l5x_parser.dart:449`). §3's `divId`/`convId` and §2's malformed/duplicate ids
draw from this same counter, which is why no two synthetic ids can collide;
§2's `parsed < 0` gate is what stops a raw `ID` from colliding with them.

**Why this is airtight.** `_build`'s step→step edge scan
(`sfc_translate.dart:50-55`) is **unconditional over `body.edges`** — it runs
before the succ/pred maps are built, before actions are grouped, before any
step or transition is processed, and it does not care about reachability. A
step node with a self-edge therefore *always* throws
`_SfcStub('complex-topology', 'step directly wired to step (missing
transition)')`. Position-independent, edge-order-independent, deterministic.

**Why exactly one verdict message.** Everything in `_build` that emits a
warning (`action associated with unknown step`, the per-action qualifier
degrades, `no initial step marked`) sits **after** that scan, so a poisoned
body produces **no** translator info warnings at all — just the single
`SFC POU "…": not translated (step directly wired to step (missing
transition)).` from `translateSfcBody`, plus the mapper's existing
`graphical body not yet translated` line. That is precisely the two-message
shape the PLCopen SFC path produces today for any stub; the builder adds no
third warning-severity message (north-star 4, §7).

**Why the reason bucket is right.** `complex-topology` is `sfcStubReasons`'
"the chart contains a shape we can't represent" bucket, which is exactly what
an unmappable element is. It is also the bucket the translator would have
picked had it been able to see the element.

**Why not the alternatives** (recorded so a reviewer does not re-litigate):

- *Emit the element as a node the translator rejects incidentally* (e.g. a
  `jump` with an impossible target name). Rejected: it only fires when the node
  happens to be a transition's successor. A `<Stop>` reached from a step, or an
  unknown element on an orphan path, would be ignored — silent loss, the exact
  failure north-star 3 forbids.
- *Emit a synthetic transition with `SfcCondNone()`.* Also unconditional (the
  transitions loop resolves the condition first, and `SfcCondNone` always
  throws), but it lands in the `unresolved-condition` bucket, which would
  corrupt the `sfcStubReasons` counter the preview screen shows.
- *Add a flag to `SfcBody`.* Rejected: changes the dialect-neutral IR for a
  dialect-specific concern, and forces a matching `sfc_translate` change.

**Known cosmetic cost.** The poison node counts toward `body.nodes.length`, so
the mapper's `(N elements captured)` is one higher than the chart's real
element count (and unmappable elements are not emitted as nodes at all, so the
count is approximate in the other direction too). `(N elements captured)` is
already an approximate IR-node count on every dialect; not worth a fix.

---

## §5 — Step timing attributes

Logix steps carry `Preset`, `LimitHigh`, `LimitLow` (each with a
`*UsesExpr` companion) — a step timer plus high/low residence limits and their
alarm bits. `SfcStep` has `{id, name, isInitial, actionSt}` and nothing else;
`sfc_exec` has no per-step timer or preset. **These are not structurally
representable, and v1 drops them.**

Dropping is *not* silent: one `WarningSeverity.info` per step per attribute,
naming both, substring `timing attribute`:

> `Routine "Main_Seq": SFC step "Step_003" timing attribute Preset dropped — no native step timer (use STEP_T in a transition condition).`

**Emit the warning only when the attribute is meaningful** — present and
parsing to a non-zero number, or with `*UsesExpr="true"`. Logix writes
`Preset="0"` on every step in a typical export; warning on those would bury the
real ones. This gate is a named test case.

**Post-import path for the user.** `sfc_exec` injects `STEP_T` (elapsed time in
the active step) as an ST variable usable in a transition condition, so a
dropped `Preset="5000"` is hand-recoverable as `STEP_T >= 5000` on the step's
outgoing transition. The warning text points at it; `docs/iec61131/
SEQUENTIAL_FUNCTION_CHART.md` documents it (§10). Automatic synthesis of that
condition is **deferred** (§11) — it would silently rewrite a transition the
user did not author, and it interacts with a transition that already has a
condition (`AND`? replace?), which needs a real corpus to decide.

---

## §6 — Actions and conditions

**Actions.** For each `<Step>`:

1. If it has `<Action>` children, each becomes one `SfcActionAssoc` with
   `stepLocalId` = the step's resolved id, `qualifier` = `Qualifier ?? 'N'`,
   `source` = `SfcActInline(<Body><STContent><Line>` texts joined with `\n`,
   trimmed). Document order is preserved, which is the order the translator
   concatenates them into `actionSt`.
2. Else, if the `<Step>` carries a direct `<Body><STContent>`, that becomes a
   single implicit `N`-qualified inline action.
3. Else, no actions (`actionSt` = `''`).

**An action with an empty or absent body** must not vanish. `SfcActInline('')`
reaches `_actionSt`, whose `if (s.text.isNotEmpty)` guard drops it **without a
warning** — the one silent-loss hole left in the otherwise-loud action path,
and one the builder must close because only the builder knows the action
existed. So: an `<Action>` whose `<Body><STContent>` is missing, empty, or
whitespace-only is **not** emitted as an `SfcActionAssoc`; instead the builder
emits one `WarningSeverity.info` naming the step and the action, assertable
substring `action has no body`. This is a **per-action degrade, not a poison** —
an empty action is a documentation stub in the source chart, not a structural
defect, and taking down a 40-step chart for one would violate north-star 1's
action-granularity rule.

**Non-`N` qualifiers** (`S`, `R`, `P`, `L`, `D`, `SD`, `DS`, `SL`) reach the
translator untouched and hit its existing per-action degrade: skipped, chart
still translates, one info warning with the verbatim substring
`unsupported — action skipped (N only)`. The builder does **not** pre-filter
them — that would duplicate policy and lose the translator's message.

**`IsBoolean="true"` actions** name a BOOL tag that Logix holds true while the
step is active and clears on deactivation. `actionSt` runs only while the step
is active but nothing runs on deactivation, so `Op := TRUE;` would leave the
bit latched forever — wrong logic, not a degrade. The builder therefore
**skips** a boolean action with an info warning (substring `boolean action`)
and defers set/reset synthesis (§11).

**Conditions.** `<Transition>`'s `<Condition><STContent><Line>` texts join with
`\n`, trim, and **a single trailing `;` is stripped** — `SfcTransition.
conditionSt` is evaluated as a boolean *expression* by `sfc_exec`, and a
trailing statement terminator would fail to parse. Empty or absent →
`SfcCondNone()`, which the translator turns into the whole-POU
`unresolved-condition` stub (correct: a transition with no condition either
never fires or fires always, and guessing which is worse than stubbing).

---

## §7 — Routine arm, and the double-warning removal

`_l5xRoutines`' `case 'SFC':` becomes, in full:

```dart
case 'SFC':
  // <SFCContent> parses into a real SfcBody; ir_to_project's existing
  // `body is SfcBody` arm translates it whole-POU (faithful-or-stub) via
  // the shared translateSfcBody. A chart that does not translate keeps
  // that arm's stub — no parser-level warning, so the message count
  // matches the PLCopen SFC path exactly.
  out.add(ImportedPou(name: name, kind: PouKind.program,
      lang: PouLanguage.sfc, localVars: const [],
      body: _l5xSfcBody(r, warnings, 'Routine "$name"')));
  break;
```

The `warnings.add(... 'Routine "$name" (SFC): graphical body not yet
translated.')` line is **deleted**. `_l5xRoutines`' doc comment (which
currently says SFC "still becomes an empty graphical body … + a
count-carrying warning") is rewritten to match the FBD sentence next to it.

**Message-count contract after this change**, asserted by a regression test:

All three rows are scoped to **messages naming this POU** — an import carrying
other routines legitimately produces warnings of its own, so the tests filter
on the POU name rather than counting the whole list:

| Outcome | Messages naming this POU |
|---|---|
| SFC routine translates | **zero** warning-severity messages naming this POU; only builder/translator `info` breadcrumbs, if any |
| SFC routine stubs | exactly **two** warning-severity messages naming this POU — `translateSfcBody`'s `SFC POU "…": not translated (<detail>).` and the mapper's `POU "…" (SequentialFunctionChart): graphical body not yet translated (N elements captured) …` — identical to the PLCopen path |
| `parseL5x` alone, any SFC routine | **zero** warning-severity messages naming this POU |

---

## §8 — Error handling and warning severities

Never-throws throughout. Every substring below is an exact, assertable
fragment.

**Builder-emitted (all `WarningSeverity.info`, all prefixed `ownerLabel`)**

| Situation | Severity | Assertable substring | Consequence |
|---|---|---|---|
| `<TextBox>` / `<Attachment>` present | info | `element(s) ignored` (FBD message shape, reused verbatim) | dropped; one warning per routine, kinds deduped |
| Unknown ID-bearing element (`<Stop>`, `<SbrRet>`, `<JSR>`, top-level `<Leg>`, future) | info | `no representable equivalent` | **poison** → whole-POU stub |
| `ID` absent, unparseable, **negative**, or **> `_kMaxL5xElementId`** | info | `malformed ID` | synthetic negative id + **poison** |
| `ID` reused by a later element | info | `duplicate ID` | later claimant gets a synthetic id (raw id never re-registered) + **poison** |
| `<DirectedLink>` endpoint names nothing | info | `dangling link` | edge kept against a synthetic id + **poison** |
| `<DirectedLink>` endpoint names a dropped annotation | — | (none) | link discarded whole; no poison — an annotation anchor is documentation, not control flow |
| `BranchType` absent/unrecognized | info | `branch type` | **poison**; no connectors synthesized |
| Any branch defect: an emission-table defect row, a wrong-kind leg head/tail, >1 trunk-in or trunk-out, connector-adjacent nesting, or a `<Branch>` no link touches | info | `branch shape not representable (` **+ a cause clause** | **poison** |
| `BranchFlow` contradicts derived topology | info | `branch flow mismatch` | derived topology wins; no stub |
| Step `Preset` / `LimitHigh` / `LimitLow` meaningful | info | `timing attribute` | dropped; chart still translates |
| `<Action IsBoolean="true">` | info | `boolean action` | action skipped; chart still translates |
| `<Action>` with empty/absent body | info | `action has no body` | action skipped; chart still translates |

**Cause clauses** carried inside `branch shape not representable (<cause>)` —
each is asserted by its own §9 case, so no two branch defects share a
message:

`divergence has no inlet` · `divergence has no legs` ·
`convergence has no inlet` · `convergence has no outlet` ·
`branch has no links` · `branch is directly adjacent to another branch` ·
`selection divergence inlet is a <kind>, expected step` ·
`selection divergence has N inlets, expected 1` ·
`selection leg head is a <kind>, expected transition` ·
`selection leg tail is a <kind>, expected transition` ·
`selection convergence outlet is a <kind>, expected step` ·
`simultaneous divergence inlet is a <kind>, expected transition` ·
`simultaneous leg head is a <kind>, expected step` ·
`simultaneous leg tail is a <kind>, expected step` ·
`simultaneous convergence outlet is a <kind>, expected transition`

**Inherited verbatim from `translateSfcBody` (unchanged, no L5X-specific text)**

| Situation | Severity | Assertable substring |
|---|---|---|
| Non-`N` action qualifier | info | `unsupported — action skipped (N only)` |
| Action on an unknown step id (unreachable on L5X — asserted by test) | info | `action associated with unknown step` |
| Action ref not resolvable to ST (unreachable on L5X) | info | `not resolvable to ST — skipped` |
| No step marked initial | info | `no initial step marked — first step used` |
| Whole-POU bail-out | **warning** | `not translated (` + one of: `chart has no steps` (`no-initial`) · `step directly wired to step (missing transition)`, `dangling edge`, `selDiv upstream not a step`, `simConv upstream not a step`, `selConv downstream not a step`, `simDiv downstream not a step`, `jump to unknown step`, `unsupported transition source`, `unsupported transition target`, `unsupported transition fan-in/out` (`complex-topology`) · `transition has no condition`, `transition references` (`unresolved-condition`) · `graphical transition condition` (`wired-condition`) |

**Inherited from the mapper arm (unchanged)**

| Situation | Severity | Assertable substring |
|---|---|---|
| Whole-POU stub | **warning** | `graphical body not yet translated` |

**Invariants asserted by test**

- **`localId` uniqueness.** No two `SfcNode`s in a built body share a
  `localId` — across real ids, malformed/duplicate synthetics, branch
  connectors and the poison node alike. This is the invariant Critical 2 exists
  to protect: a shared `localId` makes `_build`'s `byId` last-write-wins while
  `stepNodes`/`succ`/`pred` keep both, which translates cleanly as wrong logic.
  Asserted directly (`nodes.map((n) => n.localId).toSet().length ==
  nodes.length`) on every fixture in the suite, not just the malformed ones.
- **Every synthetic `localId` is negative and every real one is in
  `[0, _kMaxL5xElementId]`** — the two ranges cannot overlap, which is what
  makes the uniqueness invariant hold by construction rather than by luck.
- No negative `localId` ever reaches a `SfcStep.id` / `SfcTransition.id`: a
  poisoned body always stubs, and branch connectors never become steps or
  transitions. (Guards against a program id like `Main_Seq_s-3`.)
- **No node of kind `jump`** appears in an L5X-built `SfcBody` (§1).
- A poisoned body emits **zero** translator info warnings (the edge scan
  precedes all of them).
- `SfcBody.refBodies` and `.graphicalRefs` are empty for every L5X input.

---

## §9 — Testing

**New: `mobile/test/import/l5x_parser_sfc_test.dart`** (parser units, synthetic
fixtures written to §1's asserted schema)

*Happy paths*
- Linear chart: 2 steps + 1 transition + 2 links → 2 `step` nodes, 1
  `transition` node with `SfcCondInline`, 2 edges; `initial` set from
  `InitialStep="true"`.
- Step with two `<Action Qualifier="N">` children → two `SfcActionAssoc`s in
  document order, both `SfcActInline`; step with a direct `<Body><STContent>`
  and no `<Action>` → one implicit `N` action.
- Condition `<Line>` joining, trim, and single-trailing-`;` strip.
- `Operand` → `name`; `X`/`Y` → `x`/`y`; missing `Operand` → `''`.

*Branch synthesis (§3) — the heart of the suite*

- **Selection branch, 2 legs, paired diverge+converge.** Elements: `S0` →
  branch `B` (legs `L1`,`L2`) → legs open with `T1`,`T2`, close with `T3`,`T4`
  → `S5`. Expected `selDiv` + `selConv` nodes and exactly these **6** edges:
  `S0→selDiv`, `selDiv→T1`, `selDiv→T2`, `T3→selConv`, `T4→selConv`,
  `selConv→S5`.
- **Simultaneous branch, 2 legs — written out in full** (not "swapped per the
  table"): `S0` → `T0` → branch `B` → legs open with `S1`,`S2`, close with
  `S3`,`S4` → `T5` → `S6`. Expected `simDiv` + `simConv` and exactly these
  **6** branch edges: `T0→simDiv`, `simDiv→S1`, `simDiv→S2`, `S3→simConv`,
  `S4→simConv`, `simConv→T5` (plus the ordinary `S0→T0`, `T5→S6`, and the
  intra-leg edges). Translates to one `parallelFork` and one `parallelJoin`.
- **Encoding equivalence.** The same two charts wired via the `<Branch>` `ID`
  for the leg links (no `<Leg>` ids as endpoints anywhere) must produce the
  **same edge multiset over `(fromKind, toKind)` pairs, modulo connector
  `localId` values** — not literally "identical IR", since connector ids are
  allocation-order-dependent and the fixtures differ in element count. A
  small helper that projects `edges` onto `(kindOf(from), kindOf(to))` and
  compares as a multiset is what makes this assertable; both encodings must
  also produce the same `SfcTranslation` (same step/transition ids, kinds and
  `fromStepIds`/`toStepIds` sets).
- **`<Branch>` with no `<Leg>` children at all**, all four roles wired through
  the branch id — legal under the branch-id form — translates identically to
  the leg-id form. (Directly pins the deletion of the "no Leg id ⇒ fallback
  mode" gate: there is no mode, so this fixture needs no special handling.)
- **Both forms in one branch** (trunk via `B`, legs via `L1`/`L2` — i.e. the
  paired encoding's natural shape) → **translates**. This is the fixture the
  deleted mixed-convention rule would have poisoned; it exists to make that
  regression impossible to reintroduce silently.
- Diverge-only `<Branch>` (emission row 2) → div node only, conv dropped, no
  poison, chart translates.
- Converge-only `<Branch>` (row 3) → mirror image.
- Single-leg branch → connectors emitted, no warning, translates.
- **Step-separated nested selection branches → TRANSLATE** (happy path, not a
  stub): outer selection branch whose leg 1 contains `T1 → S1 → ` an inner
  selection branch. Assert `translated == true`, both `selDiv`s present, and
  every transition resolving to exactly one upstream and one downstream step.
  Pins Major 3.
- **Connector-adjacent nesting → poison**, cause `branch is directly adjacent
  to another branch`: a leg head that is *itself* a `<Branch>`, producing a
  `selDiv→selDiv` edge with nothing between.
- `<Branch>` nested as a *child of a `<Leg>`* (not a sibling) → unregistered by
  the flat walk → `dangling link` → poison. Pins the §2 recursion policy.
- Selection leg headed by a `<Step>` (wrong kind) → poison, cause
  `selection leg head is a step, expected transition`.
- Simultaneous leg headed by a `<Transition>` → poison, cause
  `simultaneous leg head is a transition, expected step`.
- Two trunk-ins on one branch side → poison, cause
  `selection divergence has 2 inlets, expected 1`.
- One case per **defect row of the emission table** (13 rows), each asserting
  its own cause clause: `divergence has no inlet`, `divergence has no legs`,
  `convergence has no inlet`, `convergence has no outlet`, `branch has no
  links`. Including the all-zero row (`<Branch>` with `<Leg>` children but no
  incident `<DirectedLink>`).
- One case per **shape-validation row** (8 rows), each asserting its own cause
  clause — the four wrong-inlet/outlet-kind causes and the four wrong-leg-
  head/tail-kind causes of §8's list, plus the arity cause. Together with the
  row above this makes every §8 cause clause reachable from a named test, so no
  two branch defects can be confused for one another.
- `BranchType` missing / `"Parallel"` → poison, substring `branch type`.
- `BranchFlow="Diverge"` on a paired branch → info `branch flow mismatch`,
  both connectors still emitted, no stub.

*Malformed input — the ID gate (§2)*
- `<Step>` with no `ID`; with `ID="abc"`; **with `ID="-1"`**; **with
  `ID="99999999999"`** (> `_kMaxL5xElementId`); and two elements sharing
  `ID="7"` → synthetic negative id in all five, `malformed ID` /
  `duplicate ID` substring per case, poison in all five. The **first** claimant
  of a duplicated id keeps the raw id and its inbound links.
- **The `ID="-1"` collision case, explicitly:** a chart containing both
  `<Step ID="-1">` and one well-formed branch must **stub**, and the built body
  must satisfy the `localId`-uniqueness invariant. Without the `parsed < 0`
  gate this fixture translates cleanly as the wrong chart with zero warnings —
  it is the regression test for Critical 2 and must fail loudly if the gate is
  ever removed.
- `<DirectedLink ToID="999">` naming nothing → `dangling link`, edge kept.
- `<Stop>` / `<SbrRet>` / `<Frobnicate ID="9">` / a top-level `<Leg>` →
  `no representable equivalent` naming the raw tag and id.
- Two `<SFCContent>` containers merging; a cross-container duplicate id →
  duplicate-ID path.

*Empty and absent content*
- `<Routine Type="SFC">` with **no** `<SFCContent>`, and with an **empty**
  `<SFCContent/>` → an empty body, **not** a poisoned one: the stub reason must
  be `no-initial` (`chart has no steps`) and the message count exactly the
  two of §7. Guards against a "when in doubt, poison" drift that would
  mislabel an empty routine as a topology defect.

*Poison-mechanism invariants (§4)*
- Any poisoned body: `translateSfcBody(...).translated == false`,
  `stubReason == 'complex-topology'`, `warnings.length == 1`, and that single
  warning is `WarningSeverity.warning`.
- Poison fires even when the poisoned element is on no path at all (isolated
  `<Stop>` with no links).
- Exactly one poison node regardless of how many defects were found.
- `localId` uniqueness and the "no `jump` node" invariant (§8) asserted over
  **every** fixture in the file via a shared helper, not per-test.

*Annotations*
- `<TextBox>` + `<Attachment>` → not nodes, one info warning, substring
  `element(s) ignored`, kinds deduped and listed.
- A `<DirectedLink>` anchored to a `<TextBox>` → link discarded, **no**
  `dangling link` warning, **no** poison, chart still translates. (Guards the
  §2 exception against a naive "unknown endpoint ⇒ poison" refactor.)

*Degrades*
- `Qualifier="S"` → chart still translates, `actionSt` omits it, translator's
  `N only` warning present.
- `IsBoolean="true"` → skipped, `boolean action`.
- **`<Action>` with an absent `<Body>`, and with a whitespace-only
  `<STContent>`** → skipped, one info warning per action naming step + action,
  substring `action has no body`, chart still **translates** (no poison).
  Pins Major 4 — without it the action vanishes silently inside `_actionSt`'s
  `isNotEmpty` guard.
- `Preset="0"` → **no** warning; `Preset="5000"` and
  `PresetUsesExpr="true"` → one `timing attribute` warning each, naming the
  step.

*Double-warning regression (the bug this sub-project fixes)*
- For a stubbing SFC routine: `parseL5x(xml).warnings.where((w) => w.severity
  == WarningSeverity.warning)` is **empty**; after `mapImportedProject`,
  exactly two warning-severity messages exist for that POU, matching §7's
  table. Pins the deleted parser warning against reintroduction.

**Modified: `mobile/test/import/sfc_translate_test.dart`** — one **dialect-
neutral** invariant test, added here rather than in the L5X file because the
property belongs to the translator, not to a dialect:

> *"a body with a step self-edge stubs `complex-topology` with exactly one
> warning and zero infos — import builders depend on this scan preceding every
> warning"*

Construct an `SfcBody` directly (no parser): one self-edged step, plus a
non-`N` action and an unnamed-initial step that *would* each emit an info
warning if the edge scan did not pre-empt them. Assert `translated == false`,
`stubReason == 'complex-topology'`, `warnings.length == 1`, and that the single
warning is `WarningSeverity.warning`. This is the guard that makes §4's
mechanism safe to depend on: reorder `_build` and this test fails, in the file
the reordering happens in.

**Modified: `mobile/lib/import/sfc_translate.dart`** — one **comment line**
above the step→step edge scan naming the dependency (`// Import builders
(l5x_parser's SFC poison node) depend on this scan preceding every warning
emission below — see docs/.../2026-08-07-l5x-sfc-import-design.md §4.`).
Comment-only: no behaviour, signature, or output change, so north-star 2's
zero-change reuse still holds for everything that matters.

**Modified: `mobile/test/import/l5x_parser_test.dart`**
Only the test **named** `routines -> program POUs (ST body; RLL/FBD/SFC
stubbed)` (line 227) mentions SFC, and its fixture contains **no** SFC routine
— verified: that name is the file's sole `SFC` occurrence. So **no existing
assertion depends on the removed parser warning**. Rename it to
`routines -> program POUs (ST body; RLL captured)` and leave the body alone.
The plan's first task must re-run this grep across `mobile/test/` (notably
`corpus_import_test.dart`, `import_xml_flow_test.dart`, `ir_to_project_test.dart`)
before assuming no other expectation moves.

**New: `mobile/test/import/import_l5x_sfc_e2e_test.dart`** (parse → map → scan)
- One L5X document with a `Main_Seq` SFC routine containing: an initial step
  with an `N` action assigning a tag, a linear transition, a **selection**
  branch whose two legs' conditions select on a tag, and a **simultaneous**
  fork/join.
- Assert `parseL5x` → `mapImportedProject` yields a `PlcProgram(language:
  'SequentialFunctionChart')` with the expected `sfcSteps` / `sfcTransitions`,
  including one `parallelFork` and one `parallelJoin`, and
  `report.translatedSfcCount == 1`, `stubbedSfcCount == 0`,
  `sfcStubReasons` empty.
- Run scan ticks and assert the chart actually advances: initial step's action
  fires, the selection picks the leg whose condition is true (first-true-wins),
  the fork activates both parallel steps, and the join waits for both.
- A second document whose SFC routine contains a `<Stop>` → stubbed program,
  `sfcStubReasons['complex-topology'] == 1`, message counts per §7.

**Backward-compatibility sweep.** Full `flutter test` from `mobile/`, plus
`flutter analyze` clean. Every PLCopen SFC test (`sfc_body_test.dart`,
`sfc_translate_test.dart` — apart from its one *added* invariant test —
`import_sfc_e2e_test.dart`), every L5X test, and `corpus_import_test.dart` must
be byte-identical in outcome. The only behavioural source change is
`l5x_parser.dart`; `sfc_translate.dart` receives a comment line and nothing
else.

---

## §10 — Docs

1. **`docs/import/L5X.md`**
   - Move **SFC routines** out of "What's captured but not yet translated" into
     a new "SFC routines translate" section: whole-chart faithful-or-stub, the
     supported source→native table, the stub reasons, the degrades (non-`N`
     qualifiers, boolean actions, step timing), and the e2e test path.
   - **Correct the "SFC AOI logic" bullet.** Replace "the logic itself is not
     translated" framing with: *Studio 5000 does not permit SFC as an Add-On
     Instruction `Logic` language (AOIs accept Ladder, FBD, or Structured Text),
     so there is nothing to translate; the importer keeps a defensive
     interface-only path with an info warning should such a file ever appear.*
   - Update the Deferred list: drop **L5X SFC routine translation**, add the
     new rows from §11.
2. **`docs/DEFERRED.md`**
   - "L5X import" section: strike the *L5X SFC routine translation — sub-project
     5* row as **Shipped (2026-08-07)** with the e2e test path, matching the
     strike-through style used for the FBD row.
   - Add the §11 rows (real-corpus validation, `<Stop>` semantics, step preset
     synthesis, boolean actions, non-`N` qualifiers on the L5X side).
3. **`knowledge/industry/plc-formats/rockwell-l5x.md`**
   - Retitle §5 from "FBD ships, SFC does not" to "FBD and SFC both ship";
     rewrite its headline rule and the "still-unshipped" language.
   - Add the `<SFCContent>` structure + the branch-synthesis algorithm as a
     settled fact, **flagged as asserted-and-fixture-pinned** until a real
     export lands.
   - Update front-matter `summary` (it currently asserts "the confirmed
     still-unshipped state of L5X SFC routine translation") and the
     "Read this before" note that tells the reader to verify SFC support
     against source.
   - Extend the support matrix; add the new learning ids if the run produces
     any.
4. **`docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md`**
   - Retitle the import section from "SFC import (PLCopen → native
     SequentialFunctionChart)" to cover both dialects, and add an **L5X
     subsection**: the `<SFCContent>` source→native table, the branch pair
     synthesis, the step-timing drop + the `STEP_T` hand-recovery recipe, and
     the L5X-specific degrades.

---

## §11 — Deferred (recorded in `docs/DEFERRED.md`)

| Item | Priority | Note |
|---|---|---|
| **Real-corpus SFC validation** | **near-term** | §1's schema is asserted and pinned only by synthetic fixtures. Acquire one SFC-bearing Studio 5000 `.L5X`, add it to the local corpus, run `corpus_import_test.dart`, and reconcile §1/§3 against it. The single highest-value follow-up. |
| `<Stop>` element semantics | near-term | v1 poisons the POU. A `<Stop>` maps plausibly onto a terminal step with no outgoing transition (which `sfc_exec` already parks on), but "plausibly" is not enough without a real export showing how Logix wires and resets it. |
| Step `Preset`/`LimitHigh`/`LimitLow` | later | Dropped with an info warning. Auto-synthesizing `STEP_T >= <preset>` onto the outgoing transition would silently rewrite user logic and has no defined composition with an existing condition. |
| `IsBoolean` actions | later | Skipped with an info warning. Needs a set-on-activate / reset-on-deactivate action model the native `SfcStep` does not have. |
| Non-`N` action qualifiers, L5X side | later | Rides the existing cross-dialect row (`S`/`R`/`P`/`L`/`D`/`SD`/`DS`/`SL` degrade to no-op); listed here so the L5X matrix is self-contained. |
| SFC-bodied AOIs | later | Believed impossible in Studio 5000; the defensive interface-only path stays. Revisit only if a real export contradicts it. |
| **Connector-adjacent / chained branches** | later | Only *connector-adjacent* branches stub — a leg head or tail that is itself a `<Branch>`, giving a `div→div`/`conv→conv`/`div→conv` edge. **Step-separated nesting already translates** and needs nothing (§3). Chaining would need `upstreamSteps`/`downstreamSteps` to see through more than one connector, which is a `translateSfcBody` change and out of scope for a parser sub-project. |
| Recursive `<SFCContent>` walk | later | Pass 1 is flat (direct children of `<SFCContent>`, plus a `<Branch>`'s direct `<Leg>` children). A `<Branch>` nested *inside* a `<Leg>` element is unregistered → `dangling link` → visible stub. Make the walk recursive if a real export shows Logix nests that way. |

---

## §12 — Risks a reviewer should attack

1. **§1 and §3 are asserted, not verified.** Specifically: whether one
   `<Branch>` element spans both divergence and convergence, and whether
   `<Leg ID>` values appear as `<DirectedLink>` endpoints. §3's unified
   classifier (leg endpoints by direction, branch endpoints by the other
   endpoint's kind) plus the topology-derived emission table is built to absorb
   both plausible encodings *without a mode switch* — but a *third* encoding
   would invalidate the crux.
2. **The poison mechanism depends on statement ordering inside
   `translateSfcBody`.** Its guarantee — one warning, `complex-topology`, no
   stray infos — holds because the step→step edge scan sits above every
   warning-emitting statement in `_build`. This is now guarded on **both**
   sides: a dialect-neutral invariant test lives in `sfc_translate_test.dart`
   (so a reordering fails in the file being reordered, not in a distant L5X
   test), and a one-line comment in `sfc_translate.dart` names the dependency.
   A reviewer should still confirm that comment-plus-test is the right cost —
   it is the one deviation from "zero changes to `sfc_translate.dart`".
3. **Whole-POU stubbing may be too coarse for real Logix charts.** A single
   `<Stop>` or one unrecognized element takes down a 40-step chart. That is the
   established SFC contract and the honest one, but if the corpus follow-up
   shows `<Stop>` is ubiquitous, the `<Stop>`-as-terminal-step deferred row
   becomes near-term-urgent rather than a nicety.

---

## §13 — Execution shape (for the plan)

**One plan, five tasks, strictly sequential** with a review checkpoint between
each — this repo's SDD process (spec → plan → execute) has no parallel task
execution. The tasks are ordered so each is independently testable: task 1
lands a working (branch-free) end-to-end path, task 2 adds the crux on top of a
green base, and tasks 3–4 harden and prove it.

| # | Task | Model · Effort |
|---|---|---|
| 1 | `_l5xSfcBody` core: container walk, pass 1 element registration, **the full ID gate** (absent / unparseable / negative / out-of-range / duplicate) with the `_kMaxL5xFbdId` → `_kMaxL5xElementId` and `_kL5xFbdAnnotationElements` → `_kL5xAnnotationElements` renames, steps, transitions, conditions, pass 2a/2b links, annotations; the `_l5xRoutines` SFC arm swap + parser-warning deletion; the `l5x_parser_test.dart` rename + the grep sweep for other SFC expectations. Linear-chart and ID-gate parser tests (incl. the `ID="-1"` collision regression). | opus · medium |
| 2 | **Branch → div/conv synthesis (§3)**: allocation, the **unified endpoint classifier** (leg-by-direction, branch-by-other-endpoint-kind — one rule, no mode switch), the 4-bit emission decision table, shape validation with cause clauses, connector-adjacent vs. step-separated nesting, degenerate/trunk-count cases. Full branch test matrix incl. the encoding-equivalence multiset comparison and the step-separated-nesting **happy path**. | **opus · high** |
| 3 | The never-silent surface (§4/§5/§6): poison node + its invariants (uniqueness, no-`jump`), `<Stop>`/unknown elements, dangling links, annotation anchors, step timing gate, boolean actions, empty-body actions, non-`N` degrades; the warning-severity conformance suite (exact substrings + cause clauses from §8), the empty-`<SFCContent>` → `no-initial` case, and the double-warning regression test. Plus the `sfc_translate_test.dart` dialect-neutral invariant test and the `sfc_translate.dart` coupling comment. | sonnet · medium |
| 4 | `import_l5x_sfc_e2e_test.dart` (parse → map → scan, selection + simultaneous + stub document) and the full-suite backward-compatibility sweep + `flutter analyze`. | opus · medium |
| 5 | Docs (§10): `docs/import/L5X.md`, `docs/DEFERRED.md`, `knowledge/industry/plc-formats/rockwell-l5x.md` §5 + front-matter + matrix, `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md` L5X subsection. | sonnet · low |

**Files touched (implementation)**: `mobile/lib/import/l5x_parser.dart` (all
behaviour) and `mobile/lib/import/sfc_translate.dart` (**one comment line**,
task 3).

**Files touched (tests)**: `mobile/test/import/l5x_parser_sfc_test.dart` (new),
`mobile/test/import/import_l5x_sfc_e2e_test.dart` (new),
`mobile/test/import/sfc_translate_test.dart` (one added invariant test),
`mobile/test/import/l5x_parser_test.dart` (rename only).

**Files touched (docs)**: the four in §10.
