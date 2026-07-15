# SFC Alternative (OR / Selection) Branching — Design Spec

**Date:** 2026-07-15
**Status:** Approved (design)

## Goal

Let a Sequential Function Chart (SFC) express single-token **alternative
branching** — "if A → step X, else-if B → step Y" — by giving each step
**multiple ordered outgoing transitions**, each with its own editable target
step and condition (top-to-bottom order = if / else-if priority), and rendering
the resulting divergence, convergence, and loops in the existing phone-first
vertical editor. One active step at all times (no parallel/AND branching).

## Key finding that shapes the design

The data model and the execution engine **already support this**; only the
editor doesn't:

- `SfcStep {String id, String name, bool isInitial, String actionSt}` and
  `SfcTransition {String id, String fromStepId, String toStepId, String
  conditionSt}` are the real graph, fully serialized
  (`from_step_id`/`to_step_id`/`condition_st`).
- `executeSfcPrograms` (`mobile/lib/models/sfc_exec.dart`) keeps **one** active
  step per program, runs its N-action each scan, then scans
  `prog.sfcTransitions` in **list order**, and the **first transition whose
  `fromStepId == activeStep && condition is true`** switches the token to its
  `toStepId`. It already tolerates a dangling target (a `toStepId` with no
  matching step is skipped). Priority is therefore the order of a step's
  transitions within `sfcTransitions`.
- The **editor** (`mobile/lib/screens/sfc_editor_screen.dart`) is the only gap:
  it renders a strictly linear list, pairing `step[i]` with `transition[i]`
  positionally, `+` only appends a step, and a transition's target isn't
  editable — only its condition is.

**Consequence:** no model change, no engine change, and **no data migration** —
existing charts already carry correct `from/to` on every transition, so the new
editor renders them correctly the moment it honours the real graph. The old
last→first loop simply shows as a clean GOTO chip instead of a dangling
trailing transition.

## Non-goals / YAGNI

- **No parallel / simultaneous (AND) branching** — single token only.
- No change to `sfc_exec.dart` or `project_model.dart` (the model/engine are
  sufficient). We add only an engine *test* as a regression guard.
- No 2D divergence canvas; no drag-to-reorder of step cards (flow-order layout
  is computed).
- No step-rename feature unless it already exists — targets are chosen from the
  existing step set by their current name.

## Global Constraints (carry into every task)

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at widths 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `models/` and the new `models/sfc_layout.dart`.
- Additive persistence: no new serialized fields; a scalar-only/linear chart
  round-trips byte-identically and renders equivalently to before.
- Single active step preserved; exactly one `isInitial` step.

## Component 1 — Pure layout helper (`mobile/lib/models/sfc_layout.dart`)

A Flutter-free unit the editor consumes so the flow-order and
inline-vs-GOTO decisions are testable in isolation.

```dart
/// One entry in the laid-out chart: a step plus, for each of its outgoing
/// transitions (in priority order), whether the target is drawn INLINE
/// (the next card below) or as a GOTO reference chip.
class SfcLayoutRow {
  final SfcStep step;
  final List<SfcOutgoing> outgoing; // priority order (== sfcTransitions order)
}

class SfcOutgoing {
  final SfcTransition transition;
  final SfcStep? target;   // null if toStepId dangles (deleted step)
  final bool inline;       // true → this target is the card placed directly below
}

/// Orders steps by flow from the initial step: depth-first following each
/// step's FIRST outgoing transition, placing a target card the first time it
/// is reached; already-placed targets and additional branches become GOTO
/// chips. Branch-only-reachable steps follow the main path; unreachable steps
/// (not the initial, not any transition target) come last, in list order.
/// Cycle-safe via a visited set.
List<SfcLayoutRow> layoutSfc(List<SfcStep> steps, List<SfcTransition> transitions);
```

