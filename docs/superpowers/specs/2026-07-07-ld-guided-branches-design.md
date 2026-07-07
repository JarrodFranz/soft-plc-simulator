# Ladder Editor — Guided, Blank Branches (WS22) Design

**Date:** 2026-07-07
**Status:** Approved by user (chat, 2026-07-07): guided junction-anchor picking + empty branches, resting behavior = **open / no-op until filled**.
**Area:** `mobile/lib/models/project_model.dart` (LdKind), `ld_graph.dart`, `ld_layout.dart`, `ld_exec.dart`, `mobile/lib/screens/ld_editor_screen.dart`.
**Builds on:** WS21 (ladder editor enhancements, merged `c328b58`).

## Problem

Today's branch flow (`ld_editor_screen.dart` `_onNodeTap` branch path + `addParallelBranch` in `ld_graph.dart`):
- Select **Branch** → tap one element → tap a second element → creates a new lane spanning those two, **pre-seeded with a `New_Contact`**, then exits to Select.
- No visual indication of what is tappable, no feedback that the first pick registered, no way to make a **blank** branch, and no way to merge at the **right rail** (a branch "to the end", e.g. for a second output).

The user wants: (1) branch mode shows the valid **start and end locations**; (2) pick a start then an end to create the branch; (3) the branch is created **blank** so they can then drop a coil or any element into it.

## Goal

Replace the blind two-element tap with a **guided junction-anchor flow** that creates an **empty** parallel branch (open / no logical effect until filled), including branches that merge at the right rail. Filling the branch uses the existing element tools.

## Non-goals (YAGNI)

- Nested branches (a branch inside a branch) — v-next if ever needed.
- Multi-element auto-population — the branch is created empty; the user adds elements.
- Changing series insertion, coil-terminal rules, or the drag-to-move-branch handles (they keep working).

## A. The empty-branch model — an open "link" placeholder

A branch lane must be carried by a node (the layout derives lanes from node `row`; the executor evaluates power through nodes/wires). So an empty branch is represented by **one placeholder node** of a new kind:

- **`LdKind.link`** (added to `enum LdKind { leftRail, rightRail, contact, coil, block, link }`, `project_model.dart:129`). A `link` node carries no variable/preset; it is the empty branch's single occupant.
- **Executor** (`ld_exec.dart`, new `case LdKind.link`): `power[n.id] = false` — an unfilled branch **contributes nothing** to the merge's power OR, so adding an empty branch never changes rung logic (the "open / no-op until filled" guarantee). No writes.
- **Renderer** (`ld_editor_screen.dart` `_buildLink`): a ghosted horizontal segment on the branch lane with a centered **＋ "fill" affordance**; visually distinct (dashed/low-alpha) so it reads as "empty slot", not a wire.
- **Serialization**: additive — `LdKind.link` is a new enum value; `fromJson` already tolerates unknown kinds via `orElse`, and a saved empty branch round-trips as `kind: 'link'`. Default projects contain no `link` nodes, so the WS6 byte-stable round-trip guard is unaffected.

### Filling an empty branch = REPLACE the placeholder (not insert in series)

Critical: the `link` node is **open** (blocks power). If a real element were inserted *in series* with it, the branch would stay dead (`element AND open = open`). So filling **replaces** the placeholder:

- In an element mode (Contact / Coil / Block), the `link` node's ＋ (or tapping the node) **converts** that node into the chosen element in place — same id, same lane, same tap/merge wires — via a new `fillLink(rung, linkNode, newNode)` helper that swaps the node while preserving its wiring. For a Block, the block-type picker's pending type is used; the edit dialog opens after fill.
- After the branch holds a real element, **normal series insertion** (`insertContactOnWire` via the existing ＋ wire targets) adds further elements within the branch — no `link` involved anymore.
- A branch may also be **emptied again**: deleting the sole element of a branch converts it back to a `link` placeholder rather than destroying the lane (keeps the user's branch structure while they reconsider). Deleting a `link` removes the branch entirely (tap+merge wires collapse back to the main line).

## B. Guided anchor picking

When `_editMode == 'branch'`, overlay **junction anchor dots** on the rung and drive a two-step pick:

- **Junctions** = the power-flow points on the main line where a branch may tap off or merge back: after the left rail, between each pair of consecutive main-line elements, and at the right rail. Each junction maps to an existing wire on lane 0 (a branch taps off the *source* end and merges at the *dest* end of main-line wires). Concretely, a junction is identified by the main-line node **after** which it sits (left-rail start = "before the first element"; right-rail end = "after the last element / coil").
- **Step 1 — pick start:** all junctions render as tappable dots (cyan). Tapping one sets `_branchAnchorStart`, highlights it (filled), and dims every junction **at or left of** it; only junctions strictly to its right stay lit as valid ends.
- **Step 2 — pick end:** tapping a lit end junction calls `addEmptyBranch(rung, startJunction, endJunction)` → a new lane with a single `link` node, tap wire from the start junction's source to the link, merge wire from the link to the end junction's dest. Then reset to Select (consistent with today) — the user switches to an element tool to fill it. A ＋ on the fresh branch also enters fill directly.
- **Cancel:** tapping the highlighted start again, or a "Cancel branch" hint action, clears `_branchAnchorStart`. The existing branch hint line is replaced by a stateful prompt: "Tap a start point" → "Tap an end point (or the start to cancel)".
- The right rail is a valid **end** junction (branch to the end); the left rail is a valid **start** junction. This makes "tap off mid-rung, merge past the coil" a first-class action and subsumes WS21's `addOutputCoil` special case (which remains for the Coil-mode ＋).

## Interfaces (pure helpers, `ld_graph.dart`)

- `LdNode addEmptyBranch(LdRung rung, LdNode startAfter, LdNode endAfter)` — allocates `lane = maxLane(rung)+1`, adds a `LdKind.link` node on it, wires `(source feeding the junction after startAfter) → link → (dest of the junction after endAfter)`, returns the link node. `startAfter`/`endAfter` are main-line nodes identifying the junctions (use `kLeftRailId` sentinel for the start-of-rung junction and `kRightRailId` for the end). Mirrors `addParallelBranch` wiring but inserts a `link`, not a contact, and supports rail-anchored ends.
- `LdNode fillLink(LdRung rung, LdNode link, LdNode replacement)` — replaces `link` with `replacement` in `rung.nodes`, re-points every wire referencing `link.id` to `replacement.id` (keeps id/lane), returns `replacement`. Asserts `link.kind == LdKind.link`.
- `void emptyBranchElement(LdRung rung, LdNode soleElement)` — the inverse used by delete: if `soleElement` is the only node on its (non-zero) lane, convert it back to a `link`; else fall through to normal node deletion. (Delete of a `link` removes the branch: drop the link + its two wires, reconnect nothing — the parallel path just disappears.)

## Executor / layout notes

- `ld_exec.dart`: add `case LdKind.link: power[n.id] = false; break;` (open). Everything else unchanged; the branch merge already ORs lane powers, so an open link is a no-op.
- `ld_layout.dart` / rendering: a `link` node participates in `colAssignment`/lane layout exactly like any node (it has a real `row` and wires), so lane sizing/`maxLane`/min-width already handle it; only a new visual (`_buildLink`) and inclusion in the positioned-node filter are needed. `link` node height = `_kContactH`.

## Testing

- **Pure graph unit** (`ld_graph_test.dart`): `addEmptyBranch` creates a lane with one `link` wired tap→link→merge, incl. left-rail-start and right-rail-end anchors; `fillLink` swaps kind while preserving wires/lane/id; `emptyBranchElement` reverts a sole element to `link` and leaves multi-element branches alone; deleting a `link` collapses the branch.
- **Executor unit** (`ld_exec_test.dart`): an empty branch (link) across a powered section is a **no-op** — rung output identical with and without it; after `fillLink` to a closed contact, the branch ORs power as expected (proves open→filled transition).
- **Widget** (`ld_editor_test.dart`): entering Branch mode shows junction dots; picking a start dims left/self and lights right-only ends; picking an end creates an empty (ghosted, ＋) branch; tapping the ＋ in Contact mode fills it with a contact (link gone); right-rail end anchor produces a branch to the end; no RenderFlex overflow at 320/1400.
- **Round-trip** (`serialization_roundtrip_test.dart`): a program with an empty `link` branch and a filled branch survives `toJson`/`fromJson` deep-equal.
- Full `flutter test` green, `flutter analyze` ZERO, `flutter build web --release` compiles.

## Global constraints

- No vendor branding; IEC terms fine. Zero analyze warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- Pure logic (`ld_graph`, `ld_layout`, `ld_exec`, `project_model`) stays Flutter-free.
- LD writes remain force-aware (unchanged — `link` writes nothing).
- Additive persistence: new `LdKind.link` enum value only; existing projects round-trip byte-identically (no `link` nodes in defaults). WS6 guard green.

## Phasing (one spec → three plan tasks)

1. **Model + engine + graph helpers** — `LdKind.link`, executor open-case, `addEmptyBranch`/`fillLink`/`emptyBranchElement`, unit + round-trip tests.
2. **Guided anchor UI** — junction-dot overlay, two-step start/end pick with dimming + cancel, empty-branch creation on pick, stateful hint.
3. **Fill/empty interactions + rendering + validation** — `_buildLink` ghost+＋ visual, fill-on-tap (replace) in element modes incl. block picker, delete→revert-to-link, full gates + final review.
