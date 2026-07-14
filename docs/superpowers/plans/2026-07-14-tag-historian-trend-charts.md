# Live Tag Historian + Trend Charts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a memory-only live strip-chart historian, a Trends section under Memory to manage pens and preview them, and a multi-pen `TrendChartDisplay` HMI component.

**Architecture:** A pure-Dart tick-driven `TagHistorian` keeps one ring buffer per configured `TrendPen`; the scan loop samples it each live tick. Pens are persisted on the project; captured samples are not. A hand-painted `TrendChartPainter`/`TrendChartView` (no chart library) repaints via the existing `LiveTick`, reused by both the Trends preview and the HMI component.

**Tech Stack:** Flutter/Dart (mobile-first app in `mobile/`); pure-Dart models & services; `CustomPainter` charting; SharedPreferences unaffected (pens live on the project JSON).

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); PLC/HMI/trend terms are fine.
- Dark theme; zero `flutter analyze` warnings; use `withValues(alpha:)` never `withOpacity`; braces on all control flow.
- No RenderFlex overflow at 320 / 360 / 1400 widths.
- `mobile/lib/models/**` and `mobile/lib/services/tag_historian.dart` stay pure Dart — no `dart:io`, no `Timer` in the historian (tick-driven, deterministic).
- Additive persistence: `trends` (project) and `trend_pens` / `window_ms` (component) are new optional JSON keys; older projects load clean; the WS6 lossless round-trip stays green. Captured samples are NEVER serialized.
- Live-value surfaces repaint via `LiveTickScope` only — never a per-scan whole-shell `setState`.
- Reuse: `TagAutocompleteField` (tag picker), the accent-color name vocabulary (`cyan`/`green`/`red`/`amber`/`teal`/`blue`), the `TankGraphicDisplay`-style `CustomPainter` approach.
- All commands run from the `mobile/` directory: `cd mobile && flutter test ...`.

---

### Task 1: Historian engine (`TrendSample` + `TagHistorian`)

**Files:**
- Create: `mobile/lib/services/tag_historian.dart`
- Test: `mobile/test/tag_historian_test.dart`

**Interfaces:**
- Consumes: nothing (pure, standalone). The `TrendPen` fields it reads (`tagPath`, `sampleIntervalMs`, `retentionMode`, `maxPoints`, `windowMs`) are passed as a lightweight positional record in this task and replaced by the real `TrendPen` class in Task 2 — see the `_PenCfg` note below.
- Produces:
  - `class TrendSample { final int t; final double v; const TrendSample(this.t, this.v); }`
  - `class TagHistorian` with:
    - `void syncPens(List<TrendPenLike> pens)`
    - `void sample(List<TrendPenLike> pens, double? Function(String tagPath) readValue, int nowMs)`
    - `List<TrendSample> buffer(String tagPath)`
    - `void clear()`
  - `TrendPenLike` is an abstract interface (getters `tagPath`, `sampleIntervalMs`, `retentionMode`, `maxPoints`, `windowMs`) so the engine has no dependency on `project_model.dart`. Task 2's `TrendPen implements TrendPenLike`.

> **Note on `TrendPenLike`:** to keep the engine pure and independently testable, define a minimal abstract class in `tag_historian.dart`. Task 2 makes the real `TrendPen` implement it. Tests in this task use a small fake implementing `TrendPenLike`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/tag_historian_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/tag_historian.dart';

class _FakePen implements TrendPenLike {
  @override
  final String tagPath;
  @override
  final int sampleIntervalMs;
  @override
  final String retentionMode; // 'points' | 'time'
  @override
  final int maxPoints;
  @override
  final int windowMs;
  const _FakePen(this.tagPath,
      {this.sampleIntervalMs = 250,
      this.retentionMode = 'time',
      this.maxPoints = 1200,
      this.windowMs = 300000});
}

