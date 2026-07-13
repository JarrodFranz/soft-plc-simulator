# OPC UA Folder Browsing (+ MQTT folder prefixes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose each tag's `folder` as a browsable OPC UA FolderType node (so Ignition browses `Objects ▸ Ramp1 ▸ Ramp001…`) and prefix MQTT/Sparkplug metric names with their folder.

**Architecture:** The folder lives on `PlcTag.folder`; the OPC UA address-space builder already resolves each node's tag, so it reads the folder there — no map/persistence change. The address space synthesizes one FolderType Object node per distinct folder (reserved-prefix NodeId), groups tags under them, and the Browse/Read services serve those folder nodes. MQTT metric names gain a `folder/` prefix at the map source of truth.

**Tech Stack:** pure Dart (`mobile/lib/protocols/opcua/**`, `mobile/lib/models/**`), the in-app OPC UA binary codec, `flutter_test`, and the Rust `opcua` E2E probe.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"). OPC UA/IEC terms fine.
- `mobile/lib/protocols/opcua/**` and `mobile/lib/models/**` stay PURE Dart — no `dart:io`, no Flutter. Standard NodeId/NodeClass/AttributeId values stay consistent with the vendored Rust `opcua-0.12.0` crate (FolderType i=61 and Organizes i=35 are already defined in `opcua_address_space.dart`).
- Zero `flutter analyze` warnings; braces on all control flow; prefer `const`.
- **Behavior-preserving:** a project whose tags are ALL root (`folder == ''`) must produce ZERO folder nodes and a `children(Objects)` / Objects-browse byte-identical to today. Existing OPC UA service/address-space tests must still pass.
- Folder object NodeIds use a reserved prefix (`__folder__/`) that cannot collide with a tag NodeId (`ns=1;s=<tagName>`; tag names are plain identifiers). Clients display BrowseName, not NodeId.
- MQTT metric change is additive: only foldered tags differ, and only on (re)generate/auto-generate. The entry's `tag` field stays the bare tag name (the resolver key).

**Test/analyze commands** (from `mobile/`): single file `flutter test test/<path>_test.dart`; full suite `flutter test`; `flutter analyze` (expect **No issues found!**).

---

## Phase A — Address-space folder model

