# SFC v2 — 2D Structured Layout + Parallel/AND Execution — Design Spec

**Date:** 2026-07-15
**Status:** Approved (design)

## Goal

Replace the current single-column list SFC editor with a **2D "textbook" SFC**:
steps as boxes, transitions as visible **blocks**, alternative branches drawn
**side-by-side** (single line, first-true), and **parallel (AND) operations**
drawn with **double-line** fork/join bars — **including nested parallel** — with
loops/merges shown as **GOTO** references. The execution engine gains a
**multi-token** active set so parallel branches run simultaneously and a join
proceeds only when all its branches are complete.

This supersedes the single-token vertical-list rendering shipped earlier
(alternative branching, GOTO chips) — that capability is preserved and now
rendered in the 2D layout.

## Design constraint (approved): structured + GOTO

The editor produces only **well-structured** charts: properly nested regions —
a **Sequence** (step → transition → step …), an **Alternative divergence**
(one step, N single-line branches, converging), or a **Parallel divergence**
(a fork bar, N branches, a join bar), recursively nestable — each region
single-entry / single-exit. Any non-structured jump (a loop back, an early
exit) is a **GOTO reference** to a named step, never a free-drawn wire. This
structure is what makes reliable automatic 2D layout possible. (The user's
reference image is exactly this shape.)

## Non-goals / YAGNI

- No free-form node placement / arbitrary wire drawing (structured + GOTO only).
- No action qualifiers beyond the existing N (non-stored) action (S/R/L/P/D…
  are out of scope).
- No default-project showcase change here beyond what's needed (optional,
  plan-time, guarded by scan-equivalence).

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400 (the 2D canvas pans/zooms; chrome
  must not overflow).
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. the new region /
  layout helpers.
- Additive persistence: existing SFC charts (all `single` transitions) load and
  render unchanged; new fields default so a legacy chart round-trips
  behaviourally; the default projects' 20-scan scan-equivalence stays green.
- Deterministic engine (scan-tick clock only; no wall-clock/random).

## Current state (as-found)

- Model (`mobile/lib/models/project_model.dart`): `SfcStep {String id; String
  name; bool isInitial; String actionSt;}`; `SfcTransition {String id; String
  fromStepId; String toStepId; String conditionSt;}`. A `PlcProgram` has
  `List<SfcStep> sfcSteps`, `List<SfcTransition> sfcTransitions`.
- Engine (`mobile/lib/models/sfc_exec.dart`): `SfcRuntime { Map<String,String>
  activeStepId; Map<String,int> stepElapsedMs; }` — **one** active step per
  program; each scan runs the active step's action, then the first true outgoing
  transition (list order) switches the token; dangling targets skipped;
  `STEP_T` per active step; force-aware writes.
- Editor (`mobile/lib/screens/sfc_editor_screen.dart`) + pure `sfc_layout.dart`
  (flow-order list + inline/GOTO) + `sfc_edit.dart` (add/delete/reorder branch,
  delete-step). The list rendering + GOTO chips are **replaced** by the 2D
  canvas; `sfc_edit.dart`'s pure graph-edit helpers are extended (not discarded).

## Component 1 — Model (additive)

`SfcStep` unchanged. `SfcTransition` gains:

- `String kind;` — `'single'` (default) | `'parallelFork'` | `'parallelJoin'`.
  json `kind` (fromJson default `'single'`).
- `List<String> toStepIds;` — a **parallelFork**'s N target steps (all
  activated). json `to_step_ids` (default `[]`). Unused for other kinds.
- `List<String> fromStepIds;` — a **parallelJoin**'s N source steps (all must be
  active). json `from_step_ids` (default `[]`). Unused for other kinds.

Representation per kind:
- `single`: `fromStepId` → `toStepId` (as today); lists empty.
- `parallelFork`: `fromStepId` = the diverging step; `toStepIds` = the parallel
  branch heads; `toStepId` unused (kept empty).
- `parallelJoin`: `fromStepIds` = the branch tail steps (all must be active);
  `toStepId` = the continuation step; `fromStepId` unused.

All three new fields always serialized (file style). A legacy transition has
no `kind`/`to_step_ids`/`from_step_ids` → loads as `single` with empty lists →
unchanged. No data migration.

