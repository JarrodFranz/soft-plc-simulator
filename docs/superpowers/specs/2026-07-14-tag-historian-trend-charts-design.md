# Live Tag Historian + Trend Charts — Design

**Date:** 2026-07-14
**Status:** Approved by user (chat, 2026-07-14).
**Builds on:** the tag/value model (`mobile/lib/models/project_model.dart` `PlcTag`, `HmiComponent`), the tag resolver (`readPath`), the scan loop (`workspace_shell.dart` `_executeScan`), the decoupled-repaint architecture (`widgets/live_tick.dart` `LiveTick`/`LiveTickScope`), the Memory Manager screen (`screens/memory_manager_screen.dart`), the HMI dashboard builder (`screens/hmi_dashboard_builder_screen.dart`), and the lossless project serialization (WS6).

## Problem

The app can drive ~100+ continuously-changing tags across four protocols, but there is no way to **historize** a tag's value over time or to **plot a trend**. Users want to (1) pick a set of tags to record into a rolling buffer, (2) watch them move on a live chart while tuning, and (3) drop a trend chart onto an HMI screen. No time-series capture or charting exists today: every `HmiComponent` binds exactly one tag and shows an instantaneous value; there is no chart library in `pubspec.yaml`.

## Goal

- A **live strip-chart historian**: memory-only rolling buffers, one per configured pen, sampled off the scan tick at a per-pen interval, trimmed by a per-pen retention rule.
- A new **Trends section** under Memory where the user manages the pen list and watches a **live preview chart**.
- A new **HMI trend component** (`TrendChartDisplay`) that plots a chosen subset of the pens on an HMI screen, **multi-pen**, with analog lines auto-scaled and BOOL pens drawn as digital step traces.

## Decisions (locked with the user)

- **Memory-only, live strip-chart.** Buffers live in RAM only; they are **not** persisted and they **reset to empty on project switch**. (Pen *configuration* is persisted; the captured *samples* are not.)
- **Pens are a dedicated list in the Trends section** (not a per-tag flag on `PlcTag`).
- **Per-pen retention:** each pen chooses **either** a max **point count** **or** a max **time window**.
- **Per-pen sample interval** (decoupled from the scan rate), default 250 ms.
- **A pen is defined once** in Trends — `tagPath` + `color` + `sampleIntervalMs` + retention — and is the single source of truth. An HMI trend component **references pens** and may **override the color** per pen.
- **Multi-pen** trend component; **BOOL pens render as digital step traces** (stacked 0/1 square-wave lanes at the bottom); analog pens share an auto-scaled left value axis.
- **Live preview chart inside the Trends section** (reuses the same painter as the HMI component).
- **Sampling advances only while the PLC is running.** When paused/stopped, no new points are captured; the existing buffer stays visible.

## Architecture

### Part 1 — Historian engine (`mobile/lib/services/tag_historian.dart`, pure Dart)

- **`TrendSample`** — an immutable `(int timestampMs, double value)` pair.
- **`TagHistorian`** — owns a `Map<String, List<TrendSample>>` keyed by pen `tagPath` (one ring buffer per pen). API:
  - `syncPens(List<TrendPen> pens)` — reconcile the buffer map to the current pen set: create a buffer for a new pen, drop the buffer for a removed pen. Preserves existing buffers for unchanged pens (so editing a *different* pen doesn't wipe this one's history). Called whenever the pen list changes.
  - `sample(List<TrendPen> pens, double? Function(String tagPath) readValue, int nowMs)` — for each pen, if `nowMs - lastSampleMs(pen) >= pen.sampleIntervalMs` (a pen with no samples yet always captures), read the value via `readValue`, append a `TrendSample`, then **trim**: in `time` mode drop leading samples with `timestampMs < nowMs - pen.windowMs`; in `points` mode drop leading samples while `length > pen.maxPoints`. A `null` read (unresolvable tag) is skipped (no sample appended) — never throws.
  - `buffer(String tagPath) -> List<TrendSample>` — read-only view for painters (returns an empty list for an unknown pen).
  - `clear()` — empty all buffers (called on project switch).
