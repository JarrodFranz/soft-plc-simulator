# Bulk Simulated Test Tags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bulk-generate folders of always-moving simulated "test tags" (ramp/sine/square/triangle/random/counter/toggle), phase-staggered, read-only in programs, auto-appended to the chosen OPC UA / Modbus / DNP3 / MQTT maps for exercising the protocol servers.

**Architecture:** A pure `signal_engine.dart` drives each `SignalGen`'s tag every scan (run in `scan_tick.dart` beside the sim pass, before logic). Generated tags are normal `PlcTag`s with `ioType='SimulatedOutput'` (already read-only on the wire) grouped by a new flat `PlcTag.folder`; the executors refuse logic writes to generated paths. A pure `test_tag_set.dart` builds a set and appends it to each protocol map at next-free addresses. The Memory Manager gains a Generate-Test-Set dialog + folder grouping.

**Tech Stack:** Flutter/Dart (pure Dart in `mobile/lib/models/**`), existing `tag_resolver.dart` (`readPath`/`writePath`), the four protocol map models, `flutter_test`.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"). Dark theme; zero `flutter analyze` warnings; `withValues(alpha:)` not `withOpacity`; braces on all control flow; prefer `const`. No RenderFlex overflow at 320 / 360 / 1400 px.
- `mobile/lib/models/**` stays **pure Dart** — no `dart:io`, no Flutter, no `DateTime.now()`/`Math.random()`. Time enters as `dtMs`; randomness is a seeded deterministic PRNG (mirror the WS14 noise PRNG in `sim_engine.dart`: FNV-1a seed `0x811c9dc5`/`0x01000193`, xorshift32).
- All tag writes go through `writePath`; forcing stays authoritative for reads. The signal engine writes generated tags directly; **logic writes to generated paths are refused**.
- Additive persistence: `PlcTag.folder` (default `''`) and `PlcProject.signalGens` (default `[]`) are additive; the WS6 lossless round-trip must stay green; a project with neither behaves exactly as before.
- Generated tag types: analog signals (ramp/sine/square/triangle/random) → `FLOAT64`; `counter` → `INT32` (dart2js-safe, no INT64); `toggle` → `BOOL`. Generated tags use `ioType = 'SimulatedOutput'`.
- Reuse the existing `isTaskNameTaken`-style case-insensitive collision check for tag names (no duplicate tag names project-wide) on bulk create.

**Test/analyze commands** (run from `mobile/`): single file `flutter test test/<path>_test.dart`; full suite `flutter test`; `flutter analyze` (expect **No issues found!**).

---

## Phase A — Model + pure signal engine

### Task 1: `PlcTag.folder` + `SignalGen` model + `PlcProject.signalGens`

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`PlcTag` fields/ctor/JSON; `PlcProject` field/ctor/JSON)
- Create: `mobile/lib/models/signal_gen.dart`
- Test: `mobile/test/models/signal_gen_test.dart` (create)

**Interfaces:**
- Produces: `PlcTag.folder` (String, default `''`, JSON key `folder`); `class SignalGen { String id; String targetPath; String type; double minValue; double maxValue; int periodMs; double phase; bool enabled; }` with `fromJson`/`toJson`; `PlcProject.signalGens` (`List<SignalGen>`, default `[]`, JSON key `signal_gens`).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/signal_gen_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';

