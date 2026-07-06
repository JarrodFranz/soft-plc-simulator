# OPC UA Companion Gateway Bridge (WS16) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Flutter app to a thin Rust companion gateway that exposes the running project's tags over OPC UA, via a reusable WebSocket tag-sync layer (app stays authoritative; gateway is a protocol shell).

**Architecture:** App (Dart engine) streams a tag snapshot + per-scan deltas over a WebSocket to the gateway and applies inbound writes force-aware; the gateway mirrors the tags and serves them as OPC UA variable nodes built from an editable map. The sync codec is pure/tested on both sides. App is unchanged when no gateway is connected (opt-in observer).

**Tech Stack:** Flutter/Dart (`web_socket_channel`), Rust (`tokio`, `tokio-tungstenite`, `opcua`, `serde_json`), `flutter_test` + `cargo test`.

## Global Constraints

- No third-party/reference-editor branding. Dark theme; responsive. `flutter analyze` zero. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- Pure sync/codec logic in `mobile/lib/models` (UI-free). The app behaves EXACTLY as today when no gateway is connected — the gateway is strictly opt-in (an observer that streams tag changes); NO change to the scan pipeline's behaviour.
- Additive persistence: a new optional `opcuaMap` project field with a back-compat default (empty) — the WS6 `serialization_roundtrip_test.dart` must stay green. No other serialized field changes.
- Gateway stays a simulator/training tool — keep the existing "NOT safety certified" banner. The app is a WebSocket **client** (outbound) only; no inbound server behaviour in the app.
- Existing suites stay green: `flutter test` (382) and `cargo test` (runtime 43). `flutter build web --release` and `cargo build` (gateway) succeed.

**Sequencing:** Task 1 (pure codec + map model) locks the wire contract. Task 2 (app client + UI) builds on it. Task 3 (Rust gateway) implements the other end of the same contract. Task 4 validates cross-language + documents E2E.

---

### Task 1: Sync codec + OPC UA map model (pure Dart, fully tested)

**Files:**
- Create: `mobile/lib/models/gateway_sync.dart` (message types + codec), `mobile/lib/models/opcua_map.dart` (map model + auto-generate)
- Modify: `mobile/lib/models/project_model.dart` (add optional `opcuaMap` to `PlcProject` + toJson/fromJson)
- Test: `mobile/test/gateway_sync_test.dart`, `mobile/test/opcua_map_test.dart`

**Interfaces:**
- `gateway_sync.dart`: sealed/tagged message classes and `encodeMessage(SyncMessage) -> String` (JSON) / `SyncMessage decodeMessage(String)`; helpers `tagValueToJson(dynamic, String dataType)` / `jsonToTagValue(dynamic, String dataType)`. Messages: `HelloMsg{project,controller,scanMs}`, `SnapshotMsg{List<ExposedTag>}` (`ExposedTag{path,dataType,value,access}`), `DeltaMsg{List<TagChange>}` (`TagChange{path,value}`), `WriteMsg{path,value}`, `ReadyMsg`, `PingMsg`, `PongMsg`. Decode of an unknown/malformed message returns a typed `UnknownMsg`/throws a caught `FormatException` — never an uncaught crash.
- `opcua_map.dart`: `OpcuaMap{namespaceUri, List<OpcuaNode>}`, `OpcuaNode{nodeId, tag, access}` (`access` in `{ReadOnly, ReadWrite}`); `OpcuaMap.fromJson`/`toJson` matching `examples/protocol-maps/opcua_map_example.json`; `OpcuaMap.autoGenerate(PlcProject)` → a node per scalar leaf tag (`nodeId: 'ns=1;s=<path>'`, `access: ReadWrite` for SimulatedInput/Internal, `ReadOnly` for outputs).
- `project_model.dart`: `PlcProject.opcuaMap` (`OpcuaMap?`, default null/empty), serialized under key `opcua_map` with a back-compat default on read.

