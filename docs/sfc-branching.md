# SFC v2: 2D Layout, Alternative & Parallel Branching

This note documents the v2 Sequential Function Chart (SFC) editor and
engine: a textbook 2D chart layout (step boxes, transition blocks, branch
columns, parallel fork/join double-bars), a multi-token execution engine
(simultaneous active steps), and structured authoring for both alternative
(OR) and parallel (AND) branching, including nesting.

## Model: one additive transition shape carries all three chart shapes

`SfcStep` is unchanged. `SfcTransition`
(`mobile/lib/models/project_model.dart`) gained three additive fields on
top of its original `fromStepId` / `toStepId` / `conditionSt`:

- `kind` — `'single'` (default), `'parallelFork'`, or `'parallelJoin'`.
- `toStepIds` — for a `parallelFork`, every branch head it activates at
  once (`toStepId` is unused/empty on a fork).
- `fromStepIds` — for a `parallelJoin`, every branch tail it waits on
  (`fromStepId` is unused/empty on a join).

A `'single'` transition works exactly as before: one source, one target,
one condition. Any number of `'single'` transitions may still share a
`fromStepId` — that is alternative (if/else-if) branching, unchanged from
the original design: **top-to-bottom list order is priority**, and there is
no separate priority field to keep in sync.

On disk the new fields serialize as `kind` / `to_step_ids` / `from_step_ids`
and are fully additive: an old project file with none of those keys loads
with `kind: 'single'` and empty lists, round-trips byte-for-byte, and the
Go-Online / live-execution state is session-only and never appears in
persisted project JSON (see [Testing](#testing)).

## Structured-only constraint

The parser and layout only give a faithful 2D drawing for a
**well-structured** chart: every `parallelFork` is matched by exactly one
`parallelJoin` whose `fromStepIds` are that fork's branch tails, forks/joins
nest cleanly (a branch may itself contain another fork/join or an
alternative diamond, but branches never cross each other), and an
alternative divergence's branches reconverge at a single shared step (or
never reconverge at all). The structured-authoring helpers (below) only
ever build charts in this shape. A chart built by hand outside those
helpers that violates the shape still **never crashes** the parser or the
engine — unmatched or overlapping structures degrade to plain sequential
leaves so every step and transition is still drawn and still executes —
but it will not lay out as a clean fork/join or alternative diamond.

## Engine: an active-step SET, not a single token

`SfcRuntime` (`mobile/lib/models/sfc_exec.dart`) tracks
`active: Map<String, Set<String>>` — the set of simultaneously-active step
ids per program — plus a `stepElapsedMs` STEP_T timer per step. Each scan
(`executeSfcPrograms`):

1. **Every** active step's `actionSt` runs (N/non-stored semantics) and its
   STEP_T accumulates, exactly as before — just for every step in the set
   instead of one.
2. Transitions are evaluated against a start-of-scan snapshot of the active
   set, grouped by kind:
   - **`single`** — fires like an if/else-if guard: first transition (in
     list order) out of an active step whose condition is true wins;
     firing consumes that one source step and activates its one target.
   - **`parallelFork`** — fires once its single source step is active and
     its condition is true; firing consumes that one source and activates
     **every** id in `toStepIds` at once (simultaneous divergence).
   - **`parallelJoin`** — fires only once **every** id in `fromStepIds` is
     active (and none already consumed this scan) and its condition is
     true; firing consumes all of them and activates its one target
     (synchronization: the join waits for the slowest branch).
3. A transition whose target(s) don't currently exist (a dangling
   reference) is skipped rather than stranding the scan — the same
   graceful-degradation rule as the original single-token engine.

Steps newly activated this scan start acting **next** scan (their STEP_T
begins at 0); a single-token chart with no fork/join transitions behaves
identically to before — the multi-token machinery is a strict superset,
not a special case that a legacy chart has to opt into.

## Parsing: chart graph → region tree

`parseSfc` (`mobile/lib/models/sfc_region.dart`) is a pure function that
classifies a `List<SfcStep>` + `List<SfcTransition>` graph into a tree of
regions for the 2D layout pass to consume:

- **`StepRegion`** — a single step box.
- **`TransRegion`** — a transition edge; `isGoto` marks an edge whose
  target is already placed (a loop-back or re-convergence), which the
  canvas draws as a **GOTO** reference chip instead of a straight
  connector, so cycles and reconvergence never redraw a step twice.
- **`SeqRegion`** — a straight-line run of steps/transitions.
- **`AltRegion`** — an alternative divergence: `branches` fan out from
  `head` guarded by `guards` (the `single` transitions), reconverging at
  `merge` (or `null` if the branches never rejoin).
- **`ParRegion`** — a parallel fork/join: `branches` run in parallel
  between `fork` and the matching `join`, continuing at `after`
  (`join.toStepId`).

The parser never throws and never loops forever: a visited-set makes every
cycle terminate, and any step unreachable from the initial step is still
emitted as a trailing leaf so a partially-built chart always draws in full.

## Layout: a real 2D chart, not a list

`layoutSfcRegion` (`mobile/lib/models/sfc_layout2.dart`) turns the region
tree into absolute-positioned geometry — the way an SFC reads in the
IEC 61131-3 standard, not a scrolling list:

- **Step boxes** and **transition blocks** are separate visual elements —
  a transition renders as its own bordered block holding the editable
  condition, not a thin connector.
- **Alternative branches render side-by-side**: an `AltRegion` lays its
  branches out as adjacent columns fanning out from the shared divergence
  point and funnelling back into the shared convergence point, so an
  if/else-if reads left-to-right the way it's drawn on paper instead of
  stacking vertically.
- **Parallel fork/join render as double-line bars**: a `ParRegion` draws a
  horizontal double-bar at the fork, one column per simultaneous branch
  underneath it, and a second double-bar at the join gathering every
  branch back together — the standard SFC parallel-branch notation.
- **Nesting** falls out of the recursion for free: a branch column is
  itself laid out by the same routine, so a parallel branch can contain a
  nested alternative or another nested fork/join, and it lays out and
  draws correctly at any depth.
- **GOTO references**: a loop-back or an already-drawn convergence target
  renders as a small labeled chip rather than a duplicate box, keeping
  cyclic and reconverging charts compact and readable.

## Go-Online: live highlighting on the 2D canvas

The SFC editor canvas (`mobile/lib/screens/sfc_editor_screen.dart`) has the
same session-only **Go-Online** toggle pattern as the LD editor: off by
default (a fully static editor), and when on, overlays the live scan state
directly on the boxes it already drew:

- Every step currently in `SfcRuntime.active[program.name]` glows (green
  border/fill, elevated shadow) and shows a live **STEP_T** readout; every
  other step dims, so a fork with two active branches highlights **both**
  columns at once — the highlight is inherently parallel-aware because it
  reads the same active-step set the engine writes.
- The canvas repaints on the shared `LiveTick` pulse (the same
  scan-driven, throttled repaint mechanism used by the rest of the app),
  not on a full shell rebuild — going online never triggers the wider
  editor to re-render.
- When the scan is paused, the last live state simply **freezes** instead
  of going blank (gated on the toggle alone, not on `scanRunning`).
- Nothing about this is persisted: `_online` is local widget state and
  `SfcRuntime` is passed in from the shell's own session-only runtime
  object — a chart's serialized JSON is byte-for-byte identical whether or
  not it was ever taken online.

## Structured authoring

The step menu (`_buildSfcStepCard` / step editor dialog in
`sfc_editor_screen.dart`) offers three structural actions, backed by pure
helpers in `mobile/lib/models/sfc_edit.dart`:

- **＋ Add step after** (`addSfcStepAfter`) — splices a new step into the
  linear flow immediately after the anchor.
- **＋ Add alternative branch** (`addAlternativeBranch`) — adds another
  `single` divergence out of the anchor; if the anchor already flows
  onward, the new branch reconverges at that same successor so the result
  is a clean two-armed diamond.
- **＋ Add parallel branch** (`addParallelBranch`) — if the anchor isn't
  already a fork source, builds a brand-new `parallelFork`/`parallelJoin`
  pair around it with two fresh single-step branches; if it already is,
  appends a third/Nth branch to that same fork and join. Calling this
  again on a step that's a branch tail of an *enclosing* fork **nests** a
  fork/join inside that branch instead of breaking the outer structure.

Deleting a step (`deleteSfcStepStructured`) is structure-aware: deleting
the head of a parallel branch removes that entire branch (including any
structure nested inside it) via `deleteParallelBranch`, and collapses the
fork/join back into a plain sequence once only one branch would remain;
deleting any other step falls back to the original `deleteSfcStep`
(removing every transition that references it in either direction, and
promoting a new initial step if the deleted step was initial). Every
structural helper keeps the fork/join invariant intact — a fork's
`toStepIds` always equals its branch heads and the matching join's
`fromStepIds` always equals the current branch tails — so the chart stays
parseable with no dangling references after every edit.

## Testing

Covered by dedicated test files alongside the full existing suite:
`test/sfc_transition_kind_test.dart` and `test/sfc_branch_roundtrip_test.dart`
(the additive model fields), `test/sfc_multitoken_test.dart` and
`test/sfc_exec_test.dart` / `test/sfc_exec_integration_test.dart` (the
multi-token engine: fork activates all, join waits for all, alternative
first-true, single-token parity), `test/sfc_region_test.dart` (pure region
parsing: sequences, alternatives, parallel fork/join, nesting, cycles,
dangling targets), `test/sfc_layout2_test.dart` (pure 2D layout geometry),
`test/sfc_canvas_render_test.dart` / `test/sfc_editor_branch_render_test.dart`
(canvas rendering of boxes, blocks, bars, and GOTO chips),
`test/sfc_edit_test.dart` / `test/sfc_edit_parallel_test.dart` /
`test/sfc_editor_authoring_test.dart` (structured authoring: alternative
and parallel branch creation, nesting, collapse-on-delete), and
`test/sfc_online_test.dart` (Go-Online highlighting). The final guard,
`test/sfc_v2_roundtrip_test.dart`, pins the three cross-cutting
contracts above end to end: a fork+join chart round-trips its new fields
with list order preserved, a hand-built legacy (pre-v2) project JSON loads
unchanged as all-`single` with empty lists, and running the live engine
through several scans never changes a project's serialized JSON.