### Task 1: Folder nodes in `OpcUaAddressSpace`

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_address_space.dart`
- Test: `mobile/test/opcua_address_space_folder_test.dart` (create)

**Interfaces:**
- Consumes: `PlcTag.folder`; existing `OpcUaAddressSpace.build`, `OpcUaAddressSpaceEntry`, `OpcNodeId.string`, `OpcUaStandardNodeIds`.
- Produces:
  - `OpcUaAddressSpaceEntry.folder` (String, `''` = root), set from the tag at build.
  - `const String kFolderNodePrefix = '__folder__/';`
  - `OpcNodeId folderNodeId(String folder)` → `OpcNodeId.string(1, '$kFolderNodePrefix$folder')`.
  - `bool isFolderNode(OpcNodeId)` / `String? folderNameOf(OpcNodeId)`.
  - `List<String> folders` — distinct non-empty folders, alphabetically sorted.
  - `children(Objects)` → root entries (map order) **followed by** folder nodes (as entries? no — see below); `children(<folderNode>)` → that folder's entries.

  Because `children` currently returns `List<OpcUaAddressSpaceEntry>` (variables only), add a SEPARATE accessor for folder children so the service can distinguish objects from variables:
  - `List<OpcUaAddressSpaceEntry> rootVariables()` — entries with `folder == ''`, in map order.
  - `List<String> childFolders(OpcNodeId parent)` — the folder names to show under `parent` (all `folders` when `parent` is Objects; empty otherwise).
  - `List<OpcUaAddressSpaceEntry> folderVariables(String folder)` — entries whose `folder == folder`, in map order.
  Keep the existing `children(OpcNodeId)` working for backward compatibility: return `rootVariables()` for Objects (NOT all entries — folders now hold the non-root ones), and `folderVariables(folderNameOf(parent)!)` when `parent` is a folder node, else `const []`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/opcua_address_space_folder_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_address_space.dart';

PlcProject _proj(List<PlcTag> tags) {
  final p = PlcProject(
    id: 'x', name: 'x', controllerName: 'c',
    tags: tags, structDefs: [], programs: [], tasks: [], hmis: []);
  p.protocols = ProtocolSettings(
    gatewayUrl: '',
    opcua: OpcUaProtocolConfig(
      enabled: true,
      namespaceUri: 'urn:test',
      map: OpcuaMap(namespaceUri: 'urn:test', nodes: [
        for (final t in tags) OpcuaNode(nodeId: 'ns=1;s=${t.name}', tag: t.name, access: 'ReadOnly'),
      ]),
    ),
  );
  return p;
}

PlcTag _t(String name, {String folder = ''}) =>
    PlcTag(name: name, path: name, dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: folder);

void main() {
  test('entry carries its tag folder', () {
    final space = OpcUaAddressSpace.build(_proj([_t('R1', folder: 'Ramp1')]));
    expect(space.entries.single.folder, 'Ramp1');
  });

  test('distinct folders synthesized, alphabetically; root-only has none', () {
    final space = OpcUaAddressSpace.build(_proj([
      _t('Root1'), _t('R1', folder: 'Ramp1'), _t('S1', folder: 'Sine1'), _t('R2', folder: 'Ramp1'),
    ]));
    expect(space.folders, ['Ramp1', 'Sine1']);
    final flat = OpcUaAddressSpace.build(_proj([_t('A'), _t('B')]));
    expect(flat.folders, isEmpty);
  });

  test('Objects children = root variables only; folders hold the rest', () {
    final space = OpcUaAddressSpace.build(_proj([
      _t('Root1'), _t('R1', folder: 'Ramp1'), _t('R2', folder: 'Ramp1'),
    ]));
    expect(space.rootVariables().map((e) => e.browseName), ['Root1']);
    expect(space.childFolders(OpcUaStandardNodeIds.objectsFolder), ['Ramp1']);
    expect(space.folderVariables('Ramp1').map((e) => e.browseName), ['R1', 'R2']);
    // Backward-compat children(): Objects -> root vars only.
    expect(space.children(OpcUaStandardNodeIds.objectsFolder).map((e) => e.browseName), ['Root1']);
  });

  test('folder node id uses the reserved prefix and round-trips', () {
    final space = OpcUaAddressSpace.build(_proj([_t('R1', folder: 'Ramp1')]));
    final fid = space.folderNodeId('Ramp1');
    expect(fid, OpcNodeId.string(1, '__folder__/Ramp1'));
    expect(space.isFolderNode(fid), isTrue);
    expect(space.folderNameOf(fid), 'Ramp1');
    // A tag node id is NOT a folder node.
    expect(space.isFolderNode(OpcNodeId.string(1, 'R1')), isFalse);
    // children() of a folder node returns its variables.
    expect(space.children(fid).map((e) => e.browseName), ['R1']);
  });

  test('root-only project: children(Objects) identical to entries (flat preserved)', () {
    final space = OpcUaAddressSpace.build(_proj([_t('A'), _t('B')]));
    expect(space.children(OpcUaStandardNodeIds.objectsFolder).map((e) => e.browseName),
        space.entries.map((e) => e.browseName));
    expect(space.childFolders(OpcUaStandardNodeIds.objectsFolder), isEmpty);
  });
}
```

