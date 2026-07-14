# Live Tag Historian & Trend Charts

This document covers the in-app tag historian — a memory-only, tick-driven
strip-chart recorder — the pens that configure what it records, the Trends
section's live preview, and the HMI `TrendChartDisplay` component that plots
one or more pens on a dashboard.

Implementation: `mobile/lib/services/tag_historian.dart` (the `TagHistorian`
engine + `TrendSample`/`TrendPenLike`), `mobile/lib/models/project_model.dart`
(the persisted `TrendPen` / `TrendPenRef` model, `PlcProject.trends`,
`HmiComponent.trendPens`/`windowMs`), `mobile/lib/widgets/trend_chart.dart`
(the shared `TrendChartPainter`/`TrendChartView`), `mobile/lib/screens/
memory_manager_screen.dart` (the Trends tab: pen CRUD + live preview), and
`mobile/lib/screens/hmi_dashboard_builder_screen.dart` (the
`TrendChartDisplay` HMI component: multi-pen selection + render).

## What the historian is

`TagHistorian` is a memory-only strip-chart recorder: it owns one ring buffer
of `TrendSample(t, v)` points per pen, keyed by the pen's tag path. It is
**tick-driven, not self-timed** — it holds no timer of its own. `sample()` is
called once per live scan tick (from the same scan loop that drives every
other engine), so recording is fully deterministic and testable: given the
same sequence of tick calls and tag values, the buffers end up byte-identical
every run.

A few consequences follow directly from that design:

- **Sampling only advances while the PLC is running.** Because `sample()` is
  only invoked from the live scan tick, a paused or stopped controller simply
  stops accumulating points — the existing trace stays visible, frozen, until
  Run is pressed again.
- **Captured samples are never persisted.** Only pen *configuration* is part
  of the project (see below); the actual recorded data points live only in
  the in-memory `TagHistorian` for the current app session.
- **Buffers reset to empty on project switch.** The historian's `clear()` is
  called whenever the active project changes, and `syncPens()` reconciles the
  buffer set to the new project's pens — so switching projects and switching
  back always starts every chart blank and lets it refill from scratch, it
  never resurrects stale data from the previous project or the previous time
  the same project was open.

Each pen also gates its own sample rate independently: `sample()` skips a pen
until at least its `sampleIntervalMs` has elapsed since its last recorded
point (a pen with an empty buffer always captures immediately), then trims
the buffer according to the pen's retention rule — either dropping the oldest
point past a max point count, or dropping every point older than a rolling
time window. A tag read that comes back `null` (e.g. an unresolved path) is
skipped for that tick rather than recording a gap value.

## Pens (Memory → Trends)

A **pen** is what you configure to record one tag. Pens live in the Memory
Manager's **Trends** tab (**Add Pen** button) and are persisted with the
project (see JSON keys below) — but, per the above, only the configuration
persists, not the recorded trace.

Each pen has:

- **Tag** — the tag path to record (picked from the project's tags).
- **Color** — one of the app's standard accent-color names (cyan, green, red,
  amber, teal, blue), used to draw the pen's line/lane.
- **Sample interval** — how often (in milliseconds) the historian captures a
  new point for this pen. Minimum **50 ms**; values below that are clamped up
  to 50 on save.
- **Retention** — either:
  - a **max point count** (at least **2**), keeping only the most recent N
    samples, or
  - a **time window** (at least **1 second**), keeping only samples newer
    than `now - window`.

The Trends tab shows every configured pen in a list (tag, color, interval,
and retention summarized, e.g. `250 ms • 300s` or `250 ms • 1200 pts`) plus a
**live preview chart** below the list, rendering every configured pen at once
so you can confirm a pen looks right without leaving the Trends tab or
building an HMI screen first.

## The chart itself

Both the Trends preview and the HMI component share one painter
(`TrendChartPainter`/`TrendChartView`) so they render identically:

- **Analog pens** (any non-`BOOL` tag) share one auto-scaled value axis on the
  left, drawn as connected polylines; the axis rescales continuously to the
  min/max of every visible analog pen's samples inside the current time
  window, with a small padding margin so a flat-line signal doesn't collapse
  onto a zero-height axis.
- **BOOL pens** are drawn as stacked digital step lanes along the bottom
  (one lane per BOOL pen, labeled), showing a 0/1 square-wave trace instead of
  sharing the analog axis — a boolean's "high"/"low" states don't belong on
  the same scale as an analog reading.
