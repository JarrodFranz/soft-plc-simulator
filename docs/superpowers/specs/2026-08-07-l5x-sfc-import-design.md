# L5X SFC routine import (L5X sub-project 5 — the last import gap) — Design Spec

**Status:** design complete, ready to plan
**Date:** 2026-08-07
**Branch base:** `main` @ `2fdc6cc`
**Predecessors:** `2026-07-26-sfc-import-translator-design.md` (the neutral SFC
translator), `2026-07-26-l5x-import-foundation-design.md`,
`2026-08-04-l5x-fbd-import-design.md` (the immediately preceding sub-project,
whose conventions this one mirrors).

## Changelog

- 2026-08-07 — initial design.

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
  arm — which emits `AOI "$name" logic is SFC — interface imported, logic not
  yet translated.` — is **kept as defensive dead-path handling** and gets no
  SFC branch. `keepsEnableParams` stays `false` for a non-RLL/non-FBD AOI, so
  `EnableIn`/`EnableOut` keep their historic skip. `docs/import/L5X.md`'s
  "SFC AOI logic" bullet is **corrected** to state the Studio 5000 restriction
  rather than implying the feature is merely unshipped (§10).
  *(Confidence note: the restriction is external product knowledge; nothing in
  this repo confirms or denies it. It is safe either way — if a real export
  ever carries an SFC-bodied AOI, the dead path still produces a clean
  interface-only FB + info warning, exactly as today.)*
- Any change to `sfc_translate.dart`, `import_ir.dart`, `ir_to_project.dart`,
  `models/sfc_exec.dart`, or `models/project_model.dart`. **Zero.**
- New `ImportReport` fields. `translatedSfcCount`, `stubbedSfcCount` and
  `sfcStubReasons` already exist, are dialect-agnostic, and are already
  rendered by `screens/import_xml_preview.dart:108`.

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
   no logic; they are ignored at parse with one info warning per routine,
   mirroring `_l5xFbdBody`'s `_kL5xFbdAnnotationElements` handling.
6. **Synthetic ids are routine-wide and negative.** Malformed/duplicate L5X
   `ID`s and the synthesized branch connectors draw from one descending
   negative counter per routine, so they can never collide with each other nor
   with a real (non-negative) L5X `ID`. Mirrors `_l5xFbdBody`'s routine-wide
   `malformedId` counter.
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

**Pass 1 — elements.** For each child element of each `<SFCContent>`:

1. `<TextBox>` / `<Attachment>` → increment `ignoredCount`, record the tag in
   `ignoredKinds`, `continue`. (One info warning at the end, deduped by kind.)
2. Resolve the element's id:
   - `ID` absent or not parseable as an int → **synthetic negative id** +
     info warning (`malformed ID`) + **poison**.
   - `ID` already claimed by an earlier element → the *later* claimant gets a
     **synthetic negative id** (the raw id is never re-registered, so earlier
     links keep pointing at the first claimant) + info warning
     (`duplicate ID`) + **poison**.
     *Deviation from the FBD table, deliberate:* FBD raises duplicate-ID to
     `WarningSeverity.warning` because there the stub is per-network and the
     routine may still translate, so the collision needs its own loud message.
     Here the stub is whole-POU and the loud message already exists twice
     (translator + mapper), so the breadcrumb stays `info` per north-star 4.
3. Dispatch on tag: `Step` / `Transition` → node (below); `Branch` → deferred
   to pass 3 (§3), registering `ID` and each `<Leg ID>` in the endpoint tables;
   `Leg` encountered as a top-level child (malformed) → poison; anything else
   ID-bearing → **poison** + info warning `no representable equivalent`.
4. `<Step>` → `SfcNode(kind: step, …)`; collect its actions (§6); check its
   timing attributes (§5).
   `<Transition>` → `SfcNode(kind: transition, condition: …)` (§6).