- [ ] **Step 1: Write failing tests.**
  - `gateway_sync_test.dart`: `encodeMessage` then `decodeMessage` round-trips each message type to an equal object; `tagValueToJson`/`jsonToTagValue` round-trip bool/int/float/string per dataType; a malformed JSON string decodes to `UnknownMsg` (or throws `FormatException`) without crashing.
  - `opcua_map_test.dart`: `OpcuaMap.fromJson(exampleJson)` yields the 3 example nodes with correct access; `toJson` round-trips; `autoGenerate` on a small project produces `ns=1;s=<path>` node ids with ReadWrite for a SimulatedInput tag and ReadOnly for an output tag; scalar-only (a struct/array tag is skipped in v1).
  - Extend the serialization round-trip guard implicitly: add a case (or rely on the existing per-default-project guard) that a project WITH an `opcuaMap` round-trips losslessly.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the two model files + the `PlcProject.opcuaMap` field (additive; `fromJson` defaults to null when the key is absent — verify the existing round-trip guard stays green).
- [ ] **Step 4: Tests → PASS; `serialization_roundtrip_test.dart` green; `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(gateway): tag-sync codec + OPC UA map model (pure, serialized)`.

---

### Task 2: App GatewayClient + gateway panel + map editor

**Files:**
- Create: `mobile/lib/services/gateway_client.dart`, a gateway panel screen (e.g. `mobile/lib/screens/gateway_screen.dart`)
- Modify: `mobile/lib/screens/workspace_shell.dart` (nav entry + wire tag-change streaming), `mobile/pubspec.yaml` (add `web_socket_channel`)
- Test: `mobile/test/gateway_client_test.dart`, a widget test for the panel

**Interfaces consumed:** Task 1's `gateway_sync.dart`/`opcua_map.dart`; the shell's tag DB + the force-aware write path (reuse the same write used by sim/exec so forcing wins); `PlcProject.opcuaMap`.

