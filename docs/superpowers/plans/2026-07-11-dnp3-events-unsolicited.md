# DNP3 Events + Unsolicited Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the shipped static-only DNP3 outstation into a full event-reporting outstation: input changes assigned to Class 1/2/3 are captured into per-class event buffers and delivered by solicited Class 1/2/3 polls or unsolicited push (with the DNP3 application CONFIRM handshake + bounded retry).

**Architecture:** A new pure `dnp3_events.dart` engine holds per-class bounded event ring buffers and does force-aware change detection. `dnp3_app.dart` gains event-object encoders (g2v2/g32v3/g32v7, 48-bit DNP time), the new function codes (CONFIRM=0, ENABLE_UNSOLICITED=20, DISABLE_UNSOLICITED=21, UNSOLICITED_RESPONSE=130), and IIN class-available/overflow bits. `dnp3_outstation.dart` owns the engine + unsolicited state (per-class enabled flags, unsolicited sequence, in-flight tracking) and routes solicited Class reads (events + CON + flush-on-CONFIRM), ENABLE/DISABLE, and CONFIRM. `dnp3_host.dart` (the only `dart:io` file) adds a periodic change-detection tick that drives unsolicited push + CONFIRM-wait/retry. The UI gets a per-input-point event-Class dropdown. A Rust `dnp3` master proves it end to end.

**Tech Stack:** Dart/Flutter (`mobile/`), pure-Dart protocol layer, `dart:typed_data` `ByteData` LE accessors, Rust `dnp3` crate (`gateway/examples/dnp3_probe.rs`) for the machine-proof E2E.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix") anywhere; DNP3/IEEE 1815 terms are fine.
- Zero `flutter analyze` warnings project-wide (`cd mobile && flutter analyze` → "No issues found!").
- `mobile/lib/protocols/dnp3/**` stays PURE Dart — no `dart:io`, no Flutter imports. Only `mobile/lib/services/dnp3_host.dart` imports `dart:io`. The outstation never throws on malformed input (every entry point guarded → IIN-flagged or dropped, never an uncaught exception).
- Little-endian wire. 48-bit DNP3 time via 32-bit + 16-bit accessors computed with arithmetic (`% 0x100000000`, `~/ 0x100000000`) — NEVER `getInt64`/`setInt64` (unimplemented under dart2js) and NEVER a raw `>> 32` bit-shift (dart2js bitwise ops are 32-bit and silently truncate).
- Events are force-aware: the captured value is the forced value when a tag is forced (`readPath` already resolves this).
- Additive persistence only: every new field defaults so older saved projects round-trip unchanged; the WS6 lossless round-trip test stays green; the app is byte-identical on the wire when hosting is stopped.
- Unsolicited is OFF until a master enables it (DNP3 default) — an existing static-only setup behaves exactly as before.
- No RenderFlex overflow at widths 320 / 360 / 1400; dark theme; always brace control-flow bodies; prefer `const`; use `withValues(alpha:)` (never the deprecated `withOpacity`).
- Only `binaryInput` and `analogInput` points generate events (outputs report status via static reads; output-event objects are out of scope).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `mobile/lib/models/dnp3_map.dart` | MODIFY | `DnpMapEntry.eventClass` (int, default 0); `autoGenerate` sets 0. |
| `mobile/lib/models/protocol_settings.dart` | MODIFY | `DnpProtocolConfig.unsolConfirmTimeoutMs`/`unsolMaxRetries`/`eventBufferPerClass` (additive). |
| `mobile/lib/protocols/dnp3/dnp3_events.dart` | CREATE | Pure event engine: `DnpEvent`, `DnpEventEngine` (per-class ring buffers, change detection, pull/flush, overflow). |
| `mobile/lib/protocols/dnp3/dnp3_app.dart` | MODIFY | Event-object encoders g2v2/g32v3/g32v7 + 48-bit time; new func codes + IIN bits; `buildUnsolicitedResponse`; `dnpClassOfG60Variation`. |
| `mobile/lib/protocols/dnp3/dnp3_outstation.dart` | MODIFY | Owns engine + unsolicited state; solicited Class reads (CON + flush-on-CONFIRM); ENABLE/DISABLE; CONFIRM routing; IIN bits; host-facing unsolicited push API. |
| `mobile/lib/services/dnp3_host.dart` | MODIFY | Periodic change-detection tick; unsolicited push + CONFIRM-wait/retry; skip empty (CONFIRM) responses. |
| `mobile/lib/screens/gateway_screen.dart` | MODIFY | Per-input-point event-Class dropdown; unsolicited-state indicator. |
| `gateway/examples/dnp3_probe.rs` + `tool/dnp3_e2e.sh` | MODIFY | Rust `dnp3` master: Class 1/2/3 poll + unsolicited enable/confirm assertions. |
| `docs/protocols/DNP3.md`, `docs/ROADMAP.md` (or equivalent) | MODIFY | Document the events layer. |

---

## Task 1: Config + event Class (additive model fields)

**Files:**
- Modify: `mobile/lib/models/dnp3_map.dart` (`DnpMapEntry`, `DnpMap.autoGenerate`)
- Modify: `mobile/lib/models/protocol_settings.dart` (`DnpProtocolConfig`)
- Test: `mobile/test/dnp3_map_test.dart` (extend if present, else create), `mobile/test/protocol_settings_test.dart`

**Interfaces:**
- Produces: `DnpMapEntry.eventClass` (`int`, 0–3, default 0); `DnpProtocolConfig.unsolConfirmTimeoutMs` (`int`, default 5000), `DnpProtocolConfig.unsolMaxRetries` (`int`, default 3), `DnpProtocolConfig.eventBufferPerClass` (`int`, default 200). All later tasks read these.

- [ ] **Step 1: Write the failing round-trip test for `eventClass`**

Add to `mobile/test/protocol_settings_test.dart` (or `dnp3_map_test.dart`):

```dart
test('DnpMapEntry carries eventClass and round-trips; older JSON defaults to 0', () {
  final e = DnpMapEntry(tag: 'Level', pointType: 'analogInput', index: 3, eventClass: 2);
  final round = DnpMapEntry.fromJson(e.toJson());
  expect(round.eventClass, 2);
  // Back-compat: JSON without event_class defaults to 0 (static-only).
  final legacy = DnpMapEntry.fromJson({'tag': 'X', 'point_type': 'binaryInput', 'index': 0});
  expect(legacy.eventClass, 0);
});

test('DnpProtocolConfig carries unsol/buffer fields and defaults them', () {
  final c = DnpProtocolConfig(
    map: DnpMap(entries: []),
    unsolConfirmTimeoutMs: 7000,
    unsolMaxRetries: 5,
    eventBufferPerClass: 50,
  );
  final round = DnpProtocolConfig.fromJson(c.toJson());
  expect(round.unsolConfirmTimeoutMs, 7000);
  expect(round.unsolMaxRetries, 5);
  expect(round.eventBufferPerClass, 50);
  // Legacy JSON (no new keys) falls back to spec defaults.
  final legacy = DnpProtocolConfig.fromJson({'enabled': true, 'port': 20000});
  expect(legacy.unsolConfirmTimeoutMs, 5000);
  expect(legacy.unsolMaxRetries, 3);
  expect(legacy.eventBufferPerClass, 200);
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd mobile && flutter test test/protocol_settings_test.dart`
Expected: FAIL — `eventClass`/`unsolConfirmTimeoutMs`/`unsolMaxRetries`/`eventBufferPerClass` are undefined named parameters.

- [ ] **Step 3: Add `eventClass` to `DnpMapEntry`**

In `mobile/lib/models/dnp3_map.dart`, extend `DnpMapEntry`:

```dart
class DnpMapEntry {
  String tag;
  String pointType;
  int index;

  /// DNP3 event class assignment for INPUT points: 0 = static-only (no
  /// events, the default and back-compat behavior), 1/2/3 = this point's
  /// changes are captured into event Class 1/2/3. Meaningful only for
  /// `binaryInput`/`analogInput`; ignored for output point types.
  int eventClass;

  DnpMapEntry({
    required this.tag,
    required this.pointType,
    required this.index,
    this.eventClass = 0,
  });

  factory DnpMapEntry.fromJson(Map<String, dynamic> json) => DnpMapEntry(
        tag: json['tag']?.toString() ?? '',
        pointType: json['point_type']?.toString() ?? 'binaryInput',
        index: (json['index'] as num?)?.toInt() ?? 0,
        eventClass: (json['event_class'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'point_type': pointType,
        'index': index,
        'event_class': eventClass,
      };
}
```

In `DnpMap.autoGenerate`, the `entries.add(...)` call sets `eventClass` explicitly to 0 (back-compat: static-only until the user assigns classes):

```dart
      entries.add(DnpMapEntry(
        tag: tag.name,
        pointType: pointType,
        index: index,
        eventClass: 0,
      ));
```

