# FBD Editor Overhaul — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-23

## Goal

Turn the app's flat single-canvas FBD editor into an IEC 61131-3-faithful
**multi-network** editor: a program is a top-to-bottom stack of numbered
networks that execute in sequence (data-flow order within each), every block is
nameable, and a live-value/logic overlay lets you watch and trace execution like
the LD and SFC editors. Built as **one bundled overhaul, networks-first**.

## Reference

IEC 61131-3 FBD execution (see the user's "FBD Logic Execution Order" notes):
networks execute in **numbered sequence** (normally top-to-bottom); **within** a
network, evaluation follows **data dependencies** (a block runs only when all its
inputs are available — conventionally left-to-right); **between independent
branches** no order is guaranteed, so order-sensitive logic must be placed in
**separate, ordered networks**. This design implements exactly that model.

## North-star decisions (from brainstorming)

1. **Stacked network lanes** — the program is a vertical list of numbered
   networks; each is a bounded region with a header and its own canvas. (Not a
   single banded canvas, not tabs.)
2. **One bundled overhaul, networks-first**: networks → name-all-blocks → live
   overlay → readability polish.
3. **Networks-first** everything else layers on the network model.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic execution (no clock/RNG in the
  evaluator beyond existing per-block state). Zero `flutter analyze` warnings.
- **Additive / backward-compatible**: new serialization keys only; every existing
  FBD program (and all default demos) loads and executes **identically** to
  today. No change to LD/SFC/ST.
- Responsive: no overflow at 320 / 360 / 1400; dark theme.
- Live widgets use the mandated `LiveTick`/`LiveTickScope` throttled repaint (no
  shell-wide setState per scan).

## §1 — Data model & migration

- **`FbdBlock` gains `int network`** (default `0`). A "network" is the set of
  blocks sharing that index.
- **`PlcProgram` gains `List<FbdNetwork> fbdNetworks`** where
  `FbdNetwork { String comment; }` and the **list index = network number =
  execution order**. Absent on old files → treated as a single network 0.
- **Wires are intra-network only.** Per IEC, blocks in different networks are not
  wired together; data crosses networks through **tags** (`TAG_OUTPUT` in an
  earlier network, `TAG_INPUT` in a later one). The editor only offers wiring
  between blocks in the same network; `FbdWire` needs no change (both endpoints
  are always in one network).
- **Migration:** on load, any FBD program with blocks but no explicit
  `fbdNetworks`/`network` keys → all blocks are network 0, `fbdNetworks =
  [FbdNetwork(comment: '')]`. Behaviour is unchanged (one network executes as the
  whole program does today).
- **Serialization:** additive keys `network` (on each block) and `fbd_networks`
  (on the program). All `fromJson` paths stay null-tolerant, so old ↔ new files
  round-trip.

## §2 — Execution semantics (IEC-faithful)

- **`executeFbdPrograms` becomes network-aware:** instead of one topological pass
  over all of a program's blocks, it iterates the program's networks **in index
  order (0, 1, 2, …)** and runs the existing topological worklist **scoped to
  each network's blocks/wires**.
- **Within a network:** unchanged data-flow evaluation — a block evaluates once
  all blocks feeding its inputs are done; independent branches in deterministic
  (list) order; the existing cycle guard (evaluate-once-with-cached-values)
  terminates feedback loops.
- **Cross-network data is sequential:** `TAG_OUTPUT` writes are force-aware and
  land on the tag immediately, so a `TAG_INPUT` in a later network (same scan)
  reads the updated value — the PDF's "network N before N+1" sequencing. The
  order-sensitive shared-variable case the PDF warns about becomes correct by
  putting the producer in an earlier network than the consumer.
- **Stateful blocks** (TON/TOF/TP, CTU/CTD/CTUD, PID, R_TRIG/F_TRIG) stay keyed
  by block id — per-instance state unchanged; they just live inside a network.
- **Backward-compatible:** a migrated one-network program runs identically to
  today (a single topo pass over all its blocks == one network). Deterministic.

## §3 — Editor UX (stacked lanes + naming)

- **Layout:** the editor is a vertical scroll of **network lanes**. Each lane =
  a header row + a bounded pan/zoom canvas holding that network's blocks. The
  header shows `Network N`, an **editable comment/title**, and per-lane controls:
  *add block*, *auto-arrange*, *move up*, *move down*, *delete network*
  (delete confirms; it removes the lane and its blocks/wires and renumbers).
- **Networks:** a **"+ Network"** action appends a lane; move up/down reorders
  (which *is* the execution order — touch-friendly, no separate order field).
- **Block placement & membership:** dragging a block repositions it **within its
  lane**. To move a block to a different network, use a **"Network" dropdown in
  the block's config dialog** (not drag-across-lanes). Wiring is only offered
  between blocks in the same lane. **Reassigning a block's network prunes any of
  its wires that would then cross a network boundary** (both a wire is only ever
  intra-network, so a moved block's connections to its old lane are removed);
  the same pruning applies when a network is deleted (its blocks' wires go with
  it). Wires reference block ids, so reordering/renumbering networks never
  invalidates a wire.
- **Name all blocks:** the config dialog already carries a "Block name" field for
  every type; expose an **edit affordance (tap/pencil) on every block card** —
  including operator blocks (`+ - > < &` → ADD/SUB/GT/LT/AND) which currently have
  no route to the dialog on desktop. The title renders on the card header (it
  already does). Names are labels/comments (IEC-compliant instance
  names/comments); they do not change execution.
- **Per-lane auto-arrange** reuses the existing dependency-depth layout scoped to
  one network, giving each lane a clean left-to-right data-flow layout.
- **Responsive:** lanes stack and the page scrolls at 320/360/1400; each lane's
  canvas pans/zooms. Replacing the single 1600×1200 soup with many small,
  ordered, labelled per-network canvases is itself the core readability win.

## §4 — Live-value + logic overlay (mirrors LD/SFC)

- **New `FbdMonitor`** (analogous to `LdMonitor`): a transient, memory-only map
  keyed `'<program>|<blockId>|<pin>' → value`, cleared on project switch. The
  executor already computes every block's `{pin: value}` map each scan and
  discards it — persist it into a passed-in monitor.
- **`executeFbdPrograms` gains a `monitor` param** (mirroring the LD call); the
  scan passes `rt.fbdMonitor`.
- **The FBD editor gains `monitor` + `scanRunning`** constructor params (like
  LD/SFC) and an **"online" toggle** (default off; static view unchanged).
- **Overlay (while online):**
  - **Live pin/wire values** — each wire shows the value it carries (its source
    pin): compact numbers for analog, `TRUE`/`FALSE` for booleans.
  - **Energized coloring** — boolean wires/pins glow green when `TRUE`, dim when
    `FALSE` (the LD power-flow convention) so logic is traceable at a glance.
  - Stateful blocks show their key live outputs at the pins (`Q`, `ET`, `CV`, …)
    from the monitor.
- **Throttled repaint** via `LiveTick`/`LiveTickScope` — only on-screen lanes
  rebuild per scan pulse. Values are the last scan's solve (read from the
  monitor), decoupled from the scan thread, exactly like LD/SFC.

## §5 — Readability, testing, backward-compat

**Readability** is delivered by the combination: ordered, labelled,
individually-laid-out lanes replace the block soup; per-lane auto-arrange; block
names + network comments document intent; the live overlay shows real
values/energization for tracing.

**Testing:**
- *Execution (pure):* networks evaluate in index order (a producer network before
  a consumer network yields the correct sequential result — the PDF's shared-var
  case); within-network data-flow unchanged; a migrated flat program == one
  network == identical output; stateful blocks keep per-instance state across
  scans inside a network.
- *Editor (widget):* add/reorder/delete network (with renumber); name any block
  incl. operators; reassign a block's network via the dropdown; wiring confined
  to a lane; no overflow at 320/360/1400.
- *Live overlay:* `FbdMonitor` populated by the executor; online toggle shows
  values + green energized booleans; `LiveTick` repaint; offline view unchanged.
- *Serialization:* round-trip a multi-network program; old (no-network) file
  loads as one network; full existing suite stays green.

**Backward-compat:** additive keys, default network 0, tolerant `fromJson`; no
change to LD/SFC/ST or the scan contract beyond the new `monitor` param.

## Deferred / out of scope

Tracked in the canonical registry: **`docs/DEFERRED.md`** (see the "FBD editor
overhaul" section). In short: EN/ENO chaining, jumps/returns/labels, custom user
function blocks in FBD, and cross-network wiring are all out of scope — networks
already deliver the ordering the user asked for.