Rules:
- The **initial** step is the layout root (fallback: `steps.first` if none is
  marked initial — mirrors the engine's fallback).
- A step's `outgoing` is `transitions.where((t) => t.fromStepId == step.id)` in
  their existing `transitions` list order (priority preserved).
- `inline` is true for **at most one** outgoing per step: the first outgoing
  whose target has not yet been placed when this step is emitted. That target
  becomes the next card. All other outgoings (and any whose target is already
  placed, i.e. a loop/merge) are `inline == false` → GOTO chip.
- `target == null` when `toStepId` matches no step (dangling) → render a muted
  "→ (deleted)" chip so the user can re-target.

## Component 2 — Editor rewrite (`mobile/lib/screens/sfc_editor_screen.dart`)

Replace the positional `step[i]/transition[i]` rendering with a `layoutSfc`-
driven vertical list.

**Per step card** (existing card chrome: INITIAL STEP/STEP badge, name, delete,
editable N-action ST field), followed by an **Outgoing transitions** section:

- An ordered list of branch rows, each showing (priority number ①②③):
  - the editable **condition ST** field (reuse the existing SFC tag/condition
    autocomplete),
  - a **target** control: a dropdown/picker of all step names **plus** a
    "＋ New step…" entry that creates a fresh step and targets it,
  - **reorder** up/down (moves the transition within `sfcTransitions` among
    that step's outgoings → changes if/else-if priority),
  - **delete branch** (removes the transition).
- A **＋ add branch** button appending a new `SfcTransition` from this step
  (default condition `TRUE`, target = the next step if any else itself; user
  then edits).
- When a step's single inline outgoing leads to the card directly below, draw
  the existing vertical connector between them; every non-inline outgoing draws
  a **`→ GOTO <TargetName>`** chip (with a ↺ marker when the target is an
  ancestor/loop-back). A dangling target chips as "→ (deleted)".

**Delete step:** removes the step **and every transition referencing it in
either direction** (outgoing and incoming), so no orphans remain. If the
deleted step was `isInitial`, promote the first remaining step to initial (the
engine needs an initial/first step).

**Add step** (the top `＋`): unchanged entry point, but a newly-added step has
no incoming/outgoing transitions until wired — it appears in the layout under
"unreachable" until something targets it or it gains an outgoing. (Creating a
step via a branch's "＋ New step…" wires the incoming transition immediately.)

The right-dock / bottom-sheet **tag & condition autocomplete** palette is
unchanged.

## Data flow

Scan tick → `executeSfcPrograms` (unchanged) reads `sfcSteps`/`sfcTransitions`,
routes the single token by first-true priority. Editor edits mutate
`program.sfcSteps` / `program.sfcTransitions` in place and call
`onProgramUpdated` (existing debounced autosave). No new persisted state.

## Error handling / edge cases

- **Multiple outgoing, none true:** token stays on the step (engine behaviour,
  unchanged) — a valid "wait" state.
- **Catch-all:** a `TRUE` last-priority transition acts as `else`.
- **Loop to an earlier step:** allowed; renders as a ↺ GOTO chip; engine
  re-activates it next scan.
- **Dangling target** (e.g. after an external edit): engine skips it; editor
  chips it as "→ (deleted)" and offers re-target.
- **No initial step:** engine falls back to `steps.first`; editor promotes one
  on delete so there is always an initial.

## Testing

- **Engine guard (no code change, new test):** a step with three ordered
  outgoing transitions `A→X`, `B→Y`, `TRUE→Z` selects by priority (A wins when
  A&B both true; Y when only B; Z otherwise); a loop-back transition
  re-activates the target on the next scan. Proves first-true + single-token
  routing.
- **Pure `sfc_layout` tests:** a linear chart lays out in order with the tail
  loop as a GOTO; a 2-way branch places the first target inline and the second
  as a GOTO; a convergence (two steps → one) places the merge step once; an
  unreachable step lands last; a dangling target yields `target == null`;
  cycle-safety (self-loop, mutual loop) terminates.
- **Widget tests:** a branch list renders under a step with ①②③ priority; add
  branch; edit a condition; retarget via the dropdown; "＋ New step…" creates +
  wires a step; reorder swaps priority (and the underlying `sfcTransitions`
  order); delete branch; delete step removes all transitions touching it and
  promotes a new initial when needed; GOTO chip appears for a loop-back; no
  RenderFlex overflow at 320/360/1400.
- **Round-trip:** a branched chart `toJson`→`fromJson` preserves every
  transition's `from/to/condition` and their order (priority); a legacy linear
  chart is unchanged.
- Full green gate: `flutter test`, `flutter analyze`, `flutter build web
  --release`.

## Files

- **Create:** `mobile/lib/models/sfc_layout.dart` (pure flow-order + GOTO
  decision) and its test.
- **Modify:** `mobile/lib/screens/sfc_editor_screen.dart` (branch-list UI,
  target picker, reorder, add/delete branch, delete-step cleanup, `layoutSfc`
  rendering, GOTO chips).
- **Add:** engine regression test (`sfc_exec` priority/loop) — no engine code
  change.
- **Docs:** an SFC branching note (extend `docs/` and the SFC section) +
  `ROADMAP.md`/`README.md` update on completion.
- **Unchanged:** `mobile/lib/models/sfc_exec.dart`,
  `mobile/lib/models/project_model.dart`.

## Optional showcase (decide during planning)

Add a small alternative-branch demo to the default `BottleFill_SFC` (e.g. from
`WAIT_BOTTLE`: `Bottle_Present → FILLING`, else-if `Abort_Cmd → IDLE`) so the
feature is visible out of the box. Additive to an existing project's
transitions; guarded by the round-trip + scan-equivalence tests. Left as a
plan-time call to avoid scope creep here.