Nodes are appended in document order; `initial`, `name`, `x`, `y` are read as
per §1. `name` prefers `Operand`, falls back to `Name`, else `''` (the
translator then synthesizes `s<localId>`).

**Pass 2 — links.** For each `<DirectedLink>`, resolve `FromID` and `ToID`
through the endpoint resolver (§3) and emit one `SfcEdge`. An endpoint that
resolves to nothing (absent, unparseable, or naming no registered element/leg)
→ info warning `dangling link` + **poison**, and the edge is **still emitted**
against a synthetic id so nothing is silently dropped.

**One exception, deliberate:** a link whose endpoint names a **dropped
annotation** (`<TextBox>`/`<Attachment>`) is discarded whole, with **no**
`dangling link` warning and **no** poison. Logix anchors an annotation to the
element it comments on, and that anchor is a documentation relationship, not a
control-flow edge — poisoning a chart because it is well commented would be
absurd. This requires pass 1 to register annotation ids in a separate
`annotationIds` set rather than forgetting them.

**Pass 3 — branch synthesis** (§3), which appends the synthesized connector
nodes and rewrites nothing already emitted.

**Pass 4 — finalize.** Emit the annotation info warning if
`ignoredCount > 0`; if the poison flag is set, append the poison node + its
self-edge (§4). Return
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
up front: `divId(B)` and `convId(B)`. Kinds:

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

### Endpoint resolution

One function drives everything. For a `<DirectedLink FromID="f" ToID="t">`:

```
resolveFrom(id) = id is a Branch B      -> convId(B)   // leaving the branch structure
                | id is a Leg of B      -> divId(B)    // divergence feeds this leg's head
                | id is a Step/Transition -> that node's id
                | otherwise             -> dangling (poison)

resolveTo(id)   = id is a Branch B      -> divId(B)    // entering the branch structure
                | id is a Leg of B      -> convId(B)   // this leg's tail feeds convergence
                | id is a Step/Transition -> that node's id
                | otherwise             -> dangling (poison)
```

This is deliberately direction-asymmetric, and it is what makes leg membership
a non-problem: **the builder never needs to know which elements are inside a
leg** — only each leg's head and tail, and those fall straight out of the two
`Leg`-endpoint rules. It also makes nesting fall out for free (a leg whose head
is another `<Branch>` produces a `divId(B1) → divId(B2)` edge, which the shape
check below rejects).

**Fallback convention.** If, for a given branch, **no `Leg` id appears as a
link endpoint** (i.e. the export wires legs to the `<Branch>` id directly),
classify each branch-incident link by the **other endpoint's element kind**,
using the branch type's expected pattern from the table above:

| Branch type | link direction | other endpoint is a… | role |
|---|---|---|---|
| Selection | `ToID == B` | `Step` | trunk-in → `divId(B)` inflow |
| Selection | `ToID == B` | `Transition` | leg tail → `convId(B)` inflow |
| Selection | `FromID == B` | `Transition` | leg head → `divId(B)` outflow |
| Selection | `FromID == B` | `Step` | trunk-out → `convId(B)` outflow |
| Simultaneous | `ToID == B` | `Transition` | trunk-in → `divId(B)` inflow |
| Simultaneous | `ToID == B` | `Step` | leg tail → `convId(B)` inflow |
| Simultaneous | `FromID == B` | `Step` | leg head → `divId(B)` outflow |
| Simultaneous | `FromID == B` | `Transition` | trunk-out → `convId(B)` outflow |

The kinds are unambiguous in both branch types, which is why this fallback is
sound rather than a guess. A branch that mixes both conventions (some links via
`Leg` ids, some via the `Branch` id) → **poison** + info warning
`mixed branch link convention`.

### Emission

After all links are classified, for each branch side:

- **both an inflow and an outflow** → emit the connector node and its edges.
- **neither** → drop the node silently, **provided the branch's other side was
  emitted**. This is the whole point of deriving emission from topology: a
  `Diverge`-only `<Branch>` element leaves the conv side empty, and a
  `Converge`-only one leaves the div side empty. Dropping an entirely unused
  synthetic node loses nothing.
- **both sides empty** — a `<Branch>` with no incident links at all → the
  element carries structure the chart never wires up → **poison** + info
  warning `branch shape not representable`. Silently dropping it would erase a
  declared branch, which north-star 3 forbids.
- **exactly one of the two** → structurally broken (a divergence with an inflow
  but no legs, or legs with nowhere to go) → **poison** + info warning
  `branch shape not representable`. The node is still emitted so the element
  count stays honest.

### Shape validation (before emission)

For each emitted connector, assert the neighbour kinds from the translator
table; violations → **poison** + info warning
`branch shape not representable` naming the branch `ID` and the offending
neighbour:

- `selDiv`: **exactly one** inflow, and it is a `step`; every outflow is a
  `transition`.
- `selConv`: every inflow is a `transition`; **exactly one** outflow, and it is
  a `step`.
- `simDiv`: **exactly one** inflow, and it is a `transition`; every outflow is
  a `step`.
- `simConv`: every inflow is a `step`; **exactly one** outflow, and it is a
  `transition`.

Why validate here rather than letting `translateSfcBody` catch it: the
translator's gates are reached **only from a transition's pred/succ walk**. A
malformed connector that is not on any transition's walk — e.g. a `selDiv`
whose successors are steps rather than transitions — would be *ignored*, and
the steps behind it would become unreachable islands that vanish without a
word. Validating the shape at synthesis time is what makes north-star 3 total
for branches. The translator's own gates remain as a backstop.

### Cases that are explicitly fine

- **Single-leg branch.** A `selDiv` with one outflow transition, or a `simDiv`
  with one outflow step, translates as an ordinary linear path (`upstreamSteps`
  /`downstreamSteps` see through the connector). No warning, no stub — it is a
  faithful, if pointless, chart.
- **Selection branch with unequal leg lengths.** Irrelevant: only heads and
  tails are used.
- **Loop-back leg** (a leg tail wired to an upstream step rather than back into
  the branch). It never becomes a `convId` inflow; it is just an ordinary edge.
  The conv side then has no inflow and is dropped or poisoned per the emission
  rule above depending on whether *any* leg closes.

### Cases that stub (visibly)

Nested branches (`div→div`, `conv→conv`, `div→conv` edges), a leg head of the
wrong kind, more than one trunk-in or trunk-out, an unrecognized `BranchType`,
a mixed link convention, a branch side with exactly one of inflow/outflow, and
a `<Branch>` with no incident links at all.

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

| Outcome | Messages |
|---|---|
| SFC routine translates | zero warning-severity messages; only builder/translator `info` breadcrumbs, if any |
| SFC routine stubs | exactly **two** warning-severity messages — `translateSfcBody`'s `SFC POU "…": not translated (<detail>).` and the mapper's `POU "…" (SequentialFunctionChart): graphical body not yet translated (N elements captured) …` — identical to the PLCopen path |
| `parseL5x` alone, any SFC routine | **zero** warning-severity messages from the SFC arm |

---

## §8 — Error handling and warning severities

Never-throws throughout. Every substring below is an exact, assertable
fragment.

**Builder-emitted (all `WarningSeverity.info`, all prefixed `ownerLabel`)**

