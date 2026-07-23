# FBD Networks: Multi-Lane Authoring, Ordering & the Live Overlay

The Function Block Diagram (FBD) editor organizes a program's blocks into
one or more **networks** — numbered, top-to-bottom lanes, each with its own
canvas and an optional comment, mirroring the IEC 61131-3 notion of
numbered FBD networks within a POU. This note covers the model, execution
order, how data crosses a network boundary, renaming blocks, and the
online live-value overlay.

Implementation: `mobile/lib/models/project_model.dart` (`FbdBlock.network`,
`FbdNetwork`, `PlcProgram.fbdNetworks`), `mobile/lib/models/fbd_networks.dart`
(pure edit helpers: `addFbdNetwork`/`moveFbdNetwork`/`deleteFbdNetwork`/
`setBlockNetwork`/`fbdBlocksInNetwork`/`pruneCrossNetworkWires`),
`mobile/lib/models/fbd_exec.dart` (`executeFbdPrograms`, network-ordered
execution), `mobile/lib/models/fbd_monitor.dart` (`FbdMonitor`, the live tap),
and `mobile/lib/screens/fbd_editor_screen.dart` (the lane UI, network CRUD,
block rename dialog, and the Go-Online overlay).

## The model

Each `FbdBlock` carries an `int network` (default `0`) indexing into its
owning `PlcProgram.fbdNetworks` — a list of `FbdNetwork` headers, each just a
`comment` string shown above its lane. `PlcProgram`'s constructor normalizes
`fbdNetworks` on construction (not only in `fromJson`), so an FBD program
with blocks always has at least one network header, whether it was built by
`fromJson` or directly (as the built-in default projects are). A
single-network program — every block at `network == 0` — behaves exactly as
it did before networks existed; this is the default for new FBD programs and
for every built-in demo except the one described below.

## Execution order

`executeFbdPrograms` partitions a program's blocks by `network` and
evaluates networks in **ascending index order** — network 0 fully resolves
(its topological worklist runs to completion) before network 1 starts, and
so on. Within a network, execution is unchanged from the pre-network
implementation: a block runs once every block feeding its input pins has
run.

**Wires never cross a network boundary.** An `FbdWire`'s `fromBlockId` and
`toBlockId` are always both in the same network — enforced by the editor
(`pruneCrossNetworkWires`, called after any block is reassigned to a
different network or a network is deleted) and by the demo below. This
means a network's dependency graph is fully self-contained; the executor
never has to look outside the current network to resolve an input.

## Cross-network data flow: through tags, not wires

Since wires can't cross a network boundary, one network hands a value to
another by writing a tag: a `TAG_OUTPUT` block in the earlier network writes
a value, and a `TAG_INPUT` block in a later network reads the same tag.
Because networks execute in order **within one scan**, the later network
sees the value the earlier network just wrote — no scan lag. (If the
producer were placed in a *later*-indexed network than the consumer, the
consumer would read the tag's value from *before* this scan, i.e. one scan
stale — a natural consequence of ascending-order execution, not a bug.)

### Shipped example: `WaterQuality_FBD`

The "All Languages — Water Treatment Plant" demo project's `WaterQuality_FBD`
program is split across 2 networks to show this pattern end-to-end:

- **Network 0 — "Thresholds"**: reads `Turbidity_PV`/`Turbidity_SP` into an
  `LT` gate and `Level_PV`/a `10.0` constant into a `GT` gate, then writes
  each gate's result to its own handoff tag via `TAG_OUTPUT`
  (`Turbidity_Below_SP`, `Level_Above_Min`).
- **Network 1 — "Quality gate & output"**: reads those two handoff tags back
  via `TAG_INPUT`, `AND`s them, and writes the result to `Quality_OK` via
  `TAG_OUTPUT` — the same tag the rest of the project (the ST safety
  supervisor, the LD pump interlock, the SFC backwash sequence) already
  consumes.

The net behavior is byte-identical to the prior single-network diagram
(same truth table for `Quality_OK` against turbidity/level); only the
internal structure changed, to demonstrate multi-network authoring and
ordering in a shipped project rather than only in tests. See
`mobile/test/fbd_exec_integration_test.dart` for the structural assertions
(2 networks, no wire crosses a network boundary) and the behavioral proof
(same-scan propagation through the handoff tags).

## Naming any block

Every block's `title` is user-editable, independent of its network: opening
a block's "Configure" dialog (tap/click the block) lets you rename it
freely — the network split above renames the `TAG_OUTPUT`/`TAG_INPUT` pairs
descriptively ("Turbidity OK", "Level OK") purely for readability, the same
mechanism available on any FBD project.

## The online live-value overlay

Like the LD editor's Go-Online monitor (`docs/ld-editor.md`), the FBD editor
has a session-only **Go Online** toggle (`Icons.sensors` in the app bar,
key `fbd_online_toggle`) that overlays the last scan's per-pin values on the
canvas without touching the project or any persisted state:

- `FbdMonitor` (`fbd_monitor.dart`) is a transient `Map<String, dynamic>`
  keyed by `keyFor(progName, blockId, pin)`, populated by
  `executeFbdPrograms(..., monitor: ...)` as each block is evaluated —
  across every network, in the same ascending order the scan actually runs.
- While online, each lane repaints on every `LiveTick` pulse (not a shell
  `setState`), showing wire/pin values and highlighting live state, then
  freezes on the last solved values when the scan loop is paused — the same
  `LiveTick` + freeze-on-pause pattern used throughout the app.
- Nothing here is persisted: no `toJson`/`fromJson` on `FbdMonitor`, and the
  `_online` toggle resets whenever the editor screen is rebuilt.

## Editing networks

The lane UI supports adding, reordering, deleting, and reassigning a
block's network from the editor itself; the underlying operations
(`addFbdNetwork`, `moveFbdNetwork`, `deleteFbdNetwork`, `setBlockNetwork`,
`fbdBlocksInNetwork`) live in `fbd_networks.dart` and are pure, deterministic,
and never throw — an out-of-range index or unknown block id is always a
no-op. `moveFbdNetwork` reorders execution (network index *is* execution
order); `setBlockNetwork` and `deleteFbdNetwork` both call
`pruneCrossNetworkWires` (directly or by construction) to preserve the
intra-network-only wire invariant.

## What's still deferred

EN/ENO chaining, jumps/returns/labels, and custom/user function blocks in
FBD remain out of scope — see `docs/DEFERRED.md`'s "FBD editor overhaul"
section. "Cross-network wiring" is listed there too, but that's a
description of the by-design constraint above (wires are intra-network by
design; the workaround is tags), not a missing feature.