- [ ] **Step 4: Add the unsol/buffer fields to `DnpProtocolConfig`**

In `mobile/lib/models/protocol_settings.dart`, extend `DnpProtocolConfig` (keep the existing fields; add the three new ones with defaults, wire `fromJson`/`toJson`/`defaults`):

```dart
class DnpProtocolConfig {
  bool enabled;
  int port;
  int outstationAddress;
  int masterAddress;
  DnpMap map;

  /// Unsolicited CONFIRM-wait timeout (ms) before a retry. DNP3 default 5000.
  int unsolConfirmTimeoutMs;

  /// Max unsolicited retries before giving up (events stay buffered). Default 3.
  int unsolMaxRetries;

  /// Per-class event ring-buffer capacity; oldest dropped + overflow flagged
  /// when full. Default 200.
  int eventBufferPerClass;

  DnpProtocolConfig({
    this.enabled = false,
    this.port = 20000,
    this.outstationAddress = 1024,
    this.masterAddress = 1,
    required this.map,
    this.unsolConfirmTimeoutMs = 5000,
    this.unsolMaxRetries = 3,
    this.eventBufferPerClass = 200,
  });

  factory DnpProtocolConfig.fromJson(Map<String, dynamic> j) => DnpProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 20000,
        outstationAddress: (j['outstation_address'] as num?)?.toInt() ?? 1024,
        masterAddress: (j['master_address'] as num?)?.toInt() ?? 1,
        map: j['map'] != null
            ? DnpMap.fromJson(j['map'] as Map<String, dynamic>)
            : DnpMap(entries: []),
        unsolConfirmTimeoutMs: (j['unsol_confirm_timeout_ms'] as num?)?.toInt() ?? 5000,
        unsolMaxRetries: (j['unsol_max_retries'] as num?)?.toInt() ?? 3,
        eventBufferPerClass: (j['event_buffer_per_class'] as num?)?.toInt() ?? 200,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'outstation_address': outstationAddress,
        'master_address': masterAddress,
        'map': map.toJson(),
        'unsol_confirm_timeout_ms': unsolConfirmTimeoutMs,
        'unsol_max_retries': unsolMaxRetries,
        'event_buffer_per_class': eventBufferPerClass,
      };

  static DnpProtocolConfig defaults(PlcProject p) => DnpProtocolConfig(
        enabled: false,
        port: 20000,
        outstationAddress: 1024,
        masterAddress: 1,
        map: DnpMap.autoGenerate(p),
        unsolConfirmTimeoutMs: 5000,
        unsolMaxRetries: 3,
        eventBufferPerClass: 200,
      );
}
```

- [ ] **Step 5: Run the tests — expect PASS**

Run: `cd mobile && flutter test test/protocol_settings_test.dart test/dnp3_map_test.dart`
Expected: PASS. Then run the WS6 round-trip guard to confirm additive persistence stays lossless:
Run: `cd mobile && flutter test test/project_persistence_test.dart` (or the test file that asserts full project round-trip — grep `roundtrip`/`lossless` under `mobile/test` to find it).
Expected: PASS.

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues found.

```bash
git add mobile/lib/models/dnp3_map.dart mobile/lib/models/protocol_settings.dart mobile/test/
git commit -m "feat(dnp3): event Class on map entries + unsol/buffer config (additive)"
```

---

## Task 2: Event engine (`dnp3_events.dart`)

**Files:**
- Create: `mobile/lib/protocols/dnp3/dnp3_events.dart`
- Test: `mobile/test/dnp3_events_test.dart`

**Interfaces:**
- Consumes: `DnpMap`/`DnpMapEntry` (Task 1, incl. `eventClass`); `PlcProject`; `readPath`/`dataTypeOfPath` from `../../models/tag_resolver.dart`.
- Produces:
  - `class DnpEvent { final String pointType; final int index; final int eventClass; final bool isBinary; final bool isFloat; final bool boolValue; final int intValue; final double floatValue; final int flags; final int timeMs; }`
  - `class DnpEventEngine`:
    - `DnpEventEngine({int capacityPerClass = 200})`
    - `void detectChanges(PlcProject project, DnpMap map, int nowMs)`
    - `List<DnpEvent> pull(Set<int> classes)` — snapshot (does NOT remove) of buffered events for the given classes, FIFO, class 1 then 2 then 3.
    - `void flush(List<DnpEvent> confirmed)` — remove exactly the given event instances (by identity) from their buffers.
    - `bool hasEventsForClass(int cls)`; `bool get hasAnyEvents`
    - `Set<int> get classesWithEvents` — subset of {1,2,3} with a non-empty buffer.
    - `bool get overflowed`; `void clearOverflow()`
    - `int countForClass(int cls)` (for UI/tests)

- [ ] **Step 1: Write failing engine tests**

Create `mobile/test/dnp3_events_test.dart`. Use a small in-memory `PlcProject` helper (mirror how `dnp3_outstation_test.dart` builds its project — grep that file for the existing test project builder and reuse the same helper/pattern so tag types + `readPath` resolve identically). Tests:

```dart
// A Class-1 binary input change appends exactly one binary event.
test('class 1 binary change -> one g2-style event', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
  ]);
  final eng = DnpEventEngine(capacityPerClass: 200);
  eng.detectChanges(project, map, 1000); // baseline, no event
  expect(eng.hasAnyEvents, isFalse);
  setTag(project, 'Run', true);
  eng.detectChanges(project, map, 2000);
  final events = eng.pull({1});
  expect(events.length, 1);
  expect(events.single.isBinary, isTrue);
  expect(events.single.boolValue, isTrue);
  expect(events.single.index, 0);
  expect(events.single.eventClass, 1);
  expect(events.single.timeMs, 2000);
});

// A Class-2 analog change appends a g32 event with the new value.
test('class 2 analog change -> analog event with value + time', () {
  final project = buildProject({'Level': ('FLOAT64', 'SimulatedInput', 1.0)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Level', pointType: 'analogInput', index: 5, eventClass: 2),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0);
  setTag(project, 'Level', 42.5);
  eng.detectChanges(project, map, 12345);
  final events = eng.pull({2});
  expect(events.length, 1);
  expect(events.single.isBinary, isFalse);
  expect(events.single.isFloat, isTrue);
  expect(events.single.floatValue, 42.5);
  expect(events.single.index, 5);
  expect(events.single.timeMs, 12345);
});

// Class 0 (default) points never generate events.
test('class 0 point generates no events', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 0),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0);
  setTag(project, 'Run', true);
  eng.detectChanges(project, map, 1000);
  expect(eng.hasAnyEvents, isFalse);
});

// Buffer caps at capacity, dropping oldest and flagging overflow.
test('ring buffer caps at capacity and flags overflow', () {
  final project = buildProject({'N': ('INT32', 'SimulatedInput', 0)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'N', pointType: 'analogInput', index: 0, eventClass: 1),
  ]);
  final eng = DnpEventEngine(capacityPerClass: 3);
  eng.detectChanges(project, map, 0);
  for (var v = 1; v <= 5; v++) {
    setTag(project, 'N', v);
    eng.detectChanges(project, map, v);
  }
  final events = eng.pull({1});
  expect(events.length, 3); // capped
  expect(events.first.intValue, 3); // oldest two (1,2) dropped
  expect(events.last.intValue, 5);
  expect(eng.overflowed, isTrue);
});

// pull() is a snapshot; flush(confirmed) removes only those, newer stay.
test('flush removes confirmed events only', () {
  final project = buildProject({'N': ('INT32', 'SimulatedInput', 0)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'N', pointType: 'analogInput', index: 0, eventClass: 1),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0);
  setTag(project, 'N', 1);
  eng.detectChanges(project, map, 1);
  final first = eng.pull({1});
  expect(first.length, 1);
  setTag(project, 'N', 2); // new event arrives after the pull
  eng.detectChanges(project, map, 2);
  eng.flush(first); // confirm only the first
  final remaining = eng.pull({1});
  expect(remaining.length, 1);
  expect(remaining.single.intValue, 2);
});

// Force-aware: a forced input's forced value is what gets captured.
test('forced input captures forced value', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0);
  forceTag(project, 'Run', true); // force overrides the live value
  eng.detectChanges(project, map, 1000);
  expect(eng.pull({1}).single.boolValue, isTrue);
});
```

> The `buildProject`/`setTag`/`forceTag` helpers must produce tags whose `readPath` returns the right value and whose `dataTypeOfPath` returns the declared type. Reuse the exact helper `dnp3_outstation_test.dart` already uses (grep it); if it lives inline there, lift it into a shared `test/dnp3_test_support.dart` and import it from both files in this task.

- [ ] **Step 2: Run to confirm failure**

Run: `cd mobile && flutter test test/dnp3_events_test.dart`
Expected: FAIL — `dnp3_events.dart` does not exist.

