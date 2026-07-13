# OPC UA Folder Browsing (+ MQTT folder prefixes) — Design

**Date:** 2026-07-14
**Status:** Approved by user (chat, 2026-07-14).
**Builds on:** the in-app OPC UA server (`mobile/lib/protocols/opcua/opcua_address_space.dart` + `opcua_services.dart`), the `PlcTag.folder` field and simulated-test-tag folders (merged 2026-07-13), and the MQTT map (`mobile/lib/models/mqtt_map.dart`).

## Problem

The bulk-simulated-test-tags feature groups tags into folders (`PlcTag.folder`), and the app UI shows those folders. But the OPC UA server exposes a **flat** address space: browsing the standard Objects folder returns the `Server` object plus **every** tag Variable directly, with no intermediate nodes (`OpcUaAddressSpace.children` only returns children for the Objects folder; the doc comment even says "v1 scope: a flat address space"). Ignition (and any OPC UA client) browses the real address-space hierarchy via Organizes references, so it renders `Ramp001, Ramp002, …` flat under `softPLC_Sec` instead of under a `Ramp1` folder. The app's `folder` was never mapped into the OPC UA (or MQTT) structure.

## Goal

Make the OPC UA address space reflect each tag's `folder` as a browsable **FolderType** node, so a client browses `Objects ▸ Ramp1 ▸ Ramp001…`; root-folder tags (`folder == ''`) stay directly under Objects. Additionally, prefix MQTT/Sparkplug metric names with their folder (`Ramp1/Ramp001`) so Ignition's MQTT engine renders folders there too. Modbus and DNP3 are inherently flat numeric address spaces (registers / point indices) — folders do not apply and are out of scope.

## Decisions (locked with the user)

- Scope: **OPC UA folder browsing + MQTT folder-prefixed metric names.** Modbus/DNP3 unchanged (flat by nature).
- OPC UA folders are real **FolderType Object nodes** under Objects, with the tags Organized beneath them.
- Folder object **NodeIds use a reserved prefix** so a folder named the same as a tag can never collide; the browse tree shows the folder's plain name (clients display BrowseName, not NodeId).

## Architecture

### 1. Address space (`opcua_address_space.dart`)

The `OpcuaMap` stores only tag nodes (`tag → nodeId`); the **folder comes from the live `PlcTag.folder`**, which the builder already resolves per node via `_findTag`. So no `OpcuaMap`/persistence change is needed.

- `OpcUaAddressSpaceEntry` gains a `final String folder` (populated from the tag at build time; `''` = root).
- A new synthesized **folder node** concept: for each distinct non-empty folder among the entries, a folder Object node with NodeId `OpcNodeId.string(1, '$kFolderNodePrefix$folder')` where `kFolderNodePrefix` is a reserved marker (e.g. `'__folder__/'`) that a real tag NodeId (`ns=1;s=<tagName>`, tag names are plain identifiers) can never take. Expose: the ordered list of folders; `isFolderNode(nodeId)` and `folderNameOf(nodeId)`; and folder BrowseName/DisplayName = the plain folder name.
- `children(Objects)` returns **root-folder entries (folder=='') interleaved with the folder object nodes** (deterministic order: root entries in map order, then folders alphabetically — or a single documented order). `children(<folderNode>)` returns the entries whose `folder` matches. A variable node still has no children.
- **Byte-identical when every tag is root:** if no entry has a non-empty folder, no folder nodes are synthesized and `children(Objects)` returns exactly today's flat list — existing flat projects are unchanged.

### 2. Browse + Read services (`opcua_services.dart`)

- **Browse `Objects`** (`_writeBrowseResult`, the `isObjects` branch): emit `Server` (unchanged), then a reference per root-folder variable (unchanged shape), then a reference per **folder node** — `Organizes`, isForward, NodeClass=Object, TypeDefinition=FolderType, BrowseName/DisplayName = folder name. The reference count updates to `1 (Server) + rootVars + folders`.
- **Browse a folder node** (new branch, recognized via `space.isFolderNode(nodeId)`): emit a reference per variable in that folder (Organizes, NodeClass=Variable, TypeDefinition=BaseDataVariableType) — the same per-variable shape used today for Objects children.
- **Browse a variable / Server node**: unchanged (no children).
- **Read on a folder node** (`_readAttribute`, special-cased before the `byNodeId` lookup like the `Server` node is today): NodeClass=Object (Int32), BrowseName=QualifiedName(ns:1, folder), DisplayName=LocalizedText(folder), and (if requested) TypeDefinition handling consistent with the existing Server-node attribute reads. Unknown attributes on a folder node return the same Bad status the Server-node path uses.
- Malformed / unknown nodes still return Bad_NodeIdUnknown (the existing guard extends to "not root, not Objects, not Server, not a folder node, not a variable").

