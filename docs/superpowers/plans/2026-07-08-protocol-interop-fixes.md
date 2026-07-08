# Protocol Interop Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the in-app OPC UA and Modbus servers faithfully reflect real tag state to a strict SCADA client — fix OPC UA discovery/browse, make forced values authoritative everywhere, and give Modbus an editable tag→register map (incl. struct members).

**Architecture:** Three field-found defects fixed as one workstream. The keystone is a single read seam: `readPath` returns a forced scalar tag's `forcedValue`, so logic engines and both protocol servers observe forces with no per-consumer change. OPC UA gains the standard `Server`/`NamespaceArray` nodes + top-down browse + a reachable advertised endpoint. Modbus gains an editable map-row UI and resolver-based dotted-path type/force resolution.

**Tech Stack:** Flutter/Dart (pure model + widgets), Rust E2E probes (`opcua`/`tokio-modbus`). Spec: `docs/superpowers/specs/2026-07-08-protocol-interop-fixes-design.md`.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); OPC UA / Modbus / IEC terms are fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces on all control flow; prefer `const`; color alpha via `withValues(alpha:)`.
- `mobile/lib/protocols/**` and `mobile/lib/models/**` stay pure Dart (no Flutter/`dart:io`).
- Forcing is authoritative for **reads** everywhere; write force-skip semantics (engines + both protocol servers) stay unchanged.
- No persistence schema change (`isForced`/`forcedValue`/`modbus.map` already persist); the WS6 lossless round-trip guard stays green.
- OPC UA additions are Read/Browse-only and standards-accurate; cross-check every standard NodeId/attribute/encoding against the vendored Rust `opcua` 0.12.0 source at `C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/`, citing files inline as the existing code does. The server must never crash on malformed input.
- Run commands from `mobile/` for Flutter, repo root for `git`, and `gateway/` for `cargo`.

---

### Task 1: Forcing → effective value (the read seam)

**Files:**
- Modify: `mobile/lib/models/tag_resolver.dart` (function `readPath`, the `dynamic cur = root.value;` line ~220)
- Test: `mobile/test/models/tag_resolver_force_test.dart` (new)

**Interfaces:**
- Consumes: `PlcTag.isForced` (bool), `PlcTag.forcedValue` (dynamic), `PlcTag.value` (dynamic) — existing fields in `project_model.dart`.
- Produces: `readPath(PlcProject, String)` now returns the forced value for a forced **scalar** root tag; behavior for unforced tags and composite (Map/List) tags is unchanged. Every existing caller (logic engines, `opcua_address_space.dart`'s `readVariant`, `modbus_pdu.dart`'s reads) inherits the fix with no change.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/tag_resolver_force_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/project_model.dart';
import 'package:mobile/models/tag_resolver.dart';

PlcProject _proj(List<PlcTag> tags) => PlcProject(
      id: 'p', name: 'p', tags: tags, programs: const [], hmis: const [],
    );

void main() {
  group('readPath force overlay', () {
    test('forced BOOL scalar reads forcedValue, not stored value', () {
      final p = _proj([
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL',
            value: false, ioType: 'SimulatedInput', isForced: true, forcedValue: true),
      ]);
      expect(readPath(p, 'Start_PB'), true);
    });

    test('unforced tag reads stored value', () {
      final p = _proj([
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL',
            value: false, ioType: 'SimulatedInput'),
      ]);
      expect(readPath(p, 'Start_PB'), false);
    });

    test('forced numeric scalar reads forcedValue', () {
      final p = _proj([
        PlcTag(name: 'Speed', path: 'Internal/Speed', dataType: 'INT32',
            value: 10, ioType: 'Internal', isForced: true, forcedValue: 55),
      ]);
      expect(readPath(p, 'Speed'), 55);
    });

    test('forced integer bit-read reflects forced integer', () {
      // forcedValue 0x04 -> bit 2 set, bits 0/1 clear.
      final p = _proj([
        PlcTag(name: 'Word', path: 'Internal/Word', dataType: 'INT16',
            value: 0, ioType: 'Internal', isForced: true, forcedValue: 4),
      ]);
      expect(readPath(p, 'Word.2'), true);
      expect(readPath(p, 'Word.0'), false);
    });

    test('force cleared returns to live value', () {
      final p = _proj([
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL',
            value: false, ioType: 'SimulatedInput', isForced: false, forcedValue: true),
      ]);
      expect(readPath(p, 'Start_PB'), false);
    });
  });
}
```

Adjust the `PlcProject`/`PlcTag` constructor calls if the real required params differ (read `project_model.dart` first and match exactly).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/models/tag_resolver_force_test.dart`
Expected: the "forced ..." cases FAIL (return the stored value), unforced cases pass.

