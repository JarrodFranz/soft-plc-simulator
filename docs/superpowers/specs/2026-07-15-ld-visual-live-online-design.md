# LD Editor Visual + Live-Online Monitoring — Design Spec

**Date:** 2026-07-15
**Status:** Approved (design)
**Workstream:** B (of two — the four Phase 9 process-sim features follow, each as its own spec)

## Goal

Improve the Ladder Diagram (LD) editor's rendering and add a live "online"
monitoring mode, so a running project's ladder reads like being online with a
real PLC:

1. **Branch risers** land at the horizontal midpoint of the wire gap between
   two elements, not flush against an element's edge.
2. **Contact/coil symbols** sit *on* the connecting wire (the wire passes
   through the glyph), with the tag name captioned above.
3. **Go-Online live monitoring** — an opt-in toolbar toggle that, while the PLC
   is running, highlights energized power flow (wires + elements) and shows
   live operand values on block faces.

## Non-goals / YAGNI

- No new persisted model. The monitor state and the Go-Online toggle are both
  **transient** (session-only); nothing is added to `toJson`/`fromJson`.
- No change to LD *execution* semantics — the power solve is reused verbatim,
  only tapped.
- Contacts/coils convey true/false by **color only** — no added TRUE/FALSE
  text on their faces (keeps them compact). Live *numeric* values appear only
  where they add information: block faces (timers/counters/compare/math).
- Not touching FBD/SFC/ST editors. LD only.

## Global Constraints (carry into every task)

- Dark theme; use `withValues(alpha:)` (never `withOpacity`). Braces on all
  control flow. No `flutter analyze` warnings.
- No RenderFlex overflow at widths 320 / 360 / 1400.
- Pure Dart in `models/` (no Flutter imports in `ld_layout.dart`,
  `ld_exec.dart`, `ld_monitor.dart`).
- Live-value repaint MUST go through `LiveTick` (Phase 12) — never a
  whole-shell `setState` on the scan tick. New live widgets wrap their value
  leaf in a `ListenableBuilder` on the `LiveTick` pulse.
- Additive only: existing static rendering (Go-Online off, or PLC stopped) must
  look byte-identical to today.

## Current architecture (as-found)

- `mobile/lib/models/ld_layout.dart` — pure geometry constants + helpers.
  `kLdColW=116` (column pitch), `kLdCellW=66` (cell width), `kLdCoilRailGap=40`.
  `ldColX(col)=col*kLdColW`; `ldNodeX(node,col,width)` (coils right-pin, else
  `ldColX`).