> The implementer must confirm `OpcuaMap`/`OpcuaNode`/`OpcUaProtocolConfig`/`ProtocolSettings` constructor shapes (read `opcua_map.dart` + `protocol_settings.dart`) and adapt the fixture if a named param differs — keeping the assertions identical.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/opcua_address_space_folder_test.dart`
Expected: FAIL — `folder`/`folders`/`folderNodeId`/`isFolderNode`/`rootVariables`/`childFolders`/`folderVariables` undefined.

- [ ] **Step 3: Implement**

In `opcua_address_space.dart`:
1. Add `final String folder;` to `OpcUaAddressSpaceEntry` (ctor param `required this.folder`).
2. In `OpcUaAddressSpace.build`, set `folder: tag.folder` when constructing each entry.
3. Add the constant + helpers to `OpcUaAddressSpace`:

```dart
/// Reserved NodeId-string prefix for synthesized folder Object nodes. A real
/// tag NodeId is `ns=1;s=<tagName>` (plain identifier), so this marker can
/// never collide with one.
const String kFolderNodePrefix = '__folder__/';
```

Inside the class, cache the sorted distinct folders in the private ctor (compute in `build` and pass in), and add:

```dart
final List<String> _folders; // distinct non-empty folders, sorted

List<String> get folders => List.unmodifiable(_folders);

OpcNodeId folderNodeId(String folder) => OpcNodeId.string(1, '$kFolderNodePrefix$folder');

bool isFolderNode(OpcNodeId nodeId) =>
    nodeId.namespace == 1 && nodeId.isString && (nodeId.stringId ?? '').startsWith(kFolderNodePrefix);

String? folderNameOf(OpcNodeId nodeId) =>
    isFolderNode(nodeId) ? nodeId.stringId!.substring(kFolderNodePrefix.length) : null;

List<OpcUaAddressSpaceEntry> rootVariables() =>
    _entries.where((e) => e.folder.isEmpty).toList();

List<String> childFolders(OpcNodeId parent) =>
    isObjectsFolder(parent) ? List.unmodifiable(_folders) : const [];

List<OpcUaAddressSpaceEntry> folderVariables(String folder) =>
    _entries.where((e) => e.folder == folder).toList();
```

Update `build` to compute the sorted folder list and pass it to the private ctor:

```dart
final folderSet = <String>{};
for (final e in entries) {
  if (e.folder.isNotEmpty) {
    folderSet.add(e.folder);
  }
}
final folders = folderSet.toList()..sort();
return OpcUaAddressSpace._(entries, byNodeId, opcua?.namespaceUri ?? '', folders);
```

Replace the existing `children` with the folder-aware version:

```dart
List<OpcUaAddressSpaceEntry> children(OpcNodeId parent) {
  if (isObjectsFolder(parent)) {
    return rootVariables();
  }
  final folder = folderNameOf(parent);
  if (folder != null) {
    return folderVariables(folder);
  }
  return const [];
}
```

Update the private ctor signature `OpcUaAddressSpace._(this._entries, this._byNodeId, this.namespaceUri, this._folders);`.

- [ ] **Step 4: Run tests**

Run: `flutter test test/opcua_address_space_folder_test.dart` → PASS.
Run: `flutter test test/` (any existing opcua address-space/service tests) → still green.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/opcua/opcua_address_space.dart mobile/test/opcua_address_space_folder_test.dart
git commit -m "feat(opcua): folder nodes in the address space (root vars + FolderType groups)"
```

---

## Phase B — Browse/Read services + OPC UA E2E