- [ ] **Step 3: Implement `dnp3_events.dart`**

```dart
// Pure Dart DNP3 event engine (DNP3 events + unsolicited workstream, Task 2).
// No dart:io / Flutter imports. Holds per-class (1/2/3) bounded event ring
// buffers and performs force-aware change detection over a project's DnpMap:
// each tick, every Class-1/2/3 binaryInput/analogInput point's current value
// (via readPath — forced values win) is compared to its last-reported value;
// on change an event is appended to that class's buffer. Static-only (Class 0)
// points never generate events. The buffer is bounded: when full, the oldest
// event is dropped and an overflow flag is raised (surfaced as IIN2.3 by the
// outstation). pull() returns a snapshot; flush() removes confirmed events by
// identity — so events survive until a master CONFIRMs them.
library dnp3_events;

import '../../models/dnp3_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';

/// One captured input-point change. `isBinary` selects g2v2 (binary) vs the
/// analog g32 family; for analog, `isFloat` selects g32v7 (float, value in
/// [floatValue]) vs g32v3 (32-bit int, value in [intValue]).
class DnpEvent {
  final String pointType; // 'binaryInput' | 'analogInput'
  final int index;
  final int eventClass; // 1 | 2 | 3
  final bool isBinary;
  final bool isFloat;
  final bool boolValue;
  final int intValue;
  final double floatValue;
  final int flags; // DnpFlags bits (ONLINE etc.)
  final int timeMs; // wall-clock UTC ms (host supplies)

  DnpEvent({
    required this.pointType,
    required this.index,
    required this.eventClass,
    required this.isBinary,
    required this.isFloat,
    required this.boolValue,
    required this.intValue,
    required this.floatValue,
    required this.flags,
    required this.timeMs,
  });
}

class DnpEventEngine {
  final int capacityPerClass;

  // Class 1/2/3 buffers, FIFO (oldest first).
  final Map<int, List<DnpEvent>> _buffers = {
    1: <DnpEvent>[],
    2: <DnpEvent>[],
    3: <DnpEvent>[],
  };

  // Last-reported value per point key ('pointType#index'); establishes the
  // change-detection baseline. A key present here has a baseline; a key absent
  // has never been seen (first detect records baseline, emits no event).
  final Map<String, Object?> _lastReported = {};

  bool _overflowed = false;

  DnpEventEngine({this.capacityPerClass = 200});

  bool get overflowed => _overflowed;
  void clearOverflow() => _overflowed = false;

  bool get hasAnyEvents => _buffers.values.any((b) => b.isNotEmpty);
  bool hasEventsForClass(int cls) => (_buffers[cls]?.isNotEmpty) ?? false;
  int countForClass(int cls) => _buffers[cls]?.length ?? 0;

  Set<int> get classesWithEvents =>
      {for (final c in const [1, 2, 3]) if (hasEventsForClass(c)) c};

  /// Snapshot (does NOT remove) of buffered events for [classes], class 1
  /// then 2 then 3, FIFO within each class.
  List<DnpEvent> pull(Set<int> classes) {
    final out = <DnpEvent>[];
    for (final c in const [1, 2, 3]) {
      if (classes.contains(c)) {
        out.addAll(_buffers[c] ?? const <DnpEvent>[]);
      }
    }
    return out;
  }

  /// Removes exactly the [confirmed] event instances (identity match) from
  /// their class buffers. Events not present are ignored.
  void flush(List<DnpEvent> confirmed) {
    final set = Set<DnpEvent>.identity()..addAll(confirmed);
    for (final b in _buffers.values) {
      b.removeWhere(set.contains);
    }
  }

  /// One change-detection pass. Only `binaryInput`/`analogInput` entries with
  /// `eventClass` in {1,2,3} participate; the first time a point is seen its
  /// baseline is recorded WITHOUT emitting an event (so startup does not
  /// flood). Thereafter any value change emits one event into that class.
  void detectChanges(PlcProject project, DnpMap map, int nowMs) {
    for (final e in map.entries) {
      final cls = e.eventClass;
      if (cls < 1 || cls > 3) {
        continue;
      }
      final isBinary = e.pointType == 'binaryInput';
      final isAnalog = e.pointType == 'analogInput';
      if (!isBinary && !isAnalog) {
        continue; // outputs don't generate events
      }
      final key = '${e.pointType}#${e.index}';
      final raw = readPath(project, e.tag);

      if (isBinary) {
        final v = raw == true;
        final had = _lastReported.containsKey(key);
        final prev = _lastReported[key];
        _lastReported[key] = v;
        if (!had || prev == v) {
          continue;
        }
        _append(cls, DnpEvent(
          pointType: e.pointType,
          index: e.index,
          eventClass: cls,
          isBinary: true,
          isFloat: false,
          boolValue: v,
          intValue: 0,
          floatValue: 0.0,
          flags: 0x01, // DnpFlags.online — bit 7 (state) is applied by the encoder
          timeMs: nowMs,
        ));
      } else {
        final dt = dataTypeOfPath(project, e.tag) ?? 'INT32';
        final isFloat = dt == 'FLOAT64';
        if (isFloat) {
          final v = raw is double ? raw : (raw is int ? raw.toDouble() : 0.0);
          final had = _lastReported.containsKey(key);
          final prev = _lastReported[key];
          _lastReported[key] = v;
          if (!had || prev == v) {
            continue;
          }
          _append(cls, DnpEvent(
            pointType: e.pointType,
            index: e.index,
            eventClass: cls,
            isBinary: false,
            isFloat: true,
            boolValue: false,
            intValue: 0,
            floatValue: v,
            flags: 0x01,
            timeMs: nowMs,
          ));
        } else {
          final v = raw is int ? raw : (raw is double ? raw.round() : 0);
          final had = _lastReported.containsKey(key);
          final prev = _lastReported[key];
          _lastReported[key] = v;
          if (!had || prev == v) {
            continue;
          }
          _append(cls, DnpEvent(
            pointType: e.pointType,
            index: e.index,
            eventClass: cls,
            isBinary: false,
            isFloat: false,
            boolValue: false,
            intValue: v,
            floatValue: 0.0,
            flags: 0x01,
            timeMs: nowMs,
          ));
        }
      }
    }
  }

  void _append(int cls, DnpEvent ev) {
    final buf = _buffers[cls]!;
    buf.add(ev);
    while (buf.length > capacityPerClass) {
      buf.removeAt(0); // drop oldest
      _overflowed = true;
    }
  }
}
```

> Note: `flags: 0x01` is `DnpFlags.online`. This file must NOT import `dnp3_app.dart` (keep the engine dependency-free of the codec); the literal `0x01` with the explaining comment is intentional. The point STATE bit (0x80) for binary events is applied by the encoder in Task 3 from `boolValue`, not stored in `flags`.

- [ ] **Step 4: Run the engine tests — expect PASS**

Run: `cd mobile && flutter test test/dnp3_events_test.dart`
Expected: PASS (all six tests).

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues found.

```bash
git add mobile/lib/protocols/dnp3/dnp3_events.dart mobile/test/dnp3_events_test.dart mobile/test/dnp3_test_support.dart
git commit -m "feat(dnp3): pure event engine — per-class ring buffers + change detection"
```

---

## Task 3: App codec — event objects, unsolicited, new func codes

**Files:**
- Modify: `mobile/lib/protocols/dnp3/dnp3_app.dart`
- Test: `mobile/test/dnp3_app_test.dart` (extend)

**Interfaces:**
- Consumes: existing `dnp3_app.dart` (`DnpFunc`, `DnpIin1`, `DnpIin2`, `encodeObjectHeader`, `DnpQualifier`, `DnpFlags`, `parseAppRequest`, `DnpAppRequest`).
- Produces:
  - `DnpFunc.confirm = 0`, `DnpFunc.enableUnsolicited = 20`, `DnpFunc.disableUnsolicited = 21`, `DnpFunc.unsolicitedResponse = 130`.
  - `DnpIin1.class1Events = 0x02`, `class2Events = 0x04`, `class3Events = 0x08`; `DnpIin2.eventBufferOverflow = 0x08`.
  - `Uint8List encodeG2V2({required bool value, required int flags, required int timeMs})` (7 bytes).
  - `Uint8List encodeG32V3({required int value, required int flags, required int timeMs})` (11 bytes).
  - `Uint8List encodeG32V7({required double value, required int flags, required int timeMs})` (11 bytes).
  - `int? dnpClassOfG60Variation(int variation)` (v1→0, v2→1, v3→2, v4→3, else null).
  - `Uint8List buildUnsolicitedResponse({required int seq, required int iin, required Uint8List objectData})` (fc 130, FIR|FIN|CON|UNS).
  - Test-only helpers exposed for round-trip assertions: `int getDnpTime48(Uint8List d, int offset)`.