- [ ] **Step 1: Add `web_socket_channel` to pubspec** (a maintained package; pin a version). Run `flutter pub get`.
- [ ] **Step 2: Write failing tests** for `GatewayClient` against a **fake** `StreamChannel`/`WebSocketChannel` (NO real socket): on connect it sends `hello` then `snapshot` (from the project's exposed tags per the map); calling `syncTags(project)` after a tag changes emits a `delta` with only the changed exposed tags (and nothing when unchanged); an inbound `WriteMsg` applies the value to the tag **force-aware** (a forced root tag is NOT overwritten); status transitions disconnected→connecting→connected and →error on a socket error; reconnect re-sends snapshot. A widget test: the gateway panel shows status, a Connect/Disconnect control, URL field, and exposed-tag count; no overflow at 320/1400; `takeException()` null.
- [ ] **Step 3: Implement** `GatewayClient` (a `ChangeNotifier`/`ValueNotifier<GatewayStatus>` wrapping a `WebSocketChannel`, injectable channel factory so tests pass a fake), the panel screen, the nav entry in the shell, and the per-scan hook that calls `client.syncTags(_activeProject)` when connected (changed-only). The map editor may be a section of the panel (generate default from tags via `OpcuaMap.autoGenerate`, edit node access/tag). Keep the app fully functional when disconnected.
- [ ] **Step 4: Tests → PASS; `flutter analyze` clean; full suite passes; `flutter build web --release` succeeds.** Discard plugin-registrant churn before finishing.
- [ ] **Step 5: Commit** `feat(gateway): app WebSocket client + gateway panel + OPC UA map editor`.

---

### Task 3: Rust gateway — WebSocket server + tag mirror + OPC UA server

**Files:**
- Modify: `gateway/Cargo.toml` (add `tokio`, `tokio-tungstenite`, `futures-util`, `opcua`), `gateway/src/main.rs`
- Create: `gateway/src/sync.rs` (message types + codec parity with Dart), `gateway/src/mirror.rs` (tag mirror), `gateway/src/opcua_server.rs` (address space from map)
- Test: Rust unit tests in each module + a scripted local client round-trip

- [ ] **Step 1: Write failing `cargo test`s.** `sync.rs`: decode the exact JSON the Dart codec emits (use shared fixture strings copied from the Dart tests) into the Rust message enums and re-encode to equal JSON (codec parity). `mirror.rs`: applying a `snapshot` then a `delta` yields the expected `HashMap<path, TagValue>` with correct types; unknown paths ignored. `opcua_server.rs`: building the address space from an `OpcuaMap` produces one variable per node with the right `NodeId`/access (test the builder function, not a live server).
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `sync.rs`: `serde` structs/enum mirroring the Dart messages (tag `type` discriminator), `serde_json` de/encode.
  - `mirror.rs`: the tag mirror (`HashMap`), `apply(snapshot)` / `apply(delta)`, typed value coercion reusing `soft_plc_runtime::tag::TagValue`.
  - `opcua_server.rs`: a function that, given an `OpcuaMap` + a shared mirror handle, registers variable nodes (namespace 1, string ids) with read callbacks returning the mirror value and (for ReadWrite) write callbacks that push a `write` onto an outbound channel.
  - `main.rs`: a `tokio` runtime — accept one WebSocket connection (the app), read `hello`/`snapshot`/`delta` into the mirror, start the OPC UA server from the (map in the snapshot or a bundled default), and forward OPC-client writes back as `write` messages. Keep the "NOT safety certified" banner. Graceful handling of disconnect/reconnect.
- [ ] **Step 4: `cargo test` (gateway) all pass; `cargo build` succeeds; `cargo clippy` clean if available.** A scripted local round-trip (a `#[tokio::test]` or an `examples/` binary): start the ws server + OPC UA server, connect a Rust `opcua` client, read a mapped node's value (seeded via a snapshot) and write a ReadWrite node, assert a `write` message is produced. If a full in-test OPC client proves too heavy, implement the round-trip at the mirror+builder+forward level and DOCUMENT the external-client step.
- [ ] **Step 5: Commit** `feat(gateway): OPC UA server over WebSocket tag-sync (thin, app-authoritative)`.

---

### Task 4: Validation + docs + final review

- [ ] **Step 1:** `flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` succeeds · `cargo test` (gateway + runtime) pass · `cargo build` succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" mobile/lib mobile/test gateway/src` → no matches.
- [ ] **Step 2:** Write/refresh `docs/protocols/opcua.md` (and update `README`/`ARCHITECTURE` status) covering: how to run the gateway (`cargo run -p soft-plc-gateway`), connect the app (URL), and verify with an external OPC UA client (UAExpert) — clearly marking what is machine-verified (codec/mirror/builder/round-trip tests) vs. manual (external SCADA client, native mobile transport).
- [ ] **Step 3:** Confirm end-to-end at the level achievable here: app connects to a locally-run gateway, a tag change streams through, and an OPC-client write round-trips back (scripted where feasible, documented otherwise). Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** sync codec + map model + serialization (Task 1) ✓; app client + panel + map editor (Task 2) ✓; Rust ws server + mirror + OPC UA server (Task 3) ✓; validation + docs (Task 4) ✓.
- **Additivity/guard:** the app is unchanged when disconnected (opt-in observer); the only serialized addition is the optional `opcuaMap` field (back-compat default) — round-trip guard stays green. The runtime crate is untouched; the gateway gains code + tests.
- **Type consistency:** the sync message set + `ExposedTag`/`TagChange`/`OpcuaNode` shapes are identical across Dart (`gateway_sync.dart`/`opcua_map.dart`) and Rust (`sync.rs`/`mirror.rs`/`opcua_server.rs`), locked by shared codec fixtures.
- **Testability reality:** codec (both sides), the app client (fake channel), the mirror, and the address-space builder are fully unit-tested; the live external-SCADA-client path and native mobile WebSocket transport are documented manual steps (the dev/CI environment can't host every SCADA client). Reviews will be explicit about machine-verified vs. documented.
- **Deferred:** Modbus/MQTT/DNP3 (reuse this sync layer), OPC UA security beyond anonymous/None, struct/array member nodes, FFI/Mode A, Rust-engine execution parity.
