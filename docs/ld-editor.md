# LD Editor: Branch Geometry, Symbol Layout & the Go-Online Live Monitor

This document covers the Ladder Diagram (LD) editor's visual rework — how
branch risers and element symbols are positioned on the rung canvas — and
the session-only "Go-Online" live monitor that overlays the last scan's
power-flow solve on that same canvas.

Implementation: `mobile/lib/models/ld_layout.dart` (pure geometry helpers),
`mobile/lib/screens/ld_editor_screen.dart` (rung canvas, symbol widgets,
the Go-Online toggle and `_LadderPainter`), `mobile/lib/models/ld_monitor.dart`
(the transient power tap), `mobile/lib/models/ld_exec.dart` (`executeRung`'s
monitor write), and `mobile/lib/screens/scan_tick.dart`
(`ScanTickRuntime.ldMonitor`).

## Gap-centre branch risers

A rung's elements sit on a fixed column grid (`ldColX(col) = col * kLdColW`,
`kLdColW = 116.0`, cell width `kLdCellW = 66.0`), leaving a 50 px gap between
adjacent cells for the wire. A branch riser — the vertical segment a wire
takes when it steps between lanes (rows) — used to be drawn flush against a
cell edge, which visually crowded the element it was next to. It is now
centred in that inter-cell gap instead:

- `kLdGapHalf` — half the inter-cell gap, `(kLdColW - kLdCellW) / 2 = 25.0`.
- `ldRiserXBefore(col)` — the riser x-position in the gap immediately to the
  **left** of the cell at `col` (`ldColX(col) - kLdGapHalf`).
- `ldRiserXAfter(col)` — the riser x-position in the gap immediately to the
  **right** of the cell at `col` (`ldColX(col) + kLdCellW + kLdGapHalf`).

`_LadderPainter.paint` (in `ld_editor_screen.dart`) picks between the two
per wire, based on whether the wire is descending into a deeper branch lane
(`ldRiserXBefore` of the destination column) or returning to a shallower one
(`ldRiserXAfter` of the source column) — so every riser sits at the midpoint
of the gap next to the branch element it serves, regardless of direction.

## Symbol-on-wire layout

Contact and coil symbols (`_buildContactCoil`) are laid out with a `Stack`
so the glyph (`-| |-`, `-|/|-`, `-( )-`, `-(S)-`, etc.) is centred both
horizontally and vertically in the cell — exactly where the horizontal wire
passes through it — instead of being offset above or below the wire line.
The tag/variable name is captioned as a separate `Positioned` `Text` just
above the glyph, inside the same cell, so the label never competes with the
wire for vertical space.

## The Go-Online live monitor

A **Go-Online** toggle (`Icons.sensors`, tooltip "Go Online (live monitor)")
sits in the LD editor's app bar. It is a **session-only, per-editor-instance
boolean** (`_online` in `_LdEditorScreenState`) — it is never written to the
project and is not part of any persisted state.

### The power tap (`LdMonitor`)

`LdMonitor` (`mobile/lib/models/ld_monitor.dart`) is a small, transient,
in-memory tap of the power-flow solve:

```dart
class LdMonitor {
  final Map<String, bool> nodePower = {};
  String keyFor(String prog, int rungIndex, String nodeId) =>
      '$prog|$rungIndex|$nodeId';
  void clear() => nodePower.clear();
}
```

`executeRung` (`ld_exec.dart`) accepts an optional `monitor` parameter; after
solving a rung's node power for the tick, it writes every node's energized
state into `monitor.nodePower` keyed by `keyFor(progName, rung.rungIndex,
node.id)`. `ScanTickRuntime` (`scan_tick.dart`) owns one `LdMonitor` instance
(`ldMonitor`) for the whole session and passes it into `executeLdPrograms`
on every scan tick, so `nodePower` always reflects the most recently
completed scan. `ldMonitor.clear()` runs alongside the other runtime resets
in `ScanTickRuntime.resetSession()` (project switch / run-session reset).

### Rendering: energized/de-energized palette and live values

When `_online` is true, the editor reads `widget.monitor.nodePower` (via
`_nodeLit(rung, node)`, keyed the same way `executeRung` wrote it) to decide
how to paint each wire and element:

- **Energized** (`lit == true`): bright `Colors.greenAccent` (`_kEnergized`),
  with a thicker wire stroke.
- **De-energized** (`lit == false`): a dim slate (`Color(0xFF475569)`,
  `_kDeEnergized`).

This overrides the normal static-editor colors (green contacts, amber coils,
plain green wires) only while online; the static (offline) rendering path is
completely unchanged.

Block faces (`_buildBlock`/`_buildDataBlock`) additionally show **live
values** while online, via `_liveNum(path)` (reads through `readPath` against
the live project, formatting ints as-is and doubles to one decimal, or an
em dash if unresolvable):
- Timer blocks (`TON`/`TOF`/`TP`): live `ACC` next to the configured preset.
- Counter blocks (`CTU`/`CTD`/`CTUD`): live `CV` next to the configured `PV`.
- Compare/math blocks (`GT`/`LT`/.../`ADD`/`SUB`/...): each resolved operand's
  live value, and for math blocks the resolved destination value.

### Repaint: `LiveTick`, not a shell rebuild

While online, each rung's canvas is wrapped in a `ListenableBuilder` listening
to `LiveTickScope.of(context)` (`wrapLive` in `ld_editor_screen.dart`), so it
repaints on every scan-tick pulse without the surrounding shell or workspace
doing a full `setState` — the same decoupled `LiveTick` pattern already used
by the Tag Inspector dock, the Memory Manager, and the trend chart. Offline,
`wrapLive` is a pass-through and the static tree is byte-for-byte identical
to before this feature.

### Freeze on pause

Live rendering is gated on `_online` alone, **not** on whether the scan loop
is currently running. This is deliberate: `LdMonitor.nodePower` is only ever
updated by a completed scan (`executeRung`), so when the scan loop is
paused, no new scan writes to the monitor — the last solved values simply
stay in place, and the online view freezes on that last state rather than
going blank or reverting to a "no power" default. The app bar shows a small
`LIVE`/`FROZEN` label next to the toggle (green while the scan loop is
running, amber while paused) purely as an indicator; it does not gate
rendering.

### Nothing is persisted

`LdMonitor.nodePower`, the `_online` toggle, and the `LIVE`/`FROZEN` label
are all transient, in-memory-only state:
- `LdMonitor` has no `toJson`/`fromJson` and is never attached to
  `PlcProject` or any of its child models.
- `_online` is local `State` on `_LdEditorScreenState`, reset to `false`
  every time the LD editor screen is (re)built.
- `ScanTickRuntime.ldMonitor` is cleared on every session reset alongside
  the other execution runtimes, exactly like `LdExecRuntime`/`FbdRuntime`.

`mobile/test/ld_no_persist_test.dart` is the regression guard for this: it
round-trips every default project's JSON (`PlcProject.toJson()` /
`PlcProject.fromJson()`) and asserts the re-serialized JSON is unchanged and
contains neither a `nodePower` nor an `online` key.

Other tests covering this feature: `mobile/test/ld_layout_geometry_test.dart`
(gap-centre riser geometry), `mobile/test/ld_symbol_alignment_test.dart`
(symbol-on-wire centring), `mobile/test/ld_branch_render_test.dart` (branch
rendering), `mobile/test/ld_monitor_test.dart` and
`mobile/test/scan_ld_monitor_test.dart` (the power tap through a real scan),
`mobile/test/ld_online_highlight_test.dart` (energized/de-energized
rendering), and `mobile/test/ld_online_values_test.dart` (live block values).
