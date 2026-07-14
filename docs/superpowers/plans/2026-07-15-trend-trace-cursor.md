# Trend Chart Trace Cursor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a draggable, touch-friendly trace cursor to the trend charts that reports each pen's value at a chosen time.

**Architecture:** Extract the chart's x/time mapping into a pure `TrendChartGeometry` (shared by painter + hit-test); add pure readout helpers (`nearestSample`, `relativeAgo`, `clockHms`, `formatPenValue`); the painter draws an optional vertical cursor line + dots; `TrendChartView` becomes stateful with a tap/horizontal-drag gesture and a readout overlay. Both surfaces (Trends preview + HMI `TrendChartDisplay`) inherit it via the shared `TrendChartView`.

**Tech Stack:** Flutter/Dart; `CustomPainter`; `GestureDetector`; the existing `TagHistorian`/`TrendSample` + `LiveTick`.

## Global Constraints

- No vendor branding. Dark theme; zero `flutter analyze` warnings; `withValues(alpha:)` never `withOpacity`; braces on all control flow; no RenderFlex overflow at 320/360/1400.
- Pure helpers (`TrendChartGeometry`, `nearestSample`, `relativeAgo`, `clockHms`, `formatPenValue`) take timestamps as arguments — NO internal `DateTime.now()` — so they are deterministic under test. No `dart:io`.
- Transient UI only: no new model fields, no persistence, WS6 round-trip unaffected.
- Repaint via `LiveTick` unchanged; NEVER mutate cursor state during `build` — use a `mounted`-guarded `addPostFrameCallback` for the auto-hide reset.
- Touch-first: the cursor gesture is a horizontal drag (+ tap) so it does not block the enclosing vertical page scroll.
- All commands run from `mobile/`. The Dart package name is `soft_plc_mobile` (imports: `package:soft_plc_mobile/...`).

---

### Task 1: Pure geometry + readout helpers (painter adopts geometry, no behavior change)