- [ ] **Step 3: Write minimal implementation**

In `tag_resolver.dart`, in `readPath`, replace:

```dart
  dynamic cur = root.value;
```

with:

```dart
  // Forcing is authoritative for reads: a forced SCALAR root tag resolves to
  // its forcedValue everywhere (logic engines + OPC UA + Modbus all read
  // through here). Composite (struct/array) tags are never forceable in the
  // UI, so they keep their live Map/List value. Seeding the walk from the
  // forced value also makes a bit-read of a forced integer (e.g. `Word.2`)
  // reflect the force.
  dynamic cur = (root.isForced && root.value is! Map && root.value is! List)
      ? root.forcedValue
      : root.value;
```

- [ ] **Step 4: Run the new test + the full resolver + engine suites**

Run: `cd mobile && flutter test test/models/tag_resolver_force_test.dart test/models/`
Expected: PASS. If any pre-existing engine/resolver test breaks, investigate — a break most likely means that test asserted the old display-only behavior and must be reconciled with the intended semantics (report it, don't silently rewrite an assertion whose intent you can't confirm).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/tag_resolver.dart mobile/test/models/tag_resolver_force_test.dart
git commit -m "fix(forcing): make forced scalar values authoritative in readPath"
```

---

### Task 2: OPC UA discovery — NamespaceArray, Server node, top-down browse, endpoint echo

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_address_space.dart` (standard NodeId constants + browse/read plumbing)
- Modify: `mobile/lib/protocols/opcua/opcua_services.dart` (`_writeBrowseResult`, `_readAttribute`/`_handleRead`)
- Modify: `mobile/lib/protocols/opcua/opcua_session.dart` and `mobile/lib/services/opcua_host.dart` (advertise the client-dialed endpoint host)
- Test: `mobile/test/protocols/opcua/opcua_discovery_test.dart` (new)

**Interfaces:**
- Consumes: existing `OpcUaAddressSpace`, `OpcUaWriter` (`variant`, `nodeId`, `expandedNodeId`, `qualifiedName`, `localizedText`), `OpcVariant(typeId, value, isArray)`, `OpcNodeId.numeric/string`, `OpcDataValue`.
- Produces: Read of `ns=0;i=2255` → `OpcVariant(typeId: 12, isArray: true, value: ['http://opcfoundation.org/UA/', namespaceUri])`; Browse of `i=84` returns `i=85`; Browse of `i=85` returns the `Server` object (`i=2253`) + all tag variables; advertised `endpointUrl` matches the client's dialed host.

**Standard NodeIds to add** (namespace 0, verify each against `types/node_ids.rs`): `serverNode i=2253`, `serverNamespaceArray i=2255`, `propertyType i=68`, `serverType i=2004`, `hasPropertyReferenceType i=46`, `hasComponentReferenceType i=47`. The `namespaceUri` for index 1 is `project.protocols.opcua.namespaceUri` (already on `OpcUaServerInfo`); thread it into the services layer if not already reachable there (it is available via `projectProvider()`).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/protocols/opcua/opcua_discovery_test.dart` driving the pure services layer the same way the existing OPC UA service tests do (read one first for the exact request/response harness helpers). Assert:
1. A Read of attribute `Value` on `ns=0;i=2255` returns a String array Variant whose `[0] == 'http://opcfoundation.org/UA/'` and `[1] == '<the project namespaceUri>'`.
2. A Browse of `ns=0;i=84` returns exactly one reference to `ns=0;i=85` (Objects), `Organizes`, forward.
3. A Browse of `ns=0;i=85` returns references that include `ns=0;i=2253` (Server) **and** one per mapped tag.

Use a fixture project with a non-empty `opcua.map` (mirror the setup in the existing OPC UA service test).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/protocols/opcua/opcua_discovery_test.dart`
Expected: FAIL — i=2255 read returns `Bad_NodeIdUnknown`; Browse of i=84 returns `Bad_NodeIdUnknown`; Browse of i=85 lists only tags.

- [ ] **Step 3: Implement**

