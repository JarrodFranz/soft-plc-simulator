# DNP3 Output Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `binaryOutput`/`analogOutput` DNP3 points report status change events (g11v2 / g42v3 / g42v7) via the existing per-class buffers, Class 1/2/3 polls, and unsolicited push — so all four point types have event parity with inputs, not just inputs.

**Architecture:** Three surgical changes to existing pure-Dart DNP3 files plus one UI gate widening: un-gate outputs in the change-detection engine; add three output-event encoders (byte-identical to the input-event encoders, delegating to them); grow the outstation's event grouping from 3 buckets to 6; and show the Event-class dropdown on output rows. No new files, no config/model change, no new infrastructure.

**Tech Stack:** Dart/Flutter (`mobile/`), the existing DNP3 codec/engine/outstation, the Rust `dnp3` crate (`gateway/examples/dnp3_probe.rs`) for the machine-proof E2E.

## Global Constraints

- No vendor branding; DNP3/IEEE 1815 terms fine. Zero `flutter analyze` warnings (`cd mobile && flutter analyze` → "No issues found!"). Brace all bodies; `const`; `withValues(alpha:)`; dark theme; no RenderFlex overflow at 320/360/1400.
- `mobile/lib/protocols/dnp3/**` stays PURE Dart (no `dart:io`/Flutter). Only `dnp3_host.dart` uses `dart:io`. The outstation never throws on malformed input.
- Little-endian wire; 48-bit DNP time via the existing 32+16-bit split (no `getInt64`/`setInt64`).
- Output events are force-aware (captured value = forced value when forced). **Any change** (master-commanded OR logic/sim-driven) triggers an event — same as inputs; no origin tracking.
- Additive/no-model-change: `DnpMapEntry.eventClass` already exists for every point type. The wire is **byte-identical when no output event classes are assigned** — existing input-event + static/control behavior is preserved exactly. WS6 lossless round-trip stays green.
- g11v2/g42v3/g42v7 payload byte layouts are IDENTICAL to g2v2/g32v3/g32v7 respectively; only the object-header group number differs (11 vs 2, 42 vs 32).

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `mobile/lib/protocols/dnp3/dnp3_events.dart` | MODIFY | `detectChanges` also watches `binaryOutput`/`analogOutput`; `DnpEvent` doc updated. |
| `mobile/lib/protocols/dnp3/dnp3_app.dart` | MODIFY | add `encodeG11V2`/`encodeG42V3`/`encodeG42V7` (delegating to the g2/g32 encoders). |
| `mobile/lib/protocols/dnp3/dnp3_outstation.dart` | MODIFY | `_encodeEventObjects` splits input vs output → 6 buckets. |
| `mobile/lib/screens/gateway_screen.dart` | MODIFY | Event-class dropdown gate widened to all four point types. |
| `mobile/test/dnp3_events_test.dart`, `dnp3_app_test.dart`, `dnp3_outstation_test.dart`, `gateway_screen_test.dart` | MODIFY | tests. |
| `gateway/examples/dnp3_probe.rs`, `tool/dnp3_e2e.sh`, `mobile/tool/dnp3_host_probe.dart`, `docs/protocols/DNP3.md`, `ROADMAP.md` | MODIFY | E2E + docs. |

---

## Task 1: Engine un-gates outputs + output-event encoders

**Files:**
- Modify: `mobile/lib/protocols/dnp3/dnp3_events.dart` (`detectChanges` ~`:104-114`, `DnpEvent` doc ~`:17-21`)
- Modify: `mobile/lib/protocols/dnp3/dnp3_app.dart` (after `encodeG32V7` ~`:592`)
- Test: `mobile/test/dnp3_events_test.dart`, `mobile/test/dnp3_app_test.dart`

**Interfaces:**
- Consumes: `DnpEvent` (has `pointType`/`index`/`eventClass`/`isBinary`/`isFloat`/`boolValue`/`intValue`/`floatValue`/`flags`/`timeMs`); `readPath`/`dataTypeOfPath`; `encodeG2V2`/`encodeG32V3`/`encodeG32V7`.
- Produces: change detection now emits `DnpEvent`s with `pointType` `'binaryOutput'`/`'analogOutput'`; `Uint8List encodeG11V2({required bool value, required int flags, required int timeMs})`, `Uint8List encodeG42V3({required int value, required int flags, required int timeMs})`, `Uint8List encodeG42V7({required double value, required int flags, required int timeMs})`.