| Situation | Severity | Assertable substring | Consequence |
|---|---|---|---|
| `<TextBox>` / `<Attachment>` present | info | `annotation elements ignored` | dropped; one warning per routine, kinds deduped |
| Unknown ID-bearing element (`<Stop>`, `<SbrRet>`, `<JSR>`, future) | info | `no representable equivalent` | **poison** → whole-POU stub |
| `ID` absent or unparseable | info | `malformed ID` | synthetic negative id + **poison** |
| `ID` reused by a later element | info | `duplicate ID` | later claimant gets a synthetic id (raw id never re-registered) + **poison** |
| `<DirectedLink>` endpoint names nothing | info | `dangling link` | edge kept against a synthetic id + **poison** |
| `<DirectedLink>` endpoint names a dropped annotation | — | (none) | link discarded whole; no poison — an annotation anchor is documentation, not control flow |
| `BranchType` absent/unrecognized | info | `branch type` | **poison**; no connectors synthesized |
| Branch side with inflow xor outflow; wrong neighbour kind; nesting; >1 trunk; `<Branch>` with no incident links | info | `branch shape not representable` | **poison** |
| Branch mixes `Leg`-id and `Branch`-id link conventions | info | `mixed branch link convention` | **poison** |
| `BranchFlow` contradicts derived topology | info | `branch flow mismatch` | derived topology wins; no stub |
| Step `Preset` / `LimitHigh` / `LimitLow` meaningful | info | `timing attribute` | dropped; chart still translates |
| `<Action IsBoolean="true">` | info | `boolean action` | action skipped; chart still translates |

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

- No negative `localId` ever reaches a `SfcStep.id` / `SfcTransition.id`: a
  poisoned body always stubs, and branch connectors never become steps or
  transitions. (Guards against a program id like `Main_Seq_s-3`.)
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
- Selection branch, 2 legs, paired diverge+converge → `selDiv` + `selConv`
  nodes; edges `step→selDiv`, `selDiv→t1`, `selDiv→t2`, `t3→selConv`,
  `t4→selConv`, `selConv→step`.
- Simultaneous branch, 2 legs → `simDiv` + `simConv` with the transition/step
  positions swapped per the §3 table.
- Diverge-only `<Branch>` (no leg tails, no trunk-out) → only the div node
  emitted, conv node dropped, **no** poison.
- Converge-only `<Branch>` → mirror image.
- Fallback convention: same charts wired via the `<Branch>` `ID` with no `Leg`
  ids as endpoints → identical IR.
- Mixed convention within one branch → poison.
- Single-leg branch → connectors emitted, no warning, translates.
- Nested branch (a leg head that is another `<Branch>`) → poison.
- Selection leg headed by a `<Step>` (wrong kind) → poison.
- Two trunk-ins on one branch side → poison.
- `<Branch>` with `<Leg>` children but no incident `<DirectedLink>` → poison.
- `BranchType` missing / `"Parallel"` → poison, substring `branch type`.
- `BranchFlow="Diverge"` on a paired branch → info `branch flow mismatch`,
  both connectors still emitted, no stub.

*Malformed input*
- `<Step>` with no `ID`, with `ID="abc"`, and two elements sharing `ID="7"` →
  synthetic negative ids, correct substring per case, poison in all three; the
  **first** claimant of a duplicated id keeps the raw id and its inbound links.
- `<DirectedLink ToID="999">` naming nothing → `dangling link`, edge kept.
- `<Stop>` / `<SbrRet>` / `<Frobnicate ID="9">` → `no representable
  equivalent` naming the raw tag and id.
- Two `<SFCContent>` containers merging; a cross-container duplicate id →
  duplicate-ID path.

*Poison-mechanism invariants (§4)*
- Any poisoned body: `translateSfcBody(...).translated == false`,
  `stubReason == 'complex-topology'`, `warnings.length == 1`, and that single
  warning is `WarningSeverity.warning`.
- Poison fires even when the poisoned element is on no path at all (isolated
  `<Stop>` with no links).
- Exactly one poison node regardless of how many defects were found.

*Annotations*
- `<TextBox>` + `<Attachment>` → not nodes, one info warning,
  `annotation elements ignored`.
- A `<DirectedLink>` anchored to a `<TextBox>` → link discarded, **no**
  `dangling link` warning, **no** poison, chart still translates. (Guards the
  §2 exception against a naive "unknown endpoint ⇒ poison" refactor.)

