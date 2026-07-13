# Composite/System Tag Exposure + MQTT Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose composite tags (incl. the reserved `System` UDT) on the outbound protocols by expanding them into scalar leaf entries, and cut MQTT event-loop load with a configurable publish interval, an optional analog deadband, and a throttled UI-notify.

**Architecture:** A pure `scalarLeaves(project)` enumerates every scalar leaf `(path, dataType)`; each map's `autoGenerate` iterates leaves (keyed by dotted path) instead of top-level scalars; the OPC UA address space resolves dotted leaf paths via the resolver. MQTT gains `publishIntervalMs`/`deadband` config, a deadband gate in the publisher, and a shared notify-throttle on the host.

**Tech Stack:** pure Dart (`mobile/lib/models/**`, `mobile/lib/protocols/**`), `dart:async` (Timer), `services/mqtt_host.dart` (`dart:io`), `flutter_test`, Rust `opcua` E2E.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"). OPC UA/IEC terms fine.
- `mobile/lib/models/**` and `mobile/lib/protocols/**` PURE Dart (no `dart:io`/Flutter); only `services/*_host.dart` use `dart:io`; the notify-throttle uses only `dart:async`.
- Additive persistence: `MqttProtocolConfig.publishIntervalMs` (default **250**) + `deadband` (default **0.0**) round-trip and tolerate absence; WS6 round-trip stays green. Composite expansion changes only generated maps (regenerated on demand), not a persisted field.
- Zero `flutter analyze` warnings; braces on all control flow; prefer `const`; no RenderFlex overflow at 320/360/1400 for the added MQTT config fields.
- `readPath`/`writePath`/`dataTypeOfPath` are the single tag-access path (forcing stays authoritative). Leaf paths use `.` (struct members) / `[i]` (array elements); integer leaves are NOT bit-expanded.
- A leaf's access + folder inherit from its ROOT tag (`SimulatedOutput` → ReadOnly, else ReadWrite). `System.*` stays read-only on the wire (incl. `System.AlarmReset`).
- Behavior-preserving: a scalar-only project's maps are unchanged; MQTT with interval=250/deadband=0 preserves today's report-by-exception behavior at a 250 ms tick.

**Commands** (from `mobile/`): `flutter test test/<path>_test.dart`; full `flutter test`; `flutter analyze` (expect **No issues found!**).

---

## Phase A — Composite leaf expansion

### Task 1: `scalarLeaves` resolver helper

**Files:**
- Modify: `mobile/lib/models/tag_resolver.dart`
- Test: `mobile/test/models/scalar_leaves_test.dart` (create)

**Interfaces:**
- Consumes: existing `lookupComposite`, `isIntegerType`, tag `value`/`dataType`/`arrayLength`.
- Produces: `class TagLeaf { final String path; final String dataType; const TagLeaf(this.path, this.dataType); }` and `List<TagLeaf> scalarLeaves(PlcProject p)` — every scalar leaf across all tags: a scalar tag → itself; a composite → its scalar struct members (recursively); an array → its scalar elements; integers are leaves (no bit expansion); composite/array CONTAINER nodes are NOT emitted.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/scalar_leaves_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';

