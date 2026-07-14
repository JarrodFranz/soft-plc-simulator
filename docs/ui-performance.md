# UI Repaint Architecture

This note documents how the app keeps the UI smooth when a project has many
live tags updating every scan (dozens of ramps/sines, several outbound
protocols enabled, panels open) — a workload that used to visibly stutter
because every scan tick rebuilt the *entire* workspace shell.

The fix is general Flutter performance practice, applied in four places:
scope repaint listeners narrowly, replace whole-tree `setState` with a
throttled targeted-repaint signal, virtualize long lists, and let the user
tune the repaint rate to their device.

## 1. Gateway panel: scoped listeners + virtualized lists

The Outbound Protocols (gateway) panel used to wrap its *entire* body —
status chips, connection controls, and the full tag/point map — in one
`ListenableBuilder` on each protocol host. Any change on the host (even a
single status-byte flip) rebuilt every row of every map, regardless of
whether it was visible.

Two independent fixes (`mobile/lib/screens/gateway_screen.dart`):

- **Host-scoped listeners** — each host's `ListenableBuilder` now wraps only
  the small status/connection subtree (chip, host/port fields, connect
  button). A host notifying about connection state no longer touches the
  map rows at all.
- **Virtualized map lists** — the per-protocol tag/point map is built with
  `ListView.builder` over a lazily-materialized item list (folder headers +
  entries), so only on-screen (plus a small buffer) rows are ever built.
  Scrolling to row 500 of a 1,000-row map does not build the 499 rows above
  it.

Together, a host status change repaints a status chip, not a map; a map
with hundreds of rows only pays for the rows actually on screen.

## 2. `LiveTick` / `LiveTickScope`: throttled repaint instead of whole-shell `setState`

Before this change, every scan tick called `setState` on the top-level
workspace shell. That is the single most expensive way to reflect a tag
value change — it rebuilds the active view, the toolbar, the docks, and
everything else in the tree, every scan, even though only a handful of
on-screen widgets actually display a live value.

`mobile/lib/widgets/live_tick.dart` introduces a tiny dataless pulse:

```dart
class LiveTick extends ChangeNotifier {
  void pulse() => notifyListeners();
}
```

`LiveTickScope` (an `InheritedNotifier<LiveTick>`) exposes one shared
`LiveTick` down the widget tree. Deliberately, `LiveTickScope.of(context)`
is a **non-dependency** lookup (`getInheritedWidgetOfExactType`, not
`dependOnInheritedWidgetOfExactType`): the caller hands the returned
`LiveTick` straight to a `ListenableBuilder`/`AnimatedBuilder`, which
subscribes to it directly. If `of` registered an `InheritedWidget`
dependency instead, the calling widget (often an ancestor of the actual
value leaf) would also rebuild on every pulse — defeating the point.

Each surface that displays a live value (Tag Inspector cells, Memory
Manager's Live Value column, HMI dashboard components, editor run
overlays, the toolbar Scan Count, the fault banner) wraps just its value
leaf in `ListenableBuilder(listenable: LiveTickScope.of(context), builder:
...)`. On a pulse, only that leaf rebuilds — not its ancestors, not
sibling panes, not the shell.

The workspace shell (`mobile/lib/screens/workspace_shell.dart`) no longer
calls `setState` on every scan. Instead, `_executeScan` writes the tag
model directly and calls `_repaintThrottle.request()`, which coalesces
scan ticks (via the existing `NotifyThrottle`, already used for MQTT
publish pacing) down to the configured UI refresh rate before calling
`_liveTick.pulse()`. A targeted `setState` is still used for the rare
*structural* transitions that actually change the widget tree — a fault
first tripping, or an `AlarmReset`-driven fault clear — but the steady-state
per-scan path never touches shell-level state.

## 3. Configurable UI refresh rate

Because the repaint is now a deliberate, throttled pulse rather than an
unconditional per-scan rebuild, the pulse rate is a tunable: **SoftPLC
Settings → UI refresh rate (Hz)**. Default is **10 Hz**, range 1–30 Hz
(`kDefaultRefreshHz`, `clampRefreshHz` in `workspace_shell.dart`). The
setting is persisted globally (not per-project) via `SharedPreferences`
under the `ui_refresh_hz` key, read on shell boot, and applied immediately
when changed (the old `NotifyThrottle` is disposed and a new one built with
the new coalescing window — `refreshWindow(hz) = 1000/hz` ms). Raising the
rate re-paces value updates to feel more immediate at some CPU cost;
lowering it reduces repaint work further on constrained devices.

## 4. Collapsible Tag-Inspector folders

The Tag Inspector groups tags by their `PlcTag.folder` label (root tags
first, unlabeled; every other folder as an alphabetically-ordered,
count-labeled section, reusing the same `groupEntriesByFolder` helper the
protocol map editors and Memory Manager already use). Each non-root folder
header is collapsible — tapping it hides or re-shows its rows — so a
project with many generated/foldered tags (e.g. a 100-tag load-test set)
doesn't force the inspector into one long undifferentiated list. A live
value inside a still-expanded folder keeps updating on every `LiveTick`
pulse exactly as an ungrouped tag would.

## Why this matters

Combined, these four changes are why a project with ~100 live tags
ramping/oscillating every scan, with the MQTT gateway panel open and
actively transmitting, stays smooth: the gateway panel only repaints its
status chip and the rows actually on screen; the rest of the app only
repaints the specific value widgets that are visible, at a bounded,
user-tunable rate, instead of rebuilding the whole shell on every scan
tick.