- [ ] **Step 1: Write failing codec tests**

Add to `mobile/test/dnp3_app_test.dart`:

```dart
test('g2v2 binary event encodes flags+state and 48-bit LE time', () {
  final bytes = encodeG2V2(value: true, flags: DnpFlags.online, timeMs: 0x0102030405);
  expect(bytes.length, 7);
  // flags byte: online (0x01) | state (0x80) = 0x81
  expect(bytes[0], 0x81);
  // 48-bit LE time 0x0102030405 -> 05 04 03 02 01 00
  expect(bytes.sublist(1), [0x05, 0x04, 0x03, 0x02, 0x01, 0x00]);
  expect(getDnpTime48(bytes, 1), 0x0102030405);
});

test('g32v3 analog int event: flags + int32 LE + 48-bit time', () {
  final bytes = encodeG32V3(value: 0x11223344, flags: DnpFlags.online, timeMs: 1000);
  expect(bytes.length, 11);
  expect(bytes[0], 0x01);
  expect(bytes.sublist(1, 5), [0x44, 0x33, 0x22, 0x11]);
  expect(getDnpTime48(bytes, 5), 1000);
});

test('g32v7 analog float event: flags + float32 LE + 48-bit time', () {
  final bytes = encodeG32V7(value: 1.5, flags: DnpFlags.online, timeMs: 2000);
  expect(bytes.length, 11);
  expect(bytes[0], 0x01);
  final bd = ByteData.sublistView(bytes, 1, 5);
  expect(bd.getFloat32(0, Endian.little), 1.5);
  expect(getDnpTime48(bytes, 5), 2000);
});

test('48-bit time survives a value above 2^32 (dart2js-safe)', () {
  const t = 1893456000000; // ~2030, exceeds 32 bits
  final bytes = encodeG2V2(value: false, flags: 0, timeMs: t);
  expect(getDnpTime48(bytes, 1), t);
});

test('dnpClassOfG60Variation maps variations to classes', () {
  expect(dnpClassOfG60Variation(1), 0);
  expect(dnpClassOfG60Variation(2), 1);
  expect(dnpClassOfG60Variation(3), 2);
  expect(dnpClassOfG60Variation(4), 3);
  expect(dnpClassOfG60Variation(9), isNull);
});

test('parse ENABLE_UNSOLICITED (fc20) naming class 1 via g60v2/all-points', () {
  // APP_CONTROL, fc=20, then object header g60 v2 qualifier 0x06 (all points).
  final frag = Uint8List.fromList([0xC0, 20, 60, 2, 0x06]);
  final req = parseAppRequest(frag);
  expect(req, isNotNull);
  expect(req!.functionCode, DnpFunc.enableUnsolicited);
  expect(req.objects.single.group, 60);
  expect(req.objects.single.variation, 2);
});

test('parse a CONFIRM (fc0) with no objects', () {
  final frag = Uint8List.fromList([0xD0, 0]); // UNS+... fc0
  final req = parseAppRequest(frag);
  expect(req, isNotNull);
  expect(req!.functionCode, DnpFunc.confirm);
  expect(req.objects, isEmpty);
  expect(req.uns, isTrue);
  expect(req.seq, 0);
});

test('buildUnsolicitedResponse sets fc130 and FIR|FIN|CON|UNS', () {
  final resp = buildUnsolicitedResponse(seq: 5, iin: packIin(0, 0), objectData: Uint8List(0));
  // app control = 0x80|0x40|0x20|0x10|seq = 0xF5
  expect(resp[0], 0xF5);
  expect(resp[1], 130);
  expect(resp.length, 4); // control + func + IIN(2)
});
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd mobile && flutter test test/dnp3_app_test.dart`
Expected: FAIL — new symbols undefined.

- [ ] **Step 3: Add func codes + IIN bits**

In `mobile/lib/protocols/dnp3/dnp3_app.dart`, extend `DnpFunc`:

```dart
class DnpFunc {
  static const int confirm = 0;
  static const int read = 1;
  static const int select = 3;
  static const int operate = 4;
  static const int directOperate = 5;
  static const int enableUnsolicited = 20;
  static const int disableUnsolicited = 21;
  static const int response = 129; // 0x81
  static const int unsolicitedResponse = 130; // 0x82
}
```

Extend `DnpIin1` and `DnpIin2`:

```dart
class DnpIin1 {
  static const int deviceRestart = 0x80;
  static const int class1Events = 0x02; // bit 1
  static const int class2Events = 0x04; // bit 2
  static const int class3Events = 0x08; // bit 3
}

class DnpIin2 {
  static const int noFuncCodeSupport = 0x01;
  static const int objectUnknown = 0x02;
  static const int parameterError = 0x04;
  static const int eventBufferOverflow = 0x08; // bit 3
}
```

- [ ] **Step 4: Add the 48-bit time helpers + event encoders**

Add near the other encoders in `dnp3_app.dart`:

```dart
/// Writes [timeMs] (ms since 1970-01-01 UTC) as a 48-bit little-endian
/// integer at [offset] in [bd]. dart2js-safe: the split uses arithmetic
/// (`%`/`~/` on 2^32), never a `>> 32` bit-shift (JS bitwise ops truncate to
/// 32 bits) and never setInt64 (unimplemented under dart2js).
void _setDnpTime48(ByteData bd, int offset, int timeMs) {
  final t = timeMs < 0 ? 0 : timeMs;
  final low = t % 0x100000000; // low 32 bits
  final high = t ~/ 0x100000000; // bits 32..47
  bd.setUint32(offset, low, Endian.little);
  bd.setUint16(offset + 4, high & 0xFFFF, Endian.little);
}

/// Reads a 48-bit little-endian DNP3 timestamp at [offset]. Test/parse helper.
int getDnpTime48(Uint8List data, int offset) {
  final bd = ByteData.sublistView(data, offset, offset + 6);
  final low = bd.getUint32(0, Endian.little);
  final high = bd.getUint16(4, Endian.little);
  return high * 0x100000000 + low;
}

/// Encodes a g2v2 (Binary Input Event with absolute time) object: 1 flags
/// byte (bit 7 = STATE from [value], bits 0-6 from [flags]) + 48-bit LE time.
Uint8List encodeG2V2({required bool value, required int flags, required int timeMs}) {
  final bd = ByteData(7);
  bd.setUint8(0, (flags & 0x7F) | (value ? DnpFlags.state : 0));
  _setDnpTime48(bd, 1, timeMs);
  return bd.buffer.asUint8List();
}

/// Encodes a g32v3 (Analog Input Event, 32-bit with time) object: 1 flags
/// byte + int32 LE [value] + 48-bit LE time.
Uint8List encodeG32V3({required int value, required int flags, required int timeMs}) {
  final bd = ByteData(11);
  bd.setUint8(0, flags & 0xFF);
  bd.setInt32(1, value, Endian.little);
  _setDnpTime48(bd, 5, timeMs);
  return bd.buffer.asUint8List();
}

/// Encodes a g32v7 (Analog Input Event, single-precision float with time)
/// object: 1 flags byte + float32 LE [value] + 48-bit LE time.
Uint8List encodeG32V7({required double value, required int flags, required int timeMs}) {
  final bd = ByteData(11);
  bd.setUint8(0, flags & 0xFF);
  bd.setFloat32(1, value, Endian.little);
  _setDnpTime48(bd, 5, timeMs);
  return bd.buffer.asUint8List();
}

/// Maps a g60 (Class Objects) variation to its DNP3 event class: v1 = Class 0
/// (static), v2 = Class 1, v3 = Class 2, v4 = Class 3. Returns `null` for any
/// other variation.
int? dnpClassOfG60Variation(int variation) {
  switch (variation) {
    case 1:
      return 0;
    case 2:
      return 1;
    case 3:
      return 2;
    case 4:
      return 3;
    default:
      return null;
  }
}

/// Builds an UNSOLICITED RESPONSE fragment (function code 130): app control
/// FIR|FIN|CON|UNS|seq, then IIN(2, LE per [packIin]), then [objectData]. The
/// UNS bit marks this as unsolicited and CON requests the master's CONFIRM.
Uint8List buildUnsolicitedResponse({
  required int seq,
  required int iin,
  required Uint8List objectData,
}) {
  final appControl = 0x80 | 0x40 | 0x20 | 0x10 | (seq & 0x0F); // FIR|FIN|CON|UNS
  final out = BytesBuilder();
  out.addByte(appControl);
  out.addByte(DnpFunc.unsolicitedResponse & 0xFF);
  out.addByte(iin & 0xFF);
  out.addByte((iin >> 8) & 0xFF);
  out.add(objectData);
  return out.toBytes();
}
```

