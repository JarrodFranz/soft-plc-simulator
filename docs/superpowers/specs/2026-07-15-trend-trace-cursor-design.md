# Trend Chart Trace Cursor — Design

**Date:** 2026-07-15
**Status:** Approved by user (chat, 2026-07-15).
**Builds on:** the trend chart (`mobile/lib/widgets/trend_chart.dart` — `TrendChartPainter`, `TrendChartView`, `TrendPenView`), the `TagHistorian`/`TrendSample` buffers (`mobile/lib/services/tag_historian.dart`), and the `LiveTick` repaint architecture. Shared by the Trends preview (Memory → Trends) and the HMI `TrendChartDisplay` component.

## Problem

The trend charts plot pens over time but there is no way to read the exact value of a pen at a specific moment — you can see the shape of a trace but not "what was Speed at that dip." Users want a SCADA-style **trace cursor** (scrubber): a draggable vertical line that reports each pen's value at the cursor time. It must work with **touch on mobile**, not only mouse.

## Goal

Add a draggable vertical **trace cursor** to `TrendChartView` (inherited by both surfaces): tap to place, drag to move (touch + mouse), a readout showing the cursor's timestamp (relative **and** wall-clock) plus each pen's nearest-sample value, and a clear (✕) affordance. The cursor anchors to a **timestamp** (sticks to the data as the strip chart scrolls) and **auto-hides** when that timestamp scrolls off the left edge. No persistence — the cursor is transient UI state. The live chart keeps scrolling; there is no freeze/pause (out of scope).

## Decisions (locked with the user)

- **Draggable value cursor**, usable on **mobile (touch)** and desktop (mouse), same gestures.
- Timestamp readout shows **both** a relative offset (e.g. `-1m 12s`) **and** the wall-clock time (e.g. `14:32:05`).
- When the anchored cursor time scrolls past the left edge, the trace **auto-hides** (user re-taps to inspect again).
- **Nearest-sample** lookup per pen (no interpolation) — honest for a strip chart.
- Anchored to a **timestamp**, not a screen x — the line moves left with the data as the chart scrolls.
- Transient UI state only; nothing serialized; the chart keeps scrolling live (no freeze).

## Architecture

### Pure helpers (`trend_chart.dart`)