void main() {
  test('PlcTag.folder defaults to empty and round-trips', () {
    final t = PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal');
    expect(t.folder, '');
    final t2 = PlcTag(
      name: 'B', path: 'B', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: 'ramp1');
    expect(PlcTag.fromJson(t2.toJson()).folder, 'ramp1');
    // Legacy JSON without the key defaults to root.
    expect(PlcTag.fromJson({'name': 'C', 'data_type': 'BOOL'}).folder, '');
  });

  test('SignalGen round-trips through JSON', () {
    final g = SignalGen(
      id: 'g1', targetPath: 'ramp1.Ramp001', type: 'sine',
      minValue: 0, maxValue: 100, periodMs: 2000, phase: 0.25, enabled: true);
    final back = SignalGen.fromJson(g.toJson());
    expect(back.id, 'g1');
    expect(back.targetPath, 'ramp1.Ramp001');
    expect(back.type, 'sine');
    expect(back.minValue, 0);
    expect(back.maxValue, 100);
    expect(back.periodMs, 2000);
    expect(back.phase, 0.25);
    expect(back.enabled, isTrue);
  });

  test('PlcProject.signalGens defaults to empty and round-trips', () {
    final p = PlcProject(
      id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    expect(p.signalGens, isEmpty);
    p.signalGens.add(SignalGen(
      id: 'g1', targetPath: 'T', type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000, phase: 0, enabled: true));
    final back = PlcProject.fromJson(p.toJson());
    expect(back.signalGens.length, 1);
    expect(back.signalGens.first.type, 'ramp');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/signal_gen_test.dart`
Expected: FAIL — `signal_gen.dart` missing; `folder`/`signalGens` undefined.

- [ ] **Step 3: Create `signal_gen.dart`**

```dart
/// One always-on simulated signal driving a single tag. The engine
/// (`signal_engine.dart`) writes [targetPath] every scan; the tag is grouped
/// in the UI by its `PlcTag.folder`. Pure data.
class SignalGen {
  String id;
  String targetPath;
  String type; // ramp | sine | square | triangle | random | counter | toggle
  double minValue;
  double maxValue;
  int periodMs;
  double phase; // 0..1 fraction of the period
  bool enabled;

  SignalGen({
    required this.id,
    required this.targetPath,
    required this.type,
    required this.minValue,
    required this.maxValue,
    required this.periodMs,
    this.phase = 0,
    this.enabled = true,
  });

  factory SignalGen.fromJson(Map<String, dynamic> j) => SignalGen(
        id: j['id'] ?? '',
        targetPath: j['target_path'] ?? '',
        type: j['type'] ?? 'ramp',
        minValue: (j['min_value'] as num?)?.toDouble() ?? 0,
        maxValue: (j['max_value'] as num?)?.toDouble() ?? 0,
        periodMs: (j['period_ms'] as num?)?.toInt() ?? 1000,
        phase: (j['phase'] as num?)?.toDouble() ?? 0,
        enabled: j['enabled'] ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'target_path': targetPath,
        'type': type,
        'min_value': minValue,
        'max_value': maxValue,
        'period_ms': periodMs,
        'phase': phase,
        'enabled': enabled,
      };
}
```

- [ ] **Step 4: Add `folder` to `PlcTag` and `signalGens` to `PlcProject`**

In `project_model.dart`:
- Add `String folder;` to `PlcTag`; ctor param `this.folder = ''` (place it last, after `forcedValue`); in `fromJson` add `folder: json['folder'] ?? ''`; in `toJson` add `'folder': folder`.
- Import `signal_gen.dart`. Add `List<SignalGen> signalGens;` to `PlcProject`; ctor `List<SignalGen>? signalGens` with `: signalGens = signalGens ?? []` (fold into the existing initializer list alongside `simRules`); in `fromJson` add `signalGens: (proj['signal_gens'] as List? ?? []).map((g) => SignalGen.fromJson(g)).toList()`; in `toJson` add `'signal_gens': signalGens.map((g) => g.toJson()).toList()` inside the `'project'` map.

- [ ] **Step 5: Run tests**

Run: `flutter test test/models/signal_gen_test.dart` → PASS (3).
Run: `flutter test test/serialization_roundtrip_test.dart` → still green.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/signal_gen.dart mobile/lib/models/project_model.dart mobile/test/models/signal_gen_test.dart
git commit -m "feat(sim): PlcTag.folder + SignalGen model + PlcProject.signalGens (additive)"
```

---

### Task 2: Pure signal engine (`signal_engine.dart`)

**Files:**
- Create: `mobile/lib/models/signal_engine.dart`
- Test: `mobile/test/models/signal_engine_test.dart` (create)

**Interfaces:**
- Consumes: `SignalGen`, `PlcProject`, `writePath`/`readPath` (`tag_resolver.dart`).
- Produces:
  - `class SignalRuntime { int elapsedMs = 0; void reset(); }`
  - `Set<String> generatedPaths(List<SignalGen> gens)` — enabled gens' `targetPath`s.
  - `void applySignalGens(PlcProject p, List<SignalGen> gens, int dtMs, SignalRuntime rt)` — advances the clock and writes each enabled gen's value.
  - `double signalValueAt(SignalGen g, int elapsedMs)` — pure value for analog types (exposed for tests); the engine coerces `counter`→int and `toggle`→bool.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/signal_engine_test.dart`:

```dart
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';
import 'package:soft_plc_mobile/models/signal_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

SignalGen _g(String type, {double min = 0, double max = 100, int period = 1000, double phase = 0}) =>
    SignalGen(id: 't_$type', targetPath: 'V', type: type,
        minValue: min, maxValue: max, periodMs: period, phase: phase, enabled: true);

PlcProject _proj(String dataType, dynamic initial) {
  final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
  p.tags.add(PlcTag(name: 'V', path: 'V', dataType: dataType, value: initial, ioType: 'SimulatedOutput'));
  return p;
}

void main() {
  test('ramp is a linear sawtooth over the period', () {
    expect(signalValueAt(_g('ramp'), 0), closeTo(0, 1e-9));
    expect(signalValueAt(_g('ramp'), 250), closeTo(25, 1e-9));
    expect(signalValueAt(_g('ramp'), 500), closeTo(50, 1e-9));
    expect(signalValueAt(_g('ramp'), 999), closeTo(99.9, 1e-6));
  });

  test('sine spans min..max with midpoint at t=0', () {
    expect(signalValueAt(_g('sine'), 0), closeTo(50, 1e-9));      // 0.5*span
    expect(signalValueAt(_g('sine'), 250), closeTo(100, 1e-9));   // quarter -> max
    expect(signalValueAt(_g('sine'), 500), closeTo(50, 1e-9));    // half -> mid
    expect(signalValueAt(_g('sine'), 750), closeTo(0, 1e-9));     // 3/4 -> min
  });

  test('triangle rises 0->max over first half, falls over second', () {
    expect(signalValueAt(_g('triangle'), 0), closeTo(0, 1e-9));
    expect(signalValueAt(_g('triangle'), 500), closeTo(100, 1e-9));
    expect(signalValueAt(_g('triangle'), 1000 ~/ 4), closeTo(50, 1e-9));
  });

  test('square is min in the first half, max in the second', () {
    expect(signalValueAt(_g('square'), 100), 0);
    expect(signalValueAt(_g('square'), 600), 100);
  });

  test('phase shifts the waveform', () {
    // A ramp with phase 0.5 at t=0 equals a phase-0 ramp at half period.
    expect(signalValueAt(_g('ramp', phase: 0.5), 0), closeTo(50, 1e-9));
  });

  test('periodMs <= 0 holds at min', () {
    expect(signalValueAt(_g('ramp', period: 0), 500), 0);
  });

  test('applySignalGens writes the analog tag each tick', () {
    final p = _proj('FLOAT64', 0.0);
    final rt = SignalRuntime();
    applySignalGens(p, [_g('ramp')], 250, rt); // elapsed 250
    expect(readPath(p, 'V'), closeTo(25, 1e-9));
    applySignalGens(p, [_g('ramp')], 250, rt); // elapsed 500
    expect(readPath(p, 'V'), closeTo(50, 1e-9));
  });

  test('counter increments per period as an int and clamps to max', () {
    final p = _proj('INT32', 0);
    final rt = SignalRuntime();
    final g = _g('counter', min: 0, max: 3, period: 100);
    for (var i = 0; i < 5; i++) {
      applySignalGens(p, [g], 100, rt); // elapsed 100,200,...500
    }
    // floor(500/100)=5 -> clamp into [0,3].
    expect(readPath(p, 'V'), 3);
  });

  test('toggle flips BOOL each period', () {
    final p = _proj('BOOL', false);
    final rt = SignalRuntime();
    final g = _g('toggle', period: 100);
    applySignalGens(p, [g], 100, rt); // period 1 -> true
    expect(readPath(p, 'V'), true);
    applySignalGens(p, [g], 100, rt); // period 2 -> false
    expect(readPath(p, 'V'), false);
  });

  test('random is deterministic and in range', () {
    final a = _proj('FLOAT64', 0.0);
    final b = _proj('FLOAT64', 0.0);
    final ra = SignalRuntime();
    final rb = SignalRuntime();
    final g = _g('random', min: 10, max: 20, period: 100);
    for (var i = 0; i < 8; i++) {
      applySignalGens(a, [g], 100, ra);
      applySignalGens(b, [g], 100, rb);
    }
    expect(readPath(a, 'V'), readPath(b, 'V')); // reproducible
    expect(readPath(a, 'V'), inInclusiveRange(10, 20));
  });

  test('disabled gens do not write; generatedPaths lists only enabled targets', () {
    final p = _proj('FLOAT64', 7.0);
    final rt = SignalRuntime();
    final g = _g('ramp')..enabled = false;
    applySignalGens(p, [g], 500, rt);
    expect(readPath(p, 'V'), 7.0); // untouched
    expect(generatedPaths([g]), isEmpty);
    g.enabled = true;
    expect(generatedPaths([g]), {'V'});
  });

  test('reset zeroes the clock', () {
    final p = _proj('FLOAT64', 0.0);
    final rt = SignalRuntime();
    applySignalGens(p, [_g('ramp')], 500, rt);
    rt.reset();
    applySignalGens(p, [_g('ramp')], 250, rt);
    expect(readPath(p, 'V'), closeTo(25, 1e-9)); // clock restarted from 0
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/signal_engine_test.dart`
Expected: FAIL — `signal_engine.dart` missing.

- [ ] **Step 3: Implement `signal_engine.dart`**

```dart
import 'dart:math' as math;
import 'project_model.dart';
import 'signal_gen.dart';
import 'tag_resolver.dart';

/// Per-run-session signal clock. Reset at run-session boundaries.
class SignalRuntime {
  int elapsedMs = 0;
  void reset() {
    elapsedMs = 0;
  }
}

/// Enabled gens' target paths — the set the logic write path treats read-only.
Set<String> generatedPaths(List<SignalGen> gens) {
  final out = <String>{};
  for (final g in gens) {
    if (g.enabled) {
      out.add(g.targetPath);
    }
  }
  return out;
}

/// FNV-1a 32-bit hash (mirrors the WS14 noise PRNG seed in sim_engine.dart), so
/// `random` is reproducible without `Math.random`.
int _seed(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h == 0 ? 0x1a2b3c4d : h;
}

/// One xorshift32 step.
int _xorshift(int x) {
  x = (x ^ ((x << 13) & 0xffffffff)) & 0xffffffff;
  x = (x ^ (x >> 17)) & 0xffffffff;
  x = (x ^ ((x << 5) & 0xffffffff)) & 0xffffffff;
  return x & 0xffffffff;
}

/// Continuous analog waveform value for [g] at [elapsedMs], in [min,max].
/// (For `counter`/`toggle`/`random` the engine computes discrete values; this
/// covers ramp/sine/square/triangle and is the tested pure surface.)
double signalValueAt(SignalGen g, int elapsedMs) {
  if (g.periodMs <= 0) {
    return g.minValue;
  }
  final span = g.maxValue - g.minValue;
  final frac = (((elapsedMs / g.periodMs) + g.phase) % 1.0 + 1.0) % 1.0;
  switch (g.type) {
    case 'sine':
      return g.minValue + span * (0.5 + 0.5 * math.sin(2 * math.pi * frac));
    case 'square':
      return frac < 0.5 ? g.minValue : g.maxValue;
    case 'triangle':
      return g.minValue + span * (1.0 - (2.0 * frac - 1.0).abs());
    case 'ramp':
    default:
      return g.minValue + span * frac;
  }
}

/// Integer period index for counter/toggle/random: floor(t/period + phase).
int _periodIndex(SignalGen g, int elapsedMs) =>
    ((elapsedMs / g.periodMs) + g.phase).floor();

void applySignalGens(PlcProject p, List<SignalGen> gens, int dtMs, SignalRuntime rt) {
  rt.elapsedMs += dtMs;
  for (final g in gens) {
    if (!g.enabled) {
      continue;
    }
    dynamic value;
    if (g.type == 'counter') {
      if (g.periodMs <= 0) {
        value = g.minValue.round();
      } else {
        final lo = g.minValue.round();
        final hi = g.maxValue.round();
        final n = _periodIndex(g, rt.elapsedMs);
        value = (lo + n).clamp(lo, hi);
      }
    } else if (g.type == 'toggle') {
      final n = g.periodMs <= 0 ? 0 : _periodIndex(g, rt.elapsedMs);
      value = n.isOdd;
    } else if (g.type == 'random') {
      if (g.periodMs <= 0) {
        value = g.minValue;
      } else {
        final n = _periodIndex(g, rt.elapsedMs);
        final r = _xorshift(_seed('${g.id}#$n'));
        final u = r / 0xffffffff; // [0,1]
        value = g.minValue + (g.maxValue - g.minValue) * u;
      }
    } else {
      value = signalValueAt(g, rt.elapsedMs);
    }
    writePath(p, g.targetPath, value);
  }
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/signal_engine_test.dart` → PASS (all).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/signal_engine.dart mobile/test/models/signal_engine_test.dart
git commit -m "feat(sim): pure signal engine (ramp/sine/square/triangle/random/counter/toggle)"
```

---

## Phase B — Scan integration + hard read-only

### Task 3: Refuse logic writes to generated paths (four executors)

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart` (`executeLdPrograms` + the write closure)
- Modify: `mobile/lib/models/fbd_exec.dart` (`executeFbdPrograms` + the `_forceAwareWrite` call site)
- Modify: `mobile/lib/models/sfc_exec.dart` (`executeSfcPrograms` + the write closure)
- Modify: `mobile/lib/models/st_exec.dart` (`executeStPrograms` + the `_forceAwareWrite` call site)
- Test: `mobile/test/models/executor_readonly_test.dart` (create)

**Interfaces:**
- Produces: each `executeXxxPrograms(..., {Set<String>? only, Set<String>? readOnly})` — a write to a path in `readOnly` is skipped (reads unaffected). `readOnly == null` = no restriction (existing behavior).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/executor_readonly_test.dart` (ST is simplest to drive):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _p() {
  final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
  p.tags.add(PlcTag(name: 'Gen', path: 'Gen', dataType: 'FLOAT64', value: 5.0, ioType: 'SimulatedOutput'));
  p.tags.add(PlcTag(name: 'Out', path: 'Out', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
  // Reads Gen (a generated tag) into Out, and tries to overwrite Gen.
  p.programs.add(PlcProgram(name: 'P', language: 'StructuredText',
      stSource: 'Out := Gen;\nGen := 999.0;'));
  return p;
}

void main() {
  test('logic write to a read-only (generated) path is refused; read works', () {
    final p = _p();
    executeStPrograms(p, 100, StRuntime(), readOnly: {'Gen'});
    expect(readPath(p, 'Out'), 5.0);   // read succeeded
    expect(readPath(p, 'Gen'), 5.0);   // write refused (not 999)
  });

  test('without readOnly, the write goes through (unchanged behavior)', () {
    final p = _p();
    executeStPrograms(p, 100, StRuntime());
    expect(readPath(p, 'Gen'), 999.0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/executor_readonly_test.dart`
Expected: FAIL — `readOnly` param not defined.

- [ ] **Step 3: Add the `readOnly` gate to each executor**

Each executor already has an `only` param (WS scheduler) and a `_forceAwareWrite(p, path, value)` helper. Add `Set<String>? readOnly` to each `executeXxxPrograms` signature and guard every logic write:

- **`ld_exec.dart`** — the write closure passed to `executeRung` (line ~64):
  ```dart
  executeRung(p, prog.name, rung, dtMs, rt, (path, v) {
    if (readOnly != null && readOnly.contains(path)) {
      return;
    }
    _forceAwareWrite(p, path, v);
  });
  ```
- **`sfc_exec.dart`** — the closure passed to `runStatements` (line ~73): same guard wrapping `_forceAwareWrite`.
- **`fbd_exec.dart`** — the direct call (line ~448):
  ```dart
  if (readOnly == null || !readOnly.contains(b.tagBinding)) {
    _forceAwareWrite(p, b.tagBinding, v);
  }
  ```
- **`st_exec.dart`** — the direct call (line ~263):
  ```dart
  if (readOnly == null || !readOnly.contains(s.path)) {
    _forceAwareWrite(p, s.path, v);
  }
  ```

Keep the existing `only` parameter and behavior intact; add `readOnly` as a second optional named param.

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/executor_readonly_test.dart` → PASS (2).
Run: `flutter test test/models/` → existing executor + gating tests still pass.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/ld_exec.dart mobile/lib/models/fbd_exec.dart mobile/lib/models/sfc_exec.dart mobile/lib/models/st_exec.dart mobile/test/models/executor_readonly_test.dart
git commit -m "feat(exec): optional 'readOnly' path set — refuse logic writes to generated tags"
```

---

### Task 4: Run the signal engine in the scan tick

**Files:**
- Modify: `mobile/lib/screens/scan_tick.dart` (`ScanTickRuntime`, `runScanTick`)
- Test: `mobile/test/scan_signal_test.dart` (create)

**Interfaces:**
- Consumes: `applySignalGens`, `SignalRuntime`, `generatedPaths` (Task 2); executor `readOnly` param (Task 3).
- Produces: `ScanTickRuntime.signal` (`SignalRuntime`), reset in `resetSession()`; `runScanTick` advances generated tags before logic and passes `readOnly: generatedPaths(p.signalGens)` to all four executors.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/scan_signal_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

void main() {
  test('runScanTick advances a generated tag and logic cannot overwrite it', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    p.tags.add(PlcTag(name: 'Ramp', path: 'Ramp', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput'));
    p.tags.add(PlcTag(name: 'Copy', path: 'Copy', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    p.signalGens.add(SignalGen(id: 'g', targetPath: 'Ramp', type: 'ramp',
        minValue: 0, maxValue: 100, periodMs: 1000, phase: 0, enabled: true));
    p.programs.add(PlcProgram(name: 'P', language: 'StructuredText',
        stSource: 'Copy := Ramp;\nRamp := -1.0;'));
    p.tasks.add(PlcTask(name: 'Main', type: 'Continuous', programNames: ['P']));

    final rt = ScanTickRuntime();
    runScanTick(p, 250, rt); // elapsed 250 -> Ramp ~25
    expect(readPath(p, 'Ramp'), closeTo(25, 1e-9)); // generator wrote it, logic's -1 refused
    expect(readPath(p, 'Copy'), closeTo(25, 1e-9)); // logic read the fresh value

    rt.resetSession();
    runScanTick(p, 250, rt);
    expect(readPath(p, 'Ramp'), closeTo(25, 1e-9)); // clock restarted
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/scan_signal_test.dart`
Expected: FAIL — signal engine not wired into the tick.

- [ ] **Step 3: Wire it in**

In `scan_tick.dart`:
- Import `../models/signal_engine.dart` and `../models/signal_gen.dart`.
- Add `final SignalRuntime signal = SignalRuntime();` to `ScanTickRuntime`; in `resetSession()` add `signal.reset();`.
- In `runScanTick`, immediately after the `applySimRules(...)` call (before scheduling/executor dispatch), add:
  ```dart
  applySignalGens(p, p.signalGens, dtMs, rt.signal);
  final readOnly = generatedPaths(p.signalGens);
  ```
  and pass `readOnly: readOnly` into each of the four `executeXxxPrograms(...)` calls (alongside the existing `only:`).

- [ ] **Step 4: Run tests**

Run: `flutter test test/scan_signal_test.dart` → PASS.
Run: `flutter test test/scan_scheduling_test.dart` → still green.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/scan_tick.dart mobile/test/scan_signal_test.dart
git commit -m "feat(scan): drive signal generators each tick + gate logic writes to them"
```

---

## Phase C — Bulk builder + protocol map appenders

### Task 5: `test_tag_set.dart` — set builder + four map appenders

**Files:**
- Create: `mobile/lib/models/test_tag_set.dart`
- Test: `mobile/test/models/test_tag_set_test.dart` (create)

**Interfaces:**
- Consumes: `PlcTag`, `SignalGen`, the four map models (`OpcuaMap`/`OpcuaNode`, `ModbusMap`/`ModbusMapEntry`/`ModbusMap.regsForType`, `DnpMap`/`DnpMapEntry`, `MqttMap`/`MqttMapEntry`), `dataTypeOfPath`-style dataType lookup.
- Produces:
  - `class TestSetSpec { String folder; String baseName; int count; String type; double minValue; double maxValue; int periodMs; }`
  - `({List<PlcTag> tags, List<SignalGen> gens}) buildTestSet(TestSetSpec spec)` — `count` tags named `baseName + i` (1-based, zero-padded to the width of `count`), `folder` set, `ioType='SimulatedOutput'`, dataType by `type` (FLOAT64 / INT32 for counter / BOOL for toggle), value = the gen's `t=0` value; `count` `SignalGen`s with `phase = i/count` and `id = '<folder>/<name>'`.
  - `void appendToModbusMap(ModbusMap map, List<PlcTag> tags)` / `appendToDnpMap` / `appendToOpcuaMap` / `appendToMqttMap` — append read-only entries at the next free slot after existing entries; skip a tag the map can't represent; never duplicate a tag already mapped.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/test_tag_set_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/test_tag_set.dart';

void main() {
  test('buildTestSet produces N padded FLOAT64 tags + phase-staggered gens', () {
    final r = buildTestSet(TestSetSpec(
      folder: 'ramp1', baseName: 'Ramp', count: 3, type: 'ramp',
      minValue: 0, maxValue: 100, periodMs: 1000));
    expect(r.tags.map((t) => t.name), ['Ramp1', 'Ramp2', 'Ramp3']);
    expect(r.tags.every((t) => t.folder == 'ramp1'), isTrue);
    expect(r.tags.every((t) => t.ioType == 'SimulatedOutput'), isTrue);
    expect(r.tags.every((t) => t.dataType == 'FLOAT64'), isTrue);
    expect(r.gens.map((g) => g.phase), [0.0, closeTo(1 / 3, 1e-9), closeTo(2 / 3, 1e-9)]);
  });

  test('counter set is INT32, toggle set is BOOL', () {
    expect(buildTestSet(TestSetSpec(folder: 'f', baseName: 'C', count: 1, type: 'counter',
      minValue: 0, maxValue: 10, periodMs: 100)).tags.first.dataType, 'INT32');
    expect(buildTestSet(TestSetSpec(folder: 'f', baseName: 'B', count: 1, type: 'toggle',
      minValue: 0, maxValue: 1, periodMs: 100)).tags.first.dataType, 'BOOL');
  });

  test('names zero-pad to the width of count', () {
    final r = buildTestSet(TestSetSpec(folder: 'f', baseName: 'S', count: 100, type: 'sine',
      minValue: 0, maxValue: 1, periodMs: 1000));
    expect(r.tags.first.name, 'S001');
    expect(r.tags.last.name, 'S100');
  });

  test('appendToModbusMap adds input-table entries after existing ones, no collision', () {
    final map = ModbusMap(entries: [
      ModbusMapEntry(tag: 'Existing', table: 'input', address: 0, access: 'ReadOnly'),
    ]);
    final tags = buildTestSet(TestSetSpec(folder: 'r', baseName: 'R', count: 2, type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000)).tags;
    appendToModbusMap(map, tags);
    final added = map.entries.where((e) => e.tag.startsWith('R')).toList();
    expect(added.length, 2);
    // FLOAT64 -> input table, 4 regs each, starting after the existing FLOAT64 at 0..3.
    expect(added[0].address, 4);
    expect(added[1].address, 8);
    expect(added.every((e) => e.access == 'ReadOnly'), isTrue);
    expect(map.entries.first.address, 0); // existing untouched
  });

  test('appendToDnpMap continues the analogInput index space', () {
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'A', pointType: 'analogInput', index: 0),
      DnpMapEntry(tag: 'B', pointType: 'analogInput', index: 1),
    ]);
    final tags = buildTestSet(TestSetSpec(folder: 'r', baseName: 'R', count: 2, type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000)).tags;
    appendToDnpMap(map, tags);
    final added = map.entries.where((e) => e.tag.startsWith('R')).toList();
    expect(added.map((e) => e.index), [2, 3]);
  });

  test('appenders never duplicate an already-mapped tag', () {
    final tags = buildTestSet(TestSetSpec(folder: 'r', baseName: 'R', count: 1, type: 'ramp',
      minValue: 0, maxValue: 1, periodMs: 1000)).tags;
    final map = MqttMap(entries: [MqttMapEntry(tag: 'R1', metric: 'R1')]);
    appendToMqttMap(map, tags);
    expect(map.entries.where((e) => e.tag == 'R1').length, 1);
  });
}
```

> The implementer must read the four map models for exact constructor/field names and `ModbusMap.regsForType` before writing the appenders, and adjust the fixtures if a constructor differs — keeping the asserted behavior identical.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/test_tag_set_test.dart`
Expected: FAIL — `test_tag_set.dart` missing.

- [ ] **Step 3: Implement `test_tag_set.dart`**

Implement `TestSetSpec`, `buildTestSet`, and the four appenders per the interfaces above. Key rules:
- dataType: `counter` → `INT32`; `toggle` → `BOOL`; else `FLOAT64`.
- Name width = `count.toString().length` (min 1); names are 1-based (`baseName + (i+1).padLeft(width,'0')`).
- initial value = the gen's `t=0` value (`signalValueAt` for analog / coerced for counter=min, toggle=false).
- `gens[i].phase = i / count`; `gens[i].id = '$folder/$name'`; `enabled = true`.
- **Modbus appender:** compute `nextAddr` per table by scanning existing entries — for each existing entry, end = `address + (bit table ? 1 : regsForType(dataType-of-that-tag))`; `nextAddr[table] = max(end)`. Since appended tags' dataType is known from the built `PlcTag`s, BOOL → `discrete`, numeric → `input`, advancing by 1 / `regsForType`. (For existing entries whose tag dataType isn't resolvable from the map alone, advance by a safe `1` for bit tables / `regsForType` requires the dataType; if unavailable, treat register entries as occupying `regsForType('FLOAT64')`=4 to avoid overlap — the implementer resolves this by taking `max(address)+worstCaseSize` conservatively so no overlap is possible. Document the choice.)
- **DNP appender:** `nextIndex[pointType] = max(existing index for that type) + 1` (or 0); BOOL → `binaryInput`, numeric → `analogInput`.
- **OPC UA appender:** append `OpcuaNode(nodeId: 'ns=1;s=${tag.path}', tag: tag.name, access: 'ReadOnly')`.
- **MQTT appender:** append `MqttMapEntry(tag: tag.name, metric: tag.name)`.
- All appenders: skip a tag whose `tag` name is already present in the map (no duplicate); skip unrepresentable tags matching each map's existing auto-generate skip rules (e.g. Modbus skips composite/STRING/TIMER/COUNTER).

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/test_tag_set_test.dart` → PASS.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/test_tag_set.dart mobile/test/models/test_tag_set_test.dart
git commit -m "feat(sim): test-set builder + next-free protocol map appenders"
```

---

## Phase D — Generate-Test-Set dialog + Memory Manager folder grouping

### Task 6: Generate-Test-Set dialog, folder grouping, delete-set

**Files:**
- Modify: `mobile/lib/screens/memory_manager_screen.dart`
- Test: `mobile/test/widgets/test_tag_set_ui_test.dart` (create)

**Interfaces:**
- Consumes: `buildTestSet` + appenders (Task 5); the project's `protocols` config (which protocols exist/enabled); `isTaskNameTaken`-style tag-name collision check.
- Produces: a "Generate Test Set" action that adds a set to the project and appends to the ticked protocol maps; folder-grouped tag list; delete-folder that removes the folder's tags + their `SignalGen`s + their entries in all four maps. Provide `@visibleForTesting` hooks mirroring the save/delete paths so the test can drive them without dialog plumbing (e.g. `debugGenerateTestSet(TestSetSpec, {bool opcua, modbus, dnp3, mqtt})` and `debugDeleteFolder(String folder)`), returning the created/removed counts.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/test_tag_set_ui_test.dart` driving the state hooks:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/test_tag_set.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';

void main() {
  testWidgets('generate + delete a test set updates tags, gens, and maps', (tester) async {
    final proj = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    await tester.pumpWidget(MaterialApp(
      home: MemoryManagerScreen(currentProject: proj, onProjectUpdated: () {}),
    ));
    await tester.pumpAndSettle();
    final state = tester.state<MemoryManagerScreenState>(find.byType(MemoryManagerScreen));

    state.debugGenerateTestSet(
      TestSetSpec(folder: 'ramp1', baseName: 'R', count: 5, type: 'ramp',
        minValue: 0, maxValue: 100, periodMs: 1000),
      opcua: true, modbus: false, dnp3: false, mqtt: false);
    expect(proj.tags.where((t) => t.folder == 'ramp1').length, 5);
    expect(proj.signalGens.length, 5);

    state.debugDeleteFolder('ramp1');
    expect(proj.tags.where((t) => t.folder == 'ramp1'), isEmpty);
    expect(proj.signalGens, isEmpty);
  });
}
```

> If `MemoryManagerScreen`'s State is private, the implementer makes it public `MemoryManagerScreenState` (or adds a test accessor) and adds the two `@visibleForTesting` hooks. Read the screen's existing constructor/params first.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/test_tag_set_ui_test.dart`
Expected: FAIL — hooks/screen state not available.

- [ ] **Step 3: Implement**

- Add a **Generate Test Set** button to the Memory Manager. Its dialog collects: folder name, base name, count, signal type (dropdown of the seven), min, max, period (ms), and a checkbox per protocol **that exists in `project.protocols`**. On save: reject if the folder is empty or any generated tag name collides with an existing tag (SnackBar), else `buildTestSet(spec)`, add tags + gens to the project, and for each ticked protocol call the matching appender on that protocol's `map`; then `onProjectUpdated()`.
- Factor the save into `debugGenerateTestSet(TestSetSpec spec, {required bool opcua, modbus, dnp3, mqtt})` shared by the dialog and the test.
- **Folder grouping:** render the tag list grouped by `folder` (root first, then folders alphabetically), each folder a collapsible header showing its count and a delete affordance.
- `debugDeleteFolder(String folder)` (shared with the delete affordance): remove all `tags` with that folder, remove `signalGens` whose `targetPath` is one of those tags, and remove those tags from all four protocol maps' entries; `onProjectUpdated()`.
- Guard layout for 320/360 (Expanded/ellipsis; dialog fields vertical in a SingleChildScrollView).

- [ ] **Step 4: Run tests**

Run: `flutter test test/widgets/test_tag_set_ui_test.dart` → PASS.
Run: `flutter test` + `flutter analyze` → green / no issues.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/memory_manager_screen.dart mobile/test/widgets/test_tag_set_ui_test.dart
git commit -m "feat(sim): Generate Test Set dialog + folder grouping + delete-set in Memory Manager"
```

---

## Phase E — Outbound map-view folder grouping

### Task 7: Group each protocol's map rows by folder

**Files:**
- Modify: `mobile/lib/screens/gateway_screen.dart`
- Test: `mobile/test/widgets/gateway_folder_grouping_test.dart` (create)

**Interfaces:**
- Consumes: each protocol map's entries + the project's tags (to resolve each entry's tag → `folder`).
- Produces: each protocol's map list is visually grouped by the mapped tag's folder (root first). A small pure helper `Map<String, List<T>> groupEntriesByFolder<T>(List<T> entries, String Function(T) tagOf, PlcProject p)` factored for testing.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/gateway_folder_grouping_test.dart` testing the pure grouping helper:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';

void main() {
  test('groupEntriesByFolder buckets entries by their tag folder, root first', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [
          PlcTag(name: 'Root1', path: 'Root1', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'R1', path: 'R1', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: 'ramp1'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: []);
    final entries = [
      ModbusMapEntry(tag: 'R1', table: 'input', address: 0, access: 'ReadOnly'),
      ModbusMapEntry(tag: 'Root1', table: 'discrete', address: 0, access: 'ReadOnly'),
    ];
    final grouped = groupEntriesByFolder<ModbusMapEntry>(entries, (e) => e.tag, p);
    expect(grouped.keys.first, ''); // root first
    expect(grouped['']!.single.tag, 'Root1');
    expect(grouped['ramp1']!.single.tag, 'R1');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/gateway_folder_grouping_test.dart`
Expected: FAIL — `groupEntriesByFolder` missing.

- [ ] **Step 3: Implement**

Add the pure `groupEntriesByFolder` top-level helper to `gateway_screen.dart` (or a small helper file it imports): resolve each entry's tag → `PlcTag.folder` (default `''` when the tag isn't found), bucket into a `LinkedHashMap` with `''` (root) first then folders alphabetically. Use it to render each protocol's map list with folder subheaders. Keep existing per-row editing intact.

- [ ] **Step 4: Run tests**

Run: `flutter test test/widgets/gateway_folder_grouping_test.dart` → PASS.
Run: `flutter test` + `flutter analyze` → green / no issues.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/gateway_screen.dart mobile/test/widgets/gateway_folder_grouping_test.dart
git commit -m "feat(sim): group outbound protocol map rows by tag folder"
```

---

## Phase F — Validation, docs, E2E, final review

### Task 8: Whole-workstream validation + docs + E2E

**Files:**
- Create: `docs/simulated-test-tags.md`
- Modify: `ROADMAP.md`
- Modify (E2E, optional leg): `gateway/examples/` probe + `tool/*_e2e.sh` for one protocol
- Test: full suite

- [ ] **Step 1: Full green gate**

From `mobile/`: `flutter test` (report count, all green); `flutter analyze` (**No issues found!**); `flutter build web --release` (compiles). Fix any code-caused failure; document any purely-environmental failure.

- [ ] **Step 2: Round-trip guard**

Confirm the WS6 serialization round-trip still passes and that `PlcTag.folder` + `PlcProject.signalGens` survive `toJson`→`fromJson`. If the guard is field-driven, add assertions for the two new fields.

- [ ] **Step 3: Manual responsive check**

No RenderFlex overflow at 320 / 360 / 1400 on: the Generate-Test-Set dialog, the folder-grouped Memory Manager list, and a folder-grouped protocol map view.

- [ ] **Step 4: Machine-proof E2E (one protocol)**

Extend one existing Rust-client probe (e.g. Modbus `tool/modbus_e2e.sh` or the OPC UA probe): generate a small ramp/sine set mapped into that protocol, run the real client, and assert the values move / are distinct across two reads. Preserve the existing honest build+unit fallback. If the live client can't run in this environment, document the fallback result honestly.

- [ ] **Step 5: Docs + ROADMAP + commit**

Write `docs/simulated-test-tags.md` (folders; the seven signal types + formulas; phase-staggering; read-only-in-programs + read-only-on-wire; per-protocol auto-map; delete-set) — no vendor branding. Add a ROADMAP entry. Commit.

```bash
git add docs/simulated-test-tags.md ROADMAP.md
git commit -m "docs(sim): simulated test-tags reference; ROADMAP"
```

- [ ] **Step 6: Final whole-branch review**

Dispatch the final code review (opus) over the branch diff; fix Critical/Important findings; then finish the branch (merge `--no-ff` + push) per finishing-a-development-branch.

---

## Self-Review notes (author)

- **Spec coverage:** folder model (T1) · SignalGen + signalGens (T1) · seven waveforms incl. phase/period-guard/random-determinism (T2) · scan integration + clock reset (T4) · hard read-only in programs (T3, wired T4) · protocol auto-map with next-free allocation + no-duplicate (T5) · per-protocol checkboxes + bulk create + folder grouping + delete-set (T6) · map-view folder grouping (T7) · persistence round-trip, E2E, docs (T8). All spec sections mapped.
- **Type consistency:** `SignalGen`/`SignalRuntime`/`generatedPaths`/`applySignalGens`/`signalValueAt` identical across T2/T4; executor `readOnly` param identical across T3/T4; `buildTestSet`/`TestSetSpec`/`appendTo*Map` identical across T5/T6; `groupEntriesByFolder` T7. `PlcTag.folder` + `PlcProject.signalGens` from T1 used throughout.
- **Ordering:** A(1–2) → B(3–4) → C(5) → D(6) → E(7) → F(8). Read-only executor param (T3) lands before the scan wires it (T4); the builder/appenders (T5) land before the UI uses them (T6).
