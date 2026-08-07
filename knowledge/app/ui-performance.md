---
id: knowledge:app/ui-performance
title: UI Performance
domain: app
version: "2026-08"
topics: [live-tick, notify-throttle, repaint, tag-historian, trend-chart, canvaskit]
summary: How live-value UI repaint is decoupled from the scan loop through a throttled LiveTick pulse and a leaf-only listener pattern, why the scan loop never setState's the whole shell, and the memory-only tick-driven TagHistorian ring buffer behind multi-pen trend charts.
related:
  - knowledge:app/index
  - knowledge:app/scan-engine
  - knowledge:practices/verification
---

# UI Performance

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/widgets/live_tick.dart`, `mobile/lib/services/
> notify_throttle.dart`, `mobile/lib/services/tag_historian.dart`, `mobile/lib/services/
> app_logger.dart`, `mobile/lib/screens/scan_tick.dart`, `mobile/lib/screens/workspace_shell.dart`
> (`_executeScan`, `_resyncHistorian`), `mobile/lib/widgets/trend_chart.dart`,
> `docs/ui-performance.md`, and `docs/trends.md`.
> **Read this before:** adding a widget that displays a live tag value, changing the UI refresh
> rate, or touching trend/historian rendering.

---

## 1. The headline rule

**The scan loop never triggers a whole-widget-tree rebuild; it writes the model directly and
schedules a throttled `LiveTick` pulse that only the leaf widgets actually displaying live
values subscribe to.**

`runScanTick` (`mobile/lib/screens/scan_tick.dart`, see [scan-engine.md](./scan-engine.md) §1)
is pure engine logic - it contains no `setState`/`notifyListeners` call anywhere. Its caller,
`WorkspaceShellState._executeScan` (`workspace_shell.dart:833-926`), writes scan
counters/timings as **plain model mutations**, explicitly *not* wrapped in `setState` (comment
at lines 850-856: *"NOT wrapped in setState... `_repaintThrottle.request()` below is what
actually schedules the next repaint"*). `setState` on the shell is called only on rare,
structural transitions: a **new** watchdog fault (`result.faulted && !_faulted`) and a fault
clear driven by `System.AlarmReset`. Everything else - the values an HMI screen or Tag
Inspector is currently showing - repaints through the `LiveTick` pulse (§2), not a shell
rebuild.

## 2. `LiveTick` and the leaf-only listener pattern

`LiveTick` (`mobile/lib/widgets/live_tick.dart:8-12`) is a dataless
`ChangeNotifier` - `pulse()` just calls `notifyListeners()`. `LiveTickScope`
(`live_tick.dart:17-35`) exposes one shared `LiveTick` instance to the widget subtree via
`InheritedNotifier`, but its `of(context)` deliberately uses `getInheritedWidgetOfExactType`
- a **non-dependency** lookup - rather than `dependOnInheritedWidgetOfExactType`:

> "If `of` instead registered an InheritedWidget dependency, the calling widget (wherever
> `of(context)` is textually evaluated, which is often an ancestor of the actual value leaf)
> would also rebuild on every pulse - defeating the whole point of routing repaints through a
> leaf-only listener instead of the shell's per-scan setState."

The caller passes the returned `LiveTick` straight to a `ListenableBuilder`/`AnimatedBuilder`
at the exact widget that needs to re-read a value - that widget subscribes directly via
`Listenable.addListener`, and nothing above it in the tree rebuilds. **A new live-value widget
must use this pattern (or freeze)** - reading a tag value once at build time, with no
`LiveTick`-driven rebuild, will render a value that never updates after first paint.

## 3. `NotifyThrottle`: coalescing the pulse rate

`NotifyThrottle` (`mobile/lib/services/notify_throttle.dart`, pure `dart:async`, no Flutter
dependency) coalesces high-frequency notifications to at most one trailing call per window:

```dart
class NotifyThrottle {
  void request() { _timer ??= Timer(_window, () { _timer = null; _onFire(); }); }
  void immediate() { _timer?.cancel(); _timer = null; _onFire(); }
  void dispose() { _timer?.cancel(); _timer = null; }
}
```

`request()` is the per-tick caller: if no timer is already pending, it arms one for `_window`;
repeated calls within that window are absorbed as a no-op until it fires once. `immediate()`
cancels any pending timer and fires synchronously - for state-change callers needing instant
feedback rather than per-tick callers. The shell constructs its scan-repaint throttle with an
explicit `window: refreshWindow(_refreshHz)` (`workspace_shell.dart:274`) - a user-configurable
UI refresh rate (typically 1-30 Hz, default 10 Hz) - rather than the class's own 250 ms
default, so the effective on-screen refresh rate is a product setting, not a hardcoded constant.
`NotifyThrottle` itself is generic and reused elsewhere in the app (e.g. MQTT publish pacing),
not scan-specific.

## 4. `AppLogger` follows the same discipline, deliberately not the historian's

`AppLogger` does **not** extend `ChangeNotifier` and does not notify per log entry - the Logs
screen repaints on the same throttled `LiveTick` pulse as everything else, "not on a
per-log-call listener - a per-entry notify would thrash the widget tree exactly the way
`LiveTick` was introduced to avoid for the per-scan `setState`." Separately, `AppLogger`'s
buffer is **deliberately not cleared on project switch** (unlike `TagHistorian`, §5) - log
entries are app-level, recording what the app and its hosts did across the moment of a switch,
which is exactly the "before" side needed to diagnose "it broke when I switched projects."

## 5. `TagHistorian`: a memory-only, tick-driven ring buffer

`TagHistorian` (`mobile/lib/services/tag_historian.dart`) holds one buffer per trend pen,
keyed by `tagPath`, in a plain `Map<String, List<TrendSample>>` - "Never persisted" (line 23).
It has **no internal timer**; `sample()` is called once per scan tick from
`workspace_shell.dart:907`, which is what keeps it fully deterministic under test. Retention is
per-pen configurable, not a single global cap: `retentionMode == 'points'` floors `maxPoints`
at 2 and trims with a single `removeRange(0, drop)` call rather than repeated
`removeAt(0)` (an O(n) single shift instead of an O(n) shift *per* removed element);
`'time'` mode floors `windowMs` at 1000 ms and drops every leading sample older than
`nowMs - windowMs`.

**Cleared and resynced on every project switch** - `_resyncHistorian()`
(`workspace_shell.dart:754-768`) calls `_historian.clear()` then
`_historian.syncPens(_activeProject.trends)`, because trend buffers "must never straddle two
different projects" (comment, lines 159-161). This is the opposite policy from `AppLogger`
(§4) - tag samples belong to a specific project's tags and are meaningless once that project is
gone, while log entries are app-level and span switches on purpose.

## 6. `TrendChartDisplay`: analog auto-scale, BOOL step lanes

The shared trend-chart widget (`TrendChartPainter`/`TrendChartView`,
`mobile/lib/widgets/trend_chart.dart`) renders a multi-pen chart with two distinct pen
treatments in the same view: analog pens share one auto-scaled left value axis and draw as
connected polylines, while BOOL pens draw as stacked 0/1 step (square-wave) lanes along the
bottom rather than sharing the analog axis. It repaints on the same shared `LiveTick` pulse as
every other live-value surface - "the scan loop never triggers a whole-widget rebuild for a
chart tick."

## 7. On "continuous repaint" (a caveat for CL-9/CL-16)

The practices domain's CL-9 and CL-16 describe headless-Playwright verification against this
app's canvas rendering as working "despite the continuous repaint loop," and note an in-app
screenshot pane can time out on that same repaint (see
[practices/index.md](../practices/index.md)). Within this app's own Dart code, there is no
free-running `AnimationController`/`Ticker` driving continuous whole-app repaints - a grep
across `mobile/lib` for animation-ticker APIs finds exactly one use, a `TabController`'s
`vsync` ticker for a settings screen's tab bar, unrelated to live tag data. Repaint here is
purely **event/throttle-driven**: a scan tick calls `NotifyThrottle.request()`, which fires
`LiveTick.pulse()` after coalescing, which wakes only the leaf `ListenableBuilder`s currently
mounted (§2-§3), bounded at the configured 1-30 Hz. If "continuous repaint" is observed in
practice, it is Flutter web CanvasKit's own internal engine-level frame scheduling - outside
this app's Dart code - rather than an app-architecture free-running loop.

---

## What this means practically

### "I added a widget that shows a live tag value and it never updates after first paint - why?"
It's almost certainly reading the value once at build time with no `LiveTick` subscription
(§2). Wrap the value-reading leaf in a `ListenableBuilder(listenable: LiveTickScope.of(context),
...)` so it re-reads on every pulse.

### "Why does the whole screen not visibly flicker on every single scan tick even at a fast scan speed?"
Because the shell never calls `setState` per scan (§1), and the repaint pulse itself is
throttled to the configured UI refresh rate via `NotifyThrottle` (§3) - the scan loop can run
far faster than the screen repaints.

### "My trend chart is empty after switching projects even though the new project has trend pens configured - why?"
Check that `_resyncHistorian()` actually ran for the switch path in question (§5) -
`TagHistorian.clear()` empties every buffer, and `syncPens` only creates fresh empty buffers
for the new project's pens; a pen only starts accumulating samples from the next `sample()`
call onward, not retroactively.

---

## Related

- [scan-engine.md](./scan-engine.md) - what runs before the repaint pulse is requested each tick.
- [../practices/index.md](../practices/index.md) - CL-9/CL-16, and how this canvas app is
  verified with headless Playwright despite having no DOM.
- [index.md](./index.md) - domain hub.
