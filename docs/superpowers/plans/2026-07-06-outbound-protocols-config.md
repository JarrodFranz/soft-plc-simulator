# Outbound Protocols Configuration (WS17) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the OPC-UA-specific Gateway panel with a per-project "Outbound Protocols" section where each protocol has an enable/disable toggle (multiple enabled allowed) and is configured in place — OPC UA now, structured for more later.

**Architecture:** A per-project `ProtocolSettings` model (gateway endpoint + a config per protocol) replaces the top-level `PlcProject.opcuaMap` (migrated back-compat). The `GatewayClient` streams exposed tags only for ENABLED protocols. The section renders a connection card + a protocol list (OPC UA card with enable toggle + namespace + node-map editor).

**Tech Stack:** Flutter / Dart, `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding. Dark theme; responsive (WS5). `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`; `initialValue:` on dropdowns.
- Pure model in `mobile/lib/models` (UI-free). App is a WebSocket client only, unchanged when disconnected.
- Additive/back-compat persistence: the WS6 `serialization_roundtrip_test.dart` must stay green (default projects byte-identical; `protocols` omitted when null); NO WS16-saved OPC UA map may be lost (migrate the old `opcua_map` key).
- No RenderFlex overflow at 360/320/1400. Existing 423 tests must keep passing.

**Sequencing:** Task 1 (model + migration) is the foundation. Task 2 (section + client wiring) builds on it. Task 3 validates.

---

### Task 1: `ProtocolSettings` model + migrate `opcuaMap` → `protocols`

**Files:**
- Create: `mobile/lib/models/protocol_settings.dart`
- Modify: `mobile/lib/models/project_model.dart` (replace `opcuaMap` field with `protocols`, back-compat read)
- Test: `mobile/test/protocol_settings_test.dart`; update `mobile/test/opcua_map_test.dart`'s PlcProject-level round-trip test to the new field

**Interfaces:**
- `OpcUaProtocolConfig { bool enabled; String namespaceUri; OpcuaMap map; }` with `toJson`/`fromJson` (keys `enabled`/`namespace_uri`/`map`; `map` is `OpcuaMap.toJson()` shape) and a `static OpcUaProtocolConfig defaults(PlcProject p)` → `enabled:false`, `namespaceUri:'urn:softplc:${p.id}'`, `map: OpcuaMap.autoGenerate(p)`.
- `ProtocolSettings { String gatewayUrl; OpcUaProtocolConfig? opcua; }` with `toJson`/`fromJson` (keys `gateway_url`/`opcua`) and `static ProtocolSettings defaults(PlcProject p)` → `gatewayUrl: kDefaultGatewayUrl` (import from `gateway_client.dart`, or re-declare the const in the model to keep the model UI-free — prefer a small `const kDefaultGatewayUrl` in the model or a shared constants file; DO NOT import a Flutter service into a pure model). Choose: put `kDefaultGatewayUrl` in the model file (pure) and have `gateway_client.dart` re-export/use it.
- `PlcProject.protocols` (`ProtocolSettings?`, default null). `toJson`: `if (protocols != null) 'protocols': protocols!.toJson()` and REMOVE the `opcua_map` emission. `fromJson`: `protocols = proj['protocols'] != null ? ProtocolSettings.fromJson(...) : (proj['opcua_map'] != null ? ProtocolSettings(gatewayUrl: kDefaultGatewayUrl, opcua: OpcUaProtocolConfig(enabled: true, namespaceUri: <old map's namespaceUri>, map: OpcuaMap.fromJson({'opcua_map': proj['opcua_map']}))) : null)`.

- [ ] **Step 1: Write failing tests** in `protocol_settings_test.dart`:
  - `ProtocolSettings`/`OpcUaProtocolConfig` `toJson`→`fromJson` round-trip (enabled true/false, namespaceUri, a couple map nodes).
  - **Migration:** a `PlcProject.fromJson` on a map that has the OLD top-level `opcua_map` (3 nodes) and NO `protocols` → `project.protocols` non-null, `opcua.enabled == true`, `opcua.map` has the 3 nodes; a project with NEITHER key → `project.protocols == null`; a project WITH `protocols` → parsed as-is.
  - `PlcProject` with a populated `protocols` round-trips losslessly (jsonEncode→decode→fromJson→same gatewayUrl/opcua.enabled/map).
  - `ProtocolSettings.defaults(project)` builds `opcua.enabled=false`, `namespaceUri='urn:softplc:<id>'`, a non-empty map for a project with scalar tags.
  - Update `opcua_map_test.dart`: the WS16 "PlcProject with populated opcuaMap round-trips" test now sets `project.protocols` instead of `project.opcuaMap` (the old field is gone).
- [ ] **Step 2: Run → FAIL. Step 3: Implement** `protocol_settings.dart` + the `PlcProject.protocols` field with the back-compat `fromJson` and the `toJson` change (removing `opcua_map`). Keep `OpcuaMap`/`OpcuaNode` unchanged.
- [ ] **Step 4: Tests → PASS; `serialization_roundtrip_test.dart` green (default projects byte-identical, protocols null → omitted); `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(protocols): per-project ProtocolSettings model + migrate opcua_map into it`.

---

### Task 2: Outbound Protocols section + client wiring

**Files:**
- Modify/rename: `mobile/lib/screens/gateway_screen.dart` → the Outbound Protocols section (keep the file or rename to `outbound_protocols_screen.dart`; update imports)
- Modify: `mobile/lib/services/gateway_client.dart` (exposed tags from enabled protocols; endpoint from `protocols.gatewayUrl`), `mobile/lib/screens/workspace_shell.dart` (nav label + the section wiring; the scan hook unchanged)
- Test: update `mobile/test/gateway_screen_test.dart` (→ the section) and extend `mobile/test/gateway_client_test.dart`

- [ ] **Step 1: Update `GatewayClient`** to read exposed tags from `project.protocols?.opcua` **only when `opcua.enabled == true`** (else expose nothing). The connect endpoint: the section passes `project.protocols!.gatewayUrl` to `client.connect`. Keep all other behaviour (force-aware writes, delta, status). Remove references to the old `project.opcuaMap`.
- [ ] **Step 2: Write failing tests**:
  - `gateway_client_test.dart`: with `protocols.opcua.enabled == false`, `connect` sends a snapshot with ZERO tags; with it `true`, the snapshot carries the mapped tags (decode the frame). (Reuse the fake channel harness.)
  - `gateway_screen_test.dart` (the section): renders a connection card (endpoint field + Connect) and an OPC UA protocol card with an enable toggle; toggling the enable updates `protocols.opcua.enabled` and shows/hides the config; editing the endpoint updates `protocols.gatewayUrl`; the node-map editor still edits access; no overflow at 320/1400; `takeException()` null.
- [ ] **Step 3: Run → FAIL. Step 4: Implement** the section: lazily `_ensureProtocols()` (create `ProtocolSettings.defaults(project)` in place when null, no autosave until changed — mirror WS16's `_ensureMap`); a connection card bound to `protocols.gatewayUrl`; a protocol list with an OPC UA card (enable `Switch`, namespace field, the node-map editor moved in, exposed-tag count); persist edits via `onProjectUpdated`. Relabel the shell nav entry to "Outbound Protocols" (the nav id may stay `'GATEWAY'` internally or become `'PROTOCOLS'` — if you change the id, update `_ensureValidView` + `_buildCenterWorkspace` + any test referencing it). Keep the scan hook and opt-in behaviour unchanged.
- [ ] **Step 5: Tests → PASS; `flutter analyze` clean; full suite passes; `flutter build web --release` succeeds.** Discard plugin-registrant churn before finishing.
- [ ] **Step 6: Commit** `feat(protocols): Outbound Protocols section (per-protocol enable + config)`.

---

### Task 3: Validation + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" lib test` → no matches.
- [ ] **Step 2:** Confirm end-to-end: a user opens Outbound Protocols on a project, enables OPC UA, edits the namespace/endpoint/map, connects to the gateway, and the enable/config persists with the project (survives a reload); disabling OPC UA exposes nothing.
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** `ProtocolSettings` model + `opcua_map`→`protocols` migration (Task 1) ✓; Outbound Protocols section with per-protocol enable + config + client gating (Task 2) ✓; validation (Task 3) ✓.
- **Additivity/guard:** `protocols` is additive (omitted when null) → default projects byte-identical; the migration preserves any WS16-saved OPC UA map; round-trip guard stays green.
- **Type consistency:** `ProtocolSettings.gatewayUrl`/`opcua`, `OpcUaProtocolConfig.enabled`/`namespaceUri`/`map`, and `PlcProject.protocols` used consistently across model/section/client; `kDefaultGatewayUrl` single source.
- **Extensibility:** a new protocol = a new `XProtocolConfig` field on `ProtocolSettings` + a new card in the list; no change to existing protocols. No dead placeholder UI now.
- **Deferred:** Modbus/MQTT/DNP3 cards+servers; per-protocol ports to the gateway; OPC UA security.
