# EtherNet/IP CIP Symbol Object browse — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the CIP Symbol Object (class 0x6B) — plus the Identity Object the client reads first — so a Logix-style client (`pycomm3` `LogixDriver`, Ignition's AB Logix driver) auto-discovers the app's mapped tags at connect.

**Architecture:** Two new pure-Dart CIP codecs — `cip_symbol.dart` (Get Instance Attribute List over class 0x6B, with 0x06 pagination) and `cip_identity.dart` (Identity Object Get Attributes All + encapsulation ListIdentity) — routed through the existing `dispatchCipService` seam and the existing encapsulation-command switch. Every exposed tag is already an atomic scalar leaf, so no Template Object (class 0x6C) is built; each `CipMap` entry becomes one flat atomic Symbol instance. Two real-`pycomm3` gates prove it: a deterministic generic-messaging browse (Task 2) and the full `LogixDriver.open()`+`get_tag_list()` path (Task 3).

**Tech Stack:** Dart / Flutter (`mobile/`), pure-Dart CIP codecs under `mobile/lib/protocols/enip/`, `dart:io` socket host under `mobile/lib/services/enip_host.dart`, Python `pycomm3` probe lane under `tool/py/` driven by `tool/enip_e2e.sh`.

## Global Constraints

- Pure Dart in `lib/protocols/` and `lib/models/` — no `dart:io`, no Flutter imports; only `lib/services/*_host.dart` may use `dart:io`.
- Codecs NEVER throw on malformed/truncated/hostile input — return `null` or an error-status response, mirroring `cip.dart`/`enip_encap.dart`.
- Deterministic — no clock, no randomness in codec/dispatch logic (stable instance-id order; a fixed serial number, never a generated one).
- Additive/backward-compatible: no existing serialized shape changes; a project that never enables EtherNet/IP is byte-for-byte unaffected; every non-browse CIP service stays byte-identical.
- LITTLE-endian on the wire for all multi-byte CIP fields (matches `cip.dart`: `Endian.little`).
- The real `pycomm3` client is the wire authority: when it disagrees with our unit tests, fix the Dart and report it. Assert literal bytes, never only round-trips.
- Zero `flutter analyze` warnings; braces on all control flow; `withValues(alpha:)` not `withOpacity` (no UI here, but the rule stands).
- **Runtime errors are visible in the in-app Logs screen.** Any browse/identity request that the running host answers with a non-success CIP status (a malformed browse request, an unsupported service, an unresolvable/absent object) is logged to `kLogSourceEnip` via the host's `AppLogger` so it appears in the Logs view. The pure codecs stay logger-free (they only return statuses); the **host** logs the outcome, using the existing first-occurrence `DropLogGate`/`_logDrop` pattern so a polling client cannot spam the log. Normal pagination (status 0x06 Partial Transfer) is NOT an error — log it at most at `debug`, never `warn`.
- No competitor programming-software branding, and **do not impersonate a real vendor**: the simulator's Identity reports a neutral, honest self-description, never a real vendor's assigned Vendor ID or product identity.

---

## File Structure

- `mobile/lib/protocols/enip/cip.dart` — MODIFY: add the new service code (0x55), the new general-status code (0x06 Partial Transfer), and the Symbol/Identity class-id constants, alongside the existing CIP constant blocks.
- `mobile/lib/protocols/enip/cip_symbol.dart` — CREATE: Symbol Object browse codec (request parse + reply build + pagination). Pure.
- `mobile/lib/protocols/enip/cip_identity.dart` — CREATE: Identity Object Get Attributes All reply + ListIdentity reply, with the simulator's honest identity constants. Pure.
- `mobile/lib/protocols/enip/cip_tags.dart` — MODIFY: `dispatchCipService` routes 0x55@class-0x6B to the Symbol browse and Get-Attributes-All@class-0x01 to the Identity Object.
- `mobile/lib/services/enip_host.dart` — MODIFY: answer the ListIdentity encapsulation command (0x63) at the encapsulation layer.
- `mobile/tool/enip_host_probe.dart` — MODIFY: the fixture already has a `CipMap`; no tag changes needed, but confirm it exercises browse.
- `tool/py/enip_probe.py` — MODIFY: add a deterministic generic-messaging browse assertion (Task 2) and the full `LogixDriver` browse E2E (Tasks 3–4).
- `docs/protocols/ethernet-ip.md`, `README.md` — MODIFY (Task 4): document the shipped browse, move Symbol/Identity out of "deferred."

---

## Task 1: Symbol Object browse codec (`cip_symbol.dart`)

**Files:**
- Modify: `mobile/lib/protocols/enip/cip.dart` (add constants)
- Create: `mobile/lib/protocols/enip/cip_symbol.dart`
- Test: `mobile/test/cip_symbol_test.dart`