1. **Address space** (`opcua_address_space.dart`): add the standard NodeId constants above. Add helpers so the services layer can ask: `isRootFolder(nodeId)`, `isServerNode(nodeId)`, `isNamespaceArrayNode(nodeId)`, and get the namespace-array String list (`['http://opcfoundation.org/UA/', namespaceUri]`) — the space already holds `namespaceUri` via the built project (add a field capturing `project.protocols?.opcua?.namespaceUri ?? ''` in `build`).
2. **Browse** (`_writeBrowseResult`): when the node is Root (`i=84`), emit exactly one forward `Organizes` reference to the Objects folder (`i=85`, nodeClass Object, typeDefinition `FolderType i=61`). When the node is Objects (`i=85`), prepend a forward `Organizes` reference to the `Server` object (`i=2253`, nodeClass Object, typeDefinition `ServerType i=2004`) before the existing tag references. Keep the malformed→`Bad_NodeIdUnknown` fallback for everything else.
3. **Read** (`_readAttribute`): special-case the standard nodes before the `space.byNodeId` lookup:
   - `i=2255` (NamespaceArray): `Value` → the String array Variant; `NodeClass` → Variable; `BrowseName`/`DisplayName` → "NamespaceArray"; `DataType` → String (`i=12`); `AccessLevel`/`UserAccessLevel` → read-only (`0x01`).
   - `i=2253` (Server): `NodeClass` → Object; `BrowseName`/`DisplayName` → "Server". (A Read of its `Value` is not applicable — return `Bad_AttributeIdInvalid`, matching the existing default.)
   Everything else keeps returning `Bad_NodeIdUnknown`.
4. **Endpoint echo** (`opcua_session.dart` + `opcua_host.dart`): capture the client-supplied `endpointUrl` from the Hello/GetEndpoints/CreateSession exchange (the session already reads it — `reader.string(); // endpointUrl`) and use its host in the `EndpointDescription.endpointUrl` returned by `GetEndpoints` and `CreateSession`, instead of the `_bestDisplayHost()` value. If the client-supplied URL is empty/unparseable, fall back to the current `_bestDisplayHost()` endpoint. Keep the UI-displayed endpoint (`_endpointUrl`) as-is.

Cross-check the ReferenceDescription field order and the String-array Variant encoding against the existing `_writeBrowseResult` and `OpcUaWriter.variant` — do not invent a new encoding.

- [ ] **Step 4: Run tests**

Run: `cd mobile && flutter test test/protocols/opcua/`
Expected: PASS (new discovery tests + all existing OPC UA tests still green).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/opcua/ mobile/lib/services/opcua_host.dart mobile/test/protocols/opcua/opcua_discovery_test.dart
git commit -m "fix(opcua): serve NamespaceArray/Server node, browse from Root, echo client endpoint host"
```

---

### Task 3: Modbus map editor + dotted-path type/force resolution

**Files:**
- Modify: `mobile/lib/protocols/modbus/modbus_pdu.dart` (`_tagDataType`, `_findRootTag`/`_isForcedSkip`, `_widthForEntry`)
- Modify: `mobile/lib/screens/gateway_screen.dart` (Modbus card: entry-row editor + dotted-path tag options)
- Test: `mobile/test/protocols/modbus/modbus_dotted_path_test.dart` (new) and `mobile/test/screens/modbus_map_editor_test.dart` (new widget test)

**Interfaces:**
- Consumes: `readPath`/`writePath` (dotted paths already supported), `childrenOf(PlcProject, String)` → `List<TagChild{label, path, dataType, arrayLength, value, hasChildren}>`, the OPC UA card's `_mapEditorCard`/`_nodeRow` pattern to mirror, `ModbusMapEntry{tag, table, address, access}`.
- Produces: the Modbus handler resolves a mapped entry's data type and forced-root from its (possibly dotted) `tag` path; the Modbus card can Add/edit/delete entry rows and offers composite members as tag options.

- [ ] **Step 1: Write the failing tests**

`modbus_dotted_path_test.dart`: build a project with a struct tag (e.g. `Motor` with a `Speed: INT32` field), a `ModbusMap` with a hand-added `holding` entry `tag: 'Motor.Speed'`, and assert:
1. Reading the 2 holding registers for that entry decodes back to the tag's INT32 value (proves width + type resolved via path, not the INT16 fallback).
2. With the root `Motor` tag forced, a FC06/FC10 write to that entry is skipped (value unchanged) and still echoes success.

Model the request/response harness on the existing `modbus_pdu_test.dart`. (If per-field forcing isn't representable, force the whole root tag and assert the write skip.)

`modbus_map_editor_test.dart`: pump the gateway screen (or the extracted Modbus card widget) with a fixture project, tap **Add entry**, pick a tag/table/address/access, and assert a `ModbusMapEntry` was appended to `project.protocols.modbus.map.entries`; edit and delete a row and assert the map updates. Mirror the existing OPC UA map-editor widget test if one exists.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/protocols/modbus/modbus_dotted_path_test.dart test/screens/modbus_map_editor_test.dart`
Expected: FAIL — dotted type resolves to INT16 fallback (wrong width/value); no Add-entry affordance exists.

- [ ] **Step 3: Implement**