- **BOOL handling:** the caller converts a bool value to `1.0`/`0.0` before it reaches the historian; the historian stores only doubles. (The pen knows its tag's data type via the project for render-time digital-vs-analog classification; the engine itself is type-agnostic.)
- **Purity:** no `dart:io`, no `Timer` — sampling is *driven* by the scan tick, not self-timed, so it is deterministic and unit-testable with an injected `nowMs`.

### Part 2 — Data model (additive, `project_model.dart`)

- **`TrendPen`** (new class, persisted): fields `tagPath` (String), `color` (String — reuse the existing accent-color name vocabulary: `green`/`red`/`amber`/`teal`/`blue`/`cyan`, plus we extend the resolver as needed), `sampleIntervalMs` (int, default 250, clamp ≥ 50), `retentionMode` (String `points` | `time`, default `time`), `maxPoints` (int, default 1200, clamp ≥ 2), `windowMs` (int, default 300000, clamp ≥ 1000). `fromJson`/`toJson` with defaulted reads (lossless, forward-compatible).
- **`PlcProject`** gains `List<TrendPen> trends` (default `[]`), serialized under key `trends`. Absent key → empty list (older projects load clean).
- **`HmiComponent`** gains **one** optional field: `List<TrendPenRef> trendPens` (default `[]`), where **`TrendPenRef`** = `{ penTagPath: String, colorOverride: String? }`. Serialized under `trend_pens`; absent → empty. Plus an optional component-level `windowMs` (int?, key `window_ms`) — how much of the buffer this component shows (null = show the whole buffer / each pen's own retention window). The existing `tagBinding` and all current components are untouched (the new field is ignored by non-trend components).
- New component **`type` value: `'TrendChartDisplay'`**.

### Part 3 — Trends section (under Memory)

- A new **"Trends"** surface reachable from the Memory area (a tab/section alongside Tags/Structs, matching the existing Memory Manager navigation pattern). It reads/writes `project.trends`.
- **Pen list:** each row shows a color swatch, the tag path, sample interval, and retention (`points: N` or `time: Ns`). Controls: **+ Add pen** (opens a config dialog with a **type-ahead tag picker** — reuse the existing WS7 type-ahead tag field — plus color, interval, retention-mode toggle, and the mode's value), **edit**, **remove**. On any change, call `historian.syncPens(project.trends)` and mark the project dirty (autosave).
- **Live preview chart:** a `TrendChartView` (see Part 4) below the list, bound to **all** current pens, repainting via `LiveTick` so the user can watch and tune. Empty state (no pens / no samples yet) shows a friendly placeholder.

### Part 4 — Chart painter + view (`mobile/lib/widgets/trend_chart.dart`)

- **`TrendChartPainter extends CustomPainter`** — hand-painted, no chart package (consistent with the existing TankGraphic painter). Inputs: the list of pens to draw (with resolved color + is-digital flag), each pen's buffer (`List<TrendSample>`), and the visible `windowMs`. Rendering:
  - **Time axis:** newest sample pinned to the right edge; the x-window is `[nowMs - windowMs, nowMs]` (auto-scrolling). A few gridlines + relative time labels (e.g. `-5m`, `-2.5m`, `now`).
  - **Analog pens:** collected onto a **shared left value axis** auto-scaled to the min/max across all visible analog samples (with a small margin; degenerate flat series get a ±1 pad). Each drawn as a connected polyline in its color. A left axis with 2–3 value labels.
  - **Digital (BOOL) pens:** drawn as **stacked thin lanes along the bottom** (each pen its own lane), a 0/1 square-wave (step interpolation) in the pen's color, with the pen name labelled on its lane. Digital lanes do not participate in the analog value axis.
  - **Legend:** pen name + color swatch (analog pens); digital pens are labelled on their lanes.
  - Everything uses theme colors and `withValues(alpha:)`; no `withOpacity`.
- **`TrendChartView`** — a `StatelessWidget` that wraps the painter in a `ListenableBuilder(listenable: LiveTickScope.of(context), …)` so it repaints on the tick (respecting the decoupled-repaint rule — it must NOT rely on a whole-shell `setState`). It reads each pen's buffer from the shared `TagHistorian` and each pen's data type from the project (to set the is-digital flag) at paint time. Reused by both the Trends preview and the HMI component.

### Part 5 — HMI trend component

- **`TrendChartDisplay`** in the HMI builder's `_renderComponentWidget` switch: renders a `TrendChartView` for the component's `trendPens` (resolving each ref to a project pen, applying `colorOverride` when present) using the component's `windowMs` (falling back to each pen's retention window when null).
- **Config dialog** (in the HMI builder): a **multi-select** of the project's existing pens (checkbox list by tag path), an optional per-pen **color override**, and an optional component **window** field. If the project has no pens, the dialog explains that pens are created in Memory → Trends.
- **Palette:** add `TrendChartDisplay` to the component palette with an icon (`Icons.show_chart`) and support multi-column `gridSpanWidth` (like the gauge). Icon + accent handled in the existing `_iconForType`/color helpers.
- **Run-mode gate:** the trend component is display-only (no user input), consistent with gauges/LEDs; it renders in both edit and run modes but only *advances* when the scan is running (because the historian only samples then).

### Part 6 — Scan integration (`workspace_shell.dart`)

- The shell **owns the `TagHistorian`** instance (alongside `_liveTick`).
- In `_executeScan`, **after** `runScanTick` + `updateSystemStatus` (values are current) and **before/at** the `LiveTick` pulse, call `historian.sample(project.trends, readValue, wallNowMs)` where `readValue(tagPath)` resolves via the existing `readPath` and coerces BOOL→1/0, numeric→double, non-numeric→`null` (skipped). This runs **only on a live scan tick** (paused/stopped scans don't call `_executeScan`'s sampling path), satisfying the "advance only while running" decision.
- On **project switch/load**, call `historian.clear()` then `historian.syncPens(newProject.trends)` (buffers start empty).
- On **pen list edits** (Trends section), call `historian.syncPens(project.trends)`.
- The historian is exposed to `TrendChartView` (Trends preview + HMI) via the widget tree (constructor/inherited access, matching how the shell already threads shared services).

## Testing

**Historian unit (`test/tag_historian_test.dart`, pure):**
- Interval gating: with `sampleIntervalMs: 250`, calling `sample(..., nowMs)` at 0, 100, 200 captures once (t=0), and at 250 captures again — a fast scan does not over-sample.
- Retention `time`: with `windowMs: 1000`, samples older than `nowMs - 1000` are dropped; buffer never spans more than the window.
- Retention `points`: with `maxPoints: 3`, the buffer holds at most 3, oldest dropped first.
- BOOL: caller-coerced 1.0/0.0 store and read back as doubles.
- `null` read (unresolvable tag) appends nothing and does not throw.
- `syncPens`: adding a pen creates an empty buffer; removing a pen drops its buffer; an unchanged pen keeps its samples across a `syncPens` call.
- `clear()` empties all buffers.

**Model round-trip (`test/*_test.dart`, WS6 lossless):**
- `TrendPen` and `PlcProject.trends` JSON round-trip (all fields, defaults when keys absent).
- `HmiComponent.trendPens` + `windowMs` round-trip; a legacy component JSON with no `trend_pens`/`window_ms` loads with empty pens / null window; existing non-trend components serialize unchanged.

**Painter / widget smoke (`test/trend_chart_test.dart`):**
- Analog auto-scale: two analog pens with differing ranges paint without exception; a flat series doesn't divide-by-zero.
- Digital lane: a BOOL pen renders as a stacked lane (does not affect the analog axis).
- `TrendChartView` repaints on a `LiveTick` pulse (rebuild counter advances) without a shell rebuild.
- No RenderFlex overflow at 320 / 360 / 1400 for the Trends section and an HMI screen containing a `TrendChartDisplay`.

**Integration:**
- A scan tick appends to the historian and the Trends preview reflects the new point via the tick (value advances while running; no new points while paused).
- Project switch clears buffers (new project's preview starts empty).

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release` compiles; existing Memory Manager / HMI builder / serialization tests pass.

## Global constraints

- No vendor branding (no "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); PLC/HMI/trend terminology is fine.
- Dark theme; zero `flutter analyze` warnings; `withValues(alpha:)` not `withOpacity`; braces on all control flow; no RenderFlex overflow at 320/360/1400.
- `mobile/lib/models/**` and `mobile/lib/services/tag_historian.dart` stay **pure Dart** (no `dart:io`); the historian is tick-driven, not self-timed (no `Timer`), for deterministic tests.
- **Additive persistence:** `trends` on the project and `trend_pens`/`window_ms` on the component are new optional keys; older projects load clean and the WS6 round-trip stays green. Captured samples are **never** serialized (memory-only).
- **Repaint via `LiveTick` only:** the trend view is a live-value surface — it MUST repaint through `LiveTickScope`, never a per-scan whole-shell `setState` (per the UI-repaint-decoupling architecture).
- Reuse existing patterns: the WS7 type-ahead tag field for the pen tag picker; the accent-color name vocabulary for pen colors; the Memory Manager navigation pattern for the Trends section; the TankGraphic-style `CustomPainter` approach for the chart.

## Phasing (one spec → phased plan)

- **Phase A — Historian engine.** `TrendSample` + `TagHistorian` (sync/sample/trim/clear) pure unit, fully tested. No UI.
- **Phase B — Data model.** `TrendPen`, `TrendPenRef`, `PlcProject.trends`, `HmiComponent.trendPens`/`windowMs`, `TrendChartDisplay` type constant; JSON round-trip tests; migrate/verify default projects load.
- **Phase C — Chart painter + view.** `TrendChartPainter` (analog auto-scale + digital lanes + time axis + legend) and `TrendChartView` (LiveTick-driven, reads historian + project). Painter/widget tests.
- **Phase D — Trends section.** Memory → Trends surface: pen list CRUD (type-ahead add, edit, remove), retention/interval config, `historian.syncPens` wiring, live preview chart. Widget tests.
- **Phase E — Scan + shell integration.** Shell owns `TagHistorian`; `_executeScan` samples on live ticks; clear+sync on project switch; thread the historian to the views. Integration tests.
- **Phase F — HMI trend component.** `TrendChartDisplay` render + config dialog (multi-select pens + color override + window) + palette entry. Widget tests, overflow checks.
- **Phase G — Validation, docs, final review.** Full gates; manual smoke (add pens, watch preview, drop a trend on an HMI, switch projects → buffers reset); docs; whole-branch review; merge.