- **`TrendChartGeometry`** — a small value object capturing the plot's horizontal mapping so the painter and the gesture/hit-test math share ONE source of truth (today the padding constants live only inside `paint`). Fields: `leftPad`, `rightPad`, `width`, `windowMs`, `nowMs`. Methods:
  - `double xOfTime(int tMs)` → pixel x for a timestamp (newest at the right edge): `plotLeft + plotW * (1 - (nowMs - tMs)/windowMs)`.
  - `int timeAtX(double x)` → timestamp for a pixel x (inverse), clamped to `[nowMs - windowMs, nowMs]`.
  - `plotLeft`/`plotRight`/`plotW` getters (reuse the painter's existing `_leftPad`/`_rightPad`).
  The painter is refactored to build a `TrendChartGeometry` and use `xOfTime` where it currently inlines the `xOf` closure (no behavior change), so line drawing and cursor hit-testing cannot drift.
- **`TrendSample? nearestSample(List<TrendSample> buf, int tMs)`** — the sample in `buf` whose `t` is closest to `tMs` (linear scan; `null` if empty). Used to read each pen's value at the cursor.
- **`String formatCursorTime(int cursorMs, int nowMs)`** — returns the relative part (`-1m 12s`, `-45s`, `now`) for the readout; the wall-clock part is `DateTime.fromMillisecondsSinceEpoch(cursorMs)` formatted `HH:mm:ss`. (Two small helpers: `relativeAgo(cursorMs, nowMs)` and `clockHms(cursorMs)`, so each is unit-testable.)
- **`String formatPenValue(TrendPenView pen, TrendSample? s)`** — `'—'` if `s == null`; `'ON'`/`'OFF'` if `pen.isDigital` (`s.v >= 0.5`); else `s.v.toStringAsFixed(2)`.

These are pure and independently tested. `relativeAgo`, `clockHms` must not call the wall clock themselves (timestamps are passed in) so they're deterministic under test.

### Painter — draw the cursor line (`TrendChartPainter`)

- The painter gains two optional fields: `int? cursorTimeMs` and a `Color cursorColor`. When `cursorTimeMs != null` and it is within `[nowMs - windowMs, nowMs]`, draw a vertical line at `geometry.xOfTime(cursorTimeMs)` from `plotTop` to the bottom of the digital lanes (full chart height), in `cursorColor` (a bright, theme-aware line, distinct from pen colors), plus a small filled dot at each analog pen's nearest-sample y (so the crossing point is obvious). Digital pens don't need a dot (the lane already shows state).
- `shouldRepaint` already returns `true` (live chart) — unchanged.
- If `cursorTimeMs` is null or out of window, the painter draws exactly as today (fully backward compatible; existing painter tests keep passing).

### `TrendChartView` — becomes stateful (gesture + readout overlay)

- Convert `TrendChartView` from `StatelessWidget` to `StatefulWidget`. State: `int? _cursorTimeMs` (null = no cursor).
- The build wraps the existing `ListenableBuilder(listenable: LiveTickScope.of(context))` content in a `LayoutBuilder` (to get the box width/height) and a `Stack`:
  1. A `GestureDetector` over the `CustomPaint`:
     - `onTapDown`: set `_cursorTimeMs = geometry.timeAtX(localDx)` (place/re-place the cursor). Uses the current `nowMs`/`windowMs`/width.
     - `onHorizontalDragStart` / `onHorizontalDragUpdate`: set `_cursorTimeMs = geometry.timeAtX(localDx)` (drag to move). Horizontal-only drag so a vertical page scroll (the Memory tab and HMI cards scroll vertically) is unaffected.
     - The painter is passed `cursorTimeMs: _cursorTimeMs`.
  2. A `Positioned` **readout** widget, shown only when `_cursorTimeMs != null` AND it is within the window (`_cursorTimeMs >= nowMs - windowMs`) AND there is at least one pen. It is pinned to the **top corner opposite the cursor** (cursor on the right half → readout top-left, else top-right) so a finger never covers it. Contents: a header line with the relative + wall-clock time, then one compact row per pen (color swatch • label • `formatPenValue`), and a small **✕ IconButton** that clears the cursor (`setState(() => _cursorTimeMs = null)`). The readout uses a semi-opaque dark background (`withValues(alpha:)`), constrained width, `TextOverflow.ellipsis`.
- **Auto-hide:** the readout + line are gated on the in-window check computed each build from the live `nowMs`. When the anchored time scrolls out of the window the readout/line simply stop rendering. Additionally, when it renders out-of-window, schedule a post-frame `setState(() => _cursorTimeMs = null)` to reset the state cleanly (guarded by `mounted`), so re-tapping starts fresh. (Gate-on-render is what the user sees; the post-frame reset just tidies state — never mutate state during build directly.)
- **Empty-pens placeholder** path (no pens) is unchanged — no gesture layer needed there.

Because both the Trends preview and the HMI `TrendChartDisplay` render through `TrendChartView`, both gain the cursor with no call-site changes.

## Testing

**Pure helpers (`trend_chart_test.dart` additions):**
- `TrendChartGeometry`: `xOfTime(nowMs)` is at the right edge; `xOfTime(nowMs - windowMs)` at the left; `timeAtX` inverts `xOfTime` (round-trip within rounding) and clamps x beyond the plot to the window bounds.
- `nearestSample`: picks the closest by |Δt|; returns null on empty; ties resolve deterministically (first/nearest).
- `relativeAgo`: `now` at Δ0, `-45s`, `-1m 12s` formatting; `clockHms` formats a known epoch ms to `HH:mm:ss` (pass a fixed timestamp — no wall-clock call inside).
- `formatPenValue`: null → `—`; digital 0.6 → `ON`, 0.2 → `OFF`; analog → 2-dp string.

**Painter (`trend_chart_test.dart`):** with `cursorTimeMs` in-window, the painter draws without throwing (analog + digital + a cursor); with `cursorTimeMs` out-of-window or null, output matches the no-cursor path (no throw). Flat-series / empty-buffer still safe.

**Widget (`trend_chart_test.dart` / a cursor widget test):** pump a `TrendChartView` (under a `LiveTickScope`) with a historian holding known samples; `tester.tapAt` inside the plot shows the readout (finds the timestamp text + a pen value + the ✕); a horizontal drag moves the cursor (readout value changes / cursor time updates); tapping the ✕ clears it (readout gone); no RenderFlex overflow at 320/360/1400.

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release`; existing trend/painter/Trends/HMI tests still pass (the stateless→stateful change and the optional painter fields are additive).

## Global constraints

- No vendor branding; dark theme; zero `flutter analyze` warnings; `withValues(alpha:)` never `withOpacity`; braces on all control flow; no RenderFlex overflow at 320/360/1400.
- `mobile/lib/widgets/trend_chart.dart` stays UI-layer Dart (Flutter widgets/painting), pure helpers have no `dart:io`. The relative/clock formatters take timestamps as args (no internal `DateTime.now()`), for deterministic tests.
- Transient only: no new model fields, no persistence, WS6 round-trip unaffected.
- Repaint via `LiveTick` unchanged; never mutate cursor state during `build` (use a `mounted`-guarded post-frame callback for the auto-hide reset).
- Touch-first: horizontal-drag gesture must not block the enclosing vertical scroll; the cursor must be placeable and movable by finger.

## Phasing (one spec → phased plan)

- **Phase A — Pure helpers.** `TrendChartGeometry` (+ refactor the painter to use it, no behavior change), `nearestSample`, `relativeAgo`/`clockHms`, `formatPenValue`, with unit tests.
- **Phase B — Cursor line + interactive view.** Painter `cursorTimeMs`/`cursorColor` + dots; `TrendChartView` → stateful with tap/drag gesture, readout overlay widget (both time formats + per-pen values + ✕), auto-hide gating. Widget tests. Both surfaces inherit.
- **Phase C — Validation, docs, final review.** Full gates; overflow at 320/360/1400; manual smoke (place/drag/clear on Trends preview + an HMI trend, confirm auto-hide as it scrolls off); update `docs/trends.md`; whole-branch review; merge.