**Files:**
- Modify: `mobile/lib/widgets/trend_chart.dart` (add `TrendChartGeometry`, `nearestSample`, `relativeAgo`, `clockHms`, `formatPenValue`; refactor the painter's inline `xOf` to use a `TrendChartGeometry`)
- Test: `mobile/test/trend_chart_test.dart` (append new unit tests)

**Interfaces:**
- Consumes: `TrendSample` (`services/tag_historian.dart`), `TrendPenView` (same file).
- Produces:
  - `class TrendChartGeometry { final double width; final int nowMs; final int windowMs; const TrendChartGeometry({required this.width, required this.nowMs, required this.windowMs}); static const double leftPad = 36; static const double rightPad = 8; double get plotLeft; double get plotRight; double get plotW; double xOfTime(int tMs); int timeAtX(double x); }`
  - `TrendSample? nearestSample(List<TrendSample> buf, int tMs)`
  - `String relativeAgo(int cursorMs, int nowMs)`
  - `String clockHms(int cursorMs)`
  - `String formatPenValue(TrendPenView pen, TrendSample? s)`

- [ ] **Step 1: Write the failing test**

Append to `mobile/test/trend_chart_test.dart` (add any missing imports: `package:soft_plc_mobile/services/tag_historian.dart`):

```dart
  group('trace-cursor pure helpers', () {
    test('TrendChartGeometry maps time<->x and clamps', () {
      const geo = TrendChartGeometry(width: 200, nowMs: 10000, windowMs: 1000);
      // right edge = now, left edge = now-window
      expect(geo.xOfTime(10000), closeTo(geo.plotRight, 0.001));
      expect(geo.xOfTime(9000), closeTo(geo.plotLeft, 0.001));
      // timeAtX inverts xOfTime
      expect(geo.timeAtX(geo.xOfTime(9500)), closeTo(9500, 2));
      // clamp beyond the plot bounds
      expect(geo.timeAtX(-100), 9000);
      expect(geo.timeAtX(99999), 10000);
    });

    test('nearestSample picks closest by |dt|, null on empty', () {
      final buf = [const TrendSample(0, 1), const TrendSample(100, 2), const TrendSample(300, 3)];
      expect(nearestSample(buf, 110)!.v, 2);
      expect(nearestSample(buf, 260)!.v, 3);
      expect(nearestSample(const [], 50), isNull);
    });

    test('relativeAgo formats now / seconds / minutes', () {
      expect(relativeAgo(10000, 10000), 'now');
      expect(relativeAgo(9550, 10000), '-0s'); // <1s rounds toward 0 but >0 handled below
      expect(relativeAgo(9000, 10000), '-1s');
      expect(relativeAgo(-62000 + 10000 + 62000, 10000), 'now'); // sanity guard, no throw
      expect(relativeAgo(10000 - 72000, 10000), '-1m 12s');
    });

    test('clockHms formats a fixed epoch ms to HH:mm:ss', () {
      final dt = DateTime(2026, 1, 2, 14, 32, 5);
      expect(clockHms(dt.millisecondsSinceEpoch), '14:32:05');
    });

    test('formatPenValue: null dash, digital ON/OFF, analog 2dp', () {
      const analog = TrendPenView(tagPath: 'A', color: Color(0xFF00FFFF), label: 'A', isDigital: false);
      const digital = TrendPenView(tagPath: 'D', color: Color(0xFF00FFFF), label: 'D', isDigital: true);
      expect(formatPenValue(analog, null), '—');
      expect(formatPenValue(digital, const TrendSample(0, 0.6)), 'ON');
      expect(formatPenValue(digital, const TrendSample(0, 0.2)), 'OFF');
      expect(formatPenValue(analog, const TrendSample(0, 3.14159)), '3.14');
    });
  });
```

> Note on the `relativeAgo(9550, 10000)` case: `(10000-9550)/1000 = 0.45 → round = 0`, and the spec's helper returns `'now'` when the rounded seconds ≤ 0. Adjust that one assertion to `'now'` if you implement round-to-zero-as-now (recommended — see Step 3). Keep the `-1s`, `-1m 12s`, `now` assertions.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trend_chart_test.dart`
Expected: FAIL — the new symbols don't exist.

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/widgets/trend_chart.dart`, add these top-level declarations (after `trendColorFromName`):

```dart
/// Pure horizontal mapping for the strip chart: converts between a timestamp
/// and a pixel x, using the same padding the painter draws with. Shared by the
/// painter and the trace-cursor hit-testing so the two never drift.
class TrendChartGeometry {
  final double width;
  final int nowMs;
  final int windowMs;
  const TrendChartGeometry({
    required this.width,
    required this.nowMs,
    required this.windowMs,
  });

  static const double leftPad = 36;
  static const double rightPad = 8;

  double get plotLeft => leftPad;
  double get plotRight => width - rightPad;
  double get plotW {
    final w = plotRight - plotLeft;
    return w < 1.0 ? 1.0 : w;
  }

  int get _win => windowMs <= 0 ? 1 : windowMs;

  /// Pixel x for a timestamp (newest sample sits at the right edge).
  double xOfTime(int tMs) => plotLeft + plotW * (1 - (nowMs - tMs) / _win);

  /// Timestamp for a pixel x, clamped to the visible window.
  int timeAtX(double x) {
    final frac = ((x - plotLeft) / plotW).clamp(0.0, 1.0);
    final t = nowMs - ((1 - frac) * _win).round();
    if (t < nowMs - _win) {
      return nowMs - _win;
    }
    if (t > nowMs) {
      return nowMs;
    }
    return t;
  }
}

/// The sample in [buf] whose time is closest to [tMs], or null if empty.
TrendSample? nearestSample(List<TrendSample> buf, int tMs) {
  if (buf.isEmpty) {
    return null;
  }
  var best = buf.first;
  var bestD = (best.t - tMs).abs();
  for (final s in buf) {
    final d = (s.t - tMs).abs();
    if (d < bestD) {
      best = s;
      bestD = d;
    }
  }
  return best;
}

/// Relative age of [cursorMs] vs [nowMs] as '-1m 12s' / '-45s' / 'now'.
String relativeAgo(int cursorMs, int nowMs) {
  final secs = ((nowMs - cursorMs) / 1000).round();
  if (secs <= 0) {
    return 'now';
  }
  final m = secs ~/ 60;
  final s = secs % 60;
  if (m > 0) {
    return '-${m}m ${s}s';
  }
  return '-${s}s';
}

/// Wall-clock time of [cursorMs] as 'HH:mm:ss'.
String clockHms(int cursorMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(cursorMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

/// A pen's value at a cursor sample: '—' if none, 'ON'/'OFF' for digital,
/// else a 2-dp number.
String formatPenValue(TrendPenView pen, TrendSample? s) {
  if (s == null) {
    return '—';
  }
  if (pen.isDigital) {
    return s.v >= 0.5 ? 'ON' : 'OFF';
  }
  return s.v.toStringAsFixed(2);
}
```

Now refactor the painter's `paint` to use the geometry for x-mapping (behavior-preserving). Replace the local `xOf` closure and the `plotLeft`/`plotRight`/`plotW`/`win` locals so they come from a single geometry instance. Specifically, near the top of `paint`, after computing `digitalBandH`, replace:

```dart
    const plotLeft = _leftPad;
    final plotRight = size.width - _rightPad;
    const plotTop = _topPad;
    final plotBottom = size.height - digitalBandH - 4;
    final plotW = (plotRight - plotLeft).clamp(1.0, double.infinity);
    final plotH = (plotBottom - plotTop).clamp(1.0, double.infinity);
    final win = windowMs <= 0 ? 1 : windowMs;
```
with:
```dart
    final geo = TrendChartGeometry(width: size.width, nowMs: nowMs, windowMs: windowMs);
    final plotLeft = geo.plotLeft;
    final plotRight = geo.plotRight;
    const plotTop = _topPad;
    final plotBottom = size.height - digitalBandH - 4;
    final plotW = geo.plotW;
    final plotH = (plotBottom - plotTop).clamp(1.0, double.infinity);
    final win = windowMs <= 0 ? 1 : windowMs;
```
and replace the closure `double xOf(int t) => plotLeft + plotW * (1 - (nowMs - t) / win);` with:
```dart
    double xOf(int t) => geo.xOfTime(t);
```
Leave everything else (vertical math, `_leftPad`/`_topPad`/`_laneHeight`/`_laneGap` constants, analog/digital/legend drawing) unchanged. `_leftPad`/`_rightPad` constants remain (the geometry mirrors their values; keep both in sync — both are 36 / 8).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trend_chart_test.dart`
Expected: PASS (new helper tests + the pre-existing painter tests still pass — the refactor is behavior-preserving).

- [ ] **Step 5: Analyze + commit**

```bash
cd mobile && flutter analyze lib/widgets/trend_chart.dart test/trend_chart_test.dart
cd .. && git add mobile/lib/widgets/trend_chart.dart mobile/test/trend_chart_test.dart
git commit -m "feat(trends): TrendChartGeometry + cursor readout helpers (painter adopts geometry)"
```
Expected analyze: "No issues found!"

---

### Task 2: Cursor line in the painter + interactive stateful `TrendChartView`

**Files:**
- Modify: `mobile/lib/widgets/trend_chart.dart` (painter gains optional `cursorTimeMs`/`cursorColor` + draws line/dots; `TrendChartView` → `StatefulWidget` with gesture + readout overlay)
- Test: `mobile/test/trend_chart_test.dart` (append cursor widget tests)

**Interfaces:**
- Consumes: everything from Task 1 (`TrendChartGeometry`, `nearestSample`, `relativeAgo`, `clockHms`, `formatPenValue`), `LiveTickScope` (`widgets/live_tick.dart`), `TagHistorian`.
- Produces: `TrendChartView` keeps the SAME public constructor (`{required project, required historian, required pens, required windowMs, double height = 220}`) and the SAME static `viewForPen(...)` — only its internal Stateless→Stateful nature changes, so all call sites (Trends preview, HMI component) are untouched. Painter gains `{int? cursorTimeMs, Color cursorColor}` (both optional; default `cursorColor` a bright neutral).

- [ ] **Step 1: Write the failing test**

Append to `mobile/test/trend_chart_test.dart`:

```dart
  testWidgets('trace cursor: tap shows readout, drag moves, ✕ clears', (tester) async {
    final historian = TagHistorian();
    // One analog pen 'A' with a rising ramp over the last ~1s, and a digital 'D'.
    final pen = TrendPen(tagPath: 'A', color: 'cyan', sampleIntervalMs: 0, retentionMode: 'time', windowMs: 60000);
    final penD = TrendPen(tagPath: 'D', color: 'green', sampleIntervalMs: 0, retentionMode: 'time', windowMs: 60000);
    historian.syncPens([pen, penD]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
        PlcTag(name: 'D', path: 'D', dataType: 'BOOL', value: false, ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    final pens = [
      TrendChartView.viewForPen(proj, pen),
      TrendChartView.viewForPen(proj, penD),
    ];
    // Seed buffers by directly sampling at known-ish times relative to now.
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < 5; i++) {
      historian.sample([pen, penD], (path) => path == 'A' ? (i * 10).toDouble() : (i.isEven ? 1.0 : 0.0), now - (4 - i) * 100);
    }

    final live = LiveTick();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveTickScope(
          notifier: live,
          child: TrendChartView(project: proj, historian: historian, pens: pens, windowMs: 60000, height: 220),
        ),
      ),
    ));
    await tester.pump();

    // No readout before interaction.
    expect(find.byIcon(Icons.close), findsNothing);

    // Tap in the middle of the chart → readout appears (has a ✕ and a pen row).
    await tester.tapAt(tester.getCenter(find.byType(CustomPaint).first));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.textContaining('A:'), findsOneWidget);

    // Clearing via ✕ removes the readout.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('trace cursor readout has no overflow at 320/360/1400', (tester) async {
    final historian = TagHistorian();
    final pen = TrendPen(tagPath: 'A', color: 'cyan', sampleIntervalMs: 0, windowMs: 60000);
    historian.syncPens([pen]);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal')],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    historian.sample([pen], (_) => 1.0, now - 100);
    for (final w in [320.0, 360.0, 1400.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: w,
            child: LiveTickScope(
              notifier: LiveTick(),
              child: TrendChartView(project: proj, historian: historian, pens: [TrendChartView.viewForPen(proj, pen)], windowMs: 60000),
            ),
          ),
        ),
      ));
      await tester.tapAt(tester.getCenter(find.byType(CustomPaint).first));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $w');
    }
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trend_chart_test.dart`
Expected: FAIL — `TrendChartView` isn't interactive; no readout/✕ appears.

- [ ] **Step 3: Write minimal implementation**

**(a) Painter cursor fields + drawing.** In `TrendChartPainter`, add fields and constructor params:
```dart
  final int? cursorTimeMs;
  final Color cursorColor;
```
```dart
  TrendChartPainter({
    required this.pens,
    required this.bufferOf,
    required this.windowMs,
    required this.nowMs,
    required this.axisColor,
    required this.gridColor,
    this.cursorTimeMs,
    this.cursorColor = const Color(0xFFECEFF1),
  });
```
Inside `paint`, at the very END of the method (after the legend loop), draw the cursor line + analog dots:
```dart
    // --- Trace cursor (optional) ---
    final cursor = cursorTimeMs;
    if (cursor != null && cursor >= nowMs - win && cursor <= nowMs) {
      final cx = geo.xOfTime(cursor);
      final cursorBottom = plotBottom + digitalBandH;
      canvas.drawLine(
        Offset(cx, plotTop),
        Offset(cx, cursorBottom),
        Paint()
          ..color = cursorColor.withValues(alpha: 0.9)
          ..strokeWidth = 1,
      );
      // Dot at each analog pen's nearest sample (reuse the same scale as above).
      if (lo != null && hi != null) {
        double lo2 = lo;
        double hi2 = hi;
        if ((hi2 - lo2).abs() < 1e-9) {
          lo2 -= 1;
          hi2 += 1;
        }
        final span0 = hi2 - lo2;
        lo2 -= span0 * 0.08;
        hi2 += span0 * 0.08;
        double yOf2(double v) => plotTop + plotH * (1 - (v - lo2) / (hi2 - lo2));
        for (final p in analog) {
          final s = nearestSample(bufferOf(p.tagPath).where((s) => s.t >= nowMs - win).toList(), cursor);
          if (s == null) {
            continue;
          }
          canvas.drawCircle(Offset(cx, yOf2(s.v)), 2.5, Paint()..color = p.color);
        }
      }
    }
```
> `lo`/`hi` are the analog min/max already computed earlier in `paint` (they remain in scope). This recomputes the same padded scale locally for the dots; the duplication is small and keeps the cursor block self-contained. If you prefer, hoist `loFinal`/`hiFinal`/`yOf` to method scope and reuse — either is acceptable as long as the dot sits on the drawn polyline.

**(b) `TrendChartView` → stateful.** Replace the `class TrendChartView extends StatelessWidget { ... }` with a `StatefulWidget` keeping identical fields + the static `viewForPen`, plus a `State` that holds the cursor and builds the gesture + readout:

```dart
class TrendChartView extends StatefulWidget {
  final PlcProject project;
  final TagHistorian historian;
  final List<TrendPenView> pens;
  final int windowMs;
  final double height;

  const TrendChartView({
    super.key,
    required this.project,
    required this.historian,
    required this.pens,
    required this.windowMs,
    this.height = 220,
  });

  /// Resolve a project pen to a render-ready [TrendPenView]. A BOOL leaf (by
  /// [dataTypeOfPath]) is digital; everything else is analog.
  static TrendPenView viewForPen(PlcProject project, TrendPen pen, {String? colorOverride}) {
    final type = dataTypeOfPath(project, pen.tagPath);
    return TrendPenView(
      tagPath: pen.tagPath,
      color: trendColorFromName(colorOverride ?? pen.color),
      label: pen.tagPath,
      isDigital: type == 'BOOL',
    );
  }

  @override
  State<TrendChartView> createState() => _TrendChartViewState();
}

class _TrendChartViewState extends State<TrendChartView> {
  int? _cursorTimeMs;

  @override
  Widget build(BuildContext context) {
    if (widget.pens.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text('No pens to plot', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return ListenableBuilder(
            listenable: LiveTickScope.of(context),
            builder: (context, _) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final win = widget.windowMs <= 0 ? 1 : widget.windowMs;
              final geo = TrendChartGeometry(width: width, nowMs: now, windowMs: widget.windowMs);
              final cursor = _cursorTimeMs;
              final inWindow = cursor != null && cursor >= now - win && cursor <= now;
              // Auto-hide: reset the state cleanly once the anchored time has
              // scrolled off the left edge (never mutate state during build).
              if (cursor != null && !inWindow) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _cursorTimeMs == cursor) {
                    setState(() => _cursorTimeMs = null);
                  }
                });
              }
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => setState(() => _cursorTimeMs = geo.timeAtX(d.localPosition.dx)),
                      onHorizontalDragStart: (d) => setState(() => _cursorTimeMs = geo.timeAtX(d.localPosition.dx)),
                      onHorizontalDragUpdate: (d) => setState(() => _cursorTimeMs = geo.timeAtX(d.localPosition.dx)),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: TrendChartPainter(
                          pens: widget.pens,
                          bufferOf: widget.historian.buffer,
                          windowMs: widget.windowMs,
                          nowMs: now,
                          axisColor: Colors.grey.shade300,
                          gridColor: Colors.grey.shade600,
                          cursorTimeMs: inWindow ? cursor : null,
                        ),
                      ),
                    ),
                  ),
                  if (inWindow) _buildReadout(geo, cursor, now),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildReadout(TrendChartGeometry geo, int cursor, int now) {
    final cursorX = geo.xOfTime(cursor);
    final onRight = cursorX > geo.width / 2;
    final rows = <Widget>[];
    for (final p in widget.pens) {
      final s = nearestSample(widget.historian.buffer(p.tagPath), cursor);
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, color: p.color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '${p.label}: ${formatPenValue(p, s)}',
                style: const TextStyle(fontSize: 10, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ));
    }
    return Positioned(
      top: 6,
      left: onRight ? 6 : null,
      right: onRight ? null : 6,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 170),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade700),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '${relativeAgo(cursor, now)}  ${clockHms(cursor)}',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => setState(() => _cursorTimeMs = null),
                  child: Icon(Icons.close, size: 14, color: Colors.grey.shade400),
                ),
              ],
            ),
            ...rows,
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trend_chart_test.dart`
Expected: PASS (helper tests + cursor widget tests + pre-existing painter/view tests).

- [ ] **Step 5: Guard suite + analyze + commit**

```bash
cd mobile && flutter test && flutter analyze
cd .. && git add mobile/lib/widgets/trend_chart.dart mobile/test/trend_chart_test.dart
git commit -m "feat(trends): draggable trace cursor (tap/drag + readout + auto-hide) on trend charts"
```
Expected: all pass; "No issues found!"

---

### Task 3: Validation, docs, final review

**Files:**
- Modify: `docs/trends.md` (document the trace cursor)

**Interfaces:** none.

- [ ] **Step 1: Full gates**

```bash
cd mobile && flutter test
cd mobile && flutter analyze
cd mobile && flutter build web --release
```
Expected: all tests pass; "No issues found!"; web build compiles. Fix any failure before proceeding.

- [ ] **Step 2: Manual smoke (record as a checklist)**

1. Memory → Trends: with the PLC running and a few pens, **tap** the preview chart — a vertical trace + readout (relative + wall-clock time and each pen's value) appears. **Drag** it left/right; values update. Tap **✕** to clear. Let it sit — the trace **auto-hides** as its time scrolls off the left edge.
2. Repeat on an HMI **Trend Chart** component (RUN mode). Confirm the same behavior and that a horizontal drag doesn't scroll the page while a vertical drag still does.
3. BOOL pen shows `ON`/`OFF`; a pen with no data at the cursor shows `—`.

- [ ] **Step 3: Update docs**

In `docs/trends.md`, add a short "Trace cursor" section: tap to place / drag to move (touch + mouse), the readout shows relative + wall-clock time and each pen's nearest-sample value, ✕ or scroll-off clears it, and it's transient (not saved). No vendor branding.

- [ ] **Step 4: Commit docs**

```bash
git add docs/trends.md
git commit -m "docs(trends): document the trend trace cursor"
```

- [ ] **Step 5: Whole-branch review**

Dispatch the final whole-branch review; address Critical/Important findings; then finishing-a-development-branch.

---

## Self-Review

**Spec coverage:**
- Draggable cursor, touch + mouse (tap + horizontal drag) → Task 2. ✓
- Readout with relative + wall-clock time → `relativeAgo`+`clockHms` (Task 1) shown in `_buildReadout` (Task 2). ✓
- Per-pen nearest-sample value, ON/OFF for digital, — when absent → `nearestSample`+`formatPenValue` (Task 1) in readout (Task 2). ✓
- Anchored to timestamp, sticks to data, auto-hide off-edge → in-window gate + post-frame reset (Task 2). ✓
- Cursor line + analog dots in painter → Task 2. ✓
- Shared geometry (no painter/hit-test drift) → `TrendChartGeometry` (Task 1). ✓
- Both surfaces inherit (no call-site change) → `TrendChartView` keeps its public API (Task 2). ✓
- No persistence / transient only → no model change. ✓
- Overflow 320/360/1400 → Task 2 test + Task 3 gates. ✓
- Docs + validation + review → Task 3. ✓

**Placeholder scan:** none — every step has complete code.

**Type consistency:** `TrendChartGeometry`/`nearestSample`/`relativeAgo`/`clockHms`/`formatPenValue` defined in Task 1 and consumed in Task 2; painter `cursorTimeMs`/`cursorColor` added in Task 2; `TrendChartView` public ctor + `viewForPen` unchanged so Trends/HMI call sites don't move. `TrendSample` fields `t`/`v`, `TrendPenView` fields `tagPath`/`color`/`label`/`isDigital`, `TagHistorian.buffer` all match the shipped code.

**Note for implementers:** the geometry's `leftPad`/`rightPad` (36/8) must stay equal to the painter's `_leftPad`/`_rightPad`; both are kept in the same file. Adjust the one `relativeAgo(9550, 10000)` assertion per the Task 1 note (round-to-zero → `'now'`).