> `parseAppRequest` needs NO change: fc 20/21 carry g60 objects with qualifier `0x06` (all points), which the existing parser already treats as header-only regardless of function code (see the `isReadLike || allPoints` branch); a CONFIRM (fc 0) is a 2-byte fragment with no objects, which the existing loop handles. Confirm this by making the Step-1 parse tests pass without touching the parser.

- [ ] **Step 5: Run the codec tests — expect PASS**

Run: `cd mobile && flutter test test/dnp3_app_test.dart`
Expected: PASS.

- [ ] **Step 6: analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues found.

```bash
git add mobile/lib/protocols/dnp3/dnp3_app.dart mobile/test/dnp3_app_test.dart
git commit -m "feat(dnp3): event-object encoders (g2v2/g32v3/g32v7), 48-bit time, unsolicited + class-object codec"
```

---

## Task 4: Outstation — solicited Class reads, unsolicited state, CONFIRM routing

**Files:**
- Modify: `mobile/lib/protocols/dnp3/dnp3_outstation.dart`
- Test: `mobile/test/dnp3_outstation_test.dart` (extend)

**Interfaces:**
- Consumes: Task 2 `DnpEventEngine`/`DnpEvent`; Task 3 codec additions.
- Produces (new on `DnpOutstation`):
  - Constructor gains `int eventBufferPerClass = 200` (builds the engine with it).
  - `void detectChanges(int nowMs)` — reads `projectProvider()` + its map, drives the engine.
  - `handleAppRequest` return type becomes `Uint8List` still, but returns `Uint8List(0)` (empty) for a CONFIRM (no reply) — the host skips empty responses.
  - `Set<int> get unsolicitedEnabledClasses` (read-only view, for the UI indicator).
  - `bool get hasUnsolicitedInFlight`.
  - `Uint8List? takeNullUnsolicited()` — one null unsolicited fragment pending after an ENABLE (else null); marks in-flight.
  - `Uint8List? takeEventUnsolicited(int nowMs)` — an unsolicited fragment carrying pending events of enabled classes (else null); marks in-flight.
  - `Uint8List? get inFlightUnsolicitedBytes` — the current in-flight fragment for a retry (else null).
  - `void failUnsolicited()` — abandon the in-flight attempt WITHOUT flushing (events stay), seq NOT advanced.
  - (CONFIRM handling is internal to `handleAppRequest`.)

- [ ] **Step 1: Write failing outstation tests**

Add to `mobile/test/dnp3_outstation_test.dart` (reuse its project builder). Helper to make an app fragment: `Uint8List frag(int appControl, int func, [List<int> objs = const []]) => Uint8List.fromList([appControl, func, ...objs]);`

```dart
test('solicited Class 1 read returns events with CON set; flush only on CONFIRM', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  project.protocols!.dnp3!.map = DnpMap(entries: [
    DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
  ]);
  final os = DnpOutstation(projectProvider: () => project);
  os.detectChanges(0); // baseline
  setTag(project, 'Run', true);
  os.detectChanges(1000); // one class-1 event buffered

  // Class 1 read: g60v2 all-points. app control FIR|FIN|seq=3 = 0xC3.
  final readClass1 = frag(0xC3, DnpFunc.read, [60, 2, 0x06]);
  final resp = os.handleAppRequest(readClass1, nowMs: 1000);
  expect(resp[1], DnpFunc.response);
  expect((resp[0] & 0x20) != 0, isTrue, reason: 'CON bit set (awaiting CONFIRM)');
  // Response carries a g2v2 object (group 2, variation 2) — IIN is 2 bytes then objects.
  expect(resp.sublist(4).contains(2), isTrue);

  // Without a CONFIRM, a re-read still returns the event (not flushed).
  final resp2 = os.handleAppRequest(frag(0xC4, DnpFunc.read, [60, 2, 0x06]), nowMs: 1000);
  expect((resp2[0] & 0x20) != 0, isTrue);

  // CONFIRM (fc0) with the matching sequence (3) flushes it.
  os.handleAppRequest(frag(0xC3, DnpFunc.confirm), nowMs: 1000);
  final resp3 = os.handleAppRequest(frag(0xC5, DnpFunc.read, [60, 2, 0x06]), nowMs: 1000);
  expect((resp3[0] & 0x20) != 0, isFalse, reason: 'no events left, no CON');
});

test('CONFIRM yields no reply (empty fragment)', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  final os = DnpOutstation(projectProvider: () => project);
  final resp = os.handleAppRequest(frag(0xC0, DnpFunc.confirm), nowMs: 0);
  expect(resp, isEmpty);
});

test('combined g60v1..v4 read returns static AND events', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  project.protocols!.dnp3!.map = DnpMap(entries: [
    DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
  ]);
  final os = DnpOutstation(projectProvider: () => project);
  os.detectChanges(0);
  setTag(project, 'Run', true);
  os.detectChanges(1);
  final resp = os.handleAppRequest(
      frag(0xC0, DnpFunc.read, [60, 1, 0x06, 60, 2, 0x06, 60, 3, 0x06, 60, 4, 0x06]),
      nowMs: 1);
  final objs = resp.sublist(4);
  expect(objs.contains(1), isTrue, reason: 'g1v2 static binary input present');
  expect(objs.contains(2), isTrue, reason: 'g2v2 binary event present');
});

test('ENABLE_UNSOLICITED sets the class flag and queues a null unsolicited', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  final os = DnpOutstation(projectProvider: () => project);
  os.handleAppRequest(frag(0xC0, DnpFunc.enableUnsolicited, [60, 2, 0x06]), nowMs: 0);
  expect(os.unsolicitedEnabledClasses.contains(1), isTrue);
  final nullUnsol = os.takeNullUnsolicited();
  expect(nullUnsol, isNotNull);
  expect(nullUnsol![1], DnpFunc.unsolicitedResponse);
  expect(nullUnsol.length, 4); // no objects
  expect(os.takeNullUnsolicited(), isNull, reason: 'only sent once');
});

test('unsolicited push carries events; CONFIRM flushes; failUnsolicited keeps them', () {
  final project = buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
  project.protocols!.dnp3!.map = DnpMap(entries: [
    DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
  ]);
  final os = DnpOutstation(projectProvider: () => project);
  os.handleAppRequest(frag(0xC0, DnpFunc.enableUnsolicited, [60, 2, 0x06]), nowMs: 0);
  os.takeNullUnsolicited(); // consume the null
  os.detectChanges(0);
  setTag(project, 'Run', true);
  os.detectChanges(100);
  final push = os.takeEventUnsolicited(100);
  expect(push, isNotNull);
  expect(push![1], DnpFunc.unsolicitedResponse);
  expect((push[0] & 0x10) != 0, isTrue, reason: 'UNS bit');
  expect(os.hasUnsolicitedInFlight, isTrue);
  // No second push while one is in flight.
  expect(os.takeEventUnsolicited(200), isNull);
  // A matching unsolicited CONFIRM flushes it.
  final seq = push[0] & 0x0F;
  os.handleAppRequest(frag(0x10 | seq, DnpFunc.confirm), nowMs: 300); // UNS bit set
  expect(os.hasUnsolicitedInFlight, isFalse);
  // Next detect with no change -> nothing to send.
  os.detectChanges(400);
  expect(os.takeEventUnsolicited(400), isNull);
});

test('IIN class-available + overflow bits reflect the engine', () {
  final project = buildProject({'N': ('INT32', 'SimulatedInput', 0)});
  project.protocols!.dnp3!.map = DnpMap(entries: [
    DnpMapEntry(tag: 'N', pointType: 'analogInput', index: 0, eventClass: 2),
  ]);
  final os = DnpOutstation(projectProvider: () => project, eventBufferPerClass: 2);
  os.detectChanges(0);
  for (var v = 1; v <= 4; v++) { setTag(project, 'N', v); os.detectChanges(v); }
  // A static (Class 0) read still returns and now carries IIN1 class-2 + IIN2 overflow.
  final resp = os.handleAppRequest(frag(0xC0, DnpFunc.read, [60, 1, 0x06]), nowMs: 5);
  final iin1 = resp[2];
  final iin2 = resp[3];
  expect(iin1 & DnpIin1.class2Events, DnpIin1.class2Events);
  expect(iin2 & DnpIin2.eventBufferOverflow, DnpIin2.eventBufferOverflow);
});
```

> Confirm the existing WS26 outstation tests (Class 0 integrity read, SELECT/OPERATE, DEVICE_RESTART clear) remain in the file and still pass unchanged after your edits — the static path must be byte-identical when no event classes are assigned.

- [ ] **Step 2: Run to confirm failure**

Run: `cd mobile && flutter test test/dnp3_outstation_test.dart`
Expected: FAIL — new API undefined; CONFIRM/class-read behavior not implemented.

- [ ] **Step 3: Wire the engine + unsolicited state into `DnpOutstation`**

In `dnp3_outstation.dart`, add imports and fields. Add `import 'dnp3_events.dart';`.