### 3. MQTT / Sparkplug metric folder prefixes (`mqtt_map.dart` + `test_tag_set.dart`)

- The published metric name for a foldered tag becomes **`<folder>/<name>`**; root tags stay `<name>`. Sparkplug/Ignition render slash-delimited metric names as folders.
- Applied at the metric source of truth: `MqttMap.autoGenerate` sets `metric: tag.folder.isEmpty ? tag.name : '${tag.folder}/${tag.name}'`; `appendToMqttMap` (in `test_tag_set.dart`) does the same for appended sets. The `tag` field of each entry stays the bare tag name (the resolver key). Additive — regenerating / re-auto-generating the MQTT map picks it up; existing bare-name maps are untouched until regenerated.

## Testing

**Address space (`opcua_address_space_test.dart`):** an entry carries its tag's `folder`; a project with folders synthesizes one folder node per distinct folder with the reserved-prefix NodeId and plain BrowseName; `children(Objects)` = root entries + folder nodes; `children(<folder>)` = that folder's entries; `isFolderNode`/`folderNameOf` correct; a **root-only project produces no folder nodes and a flat `children(Objects)` identical to today** (regression guard); a folder named identically to a tag does not collide (distinct NodeIds).

**Browse/Read services (`opcua_services_test.dart` or the existing service test):** browsing Objects returns `Server` + root variables + folder Object references (FolderType type-def); browsing a folder node returns its variable references; Read on a folder node returns NodeClass=Object + BrowseName/DisplayName = folder; an all-root project's Objects browse is byte-identical to before.

**MQTT (`mqtt_map_test.dart` + `test_tag_set_test.dart`):** `autoGenerate` and `appendToMqttMap` produce `folder/name` for a foldered tag and bare `name` for a root tag; the entry's `tag` stays the bare name.

**Machine-proof E2E:** extend the Rust `opcua` probe (`gateway/examples/opcua_probe.rs` + `tool/opcua_e2e.sh`): map a small set into a folder, Browse Objects and assert a folder node appears, Browse that folder and assert its tags are children, and Read one tag through the folder path. Preserve the existing honest build+unit fallback; report live vs fallback truthfully.

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release` compiles; existing OPC UA service/address-space tests still pass (flat behavior preserved for root-only projects); WS6 round-trip unaffected (this is server-side structure, not a persisted-model change).

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); OPC UA / IEC terms fine.
- `mobile/lib/protocols/opcua/**` and `mobile/lib/models/**` stay **pure Dart** (no `dart:io`, no Flutter). Every standard NodeId/NodeClass/AttributeId already in `opcua_address_space.dart` is cross-checked against the vendored Rust `opcua-0.12.0` crate — new usages (FolderType i=61 already present; Organizes i=35 already present) must stay consistent with it.
- Zero `flutter analyze` warnings; braces on all control flow; prefer `const`.
- Additive/behavior-preserving: a project with only root tags browses byte-identically to today; MQTT metric change is additive (only foldered tags differ, and only on (re)generate).
- Folder node NodeIds use a reserved prefix that cannot collide with a tag NodeId; the wire encoding matches the existing `OpcNodeId.string` path.

## Phasing (one spec → phased plan)

- **Phase A — Address-space folder model.** `OpcUaAddressSpaceEntry.folder`; synthesized folder nodes + `isFolderNode`/`folderNameOf`/`children(folder)`; `children(Objects)` = root + folders; root-only regression. Unit tests.
- **Phase B — Browse/Read services + OPC UA E2E.** Objects browse lists folder objects; folder browse lists its variables; folder-node Read. Extend the Rust `opcua` probe to prove folder browsing over the wire. Service tests.
- **Phase C — MQTT folder-prefixed metrics.** `autoGenerate` + `appendToMqttMap` emit `folder/name`. Tests.
- **Phase D — Validation, docs, final review.** Full gates; update `docs/simulated-test-tags.md` (+ any OPC UA doc) to note folder browsing; whole-branch review; merge.