## Component 2 — Engine: multi-token (`sfc_exec.dart`)

Replace the single active step with an **active-step set** per program:

```dart
class SfcRuntime {
  final Map<String, Set<String>> active = {};    // progName -> active step ids
  final Map<String, int> stepElapsedMs = {};      // '<prog>|<stepId>' -> STEP_T ms
  void clear() { active.clear(); stepElapsedMs.clear(); }
}
```

Per program, each scan (`dtMs`):

1. **Init:** if `active[prog]` is empty, seed it with the `isInitial` step (or
   `sfcSteps.first`), elapsed 0.
2. **Elapsed:** for each active step, `stepElapsedMs['$prog|$id'] += dtMs`.
3. **Actions:** run every active step's `actionSt` (deterministic order — by
   `sfcSteps` index), each with `extraVars {'STEP_T': <that step's elapsed>}`,
   force-aware writes.
4. **Compute firings against the snapshot** `S0 = active[prog]` (start of scan):
   - `single` t: eligible if `t.fromStepId ∈ S0` and `cond(t)` — sources
     `{fromStepId}`, targets `{toStepId}`.
   - `parallelFork` t: eligible if `t.fromStepId ∈ S0` and `cond(t)` — sources
     `{fromStepId}`, targets `toStepIds`.
   - `parallelJoin` t: eligible if `t.fromStepIds ⊆ S0` and `cond(t)` — sources
     `fromStepIds`, targets `{toStepId}`.
   - **Commit** eligible firings in `sfcTransitions` list order; a firing
     commits only if **none** of its source steps were already consumed by an
     earlier committed firing this scan (so alternative branches from the same
     step resolve first-true = list order; disjoint tokens all fire).
5. **Apply:** `active[prog] = (S0 − consumedSources) ∪ addedTargets`; skip a
   target that matches no step (dangling). For each **newly** added target,
   reset `stepElapsedMs['$prog|$id'] = 0`.

Properties: alternative first-true preserved; a fork removes its source and adds
all branch heads; a join removes all its branch tails and adds the continuation
only when all are active + condition; nesting is automatic (flat set + explicit
join membership); a target added this scan does not itself fire until next scan
(computed against the snapshot). Single-token charts (all `single`, no forks)
behave exactly as before.

## Component 3 — Structured region model + layout (pure)

Two Flutter-free units, replacing `sfc_layout.dart`'s list algorithm:

**`mobile/lib/models/sfc_region.dart`** — parse the well-structured graph into a
region tree from the initial step:

```dart
sealed class SfcRegion {}                 // (use a base class + subtypes if
class SeqRegion extends SfcRegion { final List<SfcRegion> items; }  // sealed unsupported)
class StepRegion extends SfcRegion { final SfcStep step; }
class TransRegion extends SfcRegion { final SfcTransition t; final SfcStep? target; final bool isGoto; }
class AltRegion extends SfcRegion { final SfcStep head; final List<SfcRegion> branches; final SfcStep? merge; }
class ParRegion extends SfcRegion { final SfcTransition fork; final List<SfcRegion> branches; final SfcTransition join; final SfcStep? after; }

SfcRegion parseSfc(List<SfcStep> steps, List<SfcTransition> transitions);
```

Parse rules (from a step, following non-back-edge outgoings):
- One `single` outgoing → the sequence continues (StepRegion, TransRegion, …).
- Multiple `single` outgoings → `AltRegion`: each outgoing begins a branch,
  branches parse until a common convergence step (or GOTO); recurse per branch.
- One `parallelFork` outgoing → `ParRegion`: each `toStepIds` head begins a
  parallel branch, each parses until its tail (a member of the matching
  `parallelJoin.fromStepIds`); the `join` continues to `join.toStepId`; recurse.
- A transition whose target is an already-visited step → `TransRegion` with
  `isGoto = true` (a GOTO reference leaf; not expanded).
- Cycle-safe (visited set); unreachable steps appended as a trailing note
  region (kept simple).