Add fields + constructor param:

```dart
  final DnpEventEngine _events;
  final Set<int> _unsolEnabled = <int>{};
  int _unsolSeq = 0;

  // In-flight unsolicited attempt: the exact bytes sent (for retry) and the
  // events it carried (flushed on CONFIRM). Null when nothing is in flight.
  Uint8List? _unsolInFlightBytes;
  List<DnpEvent>? _unsolInFlightEvents;

  // Pending null-unsolicited announcement (set on ENABLE_UNSOLICITED).
  bool _pendingNullUnsol = false;

  // Events reported in the last solicited Class read awaiting a CONFIRM, keyed
  // by that response's application sequence.
  List<DnpEvent>? _pendingSolicitedFlush;
  int _pendingSolicitedSeq = -1;

  DnpOutstation({required this.projectProvider, int eventBufferPerClass = 200})
      : _events = DnpEventEngine(capacityPerClass: eventBufferPerClass);

  Set<int> get unsolicitedEnabledClasses => Set<int>.unmodifiable(_unsolEnabled);
  bool get hasUnsolicitedInFlight => _unsolInFlightBytes != null;
  Uint8List? get inFlightUnsolicitedBytes => _unsolInFlightBytes;

  /// Runs one force-aware change-detection pass over the current project map.
  void detectChanges(int nowMs) {
    try {
      final project = projectProvider();
      final map = _mapFor(project);
      _events.detectChanges(project, map, nowMs);
    } catch (_) {
      // Detection must never throw into the host tick.
    }
  }
```

- [ ] **Step 4: Extend `_iin1()`/add `_iin2Events()` for class-available + overflow**

Replace `_iin1()` and add an event-IIN helper:

```dart
  int _iin1() {
    var v = _restartPending ? DnpIin1.deviceRestart : 0;
    final cls = _events.classesWithEvents;
    if (cls.contains(1)) v |= DnpIin1.class1Events;
    if (cls.contains(2)) v |= DnpIin1.class2Events;
    if (cls.contains(3)) v |= DnpIin1.class3Events;
    return v;
  }

  int _iin2Base() => _events.overflowed ? DnpIin2.eventBufferOverflow : 0;
```

Then, everywhere a response is built with `packIin(_iin1(), X)`, change `X` to `X | _iin2Base()` so the overflow bit rides along. (Search the file for `packIin(_iin1(),` — update each call site.)

- [ ] **Step 5: Route CONFIRM, ENABLE/DISABLE, and Class reads in `_dispatch`**

At the top of `_dispatch`, after computing `rawSeq`/`rawFunctionCode` and before the WRITE special-case, add CONFIRM handling (it produces no reply):

```dart
    if (rawFunctionCode == DnpFunc.confirm) {
      final uns = (frag[0] & 0x10) != 0;
      if (uns) {
        _confirmUnsolicited(rawSeq);
      } else {
        _confirmSolicited(rawSeq);
      }
      return Uint8List(0); // no response fragment for a CONFIRM
    }
```

In the `switch (req.functionCode)` block add the two unsolicited-control cases:

```dart
      case DnpFunc.enableUnsolicited:
        return _handleUnsolControl(project, req, enable: true);
      case DnpFunc.disableUnsolicited:
        return _handleUnsolControl(project, req, enable: false);
```

Add the handler methods:

```dart
  Uint8List _handleUnsolControl(PlcProject project, DnpAppRequest req, {required bool enable}) {
    for (final h in req.objects) {
      if (h.group == 60) {
        final cls = dnpClassOfG60Variation(h.variation);
        if (cls != null && cls >= 1 && cls <= 3) {
          if (enable) {
            _unsolEnabled.add(cls);
          } else {
            _unsolEnabled.remove(cls);
          }
        }
      }
    }
    if (enable) {
      _pendingNullUnsol = true; // announce once (DNP3 restart/enable semantics)
    }
    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: false,
      iin: packIin(_iin1(), _iin2Base()),
      objectData: Uint8List(0),
    );
  }

  void _confirmSolicited(int seq) {
    if (_pendingSolicitedFlush != null && seq == _pendingSolicitedSeq) {
      _events.flush(_pendingSolicitedFlush!);
      _events.clearOverflow();
      _pendingSolicitedFlush = null;
      _pendingSolicitedSeq = -1;
    }
  }

  void _confirmUnsolicited(int seq) {
    if (_unsolInFlightBytes != null && seq == _unsolSeq) {
      if (_unsolInFlightEvents != null) {
        _events.flush(_unsolInFlightEvents!);
      }
      _events.clearOverflow();
      _unsolSeq = (_unsolSeq + 1) & 0x0F;
      _unsolInFlightBytes = null;
      _unsolInFlightEvents = null;
    }
  }
```

- [ ] **Step 6: Rewrite `_handleRead` to serve static + events by requested class**

Replace `_handleRead` with a version that inspects the requested g60 classes (defaulting to a full static integrity scan when no class objects are named, preserving WS26 behavior):

```dart
  Uint8List _handleRead(PlcProject project, DnpAppRequest req) {
    final map = _mapFor(project);

    // Which classes did the request name via g60 objects?
    final requested = <int>{};
    var namedAnyClass = false;
    for (final h in req.objects) {
      if (h.group == 60) {
        final cls = dnpClassOfG60Variation(h.variation);
        if (cls != null) {
          requested.add(cls);
          namedAnyClass = true;
        }
      }
    }

    final includeStatic = !namedAnyClass || requested.contains(0);
    final eventClasses = requested.where((c) => c >= 1 && c <= 3).toSet();

    final out = BytesBuilder();
    if (includeStatic) {
      out.add(_buildClassZeroPayload(project, map));
    }

    var con = false;
    if (eventClasses.isNotEmpty) {
      final events = _events.pull(eventClasses);
      if (events.isNotEmpty) {
        out.add(_encodeEventObjects(events));
        con = true;
        _pendingSolicitedFlush = events;
        _pendingSolicitedSeq = req.seq;
      }
    }

    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: con,
      iin: packIin(_iin1(), _iin2Base()),
      objectData: out.toBytes(),
    );
  }
```

Add the event-object encoder (groups events by type into up to three index-prefixed objects, qualifier `0x28`):

```dart
  /// Encodes [events] into DNP3 event objects, grouped by type: binary events
  /// -> one g2v2 object, analog-int -> g32v3, analog-float -> g32v7. Each uses
  /// qualifier 0x28 (2-byte count + a 2-byte LE index prefix before each
  /// point), since events carry their own point index. FIFO order preserved
  /// within each group.
  Uint8List _encodeEventObjects(List<DnpEvent> events) {
    final binary = events.where((e) => e.isBinary).toList();
    final analogInt = events.where((e) => !e.isBinary && !e.isFloat).toList();
    final analogFloat = events.where((e) => !e.isBinary && e.isFloat).toList();

    final out = BytesBuilder();
    if (binary.isNotEmpty) {
      out.add(_encodeEventGroup(2, 2, binary,
          (e) => encodeG2V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (analogInt.isNotEmpty) {
      out.add(_encodeEventGroup(32, 3, analogInt,
          (e) => encodeG32V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (analogFloat.isNotEmpty) {
      out.add(_encodeEventGroup(32, 7, analogFloat,
          (e) => encodeG32V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs)));
    }
    return out.toBytes();
  }

  Uint8List _encodeEventGroup(
    int group,
    int variation,
    List<DnpEvent> group_,
    Uint8List Function(DnpEvent) encodeOne,
  ) {
    final out = BytesBuilder();
    out.add(encodeObjectHeader(
        group: group, variation: variation, qualifier: DnpQualifier.indexPrefix16, count: group_.length));
    for (final e in group_) {
      out.addByte(e.index & 0xFF);
      out.addByte((e.index >> 8) & 0xFF);
      out.add(encodeOne(e));
    }
    return out.toBytes();
  }
```

- [ ] **Step 7: Add the host-facing unsolicited push API**

Add to `DnpOutstation`:

```dart
  /// If an ENABLE_UNSOLICITED queued a null announcement and nothing is in
  /// flight, returns that null unsolicited fragment (fc130, no objects) and
  /// marks it in-flight; else null.
  Uint8List? takeNullUnsolicited() {
    if (!_pendingNullUnsol || _unsolInFlightBytes != null) {
      return null;
    }
    _pendingNullUnsol = false;
    final bytes = buildUnsolicitedResponse(
        seq: _unsolSeq, iin: packIin(_iin1(), _iin2Base()), objectData: Uint8List(0));
    _unsolInFlightBytes = bytes;
    _unsolInFlightEvents = <DnpEvent>[]; // null carries no events to flush
    return bytes;
  }

  /// If unsolicited is enabled for a class with pending events and nothing is
  /// in flight, builds an unsolicited response (fc130, UNS+CON) carrying those
  /// events, marks it in-flight, and returns it; else null.
  Uint8List? takeEventUnsolicited(int nowMs) {
    if (_unsolInFlightBytes != null || _unsolEnabled.isEmpty) {
      return null;
    }
    final events = _events.pull(_unsolEnabled);
    if (events.isEmpty) {
      return null;
    }
    final bytes = buildUnsolicitedResponse(
        seq: _unsolSeq, iin: packIin(_iin1(), _iin2Base()), objectData: _encodeEventObjects(events));
    _unsolInFlightBytes = bytes;
    _unsolInFlightEvents = events;
    return bytes;
  }

  /// Abandon the in-flight unsolicited attempt after the host exhausts its
  /// retries: events stay buffered (retried on the next change/tick), and the
  /// unsolicited sequence is NOT advanced.
  void failUnsolicited() {
    _unsolInFlightBytes = null;
    _unsolInFlightEvents = null;
  }
```

- [ ] **Step 8: Run the outstation tests — expect PASS**

Run: `cd mobile && flutter test test/dnp3_outstation_test.dart`
Expected: PASS (new tests + all existing WS26 tests).

- [ ] **Step 9: analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues found.

```bash
git add mobile/lib/protocols/dnp3/dnp3_outstation.dart mobile/test/dnp3_outstation_test.dart
git commit -m "feat(dnp3): outstation solicited Class reads + unsolicited state + CONFIRM routing + event IIN"
```

---

## Task 5: Host tick + retry + UI

**Files:**
- Modify: `mobile/lib/services/dnp3_host.dart`
- Modify: `mobile/lib/screens/gateway_screen.dart` (DNP3 card)
- Test: `mobile/test/dnp3_host_test.dart` (extend), `mobile/test/gateway_screen_test.dart` (DNP3 tab)

**Interfaces:**
- Consumes: Task 4 `DnpOutstation` (`detectChanges`, `takeNullUnsolicited`, `takeEventUnsolicited`, `inFlightUnsolicitedBytes`, `hasUnsolicitedInFlight`, `failUnsolicited`, `unsolicitedEnabledClasses`); Task 1 config fields.
- Produces: host-side change-detection + unsolicited push/retry loop; a testable tick seam; DNP3-card event-Class dropdown + unsolicited indicator.

- [ ] **Step 1: Write failing host tests**

The current host has no test seam for the timer. Add a package-visible `tickForTest(int nowMs)` and a way to inject connections, OR (preferred) refactor the per-master unsolicited bookkeeping into a small pure helper and test it directly, then have the periodic timer call it. Given the socket is hard to fake, follow the WS26 `dnp3_host_test.dart` approach (grep it: it likely drives bytes through a real loopback `ServerSocket`). Add these behaviors:

```dart
test('unsolicited push then CONFIRM flushes; no-CONFIRM retries to the cap then stops', () async {
  // Build a project with an enabled DNP3 outstation + one class-1 binaryInput.
  // Start the host on port 0 (ephemeral). Connect a raw client socket.
  // 1. Client sends ENABLE_UNSOLICITED (fc20, g60v2) wrapped in link+transport framing.
  // 2. Change the input value in the project.
  // 3. Drive the host tick (via the injected clock/tickForTest) with a short
  //    unsolConfirmTimeoutMs so retries happen fast.
  // 4. Assert the client receives an unsolicited response (fc130, UNS bit).
  // 5. Without confirming, drive more ticks -> assert it is re-sent up to
  //    unsolMaxRetries times, then stops (no further copies).
  // 6. Send a matching CONFIRM -> assert no more retries and the event is gone
  //    (a subsequent Class-1 poll returns empty / no CON).
});

test('malformed inbound never crashes the host and static/solicited still works', () async {
  // Feed garbage bytes; assert the host stays running and a subsequent
  // well-formed Class 0 integrity poll still returns a valid response
  // (WS26 behavior preserved).
});
```

> If a full socket-level unsolicited test is impractical to make deterministic, split it: (a) a pure unit test of the retry state machine (extract the "should I send / retry / give up" decision into a tiny pure function `UnsolAttempt` taking `(nowMs, sentAtMs, retryCount, timeoutMs, maxRetries)` → `{send, resend, giveUp}` and test that exhaustively), and (b) a lighter socket test asserting a single unsolicited push + CONFIRM flush. Prefer real coverage of the decision logic over a flaky timing test.

- [ ] **Step 2: Run to confirm failure**

Run: `cd mobile && flutter test test/dnp3_host_test.dart`
Expected: FAIL — no tick/unsolicited behavior yet.

- [ ] **Step 3: Add the change-detection tick + unsolicited retry loop to `DnpHost`**

Read config at `start()`: capture `unsolConfirmTimeoutMs`, `unsolMaxRetries`, `eventBufferPerClass`. Pass `eventBufferPerClass` to the `DnpOutstation` constructor. Start a periodic timer (default 500 ms) that calls a pure-ish `_tick(nowMs)`; make `_tick` package-visible (or add `@visibleForTesting void tickForTest(int nowMs)`).

Add fields:

```dart
  Timer? _tick;
  int _unsolSentAtMs = 0;
  int _unsolRetryCount = 0;
  int _unsolTimeoutMs = 5000;
  int _unsolMaxRetries = 3;
  static const int _tickPeriodMs = 500;
```

In `start()`, after reading `dnp3`:

```dart
    _unsolTimeoutMs = dnp3.unsolConfirmTimeoutMs;
    _unsolMaxRetries = dnp3.unsolMaxRetries;
    final eventBufferPerClass = dnp3.eventBufferPerClass;
```

Construct the outstation with the buffer size:

```dart
      final outstation = DnpOutstation(
        projectProvider: projectProvider,
        eventBufferPerClass: eventBufferPerClass,
      );
```

After `_setStatus(DnpHostStatus.running);`, start the timer (store the shared `outstation` on the host so the tick can reach it):

```dart
      _outstation = outstation;
      _tick = Timer.periodic(const Duration(milliseconds: _tickPeriodMs), (_) {
        try {
          tickForTest(DateTime.now().millisecondsSinceEpoch);
        } catch (_) {
          // A tick must never crash the host.
        }
      });
```

Add `DnpOutstation? _outstation;` field, and the tick body:

```dart
  /// One change-detection + unsolicited-push/retry pass. Package-visible so
  /// tests can drive it with a controlled clock instead of wall time.
  @visibleForTesting
  void tickForTest(int nowMs) {
    final os = _outstation;
    if (os == null || _connections.isEmpty) {
      return;
    }
    os.detectChanges(nowMs);

    if (os.hasUnsolicitedInFlight) {
      // Awaiting CONFIRM: retry on timeout, give up after the cap.
      if (nowMs - _unsolSentAtMs >= _unsolTimeoutMs) {
        if (_unsolRetryCount < _unsolMaxRetries) {
          _unsolRetryCount++;
          _unsolSentAtMs = nowMs;
          final bytes = os.inFlightUnsolicitedBytes;
          if (bytes != null) {
            _broadcast(bytes);
          }
        } else {
          os.failUnsolicited();
          _unsolRetryCount = 0;
        }
      }
      return;
    }

    // Nothing in flight: a CONFIRM (or nothing sent yet) — reset retry state.
    _unsolRetryCount = 0;
    final frame = os.takeNullUnsolicited() ?? os.takeEventUnsolicited(nowMs);
    if (frame != null) {
      _unsolSentAtMs = nowMs;
      _broadcast(frame);
    }
  }

  /// Wraps an application fragment in transport + link framing (dest = master,
  /// src = outstation) and writes it to every live connection.
  void _broadcast(Uint8List appFragment) {
    for (final conn in List<_Connection>.from(_connections)) {
      if (conn._closed) {
        continue;
      }
      final frames = _buildResponseFrames(
        appFragment: appFragment,
        outstationAddress: conn.outstationAddress,
        masterAddress: conn.masterAddress,
      );
      for (final f in frames) {
        try {
          conn.socket.add(f);
        } catch (_) {
          // Drop broadcast errors per-connection.
        }
      }
    }
  }
```

In `stop()`, cancel the timer and clear the outstation ref:

```dart
    _tick?.cancel();
    _tick = null;
    _outstation = null;
    _unsolRetryCount = 0;
```

> Import `package:flutter/foundation.dart`'s `@visibleForTesting` (already imported via `foundation.dart`). Note `Uint8List` is already imported through `foundation.dart` in this file (it re-exports `dart:typed_data`); if analyze complains, add `import 'dart:typed_data';`.

> The shared-outstation, broadcast-to-all-connections model is the v1 simplification the spec calls out (typical DNP3 TCP = one master). Leave a comment saying so.

- [ ] **Step 4: Run the host tests — expect PASS**

