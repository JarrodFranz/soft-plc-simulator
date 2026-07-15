# SFC Alternative (OR) Branching

This note documents alternative branching in the Sequential Function Chart
(SFC) editor and engine: a step choosing between several possible next
steps by priority order, evaluated on a single active token.

**Non-goal**: this is *alternative* (OR/selection) branching only — exactly
one outgoing transition fires per scan, and the chart carries exactly one
active step (token) per program. There is no parallel/AND branching (no
simultaneous divergence into multiple concurrently-active steps, and no
convergence/synchronization join). A step with multiple outgoing
transitions behaves like an if/else-if ladder, not a fork.

## Model: a step can own multiple ordered outgoing transitions

`SfcStep`/`SfcTransition` (`mobile/lib/models/project_model.dart`) already
supported this before this effort: a transition is just `fromStepId` +
`toStepId` + `conditionSt`, and any number of transitions may share the
same `fromStepId`. What changed is that the *editor* now lets a user build
and reorder that set per step, instead of one step having at most one
practically-editable outgoing path.

Top-to-bottom order of a step's outgoing transitions **is** their
if/else-if priority. That order is the transition's position within the
program's single `sfcTransitions` list (transitions sharing a `fromStepId`
form an ordered group within that list) — there is no separate priority
field to keep in sync.

## Engine: first-true wins (unchanged)

The scan engine, `executeSfcPrograms` in `mobile/lib/models/sfc_exec.dart`,
was **not modified** by this effort — it already implemented exactly the
semantics the editor now exposes:

- Each scan, the active step's `actionSt` runs (N/non-stored action
  semantics), then the engine walks `prog.sfcTransitions` **in list order**
  looking for transitions whose `fromStepId` matches the active step.
- The **first** transition in that order whose `conditionSt` evaluates true
  switches the active step (effective next scan) and stops evaluating
  further transitions for this program this scan — later transitions in
  the same group are never reached once an earlier one fires. This is the
  if/else-if behavior: priority = list order.
- If the winning transition's `toStepId` doesn't match any existing step
  (a dangling target — see below), the engine skips it and keeps
  evaluating later transitions in the group rather than stranding the scan
  with no active step.
- Only a single token is tracked (`SfcRuntime.activeStepId` is one step id
  per program name) — there is no mechanism for a step to activate more
  than one successor at once.

## Editor: per-step branch list

The step card (`_buildSfcStepCard` in
`mobile/lib/screens/sfc_editor_screen.dart`) gained an **Add branch**
button (`Icons.add_circle_outline`) that calls `addSfcBranch` — it appends
a new outgoing transition defaulted to a self-hold (`toStepId` = the
step's own id, `conditionSt = 'TRUE'`) for the user to then retarget and
re-condition.

Each outgoing transition renders its own branch-control row
(`_branchControls`) with:

- A **target dropdown** (`DropdownButton<int>`, keyed by step index rather
  than id) listing every step in the program plus a trailing sentinel
  entry **"＋ New step…"**. Picking a step retargets `toStepId`; picking
  "＋ New step…" calls `addSfcStep` and retargets to the freshly created
  step in the same action.
- **Reorder controls** (`Icons.arrow_upward` / `Icons.arrow_downward`,
  tooltips "Higher priority" / "Lower priority") calling
  `reorderSfcBranch`, which swaps the transition with its neighbor *within
  its `fromStepId` group* inside the global `sfcTransitions` list — this
  directly changes engine-observed priority, since the engine reads that
  same list order.
- A **delete-branch** control (`Icons.delete_outline`, tooltip "Delete
  branch") calling `deleteSfcTransition` to remove just that one outgoing
  transition.
- The existing condition editor (`_buildSfcTransitionGraphic`) underneath,
  unchanged, for editing that branch's `conditionSt`.

## Layout: flow order + GOTO chips

Steps are laid out top-to-bottom in **flow order** starting from the
initial step, not in raw list/creation order. `layoutSfc` (a pure helper,
`mobile/lib/models/sfc_layout.dart`) walks the chart depth-first from the
initial step (fallback: the first step), following each step's *first*
not-yet-placed outgoing target to continue the main line. A step is placed
the first time it's reached; steps never reached by any walk are appended
last, in their original list order. The walk is cycle-safe (a step already
placed is never re-entered).

For each step's outgoing transitions, at most one is drawn **inline** —
directly connecting down into the next card, the way a linear SFC always
has. That's the first outgoing (in priority order) whose target is exactly
the next card in the flow-ordered layout. Every other outgoing (including
extra branches to already-placed steps, or a step whose only successor
isn't the next card) renders as a distinct **GOTO chip** instead of an
inline connector:

- **`Icons.subdirectory_arrow_left`** — a loop-back: the target step is at
  or above the current row (a genuine cycle back into earlier logic).
- **`Icons.arrow_forward`** — a forward branch: the target step exists but
  is laid out further down than the next card (skips over intervening
  steps).
- **`Icons.link_off`** with label **"(deleted)"** — a dangling target: the
  transition's `toStepId` no longer matches any step in the program (its
  target step was deleted). The engine treats this the same way at
  runtime: it skips the transition and evaluates the next one in the
  group.

Each chip is labeled `GOTO <target step name>` (or `GOTO (deleted)`).

## Delete-step cleanup + initial promotion

`deleteSfcStep` (`mobile/lib/models/sfc_edit.dart`) removes the step and
**every** transition that references it in **either** direction — as a
source (its own outgoing branches) and as a target (any other step's
branch pointing at it, which would otherwise become a "(deleted)" chip
forever). If the deleted step was the initial step and at least one step
remains, the first remaining step is promoted to initial, so the engine
and the flow-order layout always have a start step to walk from.

## Nothing new is persisted

No serialization or migration change was needed. `SfcStep`/`SfcTransition`
already round-tripped the full graph (arbitrary transition counts per
step, arbitrary targets) before this effort — a step "owning multiple
ordered outgoing transitions" was already representable on disk; only the
editor UI to author and reorder that shape, and the flow-order layout to
render it sensibly, were new. A project saved with alternative branches,
reloaded, produces the identical step/transition graph (same ids, same
`sfcTransitions` order, same priorities).

## Testing

Covered by dedicated tests alongside the full existing suite:
`test/sfc_layout_test.dart` (flow-order placement, inline vs. GOTO
classification, cycle safety), `test/sfc_edit_test.dart` (`addSfcBranch`,
`deleteSfcTransition`, `deleteSfcStep` cleanup + initial promotion,
`reorderSfcBranch` priority swaps), `test/sfc_editor_authoring_test.dart`
and `test/sfc_editor_branch_render_test.dart` (editor UI: add/delete
branch, target dropdown incl. "＋ New step…", reorder buttons, GOTO chip
rendering), `test/sfc_branch_roundtrip_test.dart` (save/reload byte-for-
byte graph equivalence), and `test/sfc_exec_test.dart` /
`test/sfc_exec_integration_test.dart` (engine first-true-wins priority and
dangling-target skip behavior, unchanged).