- The chart is a hand-painted `CustomPainter` (no charting package
  dependency, matching the existing `TankGraphicDisplay` style), and it
  repaints on the shared `LiveTick` pulse like every other live-value surface
  in the app — the scan loop never triggers a whole-widget rebuild for a
  chart tick.

## The HMI `TrendChartDisplay` component

Pens are defined **once**, in Trends; an HMI screen doesn't redefine a pen —
it *references* one or more existing pens. Adding a **Trend Chart** component
to an HMI screen (via the HMI Dashboard Builder) lets you:

- **Select multiple pens** to plot together on the same chart (multi-pen).
- **Override a pen's color** per component, without changing the pen's own
  configured color (so the same pen can appear in green on one screen and red
  on another).
- **Optionally set a component-local time window** (in seconds). If left
  unset, the component falls back to the widest retention window implied by
  its selected pens (the largest of each pen's `windowMs`, or
  `maxPoints * sampleIntervalMs` for a point-retained pen).

At render time the component resolves each selected `TrendPenRef` back to its
project `TrendPen` (for color/tag-type) and hands the result to the same
`TrendChartView` the Trends preview uses — analog pens auto-scale together,
BOOL pens still get their own digital lanes, exactly as in the preview.

## Persistence: config only, never data

Pen **configuration** is persisted as part of the project, additively:

- `PlcProject.trends` — the project's list of `TrendPen`s, serialized under
  the top-level `"trends"` JSON key. Each pen serializes as `tag_path`,
  `color`, `sample_interval_ms`, `retention_mode` (`"points"` or `"time"`),
  `max_points`, and `window_ms`.
- `HmiComponent.trendPens` — a `TrendChartDisplay` component's selected pen
  references, serialized under `"trend_pens"` (each entry: `pen_tag_path` +
  an optional `color_override`), plus an optional component-local
  `"window_ms"`.

Both are additive keys on their respective existing JSON objects — an older
project file with neither key simply loads with no pens / no trend
components, same as any other additive field in this codebase.

**Recorded sample data is never part of this — or any — persisted JSON.** It
exists only inside the running app's `TagHistorian` and is intentionally
dropped on project switch (see "What the historian is" above). This mirrors
standard SCADA/HMI trend conventions, where a live trend is a runtime view
over recent history rather than a stored dataset — this app makes no attempt
to save historical trend data across sessions.

## Trace cursor

Both the Trends preview and the HMI `TrendChartDisplay` support a **trace
cursor** for reading exact values off the chart:

- **Tap** anywhere on the chart to drop a vertical trace line at that point
  in time. **Drag** left/right (touch or mouse) to move it. Because the drag
  gesture is horizontal-only, it never fights with the page's vertical
  scrolling — you can drag the cursor and scroll the screen without either
  one stealing the other's gesture.
- A readout above the chart shows the cursor's time two ways — a relative
  offset from now (e.g. `-1m 12s`, or `now` if it's within the current
  second) and the wall-clock time (`HH:mm:ss`) — plus every visible pen's
  value at that instant: a number for analog pens, `ON`/`OFF` for BOOL pens,
  or `—` if that pen has no sample near the cursor.
- The cursor anchors to a **moment in time**, not a pixel position, so it
  stays put on the same data as the chart keeps scrolling with new samples.
  Once that moment scrolls off the left edge of the visible window, the
  trace **auto-hides** on its own. Tap the **✕** on the readout to clear it
  sooner.
- The trace is purely a viewing aid — it's never saved with the project or
  the pen configuration, and it resets whenever the chart's own state does
  (e.g. switching projects).

## Manual smoke checklist

For a quick end-to-end sanity check after touching any part of this feature:

1. Memory → Trends → Add Pen for an analog (e.g. ramp) tag, and Add Pen for a
   BOOL tag. Start the PLC. The preview chart should draw the analog line and
   the BOOL step lane, auto-scrolling as new samples arrive.
2. Build an HMI screen, add a Trend Chart component, select both pens, and
   override one pen's color. It should plot both, respecting the override.
3. Switch to a different project and back. The charts should start blank on
   return and refill while the PLC runs — proving buffers reset on project
   switch rather than carrying over stale data.
4. Pause the PLC. No new points should accrue and the existing trace should
   stay visible, unchanged, until Run is pressed again.