void main() {
  test('interval gating: does not over-sample a fast scan', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 250)];
    h.syncPens(pens);
    double read(String _) => 1.0;
    h.sample(pens, read, 0);
    h.sample(pens, read, 100);
    h.sample(pens, read, 200);
    expect(h.buffer('A').length, 1, reason: 'only t=0 within the first interval');
    h.sample(pens, read, 250);
    expect(h.buffer('A').length, 2);
    expect(h.buffer('A').last.t, 250);
  });

  test('time retention drops samples older than the window', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 100, retentionMode: 'time', windowMs: 1000)];
    h.syncPens(pens);
    double read(String _) => 5.0;
    for (var t = 0; t <= 1500; t += 100) {
      h.sample(pens, read, t);
    }
    final buf = h.buffer('A');
    expect(buf.first.t, greaterThanOrEqualTo(1500 - 1000));
    expect(buf.every((s) => s.t >= 1500 - 1000), isTrue);
  });

  test('points retention caps the buffer length', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 100, retentionMode: 'points', maxPoints: 3)];
    h.syncPens(pens);
    double read(String _) => 2.0;
    for (var t = 0; t <= 1000; t += 100) {
      h.sample(pens, read, t);
    }
    expect(h.buffer('A').length, 3);
    expect(h.buffer('A').last.t, 1000);
  });

  test('null read appends nothing and never throws', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 100)];
    h.syncPens(pens);
    h.sample(pens, (_) => null, 0);
    h.sample(pens, (_) => null, 100);
    expect(h.buffer('A'), isEmpty);
  });

  test('syncPens adds new buffers, drops removed, keeps unchanged', () {
    final h = TagHistorian();
    final a = const _FakePen('A', sampleIntervalMs: 100);
    h.syncPens([a]);
    h.sample([a], (_) => 1.0, 0);
    expect(h.buffer('A').length, 1);
    final b = const _FakePen('B', sampleIntervalMs: 100);
    h.syncPens([a, b]); // add B, keep A
    expect(h.buffer('A').length, 1, reason: 'A preserved across sync');
    expect(h.buffer('B'), isEmpty);
    h.syncPens([b]); // drop A
    expect(h.buffer('A'), isEmpty, reason: 'A dropped');
  });

  test('clear empties all buffers', () {
    final h = TagHistorian();
    final a = const _FakePen('A', sampleIntervalMs: 100);
    h.syncPens([a]);
    h.sample([a], (_) => 1.0, 0);
    h.clear();
    expect(h.buffer('A'), isEmpty);
  });

  test('buffer of an unknown pen is empty (not null)', () {
    expect(TagHistorian().buffer('nope'), isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/tag_historian_test.dart`
Expected: FAIL — `tag_historian.dart` and its symbols don't exist yet (compile error / not found).

- [ ] **Step 3: Write minimal implementation**

Create `mobile/lib/services/tag_historian.dart`:

```dart
/// A single historized data point: monotonic wall-clock [t] (ms) and value [v].
/// BOOLs are stored as 1.0 / 0.0 by the caller before they reach the historian.
class TrendSample {
  final int t;
  final double v;
  const TrendSample(this.t, this.v);
}

/// The pen fields the historian needs. Kept as an interface so the engine has
/// no dependency on the project model (which `TrendPen` lives in). `TrendPen`
/// implements this.
abstract class TrendPenLike {
  String get tagPath;
  int get sampleIntervalMs;
  String get retentionMode; // 'points' | 'time'
  int get maxPoints;
  int get windowMs;
}

/// A memory-only, tick-driven strip-chart historian. Owns one ring buffer per
/// pen keyed by `tagPath`. Sampling is DRIVEN by the scan loop (call [sample]
/// each live tick) rather than self-timed, so it holds no timer and is fully
/// deterministic under test. Never persisted.
class TagHistorian {
  final Map<String, List<TrendSample>> _buffers = {};

  /// Reconcile the buffer map to [pens]: create an empty buffer for a new pen,
  /// drop the buffer for a removed pen, preserve buffers for unchanged pens.
  void syncPens(List<TrendPenLike> pens) {
    final wanted = pens.map((p) => p.tagPath).toSet();
    _buffers.removeWhere((key, _) => !wanted.contains(key));
    for (final p in pens) {
      _buffers.putIfAbsent(p.tagPath, () => <TrendSample>[]);
    }
  }

  /// For each pen, if its sample interval has elapsed since its last sample
  /// (a pen with no samples always captures), read via [readValue] and append,
  /// then trim by the pen's retention rule. A null read is skipped.
  void sample(List<TrendPenLike> pens, double? Function(String tagPath) readValue, int nowMs) {
    for (final p in pens) {
      final buf = _buffers.putIfAbsent(p.tagPath, () => <TrendSample>[]);
      if (buf.isNotEmpty && nowMs - buf.last.t < p.sampleIntervalMs) {
        continue;
      }
      final value = readValue(p.tagPath);
      if (value == null) {
        continue;
      }
      buf.add(TrendSample(nowMs, value));
      _trim(buf, p, nowMs);
    }
  }

  void _trim(List<TrendSample> buf, TrendPenLike p, int nowMs) {
    if (p.retentionMode == 'points') {
      final maxPts = p.maxPoints < 2 ? 2 : p.maxPoints;
      while (buf.length > maxPts) {
        buf.removeAt(0);
      }
    } else {
      final cutoff = nowMs - (p.windowMs < 1000 ? 1000 : p.windowMs);
      while (buf.isNotEmpty && buf.first.t < cutoff) {
        buf.removeAt(0);
      }
    }
  }

  /// Read-only view of a pen's buffer (empty for an unknown pen).
  List<TrendSample> buffer(String tagPath) => _buffers[tagPath] ?? const <TrendSample>[];

  /// Empty all buffers (called on project switch).
  void clear() => _buffers.clear();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/tag_historian_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd mobile && flutter analyze lib/services/tag_historian.dart test/tag_historian_test.dart
cd .. && git add mobile/lib/services/tag_historian.dart mobile/test/tag_historian_test.dart
git commit -m "feat(trends): pure tick-driven TagHistorian ring buffers"
```
Expected analyze: "No issues found!"

---

### Task 2: Data model — `TrendPen`, `TrendPenRef`, project + component fields

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (add `TrendPen`, `TrendPenRef`; add `trends` to `PlcProject`; add `trendPens`/`windowMs` to `HmiComponent`; add the `TrendChartDisplay` type constant)
- Test: `mobile/test/trend_model_test.dart`

**Interfaces:**
- Consumes: `TrendPenLike` from `tag_historian.dart` (Task 1) — `TrendPen implements TrendPenLike`.
- Produces:
  - `class TrendPen implements TrendPenLike` — mutable fields `String tagPath; String color; int sampleIntervalMs; String retentionMode; int maxPoints; int windowMs;` + `fromJson`/`toJson`.
  - `class TrendPenRef { String penTagPath; String? colorOverride; }` + `fromJson`/`toJson`.
  - `PlcProject.trends` (`List<TrendPen>`, default `[]`, JSON key `trends`).
  - `HmiComponent.trendPens` (`List<TrendPenRef>`, default `[]`, JSON key `trend_pens`) and `HmiComponent.windowMs` (`int?`, JSON key `window_ms`).
  - `const kTrendChartDisplay = 'TrendChartDisplay';` (top-level const in `project_model.dart`).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/trend_model_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/project_model.dart';
import 'package:mobile/services/tag_historian.dart';

void main() {
  test('TrendPen round-trips all fields', () {
    final pen = TrendPen(
      tagPath: 'Ramp1/Ramp_00',
      color: 'green',
      sampleIntervalMs: 500,
      retentionMode: 'points',
      maxPoints: 600,
      windowMs: 120000,
    );
    final back = TrendPen.fromJson(pen.toJson());
    expect(back.tagPath, 'Ramp1/Ramp_00');
    expect(back.color, 'green');
    expect(back.sampleIntervalMs, 500);
    expect(back.retentionMode, 'points');
    expect(back.maxPoints, 600);
    expect(back.windowMs, 120000);
    expect(back, isA<TrendPenLike>());
  });

  test('TrendPen defaults when keys absent', () {
    final back = TrendPen.fromJson({'tag_path': 'X'});
    expect(back.color, 'cyan');
    expect(back.sampleIntervalMs, 250);
    expect(back.retentionMode, 'time');
    expect(back.maxPoints, 1200);
    expect(back.windowMs, 300000);
  });

  test('TrendPenRef round-trips, override may be null', () {
    final r = TrendPenRef(penTagPath: 'A', colorOverride: 'red');
    final back = TrendPenRef.fromJson(r.toJson());
    expect(back.penTagPath, 'A');
    expect(back.colorOverride, 'red');
    final noOverride = TrendPenRef.fromJson({'pen_tag_path': 'B'});
    expect(noOverride.colorOverride, isNull);
  });

  test('PlcProject.trends round-trips; absent key -> empty', () {
    final p = PlcProject(name: 'P');
    p.trends.add(TrendPen(tagPath: 'A'));
    final back = PlcProject.fromJson(p.toJson());
    expect(back.trends.length, 1);
    expect(back.trends.first.tagPath, 'A');
    // Legacy project JSON with no `trends` key.
    final legacy = PlcProject.fromJson({'name': 'Old'});
    expect(legacy.trends, isEmpty);
  });

  test('HmiComponent trendPens + windowMs round-trip; legacy loads clean', () {
    final c = HmiComponent(
      id: 'c1', title: 'Trend', type: kTrendChartDisplay, tagBinding: '',
    );
    c.trendPens.add(TrendPenRef(penTagPath: 'A', colorOverride: 'amber'));
    c.windowMs = 60000;
    final back = HmiComponent.fromJson(c.toJson());
    expect(back.type, 'TrendChartDisplay');
    expect(back.trendPens.length, 1);
    expect(back.trendPens.first.penTagPath, 'A');
    expect(back.trendPens.first.colorOverride, 'amber');
    expect(back.windowMs, 60000);
    // Legacy component with no trend fields.
    final legacy = HmiComponent.fromJson({
      'id': 'c2', 'title': 'LED', 'type': 'LedIndicatorLight', 'tag_binding': 'X',
    });
    expect(legacy.trendPens, isEmpty);
    expect(legacy.windowMs, isNull);
  });
}
```

> Use the real `PlcProject` constructor signature — check `project_model.dart` for its required params and adjust the `PlcProject(name: 'P')` calls if the constructor requires more (supply minimal valid values). The assertions on `trends`/`trendPens`/`windowMs` are what matter.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trend_model_test.dart`
Expected: FAIL — `TrendPen`, `TrendPenRef`, `kTrendChartDisplay`, `trends`, `trendPens`, `windowMs` don't exist.

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/models/project_model.dart`:

1. Add the import at the top (near the other imports):
```dart
import '../services/tag_historian.dart';
```

2. Add a top-level const near the top of the file:
```dart
/// HMI component type id for the multi-pen trend chart.
const String kTrendChartDisplay = 'TrendChartDisplay';
```

3. Add the two classes (place them just above `class HmiComponent`):
```dart
/// A historized pen: which tag to record, its color, sample cadence, and
/// retention. Persisted on the project; the captured samples are NOT persisted
/// (they live only in the in-memory TagHistorian).
class TrendPen implements TrendPenLike {
  @override
  String tagPath;
  @override
  String color;
  @override
  int sampleIntervalMs;
  @override
  String retentionMode; // 'points' | 'time'
  @override
  int maxPoints;
  @override
  int windowMs;

  TrendPen({
    required this.tagPath,
    this.color = 'cyan',
    this.sampleIntervalMs = 250,
    this.retentionMode = 'time',
    this.maxPoints = 1200,
    this.windowMs = 300000,
  });

  factory TrendPen.fromJson(Map<String, dynamic> json) => TrendPen(
        tagPath: json['tag_path'] ?? '',
        color: json['color'] ?? 'cyan',
        sampleIntervalMs: json['sample_interval_ms'] ?? 250,
        retentionMode: json['retention_mode'] ?? 'time',
        maxPoints: json['max_points'] ?? 1200,
        windowMs: json['window_ms'] ?? 300000,
      );

  Map<String, dynamic> toJson() => {
        'tag_path': tagPath,
        'color': color,
        'sample_interval_ms': sampleIntervalMs,
        'retention_mode': retentionMode,
        'max_points': maxPoints,
        'window_ms': windowMs,
      };
}

/// An HMI trend component's reference to a project pen, with an optional
/// per-component color override.
class TrendPenRef {
  String penTagPath;
  String? colorOverride;

  TrendPenRef({required this.penTagPath, this.colorOverride});

  factory TrendPenRef.fromJson(Map<String, dynamic> json) => TrendPenRef(
        penTagPath: json['pen_tag_path'] ?? '',
        colorOverride: json['color_override'],
      );

  Map<String, dynamic> toJson() => {
        'pen_tag_path': penTagPath,
        if (colorOverride != null) 'color_override': colorOverride,
      };
}
```

4. In `class PlcProject`, add the field, constructor default, `fromJson`, and `toJson`. Add the field declaration alongside the other list fields:
```dart
  List<TrendPen> trends;
```
In the constructor parameter list, add:
```dart
    List<TrendPen>? trends,
```
and in the initializer/body set `this.trends = trends ?? []` following the existing pattern the file uses for list fields (match how `tags`/`structDefs` are defaulted — if they use `this.tags = const []`-style or an initializer list, mirror it exactly). In `PlcProject.fromJson`, add:
```dart
      trends: (json['trends'] as List? ?? [])
          .map((e) => TrendPen.fromJson(e as Map<String, dynamic>))
          .toList(),
```
In `PlcProject.toJson`, add:
```dart
      'trends': trends.map((e) => e.toJson()).toList(),
```

5. In `class HmiComponent`, add fields:
```dart
  List<TrendPenRef> trendPens;
  int? windowMs;
```
Add constructor params (both optional):
```dart
    List<TrendPenRef>? trendPens,
    this.windowMs,
```
and default `trendPens` in the initializer to `trendPens ?? []` (match the file's list-default idiom). In `HmiComponent.fromJson`:
```dart
      trendPens: (json['trend_pens'] as List? ?? [])
          .map((e) => TrendPenRef.fromJson(e as Map<String, dynamic>))
          .toList(),
      windowMs: json['window_ms'],
```
In `HmiComponent.toJson`, add:
```dart
      'trend_pens': trendPens.map((e) => e.toJson()).toList(),
      if (windowMs != null) 'window_ms': windowMs,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trend_model_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Guard the whole suite + analyze + commit**

Run the existing serialization/round-trip tests to prove additive persistence didn't break anything:
```bash
cd mobile && flutter test && flutter analyze
```
Expected: all pass; "No issues found!"
```bash
cd .. && git add mobile/lib/models/project_model.dart mobile/test/trend_model_test.dart
git commit -m "feat(trends): TrendPen/TrendPenRef model + project/component fields (additive)"
```

---

### Task 3: Chart painter + view (`TrendChartPainter`, `TrendChartView`)

**Files:**
- Create: `mobile/lib/widgets/trend_chart.dart`
- Test: `mobile/test/trend_chart_test.dart`

**Interfaces:**
- Consumes: `TrendSample`, `TagHistorian` (Task 1); `TrendPen`, `PlcProject` (Task 2); `dataTypeOfPath` from `models/tag_resolver.dart`; `LiveTickScope` from `widgets/live_tick.dart`.
- Produces:
  - `class TrendPenView { final String tagPath; final Color color; final String label; final bool isDigital; const TrendPenView({...}); }` — a resolved, render-ready pen.
  - `Color trendColorFromName(String name)` — maps the accent-color vocabulary to a `Color` (top-level).
  - `class TrendChartPainter extends CustomPainter` — ctor `TrendChartPainter({required List<TrendPenView> pens, required List<TrendSample> Function(String tagPath) bufferOf, required int windowMs, required int nowMs, required Color axisColor, required Color gridColor})`.
  - `class TrendChartView extends StatelessWidget` — ctor `TrendChartView({required PlcProject project, required TagHistorian historian, required List<TrendPenView> pens, required int windowMs, double height = 220})`; wraps a `CustomPaint` in a `ListenableBuilder(listenable: LiveTickScope.of(context), …)` and stamps `nowMs` from `DateTime.now().millisecondsSinceEpoch` inside the builder.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/trend_chart_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/tag_historian.dart';
import 'package:mobile/widgets/trend_chart.dart';

void main() {
  test('trendColorFromName maps the vocabulary and falls back to cyan', () {
    expect(trendColorFromName('green'), isA<Color>());
    expect(trendColorFromName('nonsense'), trendColorFromName('cyan'));
  });

  testWidgets('painter renders analog + digital pens without throwing', (tester) async {
    final pens = const [
      TrendPenView(tagPath: 'A', color: Colors.cyan, label: 'A', isDigital: false),
      TrendPenView(tagPath: 'B', color: Colors.green, label: 'B', isDigital: false),
      TrendPenView(tagPath: 'D', color: Colors.amber, label: 'D', isDigital: true),
    ];
    final buffers = <String, List<TrendSample>>{
      'A': [const TrendSample(0, 0), const TrendSample(500, 50), const TrendSample(1000, 100)],
      'B': [const TrendSample(0, 5), const TrendSample(1000, 5)], // flat series
      'D': [const TrendSample(0, 0), const TrendSample(400, 1), const TrendSample(800, 0)],
    };
    List<TrendSample> bufferOf(String p) => buffers[p] ?? const [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(400, 200),
          painter: TrendChartPainter(
            pens: pens,
            bufferOf: bufferOf,
            windowMs: 1000,
            nowMs: 1000,
            axisColor: Colors.white,
            gridColor: Colors.grey,
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty buffers paint without dividing by zero', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(300, 150),
          painter: TrendChartPainter(
            pens: const [TrendPenView(tagPath: 'A', color: Colors.cyan, label: 'A', isDigital: false)],
            bufferOf: (_) => const [],
            windowMs: 5000,
            nowMs: 5000,
            axisColor: Colors.white,
            gridColor: Colors.grey,
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trend_chart_test.dart`
Expected: FAIL — `trend_chart.dart` and its symbols don't exist.

- [ ] **Step 3: Write minimal implementation**

Create `mobile/lib/widgets/trend_chart.dart`:

```dart
import 'package:flutter/material.dart';

import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../services/tag_historian.dart';
import 'live_tick.dart';

/// A render-ready pen (color + digital flag resolved).
class TrendPenView {
  final String tagPath;
  final Color color;
  final String label;
  final bool isDigital;
  const TrendPenView({
    required this.tagPath,
    required this.color,
    required this.label,
    required this.isDigital,
  });
}

/// Maps the app's accent-color name vocabulary to a Color (cyan fallback).
Color trendColorFromName(String name) {
  switch (name) {
    case 'green':
      return Colors.greenAccent;
    case 'red':
      return Colors.redAccent;
    case 'amber':
      return Colors.amberAccent;
    case 'teal':
      return Colors.tealAccent;
    case 'blue':
      return Colors.blueAccent;
    case 'cyan':
    default:
      return Colors.cyanAccent;
  }
}

/// Hand-painted strip chart. Analog pens share an auto-scaled left value axis
/// and draw as connected polylines; BOOL pens draw as stacked 0/1 square-wave
/// lanes along the bottom. Time axis: [nowMs-windowMs, nowMs], newest on the
/// right. No chart package (consistent with TankGraphicDisplay).
class TrendChartPainter extends CustomPainter {
  final List<TrendPenView> pens;
  final List<TrendSample> Function(String tagPath) bufferOf;
  final int windowMs;
  final int nowMs;
  final Color axisColor;
  final Color gridColor;

  TrendChartPainter({
    required this.pens,
    required this.bufferOf,
    required this.windowMs,
    required this.nowMs,
    required this.axisColor,
    required this.gridColor,
  });

  static const double _leftPad = 36;
  static const double _rightPad = 8;
  static const double _topPad = 8;
  static const double _laneHeight = 16;
  static const double _laneGap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final digital = pens.where((p) => p.isDigital).toList();
    final analog = pens.where((p) => !p.isDigital).toList();

    final digitalBandH = digital.isEmpty
        ? 0.0
        : digital.length * (_laneHeight + _laneGap) + _laneGap;
    final plotLeft = _leftPad;
    final plotRight = size.width - _rightPad;
    final plotTop = _topPad;
    final plotBottom = size.height - digitalBandH - 4;
    final plotW = (plotRight - plotLeft).clamp(1.0, double.infinity);
    final plotH = (plotBottom - plotTop).clamp(1.0, double.infinity);
    final win = windowMs <= 0 ? 1 : windowMs;

    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    // Frame.
    canvas.drawRect(Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom), gridPaint..style = PaintingStyle.stroke);

    double xOf(int t) => plotLeft + plotW * (1 - (nowMs - t) / win);

    // --- Analog auto-scale across all visible analog samples ---
    double? lo, hi;
    for (final p in analog) {
      for (final s in bufferOf(p.tagPath)) {
        if (s.t < nowMs - win) {
          continue;
        }
        lo = (lo == null || s.v < lo) ? s.v : lo;
        hi = (hi == null || s.v > hi) ? s.v : hi;
      }
    }
    if (lo != null && hi != null) {
      if ((hi - lo).abs() < 1e-9) {
        lo -= 1;
        hi += 1;
      }
      final span = hi - lo;
      final pad = span * 0.08;
      lo -= pad;
      hi += pad;
      double yOf(double v) => plotTop + plotH * (1 - (v - lo!) / (hi! - lo));

      // Value-axis labels (lo, mid, hi).
      final tp = (double v, double y) {
        final t = TextPainter(
          text: TextSpan(text: v.toStringAsFixed(1), style: TextStyle(color: axisColor, fontSize: 9)),
          textDirection: TextDirection.ltr,
        )..layout();
        t.paint(canvas, Offset(2, y - t.height / 2));
      };
      tp(hi, plotTop);
      tp((hi + lo) / 2, plotTop + plotH / 2);
      tp(lo, plotBottom);

      for (final p in analog) {
        final buf = bufferOf(p.tagPath).where((s) => s.t >= nowMs - win).toList();
        if (buf.isEmpty) {
          continue;
        }
        final path = Path();
        for (var i = 0; i < buf.length; i++) {
          final x = xOf(buf[i].t);
          final y = yOf(buf[i].v);
          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(path, Paint()
          ..color = p.color
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke);
      }
    }

    // --- Digital lanes ---
    var laneTop = plotBottom + _laneGap;
    for (final p in digital) {
      final laneBottom = laneTop + _laneHeight;
      final buf = bufferOf(p.tagPath).where((s) => s.t >= nowMs - win).toList();
      final onY = laneTop + 2;
      final offY = laneBottom - 2;
      if (buf.isNotEmpty) {
        final path = Path();
        double prevY = buf.first.v >= 0.5 ? onY : offY;
        path.moveTo(xOf(buf.first.t), prevY);
        for (var i = 1; i < buf.length; i++) {
          final x = xOf(buf[i].t);
          final y = buf[i].v >= 0.5 ? onY : offY;
          path.lineTo(x, prevY); // horizontal hold
          path.lineTo(x, y); // step
          prevY = y;
        }
        path.lineTo(xOf(nowMs), prevY);
        canvas.drawPath(path, Paint()
          ..color = p.color
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke);
      }
      // Lane label.
      final t = TextPainter(
        text: TextSpan(text: p.label, style: TextStyle(color: p.color, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, Offset(plotLeft + 2, laneTop + 1));
      laneTop = laneBottom + _laneGap;
    }

    // --- Legend for analog pens (top-right) ---
    var lx = plotRight;
    for (final p in analog.reversed) {
      final t = TextPainter(
        text: TextSpan(text: p.label, style: TextStyle(color: p.color, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      lx -= t.width + 14;
      canvas.drawRect(Rect.fromLTWH(lx, plotTop + 1, 8, 8), Paint()..color = p.color);
      t.paint(canvas, Offset(lx + 11, plotTop));
    }
  }

  @override
  bool shouldRepaint(covariant TrendChartPainter old) => true;
}

/// A live trend chart bound to a [TagHistorian]. Repaints on each LiveTick
/// pulse (never via a whole-shell setState). Reused by the Trends preview and
/// the HMI TrendChartDisplay component.
class TrendChartView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (pens.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('No pens to plot', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: ListenableBuilder(
        listenable: LiveTickScope.of(context),
        builder: (context, _) {
          final now = DateTime.now().millisecondsSinceEpoch;
          return CustomPaint(
            size: Size.infinite,
            painter: TrendChartPainter(
              pens: pens,
              bufferOf: historian.buffer,
              windowMs: windowMs,
              nowMs: now,
              axisColor: Colors.grey.shade300,
              gridColor: Colors.grey.shade600,
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trend_chart_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Analyze + commit**

```bash
cd mobile && flutter analyze lib/widgets/trend_chart.dart test/trend_chart_test.dart
cd .. && git add mobile/lib/widgets/trend_chart.dart mobile/test/trend_chart_test.dart
git commit -m "feat(trends): TrendChartPainter + LiveTick-driven TrendChartView"
```
Expected analyze: "No issues found!"

---

### Task 4: Shell integration — own the historian, sample each tick, clear on switch

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (own a `TagHistorian`; sample in `_executeScan`; `clear()`+`syncPens` on project switch and on init; pass the historian into `MemoryManagerScreen` and `HmiDashboardBuilderScreen`)
- Test: `mobile/test/trend_shell_integration_test.dart`

**Interfaces:**
- Consumes: `TagHistorian` (Task 1); `TrendPen`, `readPath` (`models/tag_resolver.dart`); the shell's `debugRunScan()` and `debugAddProject`/project-switch helpers.
- Produces: `TagHistorian get historianForTest` (`@visibleForTesting`) exposing the shell's historian; `MemoryManagerScreen` and `HmiDashboardBuilderScreen` now receive a `historian` param (added in Tasks 5/6 — for THIS task, only wire the shell to own + sample + clear; add the constructor args when those screens gain the param).

> **Sequencing note for the implementer:** this task adds the historian to the shell and the sampling call. Passing it into the two screens happens when those screens accept it (Tasks 5 & 6). To keep this task's diff compiling, add the field, the sampling, the clear-on-switch, and the test hook now; do NOT edit the `MemoryManagerScreen(...)`/`HmiDashboardBuilderScreen(...)` call sites yet (Tasks 5 & 6 do that alongside the constructor change).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/trend_shell_integration_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/project_model.dart';
import 'package:mobile/models/tag_resolver.dart';
import 'package:mobile/screens/workspace_shell.dart';

void main() {
  testWidgets('scan tick appends a sample for a configured pen', (tester) async {
    final key = GlobalKey<WorkspaceShellState>();
    await tester.pumpWidget(MaterialApp(home: WorkspaceShell(key: key)));
    await tester.pumpAndSettle();

    final st = key.currentState!;
    final proj = st.activeProjectForTest; // existing @visibleForTesting getter (see note)
    // Add an analog tag + a pen recording it.
    proj.tags.add(PlcTag(name: 'HistTag', path: 'HistTag', dataType: 'FLOAT64', value: 1.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'HistTag', sampleIntervalMs: 0));
    st.syncHistorianForTest();

    st.debugRunScan();
    expect(st.historianForTest.buffer('HistTag').isNotEmpty, isTrue);
  });
}
```

> The test references `activeProjectForTest`, `syncHistorianForTest()`, and `historianForTest`. If the shell already exposes an active-project test getter under a different name, use it and adjust; otherwise add a minimal `@visibleForTesting PlcProject get activeProjectForTest => _activeProject;`. `sampleIntervalMs: 0` forces a capture on the first tick.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trend_shell_integration_test.dart`
Expected: FAIL — `historianForTest` / `syncHistorianForTest` don't exist; no sample captured.

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/screens/workspace_shell.dart`:

1. Add imports (near existing model/service imports):
```dart
import '../services/tag_historian.dart';
```
(Confirm `models/tag_resolver.dart` is already imported for `readPath`; if not, add `import '../models/tag_resolver.dart';`.)

2. Add the field next to `_liveTick`:
```dart
  final TagHistorian _historian = TagHistorian();
```

3. Add test hooks (near the other `@visibleForTesting` members like `debugRunScan`):
```dart
  @visibleForTesting
  TagHistorian get historianForTest => _historian;

  @visibleForTesting
  PlcProject get activeProjectForTest => _activeProject;

  @visibleForTesting
  void syncHistorianForTest() => _historian.syncPens(_activeProject.trends);
```

4. After the initial project is chosen in `initState`/load (where `_activeProject = active ?? loadedProjects.first;` at ~line 276), sync the historian to the active project's pens:
```dart
    _historian.syncPens(_activeProject.trends);
```

5. In `_executeScan`, after `updateSystemStatus(...)` and before `_repaintThrottle.request();`, sample the historian:
```dart
    _historian.sample(
      _activeProject.trends,
      (path) {
        final v = readPath(_activeProject, path);
        if (v is bool) {
          return v ? 1.0 : 0.0;
        }
        if (v is num) {
          return v.toDouble();
        }
        return null; // non-numeric (e.g. STRING) is skipped
      },
      DateTime.now().millisecondsSinceEpoch,
    );
```

6. At EVERY project-switch site (the `_activeProject = ...;` assignments at ~619, 726, 851, 877, 957, 1007, 1124 — the ones that change which project is active: open/new/duplicate/rename-not-relevant/delete/import), immediately after the assignment add:
```dart
      _historian.clear();
      _historian.syncPens(_activeProject.trends);
```
Rename (`_activeProject.name = name;` at ~905) does NOT switch projects — skip it. For the others, switching projects must reset buffers (memory-only, start empty).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trend_shell_integration_test.dart`
Expected: PASS.

- [ ] **Step 5: Guard suite + analyze + commit**

```bash
cd mobile && flutter test && flutter analyze
cd .. && git add mobile/lib/screens/workspace_shell.dart mobile/test/trend_shell_integration_test.dart
git commit -m "feat(trends): shell owns TagHistorian, samples each tick, clears on project switch"
```
Expected: all pass; "No issues found!"

---

### Task 5: Trends section under Memory (pen CRUD + live preview)

**Files:**
- Modify: `mobile/lib/screens/memory_manager_screen.dart` (add a 3rd tab "Trends"; accept a `TagHistorian`; pen list CRUD; live preview via `TrendChartView`)
- Modify: `mobile/lib/screens/workspace_shell.dart` (pass `historian: _historian` into `MemoryManagerScreen(...)` at ~2513)
- Test: `mobile/test/trends_section_test.dart`

**Interfaces:**
- Consumes: `TagHistorian` (Task 1); `TrendPen` (Task 2); `TrendChartView` + `TrendChartView.viewForPen` (Task 3); `TagAutocompleteField`; `leafAndNodePaths`/`scalarLeaves` from `models/tag_resolver.dart` for the tag picker options.
- Produces: `MemoryManagerScreen` gains `required TagHistorian historian`. After any pen edit the screen calls `historian.syncPens(currentProject.trends)` then `widget.onProjectUpdated()`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/trends_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/project_model.dart';
import 'package:mobile/screens/memory_manager_screen.dart';
import 'package:mobile/services/tag_historian.dart';
import 'package:mobile/widgets/live_tick.dart';
import 'package:mobile/widgets/trend_chart.dart';

void main() {
  testWidgets('Trends tab lists pens and renders a preview chart', (tester) async {
    final proj = PlcProject(name: 'P');
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'A', color: 'green'));
    final historian = TagHistorian()..syncPens(proj.trends);

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: MemoryManagerScreen(
          currentProject: proj,
          onProjectUpdated: () {},
          historian: historian,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to the Trends tab.
    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();

    expect(find.text('A'), findsWidgets); // pen row shows the tag path
    expect(find.byType(TrendChartView), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trends_section_test.dart`
Expected: FAIL — `MemoryManagerScreen` has no `historian` param; no 'Trends' tab.

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/screens/memory_manager_screen.dart`:

1. Add the constructor field:
```dart
  final TagHistorian historian;
```
and require it in the constructor (`required this.historian,`). Add imports:
```dart
import '../services/tag_historian.dart';
import '../widgets/trend_chart.dart';
```
(`live_tick.dart`, `tag_resolver.dart`, and `TagAutocompleteField` — add any not already imported.)

2. Change `_tabController = TabController(length: 2, vsync: this);` to `length: 3`.

3. In the `TabBar` `tabs:` list (~479) add a third tab:
```dart
            Tab(icon: Icon(Icons.show_chart), text: 'Trends'),
```
and in the `TabBarView` `children:` (~487) add `_buildTrendsTab()` as the third child.

4. Add the Trends tab builder. Pen options come from every recordable leaf (analog + BOOL scalars). Implement:
```dart
  Widget _buildTrendsTab() {
    final pens = widget.currentProject.trends;
    final penViews = pens
        .map((p) => TrendChartView.viewForPen(widget.currentProject, p))
        .toList();
    // Preview shows the widest configured window across pens (fallback 5 min).
    final windowMs = pens.isEmpty
        ? 300000
        : pens.map((p) => p.retentionMode == 'time' ? p.windowMs : p.maxPoints * p.sampleIntervalMs)
              .reduce((a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add Pen'),
              onPressed: () => _showPenDialog(null),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TrendChartView(
            project: widget.currentProject,
            historian: widget.historian,
            pens: penViews,
            windowMs: windowMs,
            height: 220,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: pens.isEmpty
              ? Center(child: Text('No pens yet — add one to start recording.', style: TextStyle(color: Colors.grey.shade500)))
              : ListView.builder(
                  itemCount: pens.length,
                  itemBuilder: (context, i) {
                    final p = pens[i];
                    final retention = p.retentionMode == 'time'
                        ? '${(p.windowMs / 1000).toStringAsFixed(0)}s'
                        : '${p.maxPoints} pts';
                    return ListTile(
                      dense: true,
                      leading: Container(width: 14, height: 14, color: trendColorFromName(p.color)),
                      title: Text(p.tagPath, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      subtitle: Text('${p.sampleIntervalMs} ms • $retention'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(icon: const Icon(Icons.settings, size: 18), onPressed: () => _showPenDialog(p)),
                        IconButton(icon: const Icon(Icons.delete, size: 18, color: Colors.redAccent), onPressed: () {
                          setState(() => widget.currentProject.trends.remove(p));
                          widget.historian.syncPens(widget.currentProject.trends);
                          widget.onProjectUpdated();
                        }),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }
```

5. Add the add/edit dialog. Reuse `TagAutocompleteField` (options = recordable scalar leaf paths), color dropdown (same vocabulary as the HMI dialog), an interval field, and a retention-mode toggle with the mode's value field:
```dart
  void _showPenDialog(TrendPen? existing) {
    final options = scalarLeaves(widget.currentProject).map((l) => l.path).toList();
    String tagPath = existing?.tagPath ?? '';
    String color = existing?.color ?? 'cyan';
    int intervalMs = existing?.sampleIntervalMs ?? 250;
    String mode = existing?.retentionMode ?? 'time';
    int maxPoints = existing?.maxPoints ?? 1200;
    int windowMs = existing?.windowMs ?? 300000;
    final intervalCtrl = TextEditingController(text: intervalMs.toString());
    final valueCtrl = TextEditingController(text: mode == 'time' ? (windowMs ~/ 1000).toString() : maxPoints.toString());

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(existing == null ? 'Add Pen' : 'Configure Pen'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TagAutocompleteField(
                options: options,
                initialValue: tagPath,
                label: 'Tag to historize',
                onChanged: (v) => tagPath = v,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: color,
                decoration: const InputDecoration(labelText: 'Color'),
                items: const [
                  DropdownMenuItem(value: 'cyan', child: Text('Cyan')),
                  DropdownMenuItem(value: 'green', child: Text('Green')),
                  DropdownMenuItem(value: 'red', child: Text('Red')),
                  DropdownMenuItem(value: 'amber', child: Text('Amber')),
                  DropdownMenuItem(value: 'teal', child: Text('Teal')),
                  DropdownMenuItem(value: 'blue', child: Text('Blue')),
                ],
                onChanged: (v) => setDlg(() => color = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: intervalCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Sample interval (ms)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Retention'),
                items: const [
                  DropdownMenuItem(value: 'time', child: Text('By time (seconds)')),
                  DropdownMenuItem(value: 'points', child: Text('By point count')),
                ],
                onChanged: (v) => setDlg(() {
                  mode = v!;
                  valueCtrl.text = mode == 'time' ? (windowMs ~/ 1000).toString() : maxPoints.toString();
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: valueCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: mode == 'time' ? 'Window (seconds)' : 'Max points'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final iv = int.tryParse(intervalCtrl.text) ?? 250;
                final val = int.tryParse(valueCtrl.text) ?? 0;
                setState(() {
                  final target = existing ?? TrendPen(tagPath: tagPath);
                  target.tagPath = tagPath;
                  target.color = color;
                  target.sampleIntervalMs = iv < 50 ? 50 : iv;
                  target.retentionMode = mode;
                  if (mode == 'time') {
                    target.windowMs = (val < 1 ? 1 : val) * 1000;
                  } else {
                    target.maxPoints = val < 2 ? 2 : val;
                  }
                  if (existing == null) {
                    widget.currentProject.trends.add(target);
                  }
                });
                widget.historian.syncPens(widget.currentProject.trends);
                widget.onProjectUpdated();
                Navigator.pop(ctx);
              },
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
```

6. In `workspace_shell.dart` at the `MemoryManagerScreen(...)` call (~2513), add `historian: _historian,`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trends_section_test.dart`
Expected: PASS.

- [ ] **Step 5: Overflow check + analyze + suite + commit**

Add an overflow guard within the same test file (or a quick manual `flutter test`), pumping the Trends tab at 320 and 1400 widths asserting `tester.takeException()` is null. Then:
```bash
cd mobile && flutter test && flutter analyze
cd .. && git add mobile/lib/screens/memory_manager_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/trends_section_test.dart
git commit -m "feat(trends): Trends section under Memory — pen CRUD + live preview"
```
Expected: all pass; "No issues found!"

---

### Task 6: HMI `TrendChartDisplay` component (render + config + palette)

**Files:**
- Modify: `mobile/lib/screens/hmi_dashboard_builder_screen.dart` (accept a `TagHistorian`; add `TrendChartDisplay` to `availableTypes` + `_paletteTemplates` + `_iconForType`; render it in `_renderComponentWidget`; extend the config dialog with a pen multi-select + optional per-pen color override + window when the type is `TrendChartDisplay`)
- Modify: `mobile/lib/screens/workspace_shell.dart` (pass `historian: _historian` into `HmiDashboardBuilderScreen(...)` at ~2506)
- Test: `mobile/test/trend_hmi_component_test.dart`

**Interfaces:**
- Consumes: `TagHistorian` (Task 1); `TrendPen`/`TrendPenRef`/`kTrendChartDisplay` (Task 2); `TrendChartView`/`TrendChartView.viewForPen`/`trendColorFromName` (Task 3).
- Produces: `HmiDashboardBuilderScreen` gains `required TagHistorian historian`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/trend_hmi_component_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/project_model.dart';
import 'package:mobile/screens/hmi_dashboard_builder_screen.dart';
import 'package:mobile/services/tag_historian.dart';
import 'package:mobile/widgets/live_tick.dart';
import 'package:mobile/widgets/trend_chart.dart';

void main() {
  testWidgets('a TrendChartDisplay component renders a TrendChartView', (tester) async {
    final proj = PlcProject(name: 'P');
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'A', color: 'green'));
    final historian = TagHistorian()..syncPens(proj.trends);
    final hmi = HmiScreen(id: 'h1', name: 'Screen', components: [
      HmiComponent(id: 'c1', title: 'Trend', type: kTrendChartDisplay, tagBinding: '',
          trendPens: [TrendPenRef(penTagPath: 'A')], windowMs: 60000),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: HmiDashboardBuilderScreen(
          currentProject: proj,
          hmiScreen: hmi,
          onScanTriggered: () {},
          onProjectUpdated: () {},
          historian: historian,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(TrendChartView), findsOneWidget);
  });
}
```

> Confirm the real HMI-screen class name/constructor (`HmiScreen`) and adjust the fixture to match `project_model.dart`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/trend_hmi_component_test.dart`
Expected: FAIL — no `historian` param; `TrendChartDisplay` not rendered.

- [ ] **Step 3: Write minimal implementation**

In `mobile/lib/screens/hmi_dashboard_builder_screen.dart`:

1. Add the field + require it; add imports:
```dart
  final TagHistorian historian;
```
```dart
import '../services/tag_historian.dart';
import '../widgets/trend_chart.dart';
```

2. Add to `availableTypes` (~49): `{'type': kTrendChartDisplay, 'label': 'Trend Chart (Multi-Pen)'}`. Add to `_paletteTemplates` (~31) a template `HmiComponent(id: '...', title: 'Trend Chart', type: kTrendChartDisplay, tagBinding: '')`. Add to `_iconForType` (~958): `case kTrendChartDisplay: return Icons.show_chart;`.

3. In `_renderComponentWidget` (~736) add a branch. A trend component ignores `comp.tagBinding` and reads `comp.trendPens`:
```dart
      case kTrendChartDisplay:
        final pens = comp.trendPens
            .map((ref) {
              final pen = widget.currentProject.trends
                  .where((p) => p.tagPath == ref.penTagPath)
                  .toList();
              if (pen.isEmpty) {
                return null;
              }
              return TrendChartView.viewForPen(widget.currentProject, pen.first,
                  colorOverride: ref.colorOverride);
            })
            .whereType<TrendPenView>()
            .toList();
        final win = comp.windowMs ??
            (widget.currentProject.trends.isEmpty
                ? 300000
                : widget.currentProject.trends
                    .map((p) => p.retentionMode == 'time' ? p.windowMs : p.maxPoints * p.sampleIntervalMs)
                    .reduce((a, b) => a > b ? a : b));
        return TrendChartView(
          project: widget.currentProject,
          historian: widget.historian,
          pens: pens,
          windowMs: win,
          height: 200,
        );
```
Because `_renderComponentWidget` is already wrapped in a `ListenableBuilder(listenable: LiveTickScope.of(ctx))` at the call site (~573), the `TrendChartView` inside it also gets a valid `LiveTickScope` (it re-looks it up). That is fine — nested `ListenableBuilder`s on the same tick are cheap.

4. Extend the config dialog (`_showAddComponentDialog`, ~46). When `selectedType == kTrendChartDisplay`, show a pen multi-select instead of relying only on the single tag field. Add local state near the other dialog vars:
```dart
    final selectedPens = <TrendPenRef>[...(existingComp?.trendPens ?? const [])];
    int? windowSecs = existingComp?.windowMs == null ? null : existingComp!.windowMs! ~/ 1000;
    final windowCtrl = TextEditingController(text: windowSecs?.toString() ?? '');
```
Inside the dialog `Column`, after the type dropdown, conditionally insert (using the dialog's `setDlgState`):
```dart
                  if (selectedType == kTrendChartDisplay) ...[
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerLeft, child: Text('Pens to plot', style: TextStyle(color: Colors.grey.shade400, fontSize: 12))),
                    ...widget.currentProject.trends.map((pen) {
                      final ref = selectedPens.where((r) => r.penTagPath == pen.tagPath).toList();
                      final checked = ref.isNotEmpty;
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        title: Text(pen.tagPath, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                        onChanged: (v) => setDlgState(() {
                          if (v == true) {
                            selectedPens.add(TrendPenRef(penTagPath: pen.tagPath));
                          } else {
                            selectedPens.removeWhere((r) => r.penTagPath == pen.tagPath);
                          }
                        }),
                      );
                    }),
                    if (widget.currentProject.trends.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('No pens defined. Create pens in Memory → Trends.', style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: windowCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Window (seconds, blank = pens\' own)'),
                    ),
                  ],
```
In the dialog's save `onPressed`, when the (existing or new) component's type is `kTrendChartDisplay`, also persist the pens + window. In the `existingComp != null` branch add:
```dart
                      existingComp.trendPens = selectedPens;
                      final ws = int.tryParse(windowCtrl.text);
                      existingComp.windowMs = ws == null ? null : ws * 1000;
```
and in the `else` (new component) branch, pass `trendPens: selectedPens` and `windowMs: int.tryParse(windowCtrl.text) == null ? null : int.parse(windowCtrl.text) * 1000` to the `HmiComponent(...)` constructor. (Non-trend components leave both at their defaults.)

5. In `workspace_shell.dart` at `HmiDashboardBuilderScreen(...)` (~2506), add `historian: _historian,`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/trend_hmi_component_test.dart`
Expected: PASS.

- [ ] **Step 5: Overflow check + analyze + suite + commit**

Pump an HMI screen containing the trend component at 320/360/1400 (extend the test) and assert no exception. Then:
```bash
cd mobile && flutter test && flutter analyze
cd .. && git add mobile/lib/screens/hmi_dashboard_builder_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/trend_hmi_component_test.dart
git commit -m "feat(trends): HMI TrendChartDisplay component — render + config + palette"
```
Expected: all pass; "No issues found!"

---

### Task 7: Validation, docs, final review

**Files:**
- Create: `mobile/docs/trends.md` (or `docs/trends.md` matching where protocol docs live — check the repo; use the existing docs location)
- Modify: none (validation task)

**Interfaces:** none.

- [ ] **Step 1: Full gates**

Run:
```bash
cd mobile && flutter test
cd mobile && flutter analyze
cd mobile && flutter build web --release
```
Expected: all tests pass; "No issues found!"; web build compiles. Fix any failures before proceeding.

- [ ] **Step 2: Manual smoke (document the steps + results)**

In a running app (or note as a manual checklist in the PR/commit body):
1. Memory → Trends → Add Pen (a ramp/analog tag) + Add Pen (a BOOL tag). Start the PLC. Confirm the preview chart draws the analog line and the BOOL step lane, auto-scrolling.
2. Build an HMI screen, add a Trend Chart component, select both pens, override one color. Confirm it plots.
3. Switch projects and back — confirm the buffers reset to empty (chart starts blank) and refill while running.
4. Pause the PLC — confirm no new points accrue; the existing trace stays visible.

- [ ] **Step 3: Write the docs**

Create the docs file describing: what the historian is (memory-only strip-chart, tick-driven), how to add pens (Memory → Trends: interval + points/time retention + color), the live preview, and the HMI `TrendChartDisplay` (multi-pen, analog auto-scale, BOOL digital lanes, per-pen color override, window). Note the memory-only nature (samples not persisted; reset on project switch; sampling only while running). No vendor branding.

- [ ] **Step 4: Commit docs**

```bash
git add <docs path>
git commit -m "docs(trends): live tag historian + trend charts"
```

- [ ] **Step 5: Whole-branch review**

Dispatch the final whole-branch code review (superpowers:requesting-code-review). Address any Critical/Important findings, then proceed to finishing-a-development-branch.

---

## Self-Review

**Spec coverage:**
- Historian engine (memory-only, tick-driven, interval gating, points/time retention, BOOL→0/1, null-skip, clear, syncPens) → Task 1. ✓
- Data model (`TrendPen`, `TrendPenRef`, `PlcProject.trends`, `HmiComponent.trendPens`/`windowMs`, `TrendChartDisplay`, additive JSON, defaults) → Task 2. ✓
- Chart painter + view (analog auto-scale, digital lanes, time axis, legend, LiveTick-driven) → Task 3. ✓
- Scan + shell integration (own historian, sample on live tick only, clear+sync on project switch) → Task 4. ✓
- Trends section (pen CRUD via type-ahead + color + interval + retention, live preview) → Task 5. ✓
- HMI trend component (render, multi-select config, color override, window, palette/icon) → Task 6. ✓
- Validation, docs, final review → Task 7. ✓
- "Sampling only while running" → satisfied structurally: `_executeScan` only runs on live ticks (Task 4). ✓
- "Buffers reset on project switch" → Task 4 clear()+syncPens at every switch site. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. UI-integration steps reference exact anchors (line numbers approximate — implementers confirm against the file). ✓

**Type consistency:** `TrendPenLike` (Task 1) ⇔ `TrendPen implements TrendPenLike` (Task 2); `TrendChartView`/`TrendPenView`/`viewForPen`/`trendColorFromName` (Task 3) used consistently in Tasks 5 & 6; `historian` constructor param added to `MemoryManagerScreen` (Task 5) and `HmiDashboardBuilderScreen` (Task 6) and passed from the shell in the same tasks; `kTrendChartDisplay` used in Tasks 2/3/6. JSON keys (`trends`, `trend_pens`, `window_ms`, `tag_path`, `sample_interval_ms`, `retention_mode`, `max_points`, `window_ms`, `color`, `pen_tag_path`, `color_override`) consistent between `toJson`/`fromJson`. ✓

**Note for implementers:** line numbers are from the plan-writing snapshot and may drift; locate the named symbols/anchors rather than trusting exact lines. Confirm real constructor signatures for `PlcProject` and the HMI-screen class before writing fixtures.