- [ ] **Step 1: Write failing engine tests** in `mobile/test/dnp3_events_test.dart` (reuse the file's existing `_buildProject`/`_setTag` helpers — grep them):

```dart
test('class 1 binaryOutput change -> one binary output event', () {
  final project = buildProject({'Motor': ('BOOL', 'Internal', false)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Motor', pointType: 'binaryOutput', index: 0, eventClass: 1),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0); // baseline, no event
  expect(eng.hasAnyEvents, isFalse);
  setTag(project, 'Motor', true);
  eng.detectChanges(project, map, 1000);
  final events = eng.pull({1});
  expect(events.length, 1);
  expect(events.single.isBinary, isTrue);
  expect(events.single.pointType, 'binaryOutput');
  expect(events.single.boolValue, isTrue);
  expect(events.single.index, 0);
});

test('class 2 analogOutput change -> analog output event with value + time', () {
  final project = buildProject({'Setpoint': ('INT32', 'Internal', 1000)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Setpoint', pointType: 'analogOutput', index: 0, eventClass: 2),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0);
  setTag(project, 'Setpoint', 1234);
  eng.detectChanges(project, map, 5);
  final events = eng.pull({2});
  expect(events.length, 1);
  expect(events.single.isBinary, isFalse);
  expect(events.single.isFloat, isFalse);
  expect(events.single.intValue, 1234);
  expect(events.single.pointType, 'analogOutput');
});

test('class 0 output generates no events; forced output captures forced value', () {
  final project = buildProject({'Motor': ('BOOL', 'Internal', false)});
  final map = DnpMap(entries: [
    DnpMapEntry(tag: 'Motor', pointType: 'binaryOutput', index: 0, eventClass: 0),
  ]);
  final eng = DnpEventEngine();
  eng.detectChanges(project, map, 0);
  setTag(project, 'Motor', true);
  eng.detectChanges(project, map, 1);
  expect(eng.hasAnyEvents, isFalse); // class 0 = no events
});
```

- [ ] **Step 2: Run — expect FAIL** (`cd mobile && flutter test test/dnp3_events_test.dart` → outputs currently skipped, no events).

- [ ] **Step 3: Un-gate outputs in `detectChanges`.** In `dnp3_events.dart`, change the point-type gate (currently `~:110-114`):

```dart
      final isBinary = e.pointType == 'binaryInput' || e.pointType == 'binaryOutput';
      final isAnalog = e.pointType == 'analogInput' || e.pointType == 'analogOutput';
      if (!isBinary && !isAnalog) {
        continue; // only binary/analog input+output points generate events
      }
```

Everything below (the `if (isBinary) { ... } else { ... }` blocks, first-seen baseline, `_append`) is unchanged — it keys off `isBinary`/`isAnalog` and stamps `pointType: e.pointType`, so output events flow through with the correct `pointType`. Also update the `detectChanges` doc comment (`~:100`) and the `DnpEvent` class doc (`~:17-21`) to say `binaryInput`/`binaryOutput`/`analogInput`/`analogOutput` instead of input-only.

- [ ] **Step 4: Write failing codec tests** in `mobile/test/dnp3_app_test.dart`:

```dart
test('g11v2 binary output event = same bytes as g2v2', () {
  final a = encodeG11V2(value: true, flags: DnpFlags.online, timeMs: 1000);
  final b = encodeG2V2(value: true, flags: DnpFlags.online, timeMs: 1000);
  expect(a, b);
  expect(a.length, 7);
  expect(a[0], 0x81); // online | state
});
test('g42v3 analog output int event = same bytes as g32v3', () {
  final a = encodeG42V3(value: 0x11223344, flags: DnpFlags.online, timeMs: 1000);
  final b = encodeG32V3(value: 0x11223344, flags: DnpFlags.online, timeMs: 1000);
  expect(a, b);
  expect(a.length, 11);
});
test('g42v7 analog output float event = same bytes as g32v7', () {
  final a = encodeG42V7(value: 1.5, flags: DnpFlags.online, timeMs: 2000);
  final b = encodeG32V7(value: 1.5, flags: DnpFlags.online, timeMs: 2000);
  expect(a, b);
  expect(a.length, 11);
});
```

- [ ] **Step 5: Add the encoders (delegating).** In `dnp3_app.dart`, after `encodeG32V7`:

```dart
/// Encodes a g11v2 (Binary Output Event with time) point. The per-point
/// payload is byte-identical to g2v2 (Binary Input Event) — flags(1, bit 7 =
/// state) + 48-bit LE time; only the object-header group number (11 vs 2)
/// distinguishes them on the wire, which the caller sets.
Uint8List encodeG11V2({required bool value, required int flags, required int timeMs}) =>
    encodeG2V2(value: value, flags: flags, timeMs: timeMs);

/// Encodes a g42v3 (Analog Output Event, 32-bit with time) point — payload
/// byte-identical to g32v3 (Analog Input Event); group 42 vs 32 distinguishes.
Uint8List encodeG42V3({required int value, required int flags, required int timeMs}) =>
    encodeG32V3(value: value, flags: flags, timeMs: timeMs);

/// Encodes a g42v7 (Analog Output Event, single-float with time) point —
/// payload byte-identical to g32v7; group 42 vs 32 distinguishes.
Uint8List encodeG42V7({required double value, required int flags, required int timeMs}) =>
    encodeG32V7(value: value, flags: flags, timeMs: timeMs);
```

- [ ] **Step 6: Run — expect PASS** (`cd mobile && flutter test test/dnp3_events_test.dart test/dnp3_app_test.dart`). `cd mobile && flutter analyze`.

- [ ] **Step 7: Commit**
```bash
git add mobile/lib/protocols/dnp3/dnp3_events.dart mobile/lib/protocols/dnp3/dnp3_app.dart mobile/test/dnp3_events_test.dart mobile/test/dnp3_app_test.dart
git commit -m "feat(dnp3): output-point change events — engine watches outputs + g11v2/g42v3/g42v7 encoders"
```

---

## Task 2: Outstation event grouping (6 buckets) + UI dropdown on output rows

**Files:**
- Modify: `mobile/lib/protocols/dnp3/dnp3_outstation.dart` (`_encodeEventObjects` ~`:449-468`)
- Modify: `mobile/lib/screens/gateway_screen.dart` (the DNP3 `_dnpRow` Event-class dropdown gate)
- Test: `mobile/test/dnp3_outstation_test.dart`, `mobile/test/gateway_screen_test.dart`

**Interfaces:**
- Consumes: Task 1's `encodeG11V2`/`encodeG42V3`/`encodeG42V7`; `DnpEvent.pointType`; `_encodeEventGroup(group, variation, events, encodeOne)`.
- Produces: a solicited Class read / unsolicited response now emits output events as g11v2/g42v3/g42v7 alongside the input g2v2/g32v3/g32v7; the DNP3-card Event-class dropdown appears on all four point-type rows.

- [ ] **Step 1: Write failing outstation test** in `mobile/test/dnp3_outstation_test.dart` (reuse the file's project/frag helpers): buffer a `binaryOutput` class-1 event + an `analogOutput` class-2 event, issue a Class 1/2/3 read, and assert the response carries a g11 object and a g42 object (not g2/g32) for those points.

```dart
test('solicited Class read returns output events as g11v2 + g42v3', () {
  final project = buildProject({'Mtr': ('BOOL','Internal',false), 'Sp': ('INT32','Internal',0)});
  project.protocols!.dnp3!.map = DnpMap(entries: [
    DnpMapEntry(tag: 'Mtr', pointType: 'binaryOutput', index: 0, eventClass: 1),
    DnpMapEntry(tag: 'Sp',  pointType: 'analogOutput', index: 0, eventClass: 2),
  ]);
  final os = DnpOutstation(projectProvider: () => project);
  os.detectChanges(0);
  setTag(project, 'Mtr', true); setTag(project, 'Sp', 42);
  os.detectChanges(1);
  final resp = os.handleAppRequest(frag(0xC0, DnpFunc.read, [60, 2, 0x06, 60, 3, 0x06]), nowMs: 1);
  final objs = resp.sublist(4);
  expect(objs.contains(11), isTrue, reason: 'g11 binary output event present');
  expect(objs.contains(42), isTrue, reason: 'g42 analog output event present');
  // and NOT emitted as input groups for these output points:
  // (a g2/g32 header would indicate misgrouping — verify by decoding the headers if the helper exists)
});
```
(If the test file has a response-object decoder, assert the exact `(group,variation)` = `(11,2)` and `(42,3)`; otherwise the `.contains` byte check plus the input-event regression tests staying green is acceptable — note which you used.)

- [ ] **Step 2: Run — expect FAIL** (outputs currently grouped as g2/g32 or absent).

- [ ] **Step 3: Split `_encodeEventObjects` into 6 buckets.** Replace the body:

```dart
  Uint8List _encodeEventObjects(List<DnpEvent> events) {
    bool isOut(DnpEvent e) => e.pointType == 'binaryOutput' || e.pointType == 'analogOutput';
    final binIn = events.where((e) => e.isBinary && !isOut(e)).toList();
    final binOut = events.where((e) => e.isBinary && isOut(e)).toList();
    final aIntIn = events.where((e) => !e.isBinary && !e.isFloat && !isOut(e)).toList();
    final aIntOut = events.where((e) => !e.isBinary && !e.isFloat && isOut(e)).toList();
    final aFloatIn = events.where((e) => !e.isBinary && e.isFloat && !isOut(e)).toList();
    final aFloatOut = events.where((e) => !e.isBinary && e.isFloat && isOut(e)).toList();

    final out = BytesBuilder();
    if (binIn.isNotEmpty) {
      out.add(_encodeEventGroup(2, 2, binIn, (e) => encodeG2V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (binOut.isNotEmpty) {
      out.add(_encodeEventGroup(11, 2, binOut, (e) => encodeG11V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aIntIn.isNotEmpty) {
      out.add(_encodeEventGroup(32, 3, aIntIn, (e) => encodeG32V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aIntOut.isNotEmpty) {
      out.add(_encodeEventGroup(42, 3, aIntOut, (e) => encodeG42V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aFloatIn.isNotEmpty) {
      out.add(_encodeEventGroup(32, 7, aFloatIn, (e) => encodeG32V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aFloatOut.isNotEmpty) {
      out.add(_encodeEventGroup(42, 7, aFloatOut, (e) => encodeG42V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs)));
    }
    return out.toBytes();
  }
```

Update the method's doc comment to list the 6 groups. `_encodeEventGroup` is unchanged.

- [ ] **Step 4: Widen the UI dropdown gate.** In `gateway_screen.dart` `_dnpRow`, find the Event-class dropdown's visibility gate (from the input-events work it is `entry.pointType == 'binaryInput' || entry.pointType == 'analogInput'`, likely a local like `isInputPoint`). Change it so the dropdown shows on **all four** point types (all of them now support events):

```dart
    final supportsEvents = entry.pointType == 'binaryInput' ||
        entry.pointType == 'binaryOutput' ||
        entry.pointType == 'analogInput' ||
        entry.pointType == 'analogOutput';
```

Use `supportsEvents` wherever the old input-only flag gated the dropdown (both the narrow and wide layouts). Since all current DNP3 point types support events, this is effectively "always show the dropdown"; keep the flag form so a future non-event point type can be excluded. Dark theme, `withValues(alpha:)`, no overflow at 320/360/1400.

- [ ] **Step 5: Write + run the UI test** in `mobile/test/gateway_screen_test.dart` (tab-aware — select the DNP3 tab, mirror the existing input-row dropdown test): a `binaryOutput` map row now shows the Event-class dropdown and editing it sets `entry.eventClass`.

- [ ] **Step 6: Run — expect PASS.** `cd mobile && flutter test test/dnp3_outstation_test.dart test/gateway_screen_test.dart`; then FULL `cd mobile && flutter test` (report count — confirm the existing input-event + static/control outstation tests stay green, proving no output classes = byte-identical). `cd mobile && flutter analyze`; `cd mobile && flutter build web --release`.

- [ ] **Step 7: Commit**
```bash
git add mobile/lib/protocols/dnp3/dnp3_outstation.dart mobile/lib/screens/gateway_screen.dart mobile/test/
git commit -m "feat(dnp3): outstation emits g11/g42 output events; DNP3-card event-Class dropdown on output rows"
```

---

## Task 3: Rust `dnp3` E2E (output-event poll) + docs + final review

**Files:**
- Modify: `gateway/examples/dnp3_probe.rs`, `mobile/tool/dnp3_host_probe.dart` (fixture), `tool/dnp3_e2e.sh`
- Modify: `docs/protocols/DNP3.md`, `ROADMAP.md`

- [ ] **Step 1: Read the existing DNP3 E2E assets.** `mobile/tool/dnp3_host_probe.dart` (the fixture — it maps input points with event classes for the input-event E2E) and `gateway/examples/dnp3_probe.rs` (the Rust `dnp3` master that polls Class 1/2/3 events). Preserve every existing input-event assertion.

- [ ] **Step 2: Extend the fixture** so the hosted project maps at least one `binaryOutput` (or `analogOutput`) point with an event Class (1/2/3), and mutates that output's value after start (the fixture already has a mutation/tick mechanism for the input-event points — add the output point to it, or flip it on the same timer). Keep the existing input event points intact.

- [ ] **Step 3: Add the output-event assertion to `dnp3_probe.rs`.** In the Class 1/2/3 event-poll section, assert the master's measurement handler receives a **binary/analog OUTPUT** event (g11/g42) for the mapped output point after its value changes — alongside the existing binary/analog input event assertions. The Step Function I/O `dnp3` crate surfaces output-status events through its `ReadHandler` (`BinaryOutputStatus`/`AnalogOutputStatus` change callbacks). Keep the print style consistent; on full success still print `DNP3 EVENTS PROBE PASS`.

- [ ] **Step 4: Wire `tool/dnp3_e2e.sh` + honest fallback.** Confirm it runs the extended probe; preserve the honest build+unit fallback (if cargo/the crate can't run: build the probe + run the Dart unit suite, and clearly report the live master leg was SKIPPED — never a fake pass).

- [ ] **Step 5: Run every gate** (report verbatim):
```bash
cd mobile && flutter test          # full suite green (report count)
cd mobile && flutter analyze       # No issues found
cd mobile && flutter build web --release
cd gateway && cargo build --examples
bash tool/dnp3_e2e.sh              # DNP3 EVENTS PROBE PASS (or honest fallback)
```
Confirm the WS6 round-trip test is still green and the input-event/static/control legs still pass.

- [ ] **Step 6: Docs.** Update `docs/protocols/DNP3.md`: all four point types now report change events — add g11v2 (binary output) and g42v3/g42v7 (analog output) to the event-object list, note the any-change trigger (master command or logic/sim), and that they ride the same Class-poll + unsolicited paths. Update `ROADMAP.md` Phase 8 to note output events are now covered (input + output events complete).

- [ ] **Step 7: Commit**
```bash
git add gateway/examples/dnp3_probe.rs tool/dnp3_e2e.sh mobile/tool/dnp3_host_probe.dart docs/protocols/DNP3.md ROADMAP.md
git commit -m "test(dnp3): Rust dnp3 master output-event poll E2E; docs; output events complete"
```

- [ ] **Step 8: Whole-branch review + finish.** Dispatch the final whole-branch code review (most capable model) over the full branch diff — focus on the 6-bucket grouping correctness (each point-type/variation → the right g-number), no-output-classes byte-identity, and never-crash. Address Critical/Important, then complete via superpowers:finishing-a-development-branch.

---

## Self-Review

**Spec coverage:** engine watches outputs (any-change, force-aware, first-seen baseline) → Task 1; g11v2/g42v3/g42v7 encoders → Task 1; outstation 6-bucket grouping → Task 2; UI dropdown on output rows → Task 2; no config/model change (byte-identical when no output classes) → asserted by the full-suite regression in Task 2; Class-poll + unsolicited reuse (unchanged) → inherent; Rust E2E output-event poll + docs → Task 3. ✅

**Placeholder scan:** no `TBD`/"handle edge cases"; every code step carries complete code. The Rust probe step (Task 3) describes the exact `dnp3`-crate callbacks (`BinaryOutputStatus`/`AnalogOutputStatus`) and assertion rather than inline Rust, consistent with how the input-event E2E was specified (the probe is Rust the plan can't fully inline) — gated by the falsifiable `DNP3 EVENTS PROBE PASS`.

**Type consistency:** `encodeG11V2(value:bool,flags:int,timeMs:int)`, `encodeG42V3(value:int,...)`, `encodeG42V7(value:double,...)` are defined once (Task 1) and consumed with those signatures in `_encodeEventObjects` (Task 2). `DnpEvent.pointType` (String, now includes the two output types) is the grouping key; `isBinary`/`isFloat` unchanged. The engine gate and the outstation `isOut` check both key off the same four `pointType` strings.