**`mobile/lib/models/sfc_layout2.dart`** — turn a region tree into positioned
geometry (pure, unit-testable): compute each region's `(width, height)`
bottom-up, then assign absolute `(x, y)` top-down, returning a flat list of
placed boxes (steps, transition blocks) + connector segments (vertical lines,
single-line alt divergence/convergence horizontals, double-line parallel
fork/join bars) + GOTO chip placements. Side-by-side branches are laid out as
columns; nesting recurses (a column's width is its sub-region's width).

## Component 4 — Rendering: 2D canvas (`sfc_editor_screen.dart`)

Rewrite the editor body to a pan/zoom canvas (like the FBD/LD editors' pattern):
- An `InteractiveViewer` hosting a `Stack`:
  - a `CustomPaint` painter drawing the connectors from `sfc_layout2` — vertical
    links, single-line alternative divergence/convergence horizontals, and the
    **double-line** parallel fork/join bars;
  - `Positioned` **step boxes** (rounded rectangle: INITIAL/STEP badge, name,
    the N-action ST) and **transition blocks** (bordered box with the condition
    ST field and the transition bar through it — the "make it a block" ask);
  - `Positioned` **GOTO** chips for back-edges (`↺ GOTO <name>`), as shipped.
- Tapping a step box or transition block opens its inline editor (name / action
  / condition / target), matching the existing edit affordances. The tag &
  condition autocomplete dock/sheet is retained.

## Component 5 — Editor authoring (structured; `sfc_edit.dart` extensions)

Pure, structure-preserving graph-edit helpers (extend the existing file), driven
by canvas affordances:
- **＋ Add step after** a step (extends the sequence).
- **＋ Add alternative branch** at a step (adds another `single` outgoing +
  branch that converges to the same next step).
- **＋ Add parallel (AND) branch** — wraps the segment after a step in a
  `parallelFork` → N branch heads → `parallelJoin` → continuation; adding
  another parallel branch inside a branch nests. Helpers create the matching
  fork/join pair and keep `toStepIds`/`fromStepIds` consistent.
- **Set target** (existing step / ＋New step / GOTO), **edit condition**,
  **delete branch**, **delete step** (cleans referencing transitions both
  directions incl. fork/join membership; promotes an initial if needed; keeps
  the chart well-structured — deleting a lone parallel branch collapses the
  fork/join if only one branch remains).
- Every op maintains the well-structured invariant (no operation can create an
  unstructured graph); illegal ops are disabled/no-ops.

## Component 6 — Live online highlighting (Go-Online)

Mirror the LD editor's Go-Online monitor for the multi-token SFC. The engine
already holds the live marking in `SfcRuntime.active[prog]` (the active-step
set) and `stepElapsedMs['$prog|$id']` (each active step's `STEP_T`). Expose it
to the editor and render it live, transient (session-only), like the LD monitor.

- **Wiring:** the shell owns `ScanTickRuntime.sfc` (`SfcRuntime`). `SfcEditorScreen`
  gains a `SfcRuntime sfcRuntime` param + a `bool scanRunning` (the shell passes
  `_scan.sfc` and `isRunning && !_faulted`) — the same pattern used for the LD
  `LdMonitor`/`scanRunning`.
- **Toggle:** a session-only `_online` bool + a "Go Online" toolbar toggle
  (`Icons.sensors`, `LIVE`/`FROZEN` label from `scanRunning`), default off,
  never persisted — identical UX to the LD editor.
- **Highlight (when `_online`):**
  - **Active step boxes** glow energized (bright green fill/border); inactive
    steps dim to slate. With parallel branches, **multiple** boxes are lit at
    once — the online view makes concurrent/parallel execution obvious.
  - An **active step's live `STEP_T`** is shown on its box (read from
    `stepElapsedMs`), like the LD block live values.
  - A transition block whose **from-step(s) are active and condition is true**
    (about to fire) highlights amber; otherwise normal. (Condition truth is
    read live via the existing ST-condition evaluation used by the engine, or
    left as active/enabled-only if that is simpler — plan-time call.)
- **Repaint** via `LiveTick` (Phase 12), gated on `_online`; paused → frozen on
  the last marking (the active set stops updating). Off / stopped → plain 2D
  view. Nothing persisted.
- **Gating** matches the LD monitor: live rendering active iff `_online`
  (so paused freezes rather than dropping to static).

## Data flow

Scan tick → `executeSfcPrograms` advances the active-step **set** (fork/join/
alternative) in `SfcRuntime`. Editor mutates `sfcSteps`/`sfcTransitions` in
place via the pure helpers + existing autosave. Rendering derives `parseSfc` →
`sfc_layout2` each build (cheap; memoize per rebuild if needed) and, when
`_online`, reads the live active set from `sfcRuntime` and repaints on the
`LiveTick` pulse. No new persisted state beyond the 3 additive transition fields
(the Go-Online toggle is transient).

## Error handling / edge cases

- Malformed/partly-built chart (mid-authoring): `parseSfc` degrades gracefully
  — an unparseable region renders as a plain sequence with GOTO leaves rather
  than throwing; the engine skips dangling targets.
- A join whose sources aren't all reachable never fires (tokens wait) — a valid
  "blocked" state, surfaced visually (join bar not satisfied).
- Exactly one initial step maintained; empty chart handled (no active set).
- Deleting one of two parallel branches collapses the fork/join to a sequence.

## Testing

- **Pure region/layout (`sfc_region_test`, `sfc_layout2_test`):** a linear
  chart; an alternative divergence (2 branches + merge); a parallel divergence
  (fork/2 branches/join); a **nested** parallel (parallel inside a parallel
  branch); a loop-back → GOTO leaf; positions non-overlapping, columns
  side-by-side, nesting widths correct; cycle-safe.
- **Engine multi-token (`sfc_exec` tests):** fork activates all branch heads;
  join fires only when all tails active + condition (and not before); nested
  parallel completes correctly; alternative first-true still holds; a
  single-token/legacy chart reproduces the old sequence exactly; loop
  reactivation; STEP_T per active step; round-trip determinism.
- **Widget:** the 2D canvas renders a reference-style chart (step boxes,
  transition blocks, alternative side-by-side, double-line parallel bars, GOTO
  chip); authoring (add step / add alternative / add parallel / nest / delete)
  updates the model + re-lays-out; edit a condition/target/name; no RenderFlex
  overflow at 320/360/1400; pan/zoom works.
- **Live online:** with a running `SfcRuntime` whose active set contains a step
  (and, for parallel, two steps), Go-Online on lights those step boxes and dims
  the rest; two concurrently-active parallel steps are both lit; Go-Online off
  renders the plain view; repaint occurs on a `LiveTick` pulse without a
  whole-shell `setState`; nothing about the toggle is persisted.
- **Round-trip:** `kind`/`to_step_ids`/`from_step_ids` survive `toJson`/
  `fromJson`; a legacy chart (no new keys) loads as all-`single`; the default
  projects' 20-scan scan-equivalence stays green.
- Full green gate: `flutter test`, `flutter analyze`, `flutter build web
  --release`.

## Files

- **Modify:** `models/project_model.dart` (SfcTransition fields + json);
  `models/sfc_exec.dart` (multi-token engine; expose the active-step set already
  held in `SfcRuntime`); `screens/sfc_editor_screen.dart` (2D canvas rewrite +
  authoring affordances + Go-Online highlight); `screens/workspace_shell.dart`
  (pass `_scan.sfc` + `isRunning && !_faulted` into `SfcEditorScreen`, mirroring
  the LD `LdMonitor`/`scanRunning` wiring).
- **Create:** `models/sfc_region.dart` (parse), `models/sfc_layout2.dart`
  (geometry) + tests.
- **Modify/retire:** `models/sfc_layout.dart` (the old list layout — replaced;
  delete once unused) and extend `models/sfc_edit.dart` (fork/join/parallel
  helpers).
- **Docs:** rewrite `docs/sfc-branching.md` → SFC v2 (2D + parallel) +
  `ROADMAP.md` (Phase 3) + `README.md` on completion.

## Migration & compatibility

No data migration. Existing single-token charts (all `single` transitions,
incl. the alternative branches shipped earlier) load unchanged and render in the
2D layout as a linear/alternative flow. The scan-equivalence guard confirms
behavioural identity for the default projects. Older app builds ignore the new
transition keys.