*Degrades*
- `Qualifier="S"` → chart still translates, `actionSt` omits it, translator's
  `N only` warning present.
- `IsBoolean="true"` → skipped, `boolean action`.
- `Preset="0"` → **no** warning; `Preset="5000"` and
  `PresetUsesExpr="true"` → one `timing attribute` warning each, naming the
  step.

*Double-warning regression (the bug this sub-project fixes)*
- For a stubbing SFC routine: `parseL5x(xml).warnings.where((w) => w.severity
  == WarningSeverity.warning)` is **empty**; after `mapImportedProject`,
  exactly two warning-severity messages exist for that POU, matching §7's
  table. Pins the deleted parser warning against reintroduction.

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
`sfc_translate_test.dart`, `import_sfc_e2e_test.dart`), every L5X test, and
`corpus_import_test.dart` must be byte-identical in outcome — the only
non-parser file touched is `l5x_parser.dart`.

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
| Nested branches | later | Poisoned (whole-POU stub). Representing a branch inside a branch needs connector-chaining support in `translateSfcBody`, which is out of scope for a parser sub-project. |

---

## §12 — Risks a reviewer should attack

1. **§1 and §3 are asserted, not verified.** Specifically: whether one
   `<Branch>` element spans both divergence and convergence, and whether
   `<Leg ID>` values appear as `<DirectedLink>` endpoints. §3's dual-convention
   design (Leg-endpoint primary, kind-based fallback) plus topology-derived
   emission is built to absorb both plausible encodings — but a *third*
   encoding would invalidate the crux.
2. **The poison mechanism depends on statement ordering inside
   `translateSfcBody`.** Its guarantee — one warning, `complex-topology`, no
   stray infos — holds because the step→step edge scan sits above every
   warning-emitting statement in `_build`. Nothing in `sfc_translate.dart`
   documents or enforces that ordering. §9's poison-invariant tests are the
   only guard; a reviewer should decide whether a comment in
   `sfc_translate.dart` naming the L5X dependency is worth the "zero changes"
   deviation (this spec says no — a test that fails loudly beats a comment).
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
| 1 | `_l5xSfcBody` core: container walk, element dispatch, ids (malformed/duplicate), steps, transitions, conditions, directed links, annotations; the `_l5xRoutines` SFC arm swap + parser-warning deletion; the `l5x_parser_test.dart` rename + the grep sweep for other SFC expectations. Linear-chart parser tests. | opus · medium |
| 2 | **Branch → div/conv synthesis (§3)**: allocation, endpoint resolver, both link conventions, topology-derived emission, shape validation, nesting/degenerate/trunk-count cases. Full branch test matrix. | **opus · high** |
| 3 | The never-silent surface (§4/§5/§6): poison node + its invariants, `<Stop>`/unknown elements, dangling links, step timing gate, boolean actions, non-`N` degrades; the warning-severity conformance suite (exact substrings from §8) and the double-warning regression test. | sonnet · medium |
| 4 | `import_l5x_sfc_e2e_test.dart` (parse → map → scan, selection + simultaneous + stub document) and the full-suite backward-compatibility sweep + `flutter analyze`. | opus · medium |
| 5 | Docs (§10): `docs/import/L5X.md`, `docs/DEFERRED.md`, `knowledge/industry/plc-formats/rockwell-l5x.md` §5 + front-matter + matrix, `docs/iec61131/SEQUENTIAL_FUNCTION_CHART.md` L5X subsection. | sonnet · low |

**Files touched (implementation)** — exactly one:
`mobile/lib/import/l5x_parser.dart`.

**Files touched (tests)**: `mobile/test/import/l5x_parser_sfc_test.dart` (new),
`mobile/test/import/import_l5x_sfc_e2e_test.dart` (new),
`mobile/test/import/l5x_parser_test.dart` (rename only).

**Files touched (docs)**: the four in §10.
