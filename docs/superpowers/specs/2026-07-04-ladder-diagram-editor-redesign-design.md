# Ladder Diagram (LD) Editor Redesign — Design Spec

**Date:** 2026-07-04
**Status:** Draft for review
**Author:** Claude (pairing with Jarrod)

## Problem

The current LD editor (`mobile/lib/screens/ld_editor_screen.dart`) has three defects:

1. **TON timer block overflows vertically by 3px** — the timer widget's natural
   height exceeds the fixed 67px row constraint, producing a Flutter RenderFlex
   overflow error (`Column` at `ld_editor_screen.dart:765`).
2. **Rungs/wires are not visually connected** — the flat model draws gappy
   horizontal wires and no continuous power-rail frame.
3. **Branches cannot span arbitrary elements** — the data model represents a
   parallel branch (`LdBranch`) as a *whole full-width alternate row*, so you
   cannot wrap an OR around just a sub-span of series contacts (e.g. contacts
   2–3). Real ladder logic requires OR-ing around any chosen elements.

The root cause of #3 is the model: `LdRung { inputInstructions[],
outputInstructions[], parallelBranches[] }` where each `LdBranch` is a complete
alternate row. This cannot express sub-span parallelism.

## Research summary (OpenPLC / Beremiz + PLCopen TC6)

- **Data model** is a node-and-wire *graph*. Every element (contact, coil,
  block, power rail) has a `localId`, input connection point(s), and output
  connection point(s). A wire is `<connection refLocalId="N">` referencing a
  source element. **An OR/parallel = one input connection point receiving
  multiple `<connection>` children** (power converges from A *or* B).
- **Series vs parallel:** series is a linear chain of `refLocalId` references;
  parallel is multiple connections converging on one input point.
- **Rendering geometry:** contacts/coils are 21×15px; power rails 3px wide;
  40px between rungs; Manhattan-routed wires. Contact modifiers: normal `| |`,
  negated `|/|`, rising `|P|`, falling `|N|`. Coil modifiers: normal `( )`,
  negated `(/)`, set `(S)`, reset `(R)`, rising `(P)`, falling `(N)`.
- **Interaction:** OpenPLC selects an element/group, right-clicks → "Add
  Divergence Branch," which extracts the left/right connectors of the selection
  and generates new parallel wires. Elements are inserted in series by dropping
  onto a wire (splitting it). Toolbar is mode-based (Select / Contact / Coil /
  Block / Power Rail / Connection).

## Decisions (confirmed with user)

1. **Data model:** free-form node-and-wire **graph** (OpenPLC-exact), not a
   series/parallel tree.
2. **Rails:** **both** — a continuous outer L1/L2 frame spanning all rungs AND
   unbroken internal wires within each rung.
3. **Branch UX:** add a branch over a selected span, **and** the branch's start
   and end are **draggable** so the user can move them to span different
   elements.

## Architecture

### Data model (`mobile/lib/models/project_model.dart`)

Replace `LdInstruction`, `LdBranch`, `LdRung` with:

```dart
enum LdKind { leftRail, rightRail, contact, coil, block }

class LdNode {
  String id;              // unique within its rung
  LdKind kind;
  String variable;        // bound tag (contact/coil); '' for rails/blocks
  String modifier;        // 'normal'|'negated'|'rising'|'falling'|'set'|'reset'
  String blockType;       // 'TON'|'TOF'|'CTU'|... (kind == block)
  int presetMs;           // block preset time (TON/TOF)
  String comment;
  int col;                // grid column (series index) — assigned by layout
  int row;                // grid lane (0 = main line) — assigned by layout
}

class LdWire {
  String fromId;          // source node id
  String fromPort;        // source output port ('out','Q','ET',...)
  String toId;            // destination node id
  String toPort;          // destination input port ('in','EN','IN','PT',...)
}

