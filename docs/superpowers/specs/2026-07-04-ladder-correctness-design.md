# Ladder Correctness (WS1) — Design Spec

**Date:** 2026-07-04
**Status:** Draft for review
**Author:** Claude (pairing with Jarrod)

This is Workstream 1 of a three-part editor improvement effort. WS2 (tag & type
system) and WS3 (simulated-inputs engine) are separate specs/plans, built after
this one.

## Problem

In the rebuilt ladder (LD) editor, three correctness issues remain, reported
from the running app:

1. **Rungs don't reach the right rail.** Each rung canvas is only as wide as its
   own content (`_rungWidth`), but the continuous L2 (right) power rail is a
   separate bar at the far right of the editor. The rung's wiring ends at its
   content width, leaving a visible gap between the last element and L2 — the
   rung "isn't connected to the other side."
2. **Coils aren't on the right.** Output coils sit at their computed column with
   a short wire to a content-width right-rail node, so they float in the middle
   rather than terminating against L2. IEC ladder convention (and the user's
   expectation) is that energize/output operations sit at the right rail and no
   non-destructive element (contact) follows an output on a path.
3. **Redundant demo logic.** The "Basic Motor Start Stop" project ships both
   `MotorControl_ST` and `MotorControl_LD` implementing the same motor logic.

A secondary symptom: the coil→rail wire renders oddly (reads as reddish/broken)
because of the content-width gap; wires are painted green in code
(`ld_editor_screen.dart` `_LadderPainter`, `Colors.greenAccent`).

## Decisions (confirmed with user)

- **Full-width rungs with right-pinned coils** (the layout fix below).
- **Hard-enforce** the coil-terminal rule: coils are the rightmost element on a
  path, connect only to the right rail, and nothing may follow them.
- **Keep LD only** in Basic Motor: remove `MotorControl_ST` from that project.

## Design

### 1. Full-width rungs; node-aware x-position

Today `_buildRungCanvas` sizes the rung `SizedBox` to `_rungWidth` (content
width) and positions every node at `_colX(col) = col * _kColW` (left-anchored).

Change:

- The rung canvas fills the **available width** `W` (from a `LayoutBuilder`
  around the rung, or the `Expanded` constraints), with
  `W = max(availableWidth, minContentWidth)` where `minContentWidth` guarantees
  the input elements and the pinned coil zone don't overlap.
- Introduce a node-aware horizontal position used by the painter,
  `_positionedNode`, and the port helpers:

  ```dart
  double _nodeX(LdRung rung, LdNode n, Map<String,int> col, double width) {
    if (n.kind == LdKind.coil) {
      return width - _kCellW - _kCoilRailGap; // right-anchored, against L2
    }
    return _colX(col[n.id] ?? 0);              // left-anchored from L1
  }
  ```

- The right-rail node's in-port sits at `x = width` (the canvas's right edge,
  flush with the continuous L2 bar), so the coil→rail wire is short and the rung
  visibly reaches L2.
- The wire from the last input element (contact/block) to a right-pinned coil is
  a single long horizontal segment filling the gap — the classic ladder look.
- Non-coil terminal elements (a rung ending in a block with no coil, e.g. a jam
  TON) stay left-anchored; their out-port connects to the right rail via a fill
  wire to `x = width`. This also closes the gap for coil-less rungs.

`_outPort` / `_inPort` are updated to call `_nodeX` instead of `_colX` for
non-rail nodes; rails keep their edge positions (left rail `x = 0`, right rail
`x = width`).

### 2. Coil-terminal invariant (hard-enforced)

**Invariant:** on every path, a coil's only outgoing wire goes to the right rail
(directly, or via a convergence that goes to the rail). No contact/block wire
ever has a coil as its source.

Enforcement points in the editor (`ld_editor_screen.dart`):

- **Contact/block insert:** the "＋" wire-insert targets are **not rendered on a
  wire whose source node is a coil**, nor on the coil→rail segment. You cannot
  insert an element after a coil.
- **Coil insert:** in Coil mode, tapping anywhere on a path adds the coil as that
  path's **terminal** element — wired directly into the right rail — regardless
  of which segment was tapped. If the tapped path already terminates in a coil,
  no insert target is offered on its terminal segment (prevents two coils in
  series). Adding another output to the same input logic is done by adding a
  parallel branch (existing Branch mode), which yields a second coil on its own
  lane — the correct IEC construct.
- A small pure helper in `ld_graph.dart` supports this:

  ```dart
  bool isCoil(LdRung rung, String nodeId); // kind == LdKind.coil
  ```

  and the editor checks `isCoil(rung, wire.fromId)` when deciding whether to show
  an insert target.

### 3. Remove redundant ST program from Basic Motor

In `default_projects.dart` `_motorProject`:

- Remove the `MotorControl_ST` `PlcProgram`.
- Remove `MotorControl_ST` from the continuous task's `programNames` list.
- Keep `MotorControl_LD` as the single program.

The scan simulation (`workspace_shell._evaluateActiveLogic`, `proj_motor`)
operates on tag names, not program objects, so it is unaffected.

### 4. Wire rendering

After (1), verify the painter draws every wire as a continuous green segment,
including the long input→coil fill and the short coil→rail segment. No red or
broken segments. If any stray coloring/logic is found, remove it. (Current paint
color is already `Colors.greenAccent`; the reddish look is expected to disappear
once the gap is gone.)

## Testing

- **Widget test** (`mobile/test/widget_test.dart`, new case): pump the LD editor
  for the conveyor program at desktop size and assert:
  - no overflow exception (existing gate preserved),
  - every coil node's rendered left-x is within the right ~20% of the canvas
    width (coils are right-pinned),
  - a rung with a coil has a wire whose endpoint reaches `x == canvasWidth`
    (rung meets the right rail).

  Because rendered positions aren't directly queryable from the widget tree, the
  test asserts via the pure position helpers: build the rung, run `colAssignment`
  + `_nodeX`, and check the coil's x and the right-rail x. The position helpers
  are therefore extracted so they are callable without a `BuildContext` (either
  as top-level functions in `ld_graph.dart` taking the layout constants, or as
  static helpers), and the widget covers the no-overflow/no-exception path.
- **Unit test** (`mobile/test/ld_graph_test.dart`): `isCoil` returns true only
  for coil nodes; a helper that lists insert-eligible wires excludes coil-source
  wires.
- **Chrome visual**: confirm rungs run L1 → contacts → coil → L2 with the coil
  against the right rail, wires continuous green, TON rung still overflow-free,
  and Basic Motor shows a single LD program.

## Global constraints (unchanged)

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` **zero** issues (`withValues(alpha:)`,
  `initialValue:` on dropdowns, braces on flow-control, prefer `const`).
- No RenderFlex overflow.

## Out of scope (deferred)

- Horizontal scrolling for rungs wider than the viewport (compress-for-now;
  noted as a limitation).
- The WS2 tag/type work (struct/bit expansion, arrays, DUT-typed tags) and WS3
  simulated-inputs engine — separate specs.
- Making `TONTimer.DN` resolve to a real member tag — that's WS2 (tag system);
  WS1 only changes layout/placement, not tag resolution.