### Task 2: Serve folder nodes in Browse + Read

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_services.dart` (`_writeBrowseResult`, `_readAttribute`)
- Test: `mobile/test/opcua_services_folder_test.dart` (create) — or extend the existing services test

**Interfaces:**
- Consumes: Task 1's `space.childFolders(...)`, `space.folderNodeId(...)`, `space.isFolderNode(...)`, `space.folderNameOf(...)`, `space.children(folderNode)`, `space.rootVariables()`.
- Produces: Browsing Objects lists Server + root variables + a FolderType Object per folder; browsing a folder node lists its variables; Read on a folder node returns Object/BrowseName/DisplayName/TypeDefinition.

- [ ] **Step 1: Write the failing test**

The Browse output is a binary buffer; assert via decoding what a client sees. Create `mobile/test/opcua_services_folder_test.dart` that builds a project with one root tag + one folder, invokes the Browse handler for the Objects node and for the folder node, and decodes the reference list. **Read the existing OPC UA services test** (find it: `grep -rl "_handleBrowse\|Browse" mobile/test`) to reuse its harness for driving `OpcUaProjectServices` and decoding a BrowseResponse; mirror that decoding. Assertions to encode:

```
// Browsing Objects returns: Server, then root variable "Root1", then a folder
// reference whose NodeClass == Object(1), TypeDefinition == FolderType(i=61),
// BrowseName == "Ramp1", target NodeId == ns=1;s=__folder__/Ramp1.
// Browsing ns=1;s=__folder__/Ramp1 returns its variable "R1" (NodeClass Variable(2)).
// Reading attribute NodeClass(2) of the folder node returns Int32 == 1 (Object);
// reading BrowseName(3) returns QualifiedName(ns:1,"Ramp1");
// reading DisplayName(4) returns LocalizedText("Ramp1").
```

Write the concrete decode+expect using the existing test's helpers. (If the existing services test lives in one file, add these cases there instead of a new file and name that file in the commit.)

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/opcua_services_folder_test.dart`
Expected: FAIL — Objects browse omits folders; folder node → Bad_NodeIdUnknown.

- [ ] **Step 3: Implement**

In `opcua_services.dart` `_writeBrowseResult`:
1. Extend the unknown-node guard to accept folder nodes: `final isFolder = space.isFolderNode(nodeId);` and include `!isFolder` in the `badNodeIdUnknown` condition.
2. In the `isObjects` branch, after emitting the root variable references (which now come from `space.children(Objects)` = root vars only), append one reference per folder. Update the reference count to `1 (Server) + rootVars.length + folders.length`:

```dart
final rootVars = space.children(OpcUaStandardNodeIds.objectsFolder);
final folders = space.childFolders(OpcUaStandardNodeIds.objectsFolder);
w.int32(rootVars.length + folders.length + 1);
// ... Server reference (unchanged) ...
for (final child in rootVars) {
  // ... existing variable reference shape ...
}
for (final folder in folders) {
  w.nodeId(OpcUaStandardNodeIds.organizesReferenceType);
  w.boolean(true); // isForward
  w.expandedNodeId(space.folderNodeId(folder));
  w.qualifiedName(OpcQualifiedName(ns: 1, name: folder));
  w.localizedText(OpcLocalizedText(text: folder));
  w.int32(OpcUaNodeClass.object);
  w.expandedNodeId(OpcUaStandardNodeIds.folderType);
}
return;
```

3. Add a folder-node browse branch BEFORE the final `w.int32(0)` (no-children) fallthrough:

```dart
if (isFolder) {
  final vars = space.children(nodeId); // folderVariables
  w.int32(vars.length);
  for (final child in vars) {
    w.nodeId(OpcUaStandardNodeIds.organizesReferenceType);
    w.boolean(true); // isForward
    w.expandedNodeId(child.nodeId);
    w.qualifiedName(OpcQualifiedName(ns: child.nodeId.namespace, name: child.browseName));
    w.localizedText(OpcLocalizedText(text: child.browseName));
    w.int32(OpcUaNodeClass.variable);
    w.expandedNodeId(OpcUaStandardNodeIds.baseDataVariableType);
  }
  return;
}
```

