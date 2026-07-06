# Outbound Protocols Configuration (WS17) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "do the OPC UA now, extensible … under
the 'Outbound protocols' area per project you disable or enable that protocol
(allowing for multiple enabled) and configure them there"). Endpoint-scope
decision (per-project) made autonomously per the recommended default; vetoable.
**Author:** Claude (pairing with Jarrod)

Replaces the WS16 OPC-UA-specific "Gateway" panel with a general, per-project
**Outbound Protocols** section: each outbound industrial protocol has an
enable/disable toggle (multiple may be enabled at once) and is configured in
place. Only OPC UA is served today; the model and UI are structured so the next
protocols (Modbus/MQTT/DNP3) slot in as each one's gateway support ships — with
**no dead placeholder UI** for protocols that don't work yet.

## What changes vs. today

WS16 put the gateway *connection* (a `ws://` URL, session-only, unsaved) and the
OPC UA *node map* (saved via the top-level `PlcProject.opcuaMap`) on one screen.
WS17:
- introduces a per-project **`ProtocolSettings`** object (serialized) that holds
  the gateway endpoint + a config per protocol (OPC UA now), and
- migrates the top-level `opcua_map` field into it (additive, back-compat), and
- reworks the screen into the **Outbound Protocols** section.

## Model (`mobile/lib/models/protocol_settings.dart`, pure)

- `OpcUaProtocolConfig`:
  - `bool enabled` (default `false`),
  - `String namespaceUri` (default `urn:softplc:<projectId>`),
  - `OpcuaMap map` (the existing node↔tag↔access model — reused verbatim).
  - `toJson`/`fromJson`; a helper to (re)generate the map from the project tags
    (reuses `OpcuaMap.autoGenerate`).
- `ProtocolSettings`:
  - `String gatewayUrl` (default `kDefaultGatewayUrl`, `ws://localhost:4855`) —
    the connection endpoint, **stored per-project**.
  - `OpcUaProtocolConfig? opcua` (null until configured).
  - `toJson`/`fromJson`. **Extensible:** a new protocol = a new
    `XProtocolConfig` field + a new card; the JSON is an object keyed by
    protocol, so adding one is additive and doesn't touch existing ones.
- `PlcProject.protocols` (`ProtocolSettings?`, default null) replaces
  `PlcProject.opcuaMap`. Serialized under key `protocols`, **omitted when null**
  so default projects (no protocol config) round-trip byte-identically.
  - **Back-compat migration** on `fromJson`: if `protocols` is absent but the old
    top-level `opcua_map` key is present (a project saved by WS16), build
    `ProtocolSettings(gatewayUrl: default, opcua: OpcUaProtocolConfig(enabled:
    true, namespaceUri: <map's namespaceUri>, map: <the old map>))`. If both
    absent → `protocols` stays null. (No data loss for any WS16-saved map.)

## The "Outbound Protocols" section (replaces `gateway_screen.dart`)

A per-project section (nav entry relabelled "Outbound Protocols"):
- **Connection card** (top): the gateway endpoint field (bound to
  `protocols.gatewayUrl`), Connect/Disconnect, and the live `GatewayStatus`
  indicator + last error (as today).
- **Protocol list**: one card per outbound protocol. Today: **OPC UA** —
  - an **enable/disable toggle** (`opcua.enabled`),
  - when enabled: a namespace field (`opcua.namespaceUri`), the exposed-tag /
    node-map editor (node↔tag↔access, Regenerate-from-tags), and the exposed-tag
    count. When disabled, the card collapses to the toggle (config hidden/greyed).
  - The list is built to hold multiple protocol cards; **multiple protocols may
    be enabled simultaneously** (the bridge streams the union of enabled
    protocols' exposed tags — today just OPC UA).
- Lazily create a default `ProtocolSettings` when the section is first opened on
  a project that has none (mirroring WS16's `_ensureMap` — mutate in place, do
  NOT autosave until the user actually changes something), so untouched default
  projects stay serialization-clean.
- Responsive, dark, no overflow at 360/320/1400.

## Client wiring (`gateway_client.dart` + shell)

- The `GatewayClient` exposes tags from `protocols.opcua` **only when
  `opcua.enabled`** (and, in future, the union across enabled protocols). When no
  protocol is enabled, `connect` sends an empty snapshot (nothing exposed).
- The gateway endpoint comes from `protocols.gatewayUrl` (per-project), with the
  section's field bound to it; the Connect button uses that value.
- Everything else (force-aware inbound writes, per-scan delta, status, opt-in /
  app-unchanged-when-disconnected) is unchanged from WS16.
- The Rust gateway is **unchanged** — it already serves OPC UA from the snapshot's
  map; enabling/disabling and the namespace are expressed through what the app
  streams. (Per-protocol server ports remain gateway-launch settings; out of
  scope here.)

## Testing

- **Model unit tests** (pure): `ProtocolSettings`/`OpcUaProtocolConfig`
  `toJson`/`fromJson` round-trip; the back-compat migration (a project JSON with
  the old top-level `opcua_map` and no `protocols` → a `ProtocolSettings` with
  `opcua.enabled = true` and the same map); a project with neither → `protocols`
  null; enable/disable persists.
- **Serialization guard:** `serialization_roundtrip_test.dart` stays green — default
  projects (protocols null) serialize byte-identically; a project WITH
  `protocols` round-trips losslessly (update the WS16 populated-map round-trip
  test to the new field).
- **Section widget tests:** the Outbound Protocols section renders the connection
  card + an OPC UA card with an enable toggle; toggling enable shows/hides the
  config and updates `opcua.enabled`; editing the endpoint updates
  `protocols.gatewayUrl`; the node-map editor still works; no overflow at
  320/1400; `takeException()` null.
- **Client test:** with OPC UA disabled, `connect` sends an empty snapshot; with
  it enabled, the snapshot carries the mapped tags (extend the existing
  `gateway_client_test.dart`).
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding. Dark theme; responsive (WS5). `flutter
analyze` zero. Pure model in `mobile/lib/models` (UI-free). Additive/back-compat
persistence — the WS6 round-trip guard stays green; no WS16-saved OPC UA map is
lost. App is a WebSocket client only, unchanged when disconnected. No RenderFlex
overflow at 360/320/1400.

## Out of scope (deferred)
- Modbus/MQTT/DNP3 config cards + servers (each ships with its own protocol
  workstream; the model/section are ready for them).
- Per-protocol server ports flowing from the app to the gateway (gateway-launch
  setting for now); OPC UA security; multi-gateway/endpoint-per-protocol.