**Interfaces:**
- Consumes (from `cip.dart`): `CipRequest`, `CipResponse`, `CipPathSegment`, `CipPathSegmentKind`, `cipTypeForTagType(String) → int?`, `kCipStatusSuccess`, and the new constants added in Step 1.
- Consumes (from models): `PlcProject`, `CipMap`, `CipMapEntry`, `dataTypeOfPath(PlcProject, String) → String?` (from `models/tag_resolver.dart`).
- Produces (for Task 2's dispatch wiring):
  - `GetInstanceAttrListRequest? parseGetInstanceAttrListRequest(CipRequest req)` — returns `{int startInstance, List<int> attributeIds}` or `null` if the path/data is malformed.
  - `CipResponse buildSymbolInstanceListResponse(PlcProject project, CipMap map, GetInstanceAttrListRequest parsed, {required int replyBudget})` — the Symbol Object reply (never throws).
  - `bool isSymbolObjectPath(List<CipPathSegment> path)` — true iff the path's first segment is `classId == kCipSymbolObjectClassId`.

### Background for the implementer

CIP **Get Instance Attribute List (service 0x55)** on the **Symbol Object (class 0x6B)** is how a Logix client uploads the controller tag list. Request path = logical `Class 0x6B` then (optionally) `Instance <start>`; request data = attribute-count (u16) then that many attribute ids (u16 each) — the client asks for **attr 1 (symbol name)** and **attr 2 (symbol type)**. The reply lists, for each instance in ascending id order from `<start>`: instance id (u32), then the requested attributes in order — attr 1 as a u16-length-prefixed ASCII string, attr 2 as a u16 elementary type code. If more instances remain than fit `replyBudget`, the reply stops early and its general status is **0x06 (Partial Transfer)**; the client re-requests from `lastReturnedId + 1`.

This app exposes only **atomic scalar leaves** (`CipMap.autoPopulate` pre-expands composites into dotted leaves like `Tank.Level` and skips `STRING`). Each `CipMapEntry` therefore becomes exactly one flat Symbol instance: **instance id = its 1-based index in `map.entries`**, **name = `entry.tagName`** verbatim (dotted names included), **type = `cipTypeForTagType(dataTypeOfPath(project, entry.tagName))`**. An entry whose type has no CIP mapping (a stale `STRING` entry) is **omitted from the listing entirely** — it never occupies an instance id (skip it while numbering, so ids stay dense over the *listable* entries; see Step 7).

The u16-length string layout for attr 1 is this codec's best reading of the Symbol Object spec; it is **verified against `pycomm3`'s own parser at the Task-2 gate** — if pycomm3 reads names wrongly, that layout is corrected there and this test updated.

- [ ] **Step 1: Add the constants to `cip.dart`**

In `mobile/lib/protocols/enip/cip.dart`, add to the service-code block (after `kCipServiceMultipleServicePacket`):

```dart
/// Get Instance Attribute List — enumerates a class's instances and the
/// requested attributes of each. Used here only against the Symbol Object
/// (class 0x6B) to serve a Logix-style client's tag-directory upload.
const int kCipServiceGetInstanceAttributeList = 0x55;
```

Add to the general-status block (after `kCipStatusSuccess`):

```dart
/// "Partial Transfer" — a Get Instance Attribute List reply that could not
/// fit every remaining instance in one reply; the client re-requests from
/// the last returned instance id + 1 until a success (0x00) completes it.
const int kCipStatusPartialTransfer = 0x06;
```

Add a new class-id block near the data-type codes:

```dart
// --- CIP object class ids (served objects) -------------------------------

/// Symbol Object — the controller tag directory a Logix-style client uploads.
const int kCipSymbolObjectClassId = 0x6B;

/// Identity Object — vendor/product/revision/serial a Logix-style client
/// reads at connect (via Get Attributes All) before uploading tags.
const int kCipIdentityObjectClassId = 0x01;

/// Get Attributes All — returns an object instance's attributes as one
/// packed structure. Served here only for the Identity Object.
const int kCipServiceGetAttributesAll = 0x01;
```

- [ ] **Step 2: Write the failing test — request parse**

Create `mobile/test/cip_symbol_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_symbol.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/cip_map.dart';

void main() {
  group('parseGetInstanceAttrListRequest', () {
    test('reads the start instance from the path and the attribute id list from data', () {
      // Path: Class 0x6B, Instance 0. Data: attr count 2, ids [1, 2].
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId), CipPathSegment.instanceId(0)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00, 0x02, 0x00]),
      );
      final parsed = parseGetInstanceAttrListRequest(req);
      expect(parsed, isNotNull);
      expect(parsed!.startInstance, 0);
      expect(parsed.attributeIds, [1, 2]);
    });

    test('defaults the start instance to 0 when the path has only a class segment', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId)],
        data: Uint8List.fromList([0x01, 0x00, 0x01, 0x00]),
      );
      final parsed = parseGetInstanceAttrListRequest(req);
      expect(parsed, isNotNull);
      expect(parsed!.startInstance, 0);
      expect(parsed.attributeIds, [1]);
    });

    test('returns null on a truncated attribute list (count claims more ids than present)', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00]), // count 2 but only 1 id
      );
      expect(parseGetInstanceAttrListRequest(req), isNull);
    });
  });
}
```

- [ ] **Step 3: Run — expect FAIL**

Run: `cd mobile && flutter test test/cip_symbol_test.dart`
Expected: FAIL — `cip_symbol.dart` / `parseGetInstanceAttrListRequest` undefined.

- [ ] **Step 4: Create `cip_symbol.dart` with the request parser**

Create `mobile/lib/protocols/enip/cip_symbol.dart`:

```dart
// CIP Symbol Object (class 0x6B) browse codec — pure Dart, no dart:io /
// Flutter. Serves Get Instance Attribute List (0x55) so a Logix-style client
// (pycomm3 LogixDriver, Ignition's AB Logix driver) uploads the tag
// directory at connect. Every exposed tag is an atomic scalar leaf (see
// models/cip_map.dart), so each CipMap entry is one flat atomic Symbol
// instance — no Template Object (class 0x6C) is involved. Sits ABOVE the CIP
// messaging layer (cip.dart) and reuses the same tag resolver the Read/Write
// Tag services use.
//
// Wire layout (Get Instance Attribute List over class 0x6B):
//  - Request path: logical Class 0x6B, then optionally Instance <start>.
//  - Request data: attribute-count (u16) + that many attribute ids (u16).
//  - Reply data: per returned instance, in ascending id order from <start>:
//      instance id (u32), then each requested attribute in order:
//        attr 1 (symbol name): u16 byte-length + that many ASCII bytes.
//        attr 2 (symbol type): u16 elementary CIP type code.
//  - Status: 0x00 when the last instance fit; 0x06 (Partial Transfer) when
//    instances remain — the client re-requests from lastReturnedId + 1.
//
// Non-throwing contract: parse/build are fed wire-derived data and must never
// throw; parse returns null, build returns an error-status CipResponse.
library cip_symbol;

import 'dart:convert';
import 'dart:typed_data';

import '../../models/cip_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'cip.dart';

/// The Symbol Object attribute ids this codec can emit.
const int kCipSymbolAttrName = 1;
const int kCipSymbolAttrType = 2;

/// A parsed Get Instance Attribute List request: the instance to start
/// enumerating from, and the ordered attribute ids the client asked for.
class GetInstanceAttrListRequest {
  final int startInstance;
  final List<int> attributeIds;
  const GetInstanceAttrListRequest({required this.startInstance, required this.attributeIds});
}

/// True iff [path]'s first segment is the Symbol Object class.
bool isSymbolObjectPath(List<CipPathSegment> path) =>
    path.isNotEmpty &&
    path[0].kind == CipPathSegmentKind.classId &&
    path[0].id == kCipSymbolObjectClassId;

/// Parses a Get Instance Attribute List [req]. The start instance is the
/// path's Instance segment value (0 if the path has no instance segment);
/// the attribute id list is `count` (u16) then that many u16 ids. Returns
/// `null` (never throws) on malformed input.
GetInstanceAttrListRequest? parseGetInstanceAttrListRequest(CipRequest req) {
  var startInstance = 0;
  for (final seg in req.path) {
    if (seg.kind == CipPathSegmentKind.instanceId) {
      startInstance = seg.id ?? 0;
    }
  }
  final data = req.data;
  if (data.length < 2) {
    return null;
  }
  final count = ByteData.sublistView(data, 0, 2).getUint16(0, Endian.little);
  final idsEnd = 2 + count * 2;
  if (idsEnd > data.length) {
    return null;
  }
  final ids = <int>[];
  for (var i = 0; i < count; i++) {
    ids.add(ByteData.sublistView(data, 2 + i * 2, 4 + i * 2).getUint16(0, Endian.little));
  }
  return GetInstanceAttrListRequest(startInstance: startInstance, attributeIds: ids);
}
```

- [ ] **Step 5: Run — expect PASS**

Run: `cd mobile && flutter test test/cip_symbol_test.dart`
Expected: PASS (the 3 request-parse tests).

- [ ] **Step 6: Write the failing test — reply build (byte-exact) + pagination**

Add to `mobile/test/cip_symbol_test.dart` a helper that builds a project + map, then these tests:

```dart
  // A project whose scalar leaves are exactly the map entries below.
  PlcProject _project() => PlcProject(
        id: 'p', name: 'p', controllerName: 'PLC',
        tags: [
          PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: true, ioType: 'Internal'),
          PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT32', value: 100, ioType: 'Internal'),
          PlcTag(name: 'Level', path: 'Internal.Level', dataType: 'FLOAT64', value: 1.5, ioType: 'Internal'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [],
      );

  CipMap _map() => CipMap(entries: [
        CipMapEntry(tagName: 'Running', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Speed', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Level', access: 'ReadWrite'),
      ]);

  group('buildSymbolInstanceListResponse', () {
    test('emits instance id (u32) + name (u16 len + ascii) + type (u16) per entry, status 0x00 when all fit', () {
      final parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(_project(), _map(), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      // First instance: id=1, name="Running" (7 bytes), type BOOL 0xC1.
      final d = resp.data;
      expect(ByteData.sublistView(d, 0, 4).getUint32(0, Endian.little), 1);
      expect(ByteData.sublistView(d, 4, 6).getUint16(0, Endian.little), 7); // name len
      expect(String.fromCharCodes(d.sublist(6, 13)), 'Running');
      expect(ByteData.sublistView(d, 13, 15).getUint16(0, Endian.little), kCipTypeBool);
    });

    test('a tiny budget returns only the instances that fit, with status 0x06 (partial)', () {
      final parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      // Budget only large enough for the first instance.
      final resp = buildSymbolInstanceListResponse(_project(), _map(), parsed, replyBudget: 20);
      expect(resp.generalStatus, kCipStatusPartialTransfer);
      // Only instance 1 present.
      expect(ByteData.sublistView(resp.data, 0, 4).getUint32(0, Endian.little), 1);
      expect(resp.data.length < 40, isTrue);
    });

    test('resuming from startInstance skips already-sent instances', () {
      final parsed = GetInstanceAttrListRequest(startInstance: 2, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(_project(), _map(), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      // First returned instance id is 2 (Speed), not 1.
      expect(ByteData.sublistView(resp.data, 0, 4).getUint32(0, Endian.little), 2);
    });

    test('empty map returns status 0x00 and zero-length data', () {
      final parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(_project(), CipMap(entries: []), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(resp.data, isEmpty);
    });

    test('a dotted-name entry is listed verbatim as one flat symbol', () {
      final project = PlcProject(
        id: 'p', name: 'p', controllerName: 'PLC',
        tags: [PlcTag(name: 'Tank', path: 'Internal.Tank', dataType: 'INT32', value: 0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: [],
      );
      final map = CipMap(entries: [CipMapEntry(tagName: 'Tank.Level', access: 'ReadWrite')]);
      final parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(project, map, parsed, replyBudget: 4096);
      // dataTypeOfPath resolves 'Tank.Level' to INT32; name is the dotted string.
      expect(ByteData.sublistView(resp.data, 4, 6).getUint16(0, Endian.little), 10); // "Tank.Level"
      expect(String.fromCharCodes(resp.data.sublist(6, 16)), 'Tank.Level');
    });
  });
```

- [ ] **Step 7: Run — expect FAIL, then implement the reply builder**

Run: `cd mobile && flutter test test/cip_symbol_test.dart` → FAIL (`buildSymbolInstanceListResponse` undefined).

Append to `cip_symbol.dart`:

```dart
/// The fixed per-instance overhead (bytes) besides the name payload: 4-byte
/// instance id + 2-byte name-length field + 2-byte type field. Used to
/// budget each instance before admitting it.
const int _kSymbolInstanceFixedBytes = 8;

/// Builds the Symbol Object Get Instance Attribute List reply for [map]'s
/// entries (each a flat atomic symbol), starting at
/// [parsed].startInstance and honoring [parsed].attributeIds (attr 1 name,
/// attr 2 type). Instance id = 1-based index over the LISTABLE entries (an
/// entry with no CIP type is skipped and consumes no id). Emits instances
/// until the next would exceed [replyBudget], then sets status 0x06;
/// otherwise 0x00. Never throws.
CipResponse buildSymbolInstanceListResponse(
  PlcProject project,
  CipMap map,
  GetInstanceAttrListRequest parsed, {
  required int replyBudget,
}) {
  // Number the listable entries 1..N, skipping entries with no CIP type.
  final listable = <({int id, String name, int typeCode})>[];
  var nextId = 1;
  for (final entry in map.entries) {
    final dataType = dataTypeOfPath(project, entry.tagName);
    final typeCode = dataType == null ? null : cipTypeForTagType(dataType);
    if (typeCode == null) {
      continue; // stale STRING / unresolved entry: not listable, no id burned.
    }
    listable.add((id: nextId, name: entry.tagName, typeCode: typeCode));
    nextId++;
  }

  final out = BytesBuilder();
  var partial = false;
  for (final sym in listable) {
    if (sym.id < parsed.startInstance) {
      continue; // already delivered in an earlier page.
    }
    final nameBytes = _asciiBytes(sym.name);
    final cost = _kSymbolInstanceFixedBytes + nameBytes.length;
    if (out.length + cost > replyBudget) {
      partial = true;
      break;
    }
    final idBytes = ByteData(4)..setUint32(0, sym.id, Endian.little);
    out.add(idBytes.buffer.asUint8List());
    if (parsed.attributeIds.contains(kCipSymbolAttrName)) {
      final lenBytes = ByteData(2)..setUint16(0, nameBytes.length, Endian.little);
      out.add(lenBytes.buffer.asUint8List());
      out.add(nameBytes);
    }
    if (parsed.attributeIds.contains(kCipSymbolAttrType)) {
      final typeBytes = ByteData(2)..setUint16(0, sym.typeCode, Endian.little);
      out.add(typeBytes.buffer.asUint8List());
    }
  }
  return CipResponse(
    service: kCipServiceGetInstanceAttributeList,
    generalStatus: partial ? kCipStatusPartialTransfer : kCipStatusSuccess,
    data: out.toBytes(),
  );
}

/// ASCII bytes for [name], non-ASCII replaced with '?', truncated to 0xFFFF
/// (the u16 length field's max). Never throws.
Uint8List _asciiBytes(String name) {
  final capped = name.length > 0xFFFF ? name.substring(0, 0xFFFF) : name;
  return Uint8List.fromList([for (final u in capped.codeUnits) u <= 0x7F ? u : 0x3F]);
}
```

Note: `_kSymbolInstanceFixedBytes` assumes both attrs 1 and 2 are requested (the Logix case). The budget is intentionally conservative — it slightly over-reserves when a client asks for only one attribute, which only makes pagination safer, never wrong.

- [ ] **Step 8: Run — expect PASS**

Run: `cd mobile && flutter test test/cip_symbol_test.dart`
Expected: PASS (all request-parse + reply-build + pagination tests).

- [ ] **Step 9: Analyze**

Run: `cd mobile && flutter analyze lib/protocols/enip/cip_symbol.dart lib/protocols/enip/cip.dart`
Expected: `No issues found!`

- [ ] **Step 10: Commit**

```bash
git add mobile/lib/protocols/enip/cip.dart mobile/lib/protocols/enip/cip_symbol.dart mobile/test/cip_symbol_test.dart
git commit -m "feat(enip): CIP Symbol Object (0x6B) browse codec + pagination"
```

---

## Task 2: Route the browse + prove it against real pycomm3 (generic-messaging gate)

**Files:**
- Modify: `mobile/lib/protocols/enip/cip_tags.dart` (`dispatchCipService`)
- Test: `mobile/test/cip_tags_test.dart` (routing)
- Modify: `tool/py/enip_probe.py` (deterministic browse assertion)
- Run: `tool/enip_e2e.sh`

**Interfaces:**
- Consumes (from Task 1): `isSymbolObjectPath`, `parseGetInstanceAttrListRequest`, `buildSymbolInstanceListResponse`, `kCipServiceGetInstanceAttributeList`, `kCipSymbolObjectClassId`.
- Produces: `dispatchCipService` now answers `0x55` addressed to class 0x6B via the Symbol browse; a browse over a connected send is bounded by `responseBudget`, over UCMM by a fixed cap.

### Background for the implementer

`dispatchCipService(project, map, req, {responseBudget})` (in `cip_tags.dart`) is the single seam both the connected and unconnected host paths call. It currently switches on `req.service` for Read/Write/MSP and returns `Service Not Supported (0x08)` otherwise. Add a `0x55` branch that requires the request path to address the Symbol Object; a `0x55` to any other class stays `Service Not Supported`. When `responseBudget` is null (UCMM), pass a fixed UCMM reply cap so the browse still paginates rather than emitting an oversized frame.

This is also the **first real-client gate**: extend `enip_probe.py` to issue a Get Instance Attribute List (0x55) to class 0x6B via `pycomm3`'s generic messaging (the same low-level path the probe already uses), and assert the fixture's tag names + type codes come back. This proves the Symbol codec is on-wire correct against a third-party client **without** needing `LogixDriver.open()` yet — and it is where the attr-1 string layout is confirmed against pycomm3's byte reading.

- [ ] **Step 1: Add the UCMM reply cap constant to `cip_tags.dart`**

Near the top constants in `mobile/lib/protocols/enip/cip_tags.dart`:

```dart
/// The reply-size cap applied to a Symbol Object browse arriving over an
/// UNCONNECTED (UCMM / SendRRData) send, which has no negotiated connection
/// size. Kept comfortably within a single UCMM reply so the browse paginates
/// (status 0x06) rather than emitting an oversized frame; a Logix client
/// re-requests from the last instance id + 1. Connected sends use the
/// negotiated `responseBudget` instead.
const int kCipUcmmBrowseReplyCap = 480;
```

- [ ] **Step 2: Write the failing routing test**

Add to `mobile/test/cip_tags_test.dart` (create the group if the file lacks it; import `cip_symbol.dart` and `cip.dart`):

```dart
  group('dispatchCipService — Symbol Object browse routing', () {
    test('0x55 addressed to class 0x6B returns a Symbol instance list', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId), CipPathSegment.instanceId(0)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00, 0x02, 0x00]),
      );
      final resp = dispatchCipService(_browseProject(), _browseMap(), req);
      expect(resp.service, kCipServiceGetInstanceAttributeList);
      expect(resp.generalStatus, anyOf(kCipStatusSuccess, kCipStatusPartialTransfer));
      expect(resp.data, isNotEmpty);
    });

    test('0x55 addressed to a non-Symbol class is Service Not Supported', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(0x04), CipPathSegment.instanceId(0)],
        data: Uint8List.fromList([0x01, 0x00, 0x01, 0x00]),
      );
      final resp = dispatchCipService(_browseProject(), _browseMap(), req);
      expect(resp.generalStatus, kCipStatusServiceNotSupported);
    });
  });
```

Add the `_browseProject()` / `_browseMap()` helpers mirroring Task 1's `_project()` / `_map()`.

- [ ] **Step 3: Run — expect FAIL**

Run: `cd mobile && flutter test test/cip_tags_test.dart`
Expected: FAIL — 0x55 currently returns Service Not Supported for the Symbol class too.

- [ ] **Step 4: Wire the branch into `dispatchCipService`**

In `mobile/lib/protocols/enip/cip_tags.dart`, add the import:

```dart
import 'cip_symbol.dart';
```

Add a case to the `switch (req.service)` inside `dispatchCipService`, before the `default`:

```dart
      case kCipServiceGetInstanceAttributeList:
        return _symbolBrowse(project, map, req, responseBudget);
```

Add the handler:

```dart
CipResponse _symbolBrowse(PlcProject project, CipMap map, CipRequest req, int? responseBudget) {
  if (!isSymbolObjectPath(req.path)) {
    // Get Instance Attribute List is only served for the Symbol Object here.
    return _errorResponse(req.service, kCipStatusServiceNotSupported);
  }
  final parsed = parseGetInstanceAttrListRequest(req);
  if (parsed == null) {
    return _errorResponse(req.service, kCipStatusEmbeddedListError);
  }
  final budget = responseBudget ?? kCipUcmmBrowseReplyCap;
  return buildSymbolInstanceListResponse(project, map, parsed, replyBudget: budget);
}
```

- [ ] **Step 5: Run — expect PASS + full suite unaffected**

Run: `cd mobile && flutter test test/cip_tags_test.dart test/cip_symbol_test.dart`
Expected: PASS.

- [ ] **Step 6: Add the deterministic browse assertion to `enip_probe.py`**

In `tool/py/enip_probe.py`, add a step (before Forward Close) that browses the Symbol Object via generic messaging and asserts the fixture's tags. Use pycomm3's `CIPDriver.generic_message` with `class_code=b"\x6B"`, `instance=b"\x00"`, `service=0x55`, `request_data = UINT.encode(2) + UINT.encode(1) + UINT.encode(2)` (attr count 2, ids 1 & 2), `connected=True`, `data_type=None` (raw bytes). Parse the raw reply as: repeated `instance(u32) + name_len(u16) + name + type(u16)`, and assert the set of `(name, type_code)` contains the fixture's mapped tags (`Running`→0xC1, `Speed`→0xC4, `Level`→0xCA, `Total64`→0xC5, `Count16`→0xC3, `Temp`→0xCA, `Forced_Speed`→0xC4). Handle status 0x06 by re-requesting from `last_id + 1` until 0x00, accumulating instances. Add a clear `STEP 8 (Symbol browse)` label and print `[probe] step 8 OK: Symbol Object browse returned N tags`, renumbering Forward Close to step 9.

The exact pycomm3 API for a raw generic message is:

```python
from pycomm3 import UINT
def symbol_browse(driver):
    tags = {}
    start = 0
    for _ in range(64):  # bounded: fixture has < 64 tags; guards against a loop
        resp = driver.generic_message(
            service=0x55,
            class_code=b"\x6B",
            instance=start.to_bytes(2, "little"),
            request_data=UINT.encode(2) + UINT.encode(1) + UINT.encode(2),
            connected=True,
            data_type=None,
            name="symbol_browse",
        )
        raw = resp.value if resp else b""
        off = 0
        last = start
        while off + 4 <= len(raw):
            inst = int.from_bytes(raw[off:off + 4], "little"); off += 4
            nlen = int.from_bytes(raw[off:off + 2], "little"); off += 2
            name = raw[off:off + nlen].decode("ascii"); off += nlen
            tcode = int.from_bytes(raw[off:off + 2], "little"); off += 2
            tags[name] = tcode
            last = inst
        if resp.service_status != 0x06:
            break
        start = last + 1
    return tags
```

If pycomm3 reads the names as garbage, the attr-1 string layout in `cip_symbol.dart` is wrong — correct it there (and the Task-1 byte-exact test), and note it in the report. **The client wins.**

- [ ] **Step 7: Run the E2E gate**

Run: `bash tool/enip_e2e.sh`
Expected: the probe prints `[probe] step 8 OK: Symbol Object browse returned 7 tags` and ends `ENIP PROBE PASS`.

- [ ] **Step 8: Commit**

```bash
git add mobile/lib/protocols/enip/cip_tags.dart mobile/test/cip_tags_test.dart tool/py/enip_probe.py
git commit -m "feat(enip): route Symbol Object browse + prove it against pycomm3 generic messaging"
```

---

## Task 3: Identity Object + full LogixDriver browse gate

**Files:**
- Create: `mobile/lib/protocols/enip/cip_identity.dart`
- Modify: `mobile/lib/protocols/enip/cip_tags.dart` (route Get Attributes All @ class 0x01)
- Modify: `mobile/lib/services/enip_host.dart` (answer ListIdentity 0x63)
- Test: `mobile/test/cip_identity_test.dart`
- Modify: `tool/py/enip_probe.py` (LogixDriver browse)

**Interfaces:**
- Consumes (from `cip.dart`): `kCipIdentityObjectClassId`, `kCipServiceGetAttributesAll`, `CipRequest`, `CipResponse`, `CipPathSegmentKind`.
- Produces:
  - `CipResponse buildIdentityGetAttributesAllResponse(int requestService)` — the Identity Object Get Attributes All reply.
  - `Uint8List buildListIdentityItem()` — the ListIdentity CPF item body for the encapsulation-layer reply.
  - `bool isIdentityObjectPath(List<CipPathSegment> path)`.

### Background for the implementer

A Logix-style client reads the **Identity Object (class 0x01)** at connect — `pycomm3`'s `LogixDriver.open()` calls `get_plc_info()`, and Ignition's driver reads controller info — **before** it will upload tags. The app serves none today, so `LogixDriver.open()` fails before `get_tag_list()`. This task serves an **honest simulator identity** and then gates the full `LogixDriver` browse path against the fixture.

Identity Object **Get Attributes All (service 0x01)** reply is a packed structure, in this order (all little-endian): Vendor ID (u16), Device Type (u16), Product Code (u16), Revision major (u8) + minor (u8), Status (u16), Serial Number (u32), Product Name (SHORT_STRING: u8 length + that many ASCII bytes). ListIdentity (encapsulation command 0x63) wraps the same identity fields plus socket/encap-version framing in a CPF item.

**Honest, deterministic identity values (no real-vendor impersonation, no competitor branding, no RNG):**
- Vendor ID: `0` (a reserved/unassigned id — the simulator claims no real vendor).
- Device Type: `0x000E` (Programmable Logic Controller — an honest description of what it is).
- Product Code: `0x0001`.
- Revision: `1.1`.
- Status: `0x0000`.
- Serial Number: `0x00000001` (fixed — the determinism constraint forbids a generated serial).
- Product Name: `"Soft PLC Simulator"`.

These are the codec's honest defaults; the **Task-3 gate confirms `LogixDriver` accepts them and reaches `get_tag_list()`**. If `LogixDriver` needs a specific Device Type/Product Code to pick the Symbol-Object tag-list path (rather than a Micro800 path), adjust these values to what makes the real client take the Symbol path, and record the change. **The client wins.**

- [ ] **Step 1: Write the failing test — Identity Get Attributes All bytes**

Create `mobile/test/cip_identity_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_identity.dart';

void main() {
  test('Identity Get Attributes All packs the identity struct little-endian', () {
    final resp = buildIdentityGetAttributesAllResponse(kCipServiceGetAttributesAll);
    expect(resp.generalStatus, kCipStatusSuccess);
    final d = resp.data;
    expect(ByteData.sublistView(d, 0, 2).getUint16(0, Endian.little), 0); // Vendor ID
    expect(ByteData.sublistView(d, 2, 4).getUint16(0, Endian.little), 0x000E); // Device Type
    expect(ByteData.sublistView(d, 4, 6).getUint16(0, Endian.little), 0x0001); // Product Code
    expect(d[6], 1); // Revision major
    expect(d[7], 1); // Revision minor
    expect(ByteData.sublistView(d, 8, 10).getUint16(0, Endian.little), 0x0000); // Status
    expect(ByteData.sublistView(d, 10, 14).getUint32(0, Endian.little), 1); // Serial
    expect(d[14], 'Soft PLC Simulator'.length); // SHORT_STRING length
    expect(String.fromCharCodes(d.sublist(15, 15 + 'Soft PLC Simulator'.length)), 'Soft PLC Simulator');
  });

  test('isIdentityObjectPath recognizes class 0x01', () {
    expect(isIdentityObjectPath([CipPathSegment.classId(kCipIdentityObjectClassId), CipPathSegment.instanceId(1)]), isTrue);
    expect(isIdentityObjectPath([CipPathSegment.classId(0x6B)]), isFalse);
  });
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd mobile && flutter test test/cip_identity_test.dart` → FAIL (`cip_identity.dart` undefined).

- [ ] **Step 3: Create `cip_identity.dart`**

```dart
// CIP Identity Object (class 0x01) — pure Dart, no dart:io / Flutter. Serves
// Get Attributes All (0x01) so a Logix-style client's connect-time
// controller-info read (pycomm3 LogixDriver.open()'s get_plc_info, Ignition's
// driver) succeeds and proceeds to upload the tag directory (see
// cip_symbol.dart). Also builds the ListIdentity (encapsulation 0x63) item.
//
// The reported identity is an HONEST self-description of the simulator: a
// reserved Vendor ID (0 — claims no real vendor), Device Type "Programmable
// Logic Controller", a fixed serial (determinism), product name
// "Soft PLC Simulator". It impersonates no real product.
//
// Get Attributes All reply layout (little-endian): Vendor ID u16, Device Type
// u16, Product Code u16, Revision major u8 + minor u8, Status u16, Serial u32,
// Product Name SHORT_STRING (u8 len + ascii).
library cip_identity;

import 'dart:typed_data';

import 'cip.dart';

const int kIdentityVendorId = 0;
const int kIdentityDeviceType = 0x000E; // Programmable Logic Controller.
const int kIdentityProductCode = 0x0001;
const int kIdentityRevisionMajor = 1;
const int kIdentityRevisionMinor = 1;
const int kIdentityStatus = 0x0000;
const int kIdentitySerialNumber = 0x00000001;
const String kIdentityProductName = 'Soft PLC Simulator';

/// True iff [path]'s first segment is the Identity Object class.
bool isIdentityObjectPath(List<CipPathSegment> path) =>
    path.isNotEmpty &&
    path[0].kind == CipPathSegmentKind.classId &&
    path[0].id == kCipIdentityObjectClassId;

/// The packed Identity attribute struct (shared by Get Attributes All and the
/// ListIdentity item body).
Uint8List _identityStruct() {
  final nameBytes = Uint8List.fromList(
    [for (final u in kIdentityProductName.codeUnits) u <= 0x7F ? u : 0x3F],
  );
  final out = BytesBuilder();
  final head = ByteData(14)
    ..setUint16(0, kIdentityVendorId, Endian.little)
    ..setUint16(2, kIdentityDeviceType, Endian.little)
    ..setUint16(4, kIdentityProductCode, Endian.little)
    ..setUint8(6, kIdentityRevisionMajor)
    ..setUint8(7, kIdentityRevisionMinor)
    ..setUint16(8, kIdentityStatus, Endian.little)
    ..setUint32(10, kIdentitySerialNumber, Endian.little);
  out.add(head.buffer.asUint8List());
  out.addByte(nameBytes.length);
  out.add(nameBytes);
  return out.toBytes();
}

/// The Identity Object Get Attributes All reply.
CipResponse buildIdentityGetAttributesAllResponse(int requestService) =>
    CipResponse(service: requestService, generalStatus: kCipStatusSuccess, data: _identityStruct());

/// The ListIdentity CPF item body (encapsulation command 0x63). Layout:
/// item type u16 (0x000C), item length u16, encap protocol version u16 (1),
/// socket address (16 bytes, zeroed — the client already knows the socket it
/// connected on), then the identity struct, then a device state u8 (0xFF =
/// unknown/not-applicable for a soft device).
Uint8List buildListIdentityItem() {
  final id = _identityStruct();
  final body = BytesBuilder();
  final ver = ByteData(2)..setUint16(0, 1, Endian.little);
  body.add(ver.buffer.asUint8List());
  body.add(Uint8List(16)); // socket address, zeroed.
  body.add(id);
  body.addByte(0xFF); // device state.
  final payload = body.toBytes();
  final out = BytesBuilder();
  final hdr = ByteData(4)
    ..setUint16(0, 0x000C, Endian.little) // CPF item type: ListIdentity response.
    ..setUint16(2, payload.length, Endian.little);
  out.add(hdr.buffer.asUint8List());
  out.add(payload);
  return out.toBytes();
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd mobile && flutter test test/cip_identity_test.dart`
Expected: PASS.

- [ ] **Step 5: Route Get Attributes All @ class 0x01 in `dispatchCipService`**

In `cip_tags.dart`, add `import 'cip_identity.dart';`, then a case before the `default`:

```dart
      case kCipServiceGetAttributesAll:
        return isIdentityObjectPath(req.path)
            ? buildIdentityGetAttributesAllResponse(req.service)
            : _errorResponse(req.service, kCipStatusServiceNotSupported);
```

- [ ] **Step 6: Answer ListIdentity (0x63) at the encapsulation layer**

In `mobile/lib/services/enip_host.dart`, find the encapsulation-command switch (where `kEnipCommandListIdentity` / RegisterSession / SendRRData are dispatched). Add a handler that, on `kEnipCommandListIdentity` (0x63), replies with a CPF-style body: item count u16 (1) + `buildListIdentityItem()`. Import `cip_identity.dart`. Use the existing `_reply(header, 0, data)` helper. (Read the surrounding switch first; match its exact reply-framing pattern — the ListIdentity reply is an encapsulation reply with the command echoed and status 0.)

- [ ] **Step 7: Surface non-success CIP outcomes in the in-app Logs**

In `mobile/lib/services/enip_host.dart`, at BOTH `dispatchCipService` call sites (the unconnected `_handleSendRRData` path ~line 335 and the connected `_handleSendUnitData` path ~line 434), after computing `resp`, log a warning when the running host answers a request with an abnormal status — so a client that can't browse/read/write sees why in the Logs view. Read the file's existing `_logDrop(String key, String Function() msg)` helper (it gates on first-occurrence via a `DropLogGate` so it can't be spammed) and reuse it:

```dart
    // Surface a non-success CIP outcome to the in-app Logs (first-occurrence
    // gated). Partial Transfer (0x06) is normal browse pagination, not an error.
    if (resp.generalStatus != kCipStatusSuccess && resp.generalStatus != kCipStatusPartialTransfer) {
      _logDrop('enip-cip-status-${_hex(resp.service)}-${_hex(resp.generalStatus)}',
          () => 'CIP service ${_hex(req.service)} answered with general status '
              '${_hex(resp.generalStatus)} (non-success).');
    }
```

Place it where `req` and `resp` are both in scope (in the connected path, guard for `req != null`). Import `kCipStatusPartialTransfer` if not already visible. This is the concrete realization of the Global Constraint "runtime errors are visible in the in-app Logs screen."

- [ ] **Step 8: Analyze**

Run: `cd mobile && flutter analyze lib/protocols/enip/ lib/services/enip_host.dart`
Expected: `No issues found!`

- [ ] **Step 9: The full LogixDriver browse gate**

Replace the Task-2 generic-messaging browse step in `enip_probe.py` with (or add alongside it) a `LogixDriver` path that is the real goal:

```python
from pycomm3 import LogixDriver
def logix_browse(host, port):
    drv = LogixDriver(host)
    drv._cfg["port"] = port
    with drv:  # open() reads Identity via get_plc_info, then we upload tags
        tags = drv.get_tag_list()
        names = {t["tag_name"] for t in tags}
        for expected in ("Speed", "Running", "Level"):
            check(expected in names, f"LogixDriver browse: {expected!r} not in tag list {sorted(names)}")
        # Read one browsed tag back through LogixDriver's own read path.
        result = drv.read("Speed")
        check(result and result.value is not None, "LogixDriver read of a browsed tag failed")
```

Wire this into `run()` as its own step, printing `[probe] step 9 OK: LogixDriver browsed N tags and read one back`.

- [ ] **Step 9: Run the gate — and adjust to what the client demands**

Run: `bash tool/enip_e2e.sh`

If `LogixDriver.open()` still fails, its error names the missing object/attribute — serve exactly that (most likely an additional Identity attribute, or a specific Device Type/Product Code that steers LogixDriver onto the Symbol-Object tag-list path) and re-run. Record in the report precisely what `open()` required and whether the dotted-name representation (`Tank.Level`) survived `get_tag_list()`. If pycomm3 rejects dotted atomic symbols, fall back (sanitized separator or top-level-only) and report. **Do not weaken the assertion to pass.**
Expected on success: `[probe] step 9 OK: LogixDriver browsed 7 tags and read one back` and `ENIP PROBE PASS`.

- [ ] **Step 10 (gate-surfaced, CONTROLLER-AUTHORIZED): serve Unconnected Send (0x52) + Program Name Object (0x64)**

The Task-3 gate revealed `LogixDriver.open()` needs two more small, honest CIP surfaces before it reaches `get_tag_list()` — NOT the out-of-scope Template Object. Both are authorized (they are exactly the "controller attributes the gate surfaces" this plan's design sanctions; Ignition's Logix driver reads the same info):

- **CIP Unconnected Send (service 0x52, Connection Manager class 0x06/instance 0x01).** `get_plc_info`/`get_plc_name` wrap their reads in an Unconnected Send. Handle it as a transparent wrapper: parse the embedded request (priority/tick u8, timeout_ticks u8, embedded-message size u16, that many embedded-request bytes [pad byte if size odd], route-path size u8 + reserved u8 + route path), re-dispatch the embedded `CipRequest` through `dispatchCipService` (UCMM → `responseBudget: null`), and return the embedded service's response directly (the Unconnected Send adds no reply wrapper). Verify the exact request layout against pycomm3's `pycomm3/packets/util.py` / `cip/` in the installed venv — the client is the authority. Pure Dart; never throw (malformed → an error-status response). Add byte-exact unit tests.
- **Program Name Object (class 0x64) Get Attributes All → STRING.** `get_plc_name()` reads this unconditionally on the non-Micro800 path. Return `project.controllerName` (honest, deterministic) encoded as the Logix STRING attribute layout pycomm3 expects (verify against its parser). Route it in `dispatchCipService` alongside the Identity case. Add byte-exact unit tests.

Keep the Identity + Symbol work from Steps 1–9. Keep determinism/never-throw/purity and the honest, non-impersonating identity. The **Template Object (class 0x6C) / UDT modelling remains the hard out-of-scope boundary** — if anything beyond 0x52 + 0x64 + the served Symbol attributes is still demanded, STOP and escalate rather than build it.

- [ ] **Step 11: Flip on the LogixDriver browse gate + commit**

With 0x52 + 0x64 served, the `LogixDriver.open()` → `get_tag_list()` → read step (from Step 8) must now PASS against the fixture; commit it into `enip_probe.py` as a live step so the shared `tool/enip_e2e.sh` proves the full browse path (do NOT commit a red step — only enable it once green). Record what `open()` finally required and whether the dotted-name representation survived `get_tag_list()`.

```bash
git add mobile/lib/protocols/enip/cip_identity.dart mobile/lib/protocols/enip/cip_symbol.dart mobile/lib/protocols/enip/cip_tags.dart mobile/lib/services/enip_host.dart mobile/test/cip_identity_test.dart mobile/test/cip_symbol_test.dart tool/py/enip_probe.py
git commit -m "feat(enip): Identity + Program Name + Unconnected Send; full LogixDriver browse gate"
```

---

## Task 4: Pagination hardening, full E2E, docs, review

**Files:**
- Test: `mobile/test/cip_symbol_test.dart` (multi-page pagination integration)
- Modify: `tool/py/enip_probe.py` (finalize step order/labels)
- Modify: `docs/protocols/ethernet-ip.md`, `README.md`
- Run: full suite + analyze + web build + sibling E2Es

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: shipped, documented browse.

- [ ] **Step 1: Write a multi-page pagination test**

Add to `mobile/test/cip_symbol_test.dart` a test with a map of ~10 entries and a small budget, driving `buildSymbolInstanceListResponse` in a loop (start at 0; on status 0x06 resume from `lastId + 1`) and asserting the union of returned instances equals all listable entries exactly once, with the final page status 0x00:

```dart
  test('paginating with a small budget returns every listable entry exactly once', () {
    final tags = [for (var i = 0; i < 10; i++)
        PlcTag(name: 'T$i', path: 'Internal.T$i', dataType: 'INT32', value: i, ioType: 'Internal')];
    final project = PlcProject(id: 'p', name: 'p', controllerName: 'PLC',
        tags: tags, structDefs: [], programs: [], tasks: [], hmis: []);
    final map = CipMap(entries: [for (var i = 0; i < 10; i++) CipMapEntry(tagName: 'T$i')]);
    final seen = <int>[];
    var start = 0;
    var status = kCipStatusPartialTransfer;
    var guard = 0;
    while (status == kCipStatusPartialTransfer && guard++ < 50) {
      final resp = buildSymbolInstanceListResponse(project, map,
          GetInstanceAttrListRequest(startInstance: start, attributeIds: [1, 2]), replyBudget: 24);
      status = resp.generalStatus;
      var off = 0;
      var lastId = start;
      while (off + 4 <= resp.data.length) {
        final id = ByteData.sublistView(resp.data, off, off + 4).getUint32(0, Endian.little); off += 4;
        final nlen = ByteData.sublistView(resp.data, off, off + 2).getUint16(0, Endian.little); off += 2;
        off += nlen; off += 2; // skip name + type
        seen.add(id); lastId = id;
      }
      start = lastId + 1;
    }
    expect(seen, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(status, kCipStatusSuccess);
  });
```

- [ ] **Step 2: Run — expect PASS** (implement any fix if a single-instance budget edge fails)

Run: `cd mobile && flutter test test/cip_symbol_test.dart`
Expected: PASS. (Edge to verify: a budget too small for even one instance must still make progress or terminate — a single instance is admitted if it alone fits; if the very first instance exceeds the budget, the loop must not spin. If that edge can occur with a real connection size, cap the minimum sensibly and note it.)

- [ ] **Step 3: Finalize the probe step numbering/labels**

Ensure `enip_probe.py` runs, in order: RegisterSession → Forward Open → connected read/write/read-back → UCMM read → refusal semantics → **Symbol browse (generic messaging)** → **LogixDriver browse + read** → Forward Close → UnRegisterSession, each with a `STEP n` label, ending `ENIP PROBE PASS`. Keep BOTH browse proofs (the generic-messaging one is the deterministic codec proof; the LogixDriver one is the real-goal proof).

- [ ] **Step 4: Full gate**

```bash
cd mobile && flutter analyze
cd mobile && flutter test
cd mobile && flutter build web --release
bash tool/enip_e2e.sh
bash tool/fins_e2e.sh && bash tool/s7_e2e.sh && bash tool/modbus_e2e.sh && bash tool/opcua_e2e.sh && bash tool/slmp_e2e.sh
```
Expected: analyze clean; full suite all pass (record the count — baseline 2100 + the new cip_symbol/cip_identity/cip_tags tests); web build succeeds; ENIP E2E `PASS`; no sibling regression. If a sibling E2E's toolchain/venv is unavailable, run what is available and report which could not run.

- [ ] **Step 5: Docs**

In `docs/protocols/ethernet-ip.md`: move the Symbol Object and Identity Object OUT of the "deliberately deferred" list into the served-features section. Document: flat-atomic Symbol browse (one instance per `CipMap` entry, dotted names verbatim), Get Instance Attribute List (0x55) with 0x06 pagination, the honest Identity (Vendor ID 0, "Soft PLC Simulator", PLC device type, fixed serial) and ListIdentity, and what the real `LogixDriver` gate settled about `open()` and the dotted-name representation. Keep DEFERRED: Template Object / UDT structure, `STRING`, implicit (Class 1 I/O) messaging, Large Forward Open. In `README.md`: update the EtherNet/IP bullet to note tag browsing is supported. No competitor branding.

- [ ] **Step 6: Commit**

```bash
git add mobile/test/cip_symbol_test.dart tool/py/enip_probe.py docs/protocols/ethernet-ip.md README.md
git commit -m "feat+docs(enip): Symbol Object browse pagination E2E + docs"
```

---

## Self-Review

**Spec coverage:**
- Symbol Object browse (flat atomic, one instance per CipMap entry, dotted names verbatim) → Task 1 (codec) + Task 2 (routing/proof). ✓
- Get Instance Attribute List (0x55) over class 0x6B with 0x06 pagination → Task 1 (build/paginate) + Task 4 (multi-page test). ✓
- Route through the existing `dispatchCipService` seam → Task 2. ✓
- No Template Object (atomic-only) → enforced by design; `cip_symbol.dart` emits only elementary type codes; STRING/unmapped entries skipped (Task 1 Step 7). ✓
- Probe-early gate settling `open()` requirements + dotted-name representation → Task 2 (generic-messaging codec proof) + Task 3 (full LogixDriver gate, Identity Object discovered/served). ✓
- Reply bounded by connection size (connected) / UCMM cap (unconnected) → Task 2 Step 1 + `_symbolBrowse`. ✓
- Never-throw, deterministic, additive, no branding, zero analyze warnings → Global Constraints; asserted per task. ✓
- Full pycomm3 `LogixDriver` E2E (open → get_tag_list → read) → Task 3 Step 8 + Task 4. ✓

Gap addressed vs. the spec: the spec framed Identity as "an attribute the gate surfaces"; this plan makes it an explicit Task 3 because a Logix client provably reads the Identity Object before `get_tag_list()`, and none is served today — building it is a known prerequisite, not speculation. Still gated against the real client.

**Placeholder scan:** No TBD/TODO. The one genuinely client-determined value — the exact Identity Device Type/Product Code that steers `LogixDriver` onto the Symbol tag-list path, and the attr-1 string layout — are given concrete honest defaults AND an explicit "settle at the gate, the client wins" instruction, matching this project's probe-early pattern (S7/FINS/SLMP Task 3 gates).

**Type consistency:** `GetInstanceAttrListRequest{startInstance, attributeIds}`, `buildSymbolInstanceListResponse(project, map, parsed, {replyBudget})`, `isSymbolObjectPath`, `parseGetInstanceAttrListRequest`, `buildIdentityGetAttributesAllResponse(int)`, `isIdentityObjectPath`, `buildListIdentityItem()` — names and signatures are used identically in the tasks that produce and consume them. New constants (`kCipServiceGetInstanceAttributeList`, `kCipStatusPartialTransfer`, `kCipSymbolObjectClassId`, `kCipIdentityObjectClassId`, `kCipServiceGetAttributesAll`, `kCipUcmmBrowseReplyCap`, `kCipSymbolAttrName/Type`, the `kIdentity*` block) are each defined once and referenced consistently.