Run: `cd mobile && flutter test test/dnp3_host_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing DNP3-card UI test**

In `mobile/test/gateway_screen_test.dart` (tab-aware — select the DNP3 tab first, mirroring how the existing Modbus-tab tests select their tab), assert an event-Class dropdown appears on an input row and edits the config:

```dart
testWidgets('DNP3 card exposes an event-Class dropdown on input rows', (tester) async {
  // Build a project whose DNP3 map has a binaryInput entry, pump the gateway
  // screen, select the DNP3 tab, find the event-class dropdown for that row,
  // change it to Class 2, and assert the entry's eventClass became 2.
  // Follow the existing DNP3/Modbus map-editor test setup in this file.
});
```

- [ ] **Step 6: Add the event-Class dropdown + unsolicited indicator to the DNP3 card**

In `gateway_screen.dart`, locate the DNP3 point-map editor rows (grep for the DNP3 card / `dnp3` map row builder — it mirrors the Modbus map editor). For rows whose `pointType` is `binaryInput` or `analogInput`, add a compact `DropdownButton<int>` (values 0/1/2/3, labels `Static` / `Class 1` / `Class 2` / `Class 3`) bound to `entry.eventClass`, calling the same "mutate config + setState + persist" path the other row fields use. For `binaryOutput`/`analogOutput` rows, omit it (or show a disabled dash) — events don't apply to outputs. Add a small read-only line near the DNP3 status showing unsolicited state, e.g. `Unsolicited: off` when `host.status != running` or no classes enabled, else `Unsolicited: Class 1,2` from `host` state (expose `unsolicitedEnabledClasses` via the host if needed for display, or simply label it master-controlled). Keep it dark-theme, `withValues(alpha:)`, no overflow at 320/360/1400.

- [ ] **Step 7: Run the UI test + full mobile suite**

Run: `cd mobile && flutter test test/gateway_screen_test.dart`
Expected: PASS.
Run: `cd mobile && flutter test`
Expected: All tests pass (report the count).

- [ ] **Step 8: analyze + build-web + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues found.
Run: `cd mobile && flutter build web --release`
Expected: Compiles (proves the dart2js-safety of the 48-bit time math end to end).

```bash
git add mobile/lib/services/dnp3_host.dart mobile/lib/screens/gateway_screen.dart mobile/test/
git commit -m "feat(dnp3): host change-detection tick + unsolicited push/retry; DNP3-card event-Class dropdown"
```

---

## Task 6: Rust `dnp3` E2E + docs + final review

**Files:**
- Modify: `gateway/examples/dnp3_probe.rs`
- Modify: `tool/dnp3_e2e.sh`
- Modify: `docs/protocols/DNP3.md` (and `docs/ROADMAP.md` or the equivalent phase tracker)
- Test: the probe itself is the test.

**Interfaces:**
- Consumes: the running in-app outstation (from a Dart fixture that starts `DnpHost` with a known map: at least one class-1 `binaryInput` and one class-2 `analogInput`, plus the ability to change those values on command).

- [ ] **Step 1: Read the existing probe + runner to match their structure**

Read `gateway/examples/dnp3_probe.rs` and `tool/dnp3_e2e.sh` end to end. The WS26 probe already: builds the outstation address config, connects the Step Function I/O `dnp3` master, runs a Class 0 integrity poll, and asserts static values + a control. Preserve all of that; you are ADDING an events section.

- [ ] **Step 2: Extend the Dart fixture the runner drives**

Find the fixture the WS26 `tool/dnp3_e2e.sh` launches (a headless Dart entrypoint that starts `DnpHost` against a fixed project). Extend that project so it has: a `binaryInput` at a known index with `eventClass: 1`, and an `analogInput` at a known index with `eventClass: 2`. Give the fixture a way to mutate those two tags after a delay (e.g. it flips the binary and bumps the analog a second or two after start, or exposes a trigger) so the master observes a change → event. Keep the existing static/control points intact.

- [ ] **Step 3: Add the Class 1/2/3 poll assertion to `dnp3_probe.rs`**

After the existing integrity-poll section, add: configure the master with an event poll for Class 1/2/3 (the `dnp3` crate's `add_poll` with `EventClasses`/`Classes`), trigger the fixture's change, wait for the poll, and assert the master's measurement handler received a binary-input event (the flipped value) and an analog-input event (the bumped value). Print progress lines consistent with the existing probe style.

- [ ] **Step 4: Add the unsolicited assertion**

Enable unsolicited on the master session for Class 1/2/3 (the `dnp3` crate enables unsolicited during startup handshake when configured). Trigger a fixture change, and assert the master receives an outstation-initiated unsolicited event (not in response to a poll) and that the library auto-CONFIRMs it (the crate confirms unsolicited responses automatically). Assert a follow-up integrity/Class poll no longer re-delivers the same event (proving the CONFIRM flushed it). On full success print `DNP3 EVENTS PROBE PASS`.

- [ ] **Step 5: Wire `tool/dnp3_e2e.sh` + honest fallback**

Update `tool/dnp3_e2e.sh` to run the extended probe. Keep the existing honest fallback: if the environment can't run the Rust master (no cargo, offline crate fetch, CI without the toolchain), the script must build the probe (`cargo build --example dnp3_probe`) and run the Dart unit suite, and clearly report that the live master leg was skipped — never silently claim a pass it didn't run.

- [ ] **Step 6: Run every gate**

```bash
cd mobile && flutter test          # full suite green (report count)
cd mobile && flutter analyze       # No issues found
cd mobile && flutter build web --release
cd gateway && cargo build --examples
bash tool/dnp3_e2e.sh              # DNP3 EVENTS PROBE PASS (or honest fallback)
```

Also confirm the WS26 static/control E2E still passes (run the original probe path if the script kept it separate) and the WS6 round-trip test is still green.

- [ ] **Step 7: Docs**

Update `docs/protocols/DNP3.md`: document event classes (per-point 0/1/2/3), event objects (g2v2/g32v3/g32v7 with 48-bit time), solicited Class 1/2/3 polls (CON + flush-on-CONFIRM), unsolicited responses (enable/disable via fc20/21, CONFIRM + retry policy with the config knobs), and the IIN class-available/overflow bits. Note the v1 simplifications (any-change events with no deadband; unsolicited broadcast to all connections; timestamps always absolute). Update the phase tracker to mark DNP3 events + unsolicited done.

- [ ] **Step 8: Commit**

```bash
git add gateway/examples/dnp3_probe.rs tool/dnp3_e2e.sh docs/ mobile/
git commit -m "test(dnp3): Rust dnp3 master Class-poll + unsolicited E2E; docs; DNP3 events complete"
```

- [ ] **Step 9: Whole-branch review**

Dispatch the final whole-branch code review (superpowers:requesting-code-review, most capable model) over the full branch diff. Address Critical/Important findings, then complete via superpowers:finishing-a-development-branch.

---

## Self-Review

**Spec coverage:**
- Per-point event Class (0–3), default 0, autoGenerate=0 → Task 1. ✅
- Change detection + bounded buffers + overflow → Task 2. ✅
- Event objects g2v2/g32v3/g32v7, 48-bit time, qualifier 0x28 → Task 3 (encoders) + Task 4 (assembled with headers). ✅
- Solicited Class reads g60v2/v3/v4, CON, flush-on-CONFIRM; combined g60v1..v4 = static+events → Task 4. ✅
- Unsolicited: enable/disable fc20/21, fc130 UNS+CON, CONFIRM, retry, null-on-enable → Task 4 (state/build) + Task 5 (tick/retry). ✅
- IIN class-available + overflow → Task 3 (bits) + Task 4 (set). ✅
- Config UI event-Class dropdown + unsol indicator → Task 5. ✅
- E2E Rust master Class poll + unsolicited → Task 6. ✅
- Config model additive fields → Task 1. ✅

**Placeholder scan:** No "TBD"/"handle edge cases"; every code step carries real code; test bodies with English-only descriptions (Task 5 socket test, Task 6 probe) are deliberate because they wrap `dart:io`/Rust the plan can't fully inline — each names the exact assertions to make. Acceptable per the "only `*_host.dart` uses dart:io / the probe is Rust" boundary.

**Type consistency:** `DnpEvent`/`DnpEventEngine` signatures match between Task 2 (definition) and Task 4 (use); `eventClass` field name consistent across Tasks 1/2/4/5; func-code constant names (`DnpFunc.confirm/enableUnsolicited/disableUnsolicited/unsolicitedResponse`) consistent Tasks 3/4/5; `takeNullUnsolicited`/`takeEventUnsolicited`/`failUnsolicited`/`inFlightUnsolicitedBytes`/`hasUnsolicitedInFlight` consistent Tasks 4/5. `handleAppRequest` returns `Uint8List` (empty for CONFIRM), so the host's existing `response`/frame path only needs an `isNotEmpty` guard (Task 5).