In `_readAttribute`, special-case folder nodes BEFORE the `space.byNodeId` lookup (mirroring the existing `isServerNode` special-case) — add a helper `_readFolderNodeAttribute(String folderName, int attributeId, String? indexRange)` returning:
- `nodeClass` (2) → `OpcDataValue(value: OpcVariant(typeId: 6, value: OpcUaNodeClass.object))` (Int32).
- `browseName` (3) → a QualifiedName variant `OpcQualifiedName(ns: 1, name: folderName)` (encode with the same variant type the codec uses for QualifiedName — mirror how the Server node's browseName is answered; read that code first).
- `displayName` (4) → LocalizedText `folderName` (mirror the Server node's displayName answer).
- any other attribute → the same Bad status the Server-node path returns for unsupported attributes.
Wire it in: `if (space.isFolderNode(nodeId)) { return _readFolderNodeAttribute(space.folderNameOf(nodeId)!, attributeId, indexRange); }`.

> Read the existing `_readServerNodeAttribute` and the `OpcDataValue`/variant helpers to match exact encodings for QualifiedName/LocalizedText/NodeClass so the folder-node reads are wire-consistent.

- [ ] **Step 4: Run tests**

Run: `flutter test test/opcua_services_folder_test.dart` → PASS.
Run: `flutter test test/` (existing opcua service tests) → still green (root-only Objects browse unchanged: with no folders, the folder loop adds nothing and the count math equals the old `children.length + 1`).

- [ ] **Step 5: Extend the Rust `opcua` E2E probe**

Modify `gateway/examples/opcua_probe.rs` + `tool/opcua_e2e.sh` (read them first): the Dart fixture host maps a small set into a folder (e.g. two FLOAT64 tags with `folder: 'Ramp1'`); the Rust `opcua` client Browses the Objects folder, asserts a reference whose BrowseName == `Ramp1` and NodeClass == Object exists, Browses that folder node, asserts its tag children are present, and Reads one tag through it. Preserve the existing honest build+unit fallback (if the live client can't run, fall back and report truthfully). Run `bash tool/opcua_e2e.sh` and record the result (live PASS vs honest fallback) — do NOT claim a live PASS that did not occur.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/protocols/opcua/opcua_services.dart mobile/test/opcua_services_folder_test.dart gateway/examples/opcua_probe.rs tool/opcua_e2e.sh
git commit -m "feat(opcua): browse/read FolderType nodes; Rust opcua folder-browse E2E"
```

---

## Phase C — MQTT folder-prefixed metrics

### Task 3: Folder-prefix MQTT/Sparkplug metric names

**Files:**
- Modify: `mobile/lib/models/mqtt_map.dart` (`autoGenerate`)
- Modify: `mobile/lib/models/test_tag_set.dart` (`appendToMqttMap`)
- Test: `mobile/test/models/mqtt_map_test.dart` (extend or create) + `mobile/test/models/test_tag_set_test.dart` (extend)

**Interfaces:**
- Consumes: `PlcTag.folder`.
- Produces: an MQTT metric of `'<folder>/<name>'` for a foldered tag, bare `'<name>'` for a root tag; the entry's `tag` stays the bare tag name.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/models/mqtt_map_test.dart` (create if absent):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';

void main() {
  test('autoGenerate folder-prefixes the metric; root stays bare; tag stays bare name', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [
        PlcTag(name: 'Root1', path: 'Root1', dataType: 'BOOL', value: false, ioType: 'Internal'),
        PlcTag(name: 'R1', path: 'R1', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: 'Ramp1'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: []);
    final map = MqttMap.autoGenerate(p);
    final root = map.entries.firstWhere((e) => e.tag == 'Root1');
    final r1 = map.entries.firstWhere((e) => e.tag == 'R1');
    expect(root.metric, 'Root1');
    expect(r1.metric, 'Ramp1/R1');
    expect(r1.tag, 'R1'); // resolver key stays bare
  });
}
```

And add to `mobile/test/models/test_tag_set_test.dart`:

```dart
test('appendToMqttMap folder-prefixes generated metrics', () {
  final tags = buildTestSet(TestSetSpec(folder: 'Ramp1', baseName: 'R', count: 2, type: 'ramp',
    minValue: 0, maxValue: 1, periodMs: 1000)).tags;
  final map = MqttMap(entries: []);
  appendToMqttMap(map, tags);
  expect(map.entries.map((e) => e.metric), ['Ramp1/R1', 'Ramp1/R2']);
  expect(map.entries.map((e) => e.tag), ['R1', 'R2']);
});
```

> Confirm `MqttMap`/`MqttMapEntry` constructor names and whether the test file needs the `mqtt_map` import — adapt the fixture, keep the assertions.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/mqtt_map_test.dart test/models/test_tag_set_test.dart`
Expected: FAIL — metrics are bare `R1`/`R2`, not folder-prefixed.

- [ ] **Step 3: Implement**

- In `mqtt_map.dart` `autoGenerate`, change the metric assignment:
  ```dart
  entries.add(MqttMapEntry(
    tag: tag.name,
    metric: tag.folder.isEmpty ? tag.name : '${tag.folder}/${tag.name}',
    writable: tag.ioType != 'SimulatedOutput',
  ));
  ```
- In `test_tag_set.dart` `appendToMqttMap`, set each appended entry's metric to `tag.folder.isEmpty ? tag.name : '${tag.folder}/${tag.name}'` (keep `tag: tag.name`; keep the existing "skip already-present tag" dedup).

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/mqtt_map_test.dart test/models/test_tag_set_test.dart` → PASS.
Run: `flutter test test/models/` → still green (existing MQTT/test-set tests: bare-name expectations for root tags unchanged; adjust any pre-existing test that asserted a bare metric for a FOLDERED tag — there should be none, since folders are new).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/mqtt_map.dart mobile/lib/models/test_tag_set.dart mobile/test/models/mqtt_map_test.dart mobile/test/models/test_tag_set_test.dart
git commit -m "feat(mqtt): folder-prefixed metric names for Sparkplug folder rendering"
```

---

## Phase D — Validation, docs, final review

### Task 4: Whole-workstream validation + docs

**Files:**
- Modify: `docs/simulated-test-tags.md` (+ any OPC UA doc under `docs/`)
- Modify: `ROADMAP.md`
- Test: full suite

- [ ] **Step 1: Full green gate**

From `mobile/`: `flutter test` (report count, all green); `flutter analyze` (**No issues found!**); `flutter build web --release` (compiles). Fix code-caused failures; document environmental ones honestly.

- [ ] **Step 2: Regression confirmation**

Confirm the existing OPC UA service/address-space tests pass unchanged (root-only projects browse flat exactly as before). Confirm the WS6 round-trip test still passes (this workstream changes no persisted model — folder already round-trips; MQTT metric is regenerated, not a new persisted field).

- [ ] **Step 3: E2E result**

Report the `tool/opcua_e2e.sh` outcome from Task 2 (live folder-browse PASS vs honest fallback) truthfully.

- [ ] **Step 4: Docs + ROADMAP**

Update `docs/simulated-test-tags.md` to note that folders now appear as OPC UA FolderType nodes when browsing (e.g. in Ignition) and as `folder/metric` names over MQTT/Sparkplug. Add a ROADMAP entry. No vendor branding beyond naming the tested client factually.

```bash
git add docs/simulated-test-tags.md ROADMAP.md
git commit -m "docs(opcua): folder browsing + MQTT folder metrics; ROADMAP"
```

- [ ] **Step 5: Final whole-branch review**

Dispatch the final code review (opus) over the branch diff; fix Critical/Important findings; then finish the branch (merge `--no-ff` + push) per finishing-a-development-branch.

---

## Self-Review notes (author)

- **Spec coverage:** address-space folder nodes + root-only regression (T1); Browse Objects lists folders + folder browse + folder-node Read + OPC UA E2E (T2); MQTT folder-prefix metrics in autoGenerate + appendToMqttMap (T3); validation/docs/round-trip/final review (T4). All spec sections mapped.
- **Type consistency:** `folder`/`folders`/`folderNodeId`/`isFolderNode`/`folderNameOf`/`rootVariables`/`childFolders`/`folderVariables`/`children(folderNode)` defined in T1 and consumed identically in T2; `kFolderNodePrefix` used in T1 (node id) and matched by the E2E/services in T2; MQTT `'<folder>/<name>'` rule identical in T3's two edit sites.
- **Ordering:** A(1) → B(2) → C(3) → D(4). The service task (T2) depends only on T1's accessors; MQTT (T3) is independent; T1's `children(Objects)` change (root vars only) is what makes folders hold the non-root tags, and its root-only regression test guards the flat path.