1. **Handler** (`modbus_pdu.dart`): change `_tagDataType(project, tagName)` to resolve the data type of a **path** — walk the path via the resolver (reuse `childrenOf`/the field-def walk, or add a small `dataTypeOfPath` helper in `tag_resolver.dart` and call it) so `Motor.Speed` → `INT32`. Change `_isForcedSkip` to find the **root** tag of the path (`path.split('.').first.split('[').first`) and honor its `isForced` (mirror the engines' `_forceAwareWrite` root resolution). `_widthForEntry` then gets the correct width for dotted entries.
2. **UI** (`gateway_screen.dart`): add a Modbus map-editor section mirroring `_mapEditorCard`/`_nodeRow` — one row per `ModbusMapEntry` (tag dropdown, table dropdown `coil`/`discrete`/`holding`/`input`, address `TextField` (int), access dropdown), an **Add entry** button (appends a default entry), a per-row delete, and the existing **Regenerate**. Build tag options from top-level tags **plus** composite members via `childrenOf` (dotted paths). Every mutation calls the same `onProjectChanged`/autosave path the OPC UA editor uses. Keep rows overflow-safe at 320/360/1400 (use the OPC UA row layout).

- [ ] **Step 4: Run tests**

Run: `cd mobile && flutter test test/protocols/modbus/ test/screens/modbus_map_editor_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/modbus/modbus_pdu.dart mobile/lib/screens/gateway_screen.dart mobile/lib/models/tag_resolver.dart mobile/test/protocols/modbus/modbus_dotted_path_test.dart mobile/test/screens/modbus_map_editor_test.dart
git commit -m "feat(modbus): editable map rows + dotted-path (struct member) type/force resolution"
```

---

### Task 4: Machine-proof E2E + validation + docs + final review

**Files:**
- Modify: `gateway/examples/opcua_probe.rs` (browse-from-Root + read NamespaceArray)
- Modify: `gateway/examples/modbus_probe.rs` (force→coil + dotted-member register)
- Modify: `docs/protocols/opcua.md`, `docs/protocols/modbus.md`, `ROADMAP.md`
- Modify (fixture, if needed): the probe harness fixture project (`mobile/tool/*_host_probe.dart`) to include a forced tag + a struct member mapping

**Interfaces:**
- Consumes: the running in-app hosts (Dart) and the existing `tool/opcua_e2e.sh` / `tool/modbus_e2e.sh` harnesses.
- Produces: `OPC UA PROBE PASS` only if a top-down browse from Root reaches the tags and NamespaceArray[1] is the project URI; `MODBUS PROBE PASS` only if a forced tag reads back forced over Modbus.

- [ ] **Step 1: Extend the OPC UA probe**

In `opcua_probe.rs`: after session activation, read `NamespaceArray` (`ns=0;i=2255`) and assert index 1 equals the project namespace URI; browse `RootFolder` → `ObjectsFolder` → variables and assert the fixture's tags are found by walking from Root (not by addressing Objects directly). Fail loudly otherwise.

- [ ] **Step 2: Extend the Modbus probe**

In `modbus_probe.rs` (and the Dart host-probe fixture): mark a coil-mapped tag `isForced: true, forcedValue: true` in the fixture, read that coil, and assert it reads **1** — the falsifiable proof the force reaches Modbus. Add a struct-member holding-register read asserting the decoded value. Keep the existing read/write assertions.

- [ ] **Step 3: Run both E2E probes**

Run: `bash tool/opcua_e2e.sh` and `bash tool/modbus_e2e.sh` (or the documented equivalents).
Expected: `OPC UA PROBE PASS` and `MODBUS PROBE PASS`. If the environment can't run a probe, say so explicitly and fall back to `cargo build --examples` + the Dart host/unit tests — do not claim a pass that didn't run.

- [ ] **Step 4: Full regression gate**

Run, and paste the real output:
- `cd mobile && flutter test`
- `cd mobile && flutter analyze` (expect zero issues)
- `cd mobile && flutter build web --release` (compiles)
- `cd gateway && cargo build --examples`

- [ ] **Step 5: Docs + roadmap**

Update `docs/protocols/opcua.md` (NamespaceArray/Server node/top-down browse/endpoint echo now supported), `docs/protocols/modbus.md` (editable map + struct-member mapping + forcing now visible over Modbus), and add a short note to `ROADMAP.md` that live Ignition/Modbus interop surfaced and fixed these. No vendor branding.

- [ ] **Step 6: Commit**

```bash
git add gateway/examples/ mobile/tool/ docs/ ROADMAP.md
git commit -m "test(interop): E2E proof of OPC UA discovery + forced-value read-through; docs"
```

- [ ] **Step 7: Whole-branch review** — dispatch the final code reviewer (superpowers:requesting-code-review) over the full branch diff, then use superpowers:finishing-a-development-branch to merge to `main` ahead of MQTT.