void main() {
  test('a scalar tag is a single leaf (itself)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    final leaves = scalarLeaves(p);
    expect(leaves.map((l) => l.path), ['A']);
    expect(leaves.single.dataType, 'FLOAT64');
  });

  test('a SYSTEM composite expands to its scalar leaves with dotted paths + types', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    ensureSystemTag(p); // adds the reserved System SYSTEM composite tag
    final leaves = scalarLeaves(p);
    final byPath = {for (final l in leaves) l.path: l.dataType};
    expect(byPath['System.Fault'], 'BOOL');
    expect(byPath['System.ScanTimeMs'], 'FLOAT64');
    expect(byPath['System.Hour'], 'INT32');
    expect(byPath['System.DateTime'], 'STRING');
    // The composite container itself is NOT a leaf.
    expect(byPath.containsKey('System'), isFalse);
  });

  test('an array tag expands to scalar elements', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'Arr', path: 'Arr', dataType: 'INT32', arrayLength: 3, value: [0, 0, 0], ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    expect(scalarLeaves(p).map((l) => l.path), ['Arr[0]', 'Arr[1]', 'Arr[2]']);
  });

  test('integer leaves are NOT bit-expanded', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'W', path: 'W', dataType: 'INT16', value: 0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    expect(scalarLeaves(p).map((l) => l.path), ['W']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/scalar_leaves_test.dart`
Expected: FAIL — `scalarLeaves`/`TagLeaf` undefined.

- [ ] **Step 3: Implement**

Add to `tag_resolver.dart` (reuse the existing walk shape from `leafAndNodePaths`, but emit ONLY scalar leaves — skip composite/array container nodes):

```dart
/// One scalar leaf of a tag: its addressable dotted path and base dataType.
class TagLeaf {
  final String path;
  final String dataType;
  const TagLeaf(this.path, this.dataType);
}

/// Every scalar leaf across all of [p]'s tags. A scalar tag yields itself; a
/// composite yields its scalar struct members (recursively); an array yields
/// its scalar elements. Composite/array container nodes are not emitted;
/// integers are leaves (bits are not expanded).
List<TagLeaf> scalarLeaves(PlcProject p) {
  final out = <TagLeaf>[];
  void walk(String path, String base, int arrayLength, dynamic value) {
    if (arrayLength > 0 && value is List) {
      for (var i = 0; i < value.length; i++) {
        walk('$path[$i]', base, 0, value[i]);
      }
      return;
    }
    final comp = lookupComposite(p, base);
    if (comp != null && value is Map) {
      for (final f in comp.fields) {
        walk('$path.${f.name}', f.dataType, f.arrayLength, value[f.name]);
      }
      return;
    }
    // Scalar leaf.
    out.add(TagLeaf(path, base));
  }

  for (final t in p.tags) {
    walk(t.name, t.dataType, t.arrayLength, t.value);
  }
  return out;
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/scalar_leaves_test.dart` → PASS (4).
Run: `flutter test test/tag_resolver_test.dart` → still green.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/tag_resolver.dart mobile/test/models/scalar_leaves_test.dart
git commit -m "feat(tags): scalarLeaves() enumerates scalar leaves of composite/array tags"
```

---

### Task 2: Expand the four map `autoGenerate`s to leaves

**Files:**
- Modify: `mobile/lib/models/opcua_map.dart`, `modbus_map.dart`, `dnp3_map.dart`, `mqtt_map.dart` (each `autoGenerate`)
- Test: `mobile/test/models/composite_map_expansion_test.dart` (create)

**Interfaces:**
- Consumes: `scalarLeaves(project)` (Task 1); each map's existing per-type skip/table/address rules.
- Produces: each `autoGenerate` emits one entry per scalar leaf, keyed by the leaf's dotted path; STRING leaves included for OPC UA/MQTT, skipped for Modbus/DNP3; access/folder inherited from the ROOT tag (first path segment).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/composite_map_expansion_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';

PlcProject _projWithSystem() {
  final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
  ensureSystemTag(p);
  return p;
}

void main() {
  test('OPC UA autoGenerate exposes System leaves incl. STRING', () {
    final map = OpcuaMap.autoGenerate(_projWithSystem());
    final tags = map.nodes.map((n) => n.tag).toSet();
    expect(tags.contains('System.Fault'), isTrue);
    expect(tags.contains('System.DateTime'), isTrue); // STRING allowed on OPC UA
    // Node id is the dotted path; System (SimulatedOutput) leaves are ReadOnly.
    final fault = map.nodes.firstWhere((n) => n.tag == 'System.Fault');
    expect(fault.nodeId, 'ns=1;s=System.Fault');
    expect(fault.access, 'ReadOnly');
  });

  test('MQTT autoGenerate exposes System leaves incl. STRING; not writable', () {
    final map = MqttMap.autoGenerate(_projWithSystem());
    final e = map.entries.firstWhere((e) => e.tag == 'System.DateTime');
    expect(e.metric, 'System.DateTime'); // root folder -> bare dotted path
    expect(e.writable, isFalse);
  });

  test('Modbus + DNP3 expose numeric/BOOL System leaves but SKIP STRING', () {
    final mb = ModbusMap.autoGenerate(_projWithSystem());
    final dnp = DnpMap.autoGenerate(_projWithSystem());
    expect(mb.entries.any((e) => e.tag == 'System.ScanTimeMs'), isTrue);
    expect(mb.entries.any((e) => e.tag == 'System.DateTime'), isFalse); // STRING skipped
    expect(dnp.entries.any((e) => e.tag == 'System.Fault'), isTrue);
    expect(dnp.entries.any((e) => e.tag == 'System.DateTime'), isFalse);
  });

  test('scalar-only project is unchanged (regression)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    expect(MqttMap.autoGenerate(p).entries.map((e) => e.tag), ['A']);
    expect(OpcuaMap.autoGenerate(p).nodes.map((n) => n.tag), ['A']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/composite_map_expansion_test.dart`
Expected: FAIL — composites are skipped, System leaves absent.

- [ ] **Step 3: Implement**

In each `autoGenerate`, replace the `for (final tag in p.tags) { ... skip composites ... }` loop with a loop over `scalarLeaves(p)`. For each `TagLeaf leaf`:
- Resolve the ROOT tag = the tag whose `name` equals the first path segment (`leaf.path.split(RegExp(r'[.\[]')).first`) to inherit `ioType` (access) and `folder`. Access: `SimulatedOutput` → ReadOnly, else ReadWrite (mirror each map's existing rule).
- Apply the map's existing per-type support: **Modbus/DNP3 skip STRING** (and any type they already skip); **OPC UA/MQTT allow STRING**. Numeric/BOOL type→table/address/index/node rules unchanged, but keyed on `leaf.dataType`.
- Emit the entry with `tag: leaf.path`:
  - `OpcuaNode(nodeId: 'ns=1;s=${leaf.path}', tag: leaf.path, access: access)`.
  - `ModbusMapEntry(tag: leaf.path, table: <by leaf.dataType>, address: <next>, access: access)`.
  - `DnpMapEntry(tag: leaf.path, pointType: <BOOL→binaryInput / numeric→analogInput>, index: <next>)`.
  - `MqttMapEntry(tag: leaf.path, metric: rootFolder.isEmpty ? leaf.path : '$rootFolder/${leaf.path}', writable: rootIoType != 'SimulatedOutput')`.

Keep each map's existing dedup / value-shape skip removed (leaves are already scalar). Import `scalarLeaves`/`TagLeaf` from `tag_resolver.dart`. Factor a tiny local helper `_rootTagOf(p, leafPath)` in each map (or a shared one in tag_resolver) to get the root `PlcTag` for access/folder.

> The implementer reads each `autoGenerate` first and preserves its table/address/index allocation exactly, only swapping the iteration source (leaves) and the `tag`/`nodeId`/`metric` values (dotted paths). Confirm `MqttMapEntry`/`OpcuaNode`/`ModbusMapEntry`/`DnpMapEntry` field names.

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/composite_map_expansion_test.dart` → PASS.
Run: `flutter test test/models/` → existing map tests still pass (scalar-only maps unchanged; if a pre-existing test built a project with a composite tag and asserted it was skipped, update that assertion — the new behavior expands it).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/opcua_map.dart mobile/lib/models/modbus_map.dart mobile/lib/models/dnp3_map.dart mobile/lib/models/mqtt_map.dart mobile/test/models/composite_map_expansion_test.dart
git commit -m "feat(protocols): auto-generate expands composite/System tags into scalar leaf entries"
```

---

### Task 3: OPC UA address space resolves dotted leaf paths + E2E

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_address_space.dart` (`build`)
- Modify (E2E): `gateway/examples/opcua_probe.rs` + `tool/opcua_e2e.sh`
- Test: `mobile/test/opcua_address_space_leaf_test.dart` (create)

**Interfaces:**
- Consumes: `dataTypeOfPath` + `readPath` (`tag_resolver.dart`); the folder logic from the folder-browsing workstream.
- Produces: `OpcUaAddressSpace.build` resolves a node whose `tag` is a dotted leaf path — dataType via `dataTypeOfPath` (skip if null), BrowseName = the dotted path, folder = the ROOT tag's folder, value via the existing `readVariant`→`readPath`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/opcua_address_space_leaf_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_address_space.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';

void main() {
  test('address space resolves a System dotted leaf node (dataType/value/browseName)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    ensureSystemTag(p);
    p.protocols = ProtocolSettings(
      gatewayUrl: '',
      opcua: OpcUaProtocolConfig(enabled: true, namespaceUri: 'urn:t',
        map: OpcuaMap.autoGenerate(p)),
    );
    final space = OpcUaAddressSpace.build(p);
    final entry = space.byNodeId(OpcNodeId.string(1, 'System.Fault'));
    expect(entry, isNotNull);
    expect(entry!.browseName, 'System.Fault');
    expect(entry.dataType, 'BOOL');
    // Live value reads through the resolver.
    final variant = entry.readVariant(p);
    expect(variant, isNotNull);
    expect(variant!.value, false);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/opcua_address_space_leaf_test.dart`
Expected: FAIL — `_findTag('System.Fault')` returns null, node skipped, entry absent.

- [ ] **Step 3: Implement**

In `OpcUaAddressSpace.build`, replace the per-node `_findTag(project, node.tag)` resolution with dotted-path resolution:

```dart
final dt = dataTypeOfPath(project, node.tag);
if (dt == null) {
  continue; // unresolvable path — skip.
}
final rootName = node.tag.split(RegExp(r'[.\[]')).first;
final rootTag = _findTag(project, rootName);
final entry = OpcUaAddressSpaceEntry(
  nodeId: parsed,
  browseName: node.tag,          // dotted path (unique)
  tagName: node.tag,             // readVariant/readPath resolve dotted paths
  dataType: dt,
  access: node.access,
  folder: rootTag?.folder ?? '',
);
```

Keep `_findTag` for resolving the root tag's folder. A bare scalar name still resolves (`dataTypeOfPath` returns its type; root == the tag itself). The folder-node synthesis (from the folder-browsing workstream) is unaffected — leaves inherit the root folder.

- [ ] **Step 4: Extend the Rust `opcua` E2E**

In `gateway/examples/opcua_probe.rs` + `tool/opcua_e2e.sh` (read first): the Dart fixture ensures a `System` tag and auto-generates the OPC UA map; the Rust client Reads `ns=1;s=System.Fault` (asserts a Boolean) and `ns=1;s=System.ScanTimeMs` (asserts a Double). Preserve the honest fallback; run `bash tool/opcua_e2e.sh` and report live vs fallback truthfully.

- [ ] **Step 5: Run tests + commit**

Run: `flutter test test/opcua_address_space_leaf_test.dart test/opcua_services_test.dart` → PASS.
Run: `flutter analyze` → No issues found!

```bash
git add mobile/lib/protocols/opcua/opcua_address_space.dart mobile/test/opcua_address_space_leaf_test.dart gateway/examples/opcua_probe.rs tool/opcua_e2e.sh
git commit -m "feat(opcua): address space resolves dotted leaf paths (System.* exposed); E2E reads System.Fault"
```

---

## Phase B — MQTT interval + deadband

### Task 4: `publishIntervalMs` + `deadband` config, publisher gate, host interval, UI

**Files:**
- Modify: `mobile/lib/models/protocol_settings.dart` (`MqttProtocolConfig`)
- Modify: `mobile/lib/protocols/mqtt/mqtt_publisher.dart` (`changedPublishes`)
- Modify: `mobile/lib/services/mqtt_host.dart` (`_startTickTimer`)
- Modify: `mobile/lib/screens/gateway_screen.dart` (MQTT card: two number fields)
- Test: `mobile/test/models/mqtt_deadband_test.dart` (create) + extend the serialization round-trip test

**Interfaces:**
- Produces: `MqttProtocolConfig.publishIntervalMs` (int, default 250, JSON `publish_interval_ms`), `MqttProtocolConfig.deadband` (double, default 0.0, JSON `deadband`); `changedPublishes` suppresses a numeric metric whose `|Δ| <= deadband`; the host tick uses `publishIntervalMs` (clamped ≥ 20).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/mqtt_deadband_test.dart`. Drive `MqttPublisher` (read the existing MQTT publisher test for the harness — how it calls `birthMessages` then `changedPublishes` with a project + wallMs, and decodes the metric list):

```dart
// Pseudocode contract — implement against the real MqttPublisher API found in
// the existing mqtt publisher test:
// 1. Build a project with one FLOAT64 tag 'A' mapped over MQTT, deadband = 5.0.
// 2. birthMessages(project, 0) to seed the baseline at A's current value (0.0).
// 3. Set A = 3.0 -> changedPublishes suppressed (|3-0| = 3 <= 5).
// 4. Set A = 10.0 -> changedPublishes publishes A (|10-0| = 10 > 5), baseline -> 10.
// 5. deadband 0.0 -> any change publishes (A = 10.0000001 publishes).
// 6. A BOOL/STRING tag always publishes on change regardless of deadband.
```

Write the concrete decode+expect using the existing publisher test's helpers, plus a `MqttProtocolConfig` round-trip test asserting `publishIntervalMs`/`deadband` survive JSON and default to 250/0.0 when absent.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/mqtt_deadband_test.dart`
Expected: FAIL — `deadband`/`publishIntervalMs` undefined; no deadband gate.

- [ ] **Step 3: Implement**

- `MqttProtocolConfig`: add `int publishIntervalMs` (ctor `this.publishIntervalMs = 250`), `double deadband` (ctor `this.deadband = 0.0`); `fromJson`: `publishIntervalMs: (j['publish_interval_ms'] as num?)?.toInt() ?? 250`, `deadband: (j['deadband'] as num?)?.toDouble() ?? 0.0`; `toJson`: `'publish_interval_ms': publishIntervalMs`, `'deadband': deadband`.
- `changedPublishes`: read `cfg.deadband`. For each mapped metric, after computing the current value and the `_lastPublished` baseline: if the value is numeric AND `deadband > 0` AND `(current - last).abs() <= deadband`, skip (don't publish, don't update baseline). BOOL/STRING and `deadband == 0` behave exactly as today.
- `mqtt_host.dart` `_startTickTimer`: read the current project's `cfg.publishIntervalMs`, clamp `max(20, interval)`, and `Timer.periodic(Duration(milliseconds: clamped), _onTick)`. Re-arm on (re)connect (already calls `_startTickTimer`) so a config change picked up next connect.
- `gateway_screen.dart` MQTT card: add two numeric `TextField`s — "Publish interval (ms)" (default 250) and "Deadband (analog)" (default 0.0) — writing `cfg.publishIntervalMs`/`cfg.deadband` and calling the existing config-update callback. Guard layout at 320/360 (vertical, existing field pattern).

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/mqtt_deadband_test.dart test/serialization_roundtrip_test.dart` → PASS.
Run: `flutter test` + `flutter analyze` → green / no issues (existing mqtt_host tests: if any asserted the 50 ms tick literally, update to the config value / injected interval).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/protocol_settings.dart mobile/lib/protocols/mqtt/mqtt_publisher.dart mobile/lib/services/mqtt_host.dart mobile/lib/screens/gateway_screen.dart mobile/test/models/mqtt_deadband_test.dart
git commit -m "feat(mqtt): configurable publish interval (250ms) + analog deadband (0=off)"
```

---

## Phase C — Notify-throttle

### Task 5: Shared notify-throttle + wire into the MQTT host

**Files:**
- Create: `mobile/lib/services/notify_throttle.dart`
- Modify: `mobile/lib/services/mqtt_host.dart`
- Test: `mobile/test/services/notify_throttle_test.dart` (create)

**Interfaces:**
- Produces: `class NotifyThrottle { NotifyThrottle(void Function() onFire, {Duration window}); void request(); void immediate(); void dispose(); }` — `request()` coalesces to at most one `onFire` per `window` (trailing); `immediate()` fires now and resets the window; `dispose()` cancels the timer. Uses only `dart:async`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/services/notify_throttle_test.dart` using `fakeAsync`:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/services/notify_throttle.dart';

void main() {
  test('coalesces rapid requests to one trailing fire per window', () {
    fakeAsync((async) {
      var fires = 0;
      final t = NotifyThrottle(() => fires++, window: const Duration(milliseconds: 250));
      for (var i = 0; i < 20; i++) {
        t.request();
      }
      expect(fires, 0); // trailing — nothing yet
      async.elapse(const Duration(milliseconds: 260));
      expect(fires, 1); // exactly one coalesced fire
      t.dispose();
    });
  });

  test('immediate() fires at once', () {
    fakeAsync((async) {
      var fires = 0;
      final t = NotifyThrottle(() => fires++, window: const Duration(milliseconds: 250));
      t.immediate();
      expect(fires, 1);
      t.dispose();
    });
  });

  test('dispose cancels a pending trailing fire', () {
    fakeAsync((async) {
      var fires = 0;
      final t = NotifyThrottle(() => fires++, window: const Duration(milliseconds: 250));
      t.request();
      t.dispose();
      async.elapse(const Duration(milliseconds: 300));
      expect(fires, 0);
    });
  });
}
```

> If `fake_async` isn't already a dev dependency, the implementer confirms via `pubspec.yaml` (it's used elsewhere in the suite); if absent, use the existing async-test pattern the repo uses instead — keep the assertions equivalent.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/services/notify_throttle_test.dart`
Expected: FAIL — `notify_throttle.dart` missing.

- [ ] **Step 3: Implement**

Create `mobile/lib/services/notify_throttle.dart`:

```dart
import 'dart:async';

/// Coalesces high-frequency notifications to at most one trailing call per
/// [window]. State-change callers use [immediate]; per-tick callers use
/// [request]. Pure `dart:async` — no Flutter.
class NotifyThrottle {
  final void Function() _onFire;
  final Duration _window;
  Timer? _timer;

  NotifyThrottle(this._onFire, {Duration window = const Duration(milliseconds: 250)})
      : _window = window;

  void request() {
    _timer ??= Timer(_window, () {
      _timer = null;
      _onFire();
    });
  }

  void immediate() {
    _timer?.cancel();
    _timer = null;
    _onFire();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
```

In `mqtt_host.dart`: construct a `NotifyThrottle(() => notifyListeners())` (window 250 ms). Route the **per-tick** `_onTick` publish-count `notifyListeners()` through `_throttle.request()`; keep **state-change** notifications (connect / disconnect / error / connack) as `_throttle.immediate()` (or a direct `notifyListeners()` — but prefer `immediate()` so a pending trailing fire is coalesced). Call `_throttle.dispose()` in the host's `dispose()`.

- [ ] **Step 4: Run tests**

Run: `flutter test test/services/notify_throttle_test.dart` → PASS.
Run: `flutter test` + `flutter analyze` → green / no issues (existing mqtt_host tests that asserted a `notifyListeners`/publish-count update after a tick may need to advance fake time by the throttle window — update them to elapse past 250 ms).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/services/notify_throttle.dart mobile/lib/services/mqtt_host.dart mobile/test/services/notify_throttle_test.dart
git commit -m "feat(mqtt): throttle UI notifications to ~4Hz (immediate on state change)"
```

---

## Phase D — Validation, docs, final review

### Task 6: Whole-workstream validation + docs

**Files:**
- Modify: `docs/` (System exposure + MQTT tuning), `ROADMAP.md`
- Test: full suite

- [ ] **Step 1: Full green gate**

From `mobile/`: `flutter test` (report count, all green); `flutter analyze` (**No issues found!**); `flutter build web --release` (compiles). Fix code-caused failures; document environmental ones honestly.

- [ ] **Step 2: Regression + round-trip**

Confirm scalar-only maps unchanged; the serialization round-trip passes and `publishIntervalMs`/`deadband` survive it; existing OPC UA/MQTT service tests pass. Name the files run.

- [ ] **Step 3: E2E result**

Report the `tool/opcua_e2e.sh` outcome (live `System.Fault`/`System.ScanTimeMs` read vs honest fallback) truthfully.

- [ ] **Step 4: Docs + ROADMAP**

Update `docs/simulated-test-tags.md` / `docs/protocols/opcua.md` (or a protocols doc) to note: composite/struct tags (incl. `System`) are exposed as per-field leaf points (dotted paths) when you regenerate a protocol map; `System.*` is read-only on the wire; and MQTT has a configurable publish interval (default 250 ms) + optional analog deadband, with UI notifications throttled. Add a ROADMAP entry. No vendor branding.

```bash
git add docs/ ROADMAP.md
git commit -m "docs(protocols): composite/System tag exposure + MQTT perf tuning; ROADMAP"
```

- [ ] **Step 5: Final whole-branch review**

Dispatch the final code review (opus) over the branch diff; fix Critical/Important findings; then finish the branch (merge `--no-ff` + push) per finishing-a-development-branch.

---

## Self-Review notes (author)

- **Spec coverage:** scalar-leaf enumeration (T1); four maps expand composites + STRING skip rules + access/folder inheritance + scalar-only regression (T2); OPC UA dotted-path resolution + E2E (T3); MQTT interval + deadband config/publisher/host/UI + round-trip (T4); notify-throttle + host wiring (T5); validation/docs/final review (T6). All spec sections mapped.
- **Type consistency:** `scalarLeaves`/`TagLeaf` defined in T1, consumed in T2; `tag: <dotted path>` entries from T2 consumed by the T3 address-space resolver (`dataTypeOfPath`/`readPath`); `publishIntervalMs`/`deadband` defined in T4 and used by host (T4) — no cross-task name drift; `NotifyThrottle.request/immediate/dispose` defined in T5 and wired in T5.
- **Ordering:** A(1→2→3) → B(4) → C(5) → D(6). Leaf helper (T1) precedes the maps (T2); maps' dotted `tag` values precede the address-space resolver (T3). Perf (B/C) is independent of A.