- `mobile/lib/screens/ld_editor_screen.dart` (~1547 lines):
  - Per-node geometry: `_nodeCenterY`, `_outPort`, `_inPort` (ports at the
    cell's vertical center = `_nodeCenterY`).
  - `_LadderPainter` (`CustomPainter`, lines ~1497-1547) draws wires/branch
    risers. For a wire whose endpoints share a row it draws a straight
    horizontal line; going to a deeper lane (`dst.row > src.row`) it drops a
    vertical at `p1.dx` (source's right edge) then goes horizontal; returning
    (`dst.row < src.row`) it goes horizontal to `p2.dx` (destination's left
    edge) then vertical. `shouldRepaint => true`.
  - `_buildContactCoil(n)` (lines ~1259-1322): a centered
    `Column[ Text(tagName, 9pt), SizedBox(2), Text(symbol, 14pt) ]` inside a
    bordered `Container`. Because the column is centered, the port Y (cell
    center) falls in the 2px gap *above* the symbol, so the wire does not pass
    through the glyph.
  - `_buildBlock(n)` / `_buildDataBlock(n)`: block faces (header + pin rows +
    preset/operand text). Timers show static `PT <ms>ms`; counters `PV <n>`;
    compare/math show operand A / glyph / operand B.
  - Branch junction dots (`_junctionDot`), wire-insert targets
    (`_wireInsertTarget`), and draggable branch handles (`_handle`) are all
    positioned off `_outPort`/`_inPort`.
- `mobile/lib/models/ld_exec.dart` — `executeRung(...)` builds a local
  `power = <String,bool>{}` map (node id → energized/passing), used to drive
  coils/blocks, then discarded. `LdExecRuntime` holds cross-scan edge state
  (`prevBool`), cleared on project switch.
- `LiveTick`/`LiveTickScope` (`mobile/lib/widgets/live_tick.dart`) — Phase 12
  throttled repaint pulse; `readPath` (`tag_resolver.dart`) reads live values.

## Part A — Branch risers at the gap midpoint

**Rule:** a branch riser is drawn at the center of the wire gap adjacent to the
branch element it serves, i.e. inset `(kLdColW - kLdCellW)/2 = 25px` from the
element edge, with a short horizontal stub connecting the element port to the
riser.

**New pure helper** in `ld_layout.dart`:

```dart
/// Half the inter-cell wire gap — the inset from a cell edge to the centre of
/// the gap between it and the neighbouring column.
const double kLdGapHalf = (kLdColW - kLdCellW) / 2; // 25.0

/// X of the vertical branch riser sitting in the gap immediately to the LEFT
/// of the cell at [col] (i.e. centred between col-1's right edge and col's
/// left edge).
double ldRiserXBefore(int col) => ldColX(col) - kLdGapHalf;

/// X of the vertical branch riser sitting in the gap immediately to the RIGHT
/// of the cell at [col].
double ldRiserXAfter(int col) => ldColX(col) + kLdCellW + kLdGapHalf;
```

**Painter change** (`_LadderPainter.paint`): for a lane-changing wire, replace
the flush-edge vertical with a gap-centered riser:
- Deeper (`dst.row > src.row`): the branch *drops in* before its first element.
  Riser X = `ldRiserXBefore(col[dst])`. Path: from `p1` (source out-port)
  horizontal to riser X, vertical down to `p2.dy`, horizontal to `p2` (dest
  in-port).
- Returning (`dst.row < src.row`): the branch *rejoins* after its last element.
  Riser X = `ldRiserXAfter(col[src])`. Path: from `p1` (source out-port)
  horizontal to riser X, vertical up to `p2.dy`, horizontal to `p2`.
- Same-row wires unchanged (straight horizontal).

The junction-dot and branch-handle positions are element ports (unchanged) —
only the connecting riser geometry moves, so handles/dots keep working. Verify
during implementation that the drawn stubs meet the handles cleanly.

**Edge cases:** a branch whose element sits at column 0-adjacent to the left
rail still has a ≥25px gap (rail at x=0, first column at x=116). Multi-element
branches: each lane-change wire is handled independently by the rule above.

## Part B — Contact/coil symbol on the wire

**Rule:** the symbol glyph is vertically centered in the cell (so the port-Y /
wire passes through it); the tag name is captioned just above the symbol.

**Change** `_buildContactCoil` to a `Stack` (or an equivalent centered layout):
- The symbol `Text` is centered in the cell (`Alignment.center`), so its
  vertical middle coincides with `_nodeCenterY`.
- The tag name `Text` is placed just above the symbol (e.g. a `Positioned` near
  the top of the cell, or a bottom-anchored caption above the centered glyph),
  single-line, ellipsized, same 9pt style.
- Border/fill container unchanged in size (`kLdCellW` × `_kContactH=54`), so
  layout/branch math is unaffected. Port Y stays `_nodeCenterY`.

Confirm the wire (drawn by the painter at `_nodeCenterY`) visually enters/exits
through the glyph on both contacts and coils, at all modifiers
(`-| |-`, `-|/|-`, `-( )-`, `-(S)-`, etc.).

## Part C — Go-Online live monitoring

### C1 — Power tap (`ld_monitor.dart`, pure)

A transient holder recording the last scan's per-node power, keyed to survive
across rungs/programs:

```dart
class LdMonitor {
  /// Key: '<progName>|<rungIndex>|<nodeId>' -> energized/passing this scan.
  final Map<String, bool> nodePower = {};
  void clear() => nodePower.clear();
}
```

`executeRung` gains an optional `LdMonitor? monitor` parameter. Where it already
assigns `power[n.id] = ...` for each node, when `monitor != null` it also writes
`monitor.nodePower['$progName|${rung.rungIndex}|${n.id}'] = <that value>`. No
other behavior changes; when `monitor == null` (all existing callers/tests) the
function is byte-identical.

`executeLdPrograms` gains the same optional `LdMonitor? monitor` pass-through.

A wire is energized iff its source node is energized: the editor reads
`monitor.nodePower['$prog|$rung|${wire.fromId}']`.

### C2 — Wiring the monitor through the scan + editor

- The shell/scan owner (the object holding `LdExecRuntime`) also owns one
  `LdMonitor`, created alongside it and `clear()`ed at the same points
  (project switch, program-structure change) as the exec runtime.
- `scan_tick.dart` passes the monitor into `executeLdPrograms` each scan (only
  needed when a monitored view is open, but passing always is cheap and keeps
  the map warm; decide during planning — default: pass always).
- `LdEditorScreen` receives the `LdMonitor` and a "is running" signal. The
  editor already receives `currentProject`; add constructor params for the
  monitor and a running-state accessor (or reuse an existing shell handle).
  Confirm the exact plumbing when reading the editor's launch site during
  planning.

### C3 — Go-Online toggle

- New `_online` bool in `_LdEditorScreenState`, default `false`, session-only
  (not persisted).
- A toolbar toggle (e.g. an `Icons.sensors`/"MONITOR" affordance in the app-bar
  actions or the mode toolbar) flips `_online`.
- **Live rendering is active iff `_online && isRunning`.** Otherwise the static
  view renders exactly as today.

### C4 — Visual conventions (live active)

- **Energized** (power true): bright theme green with a subtle glow — wire
  stroke brighter/thicker; element gets an energized border + faint fill tint.
- **De-energized** (power false): dim gray (wires) / dim element border+text.
- Contact passing / coil energized / block Q true → energized styling; blocked
  → de-energized.
- **Live values on block faces** (only when live active):
  - Timer (`TON`/`TOF`/`TP`): show live `ACC / PT` (read `<base>.ACC`,
    `<base>.PRE`) — e.g. `1400 / 3000 ms`.
  - Counter (`CTU`/`CTD`/`CTUD`): show live `CV / PV`.
  - Compare/math: show live resolved operand A / B and (compare) the boolean
    result via the block's energized styling; (math) the written result value.
- Contacts/coils: **no added text** — the energized/de-energized color *is* the
  indicator.

### C5 — Repaint

- Wrap the rung canvas's `CustomPaint` and the live-styled element faces in a
  `ListenableBuilder` on the `LiveTick` pulse (via `LiveTickScope.of(context)`),
  so they repaint on the throttled tick only while `_online && isRunning`.
- `_LadderPainter` already `shouldRepaint => true`; it reads `monitor.nodePower`
  + `_online`/running so each pulse reflects the latest scan.
- Paused: the scan stops updating `nodePower`, so the view naturally **freezes**
  on the last scan (desired — inspect a frozen state). Stopped or `_online`
  off: static view.

## Testing

- **Pure (`ld_layout` geometry):** `ldRiserXBefore`/`ldRiserXAfter`/`kLdGapHalf`
  return the gap-center X for sample columns (e.g. col 1 → `116-25=91` before,
  `116+66+25=207` after).
- **Pure (`ld_monitor` / power tap):** run `executeRung` with a monitor over a
  rung containing a false series contact; assert the contact and every
  downstream node read `nodePower == false`, and a parallel true path reads
  `true` (mirror the existing power-flow tests, now asserting the tapped map).
  Assert `monitor == null` path is unchanged (existing exec tests stay green).
- **Widget (symbol-on-wire):** pump a rung; assert the symbol glyph's center
  aligns to `_nodeCenterY` within tolerance (or a golden-free geometric check
  via the render box), for a contact and a coil.
- **Widget (Go-Online):** with a running fixture + `_online` on, the painter/
  faces use energized colors for a true path and dim for a false path; with
  `_online` off, colors match the static palette. Toggle flips it.
- **Widget (LiveTick):** a `nodePower` change + `LiveTick` pulse repaints the
  ladder without a shell-level `setState` (reuse the Phase 12 no-shell-rebuild
  pattern).
- **Overflow:** the rung canvas has no RenderFlex overflow at 320/360/1400 in
  both static and live modes.
- **Round-trip:** a project with rungs/branches/blocks `toJson`→`fromJson` is
  unchanged; assert `LdMonitor`/`_online` add nothing to the serialized JSON.
- Full green gate: `flutter test`, `flutter analyze`,
  `flutter build web --release`.

## Files

- `mobile/lib/models/ld_layout.dart` — add `kLdGapHalf`, `ldRiserXBefore`,
  `ldRiserXAfter`.
- `mobile/lib/models/ld_monitor.dart` — new `LdMonitor` holder.
- `mobile/lib/models/ld_exec.dart` — optional `LdMonitor? monitor` on
  `executeRung` + `executeLdPrograms`; record `nodePower` when present.
- `mobile/lib/screens/ld_editor_screen.dart` — painter riser geometry (Part A),
  `_buildContactCoil` symbol layout (Part B), Go-Online toggle + live rendering
  + LiveTick wiring (Part C).
- `mobile/lib/screens/scan_tick.dart` (+ the shell owning `LdExecRuntime`) —
  own, thread, and `clear()` the `LdMonitor`.
- Docs: extend/author an LD monitoring note under `docs/` (e.g.
  `docs/ld-editor.md`), and update `ROADMAP.md`/`README.md` on completion.