class LdRung {
  int rungIndex;
  String comment;
  List<LdNode> nodes;     // includes exactly one leftRail and one rightRail
  List<LdWire> wires;
}
```

- **Series** A→B: wires `[railL→A, A→B, B→railR]`.
- **Parallel around B** (OR of B and B2): add node `B2` (row 1) and wires
  `A→B2`, `B2→railR`. Now `railR.in` receives from both `B` and `B2` — an OR.
  More generally a branch taps any node's output and merges into any downstream
  node's input.

### Layout algorithm (pure function: rung → positioned nodes + routed wires)

1. **Column assignment:** `leftRail.col = 0`. For each node,
   `col = 1 + max(col of every node feeding its inputs)` (longest path from the
   left rail). `rightRail.col = maxCol + 1`. This orders series elements.
2. **Row/lane assignment:** DFS from `leftRail`; the first path found is lane 0
   (main line). Each additional incoming wire at a convergence spawns a new lane
   for the nodes unique to that path. Lanes are packed to minimise height.
3. **Pixel geometry:** `x = col * kColW`; `y = laneTop(row)`. Each lane's height
   is the tallest element in it (a TON block lane is taller than a contact lane),
   so **nothing is constrained smaller than its content → no overflow.**

### Rendering (`ld_editor_screen.dart`)

- A single scrolling canvas. A `CustomPainter` (`_LadderPainter`) draws:
  - the **continuous L1 (green) and L2 (blue) frame** down the full program
    height,
  - per-rung **horizontal wires** and **vertical branch brackets**, computed
    from node grid positions (Manhattan segments), unbroken end to end.
- Element widgets (`_ContactWidget`, `_CoilWidget`, `_BlockWidget`) live in a
  `Stack` layer above the painter at computed `(x,y)`. Blocks (TON/TOF) get a
  fitted fixed size with IN/PT/Q/ET pins laid out inside — no intrinsic overflow.
- Selected elements draw a highlight; a selected branch draws its two drag
  handles.

### Interaction

Toolbar modes (mirrors OpenPLC): **Select · Contact · Coil · Block · Branch**.

- **Series insert:** in Contact/Coil/Block mode, tap a wire segment → element is
  inserted on that wire, splitting it (the wire's downstream endpoint re-points
  to the new element's output).
- **Add branch:** in Branch mode (or via a "＋ Branch" action), tap a start
  element then an end element; a new empty parallel lane is wired from the start
  element's upstream node output to the end element's downstream node input.
- **Movable branch endpoints:** a selected branch shows **drag handles at its
  start and end**. Dragging a handle horizontally snaps it to the nearest
  element's connection column and re-wires the branch to span a different set of
  elements. (This is the user's explicit requirement beyond OpenPLC.)
- **Edit element:** double-tap → dialog with variable (tag autocomplete) +
  modifier (normal / negated / rising / falling for contacts; normal / negated /
  set / reset / rising / falling for coils) + preset (blocks).
- **Delete:** select element or branch → delete button removes it and heals the
  wires (upstream re-points to downstream).

### Migration

- Rewrite the two LD default programs in `default_projects.dart`
  (`ConveyorBelt_LD` in `_ldConveyorProject`, `PumpControl_LD` in
  `_allWaterProject`) and the built-in motor/mixer demo rungs in
  `_ensureDefaultRungs()` into the new node/wire graph.
- The scan simulation (`workspace_shell._evaluateActiveLogic`) uses hardcoded
  per-project physics and does **not** read the LD structure, so it continues to
  work unchanged. Verify no other code references the removed LD fields.

## Testing / validation

- `flutter analyze` → **zero** issues (use `withValues(alpha:)`,
  `initialValue:` on dropdowns).
- Build web release, run under the Chrome extension, and verify:
  1. No RenderFlex overflow on the TON rung.
  2. Continuous L1/L2 frame and unbroken wires across all rungs.
  3. Adding a parallel branch over a chosen span works.
  4. Dragging a branch's start/end handle re-spans it across different elements.
  5. All 7 default projects still load; the two LD programs render correctly.

## Constraints (must hold)

- No "OpenPLC" branding in any user-facing UI, labels, comments, or identifiers.
- Dark theme preserved.
- Zero `flutter analyze` warnings.

## Out of scope

- Non-series-parallel bridge circuits are *representable* in the graph model but
  the auto-layout targets series-parallel topologies; exotic bridge layouts may
  render imperfectly.
- Executing the LD graph in the scan engine (kept as hardcoded physics for now).
