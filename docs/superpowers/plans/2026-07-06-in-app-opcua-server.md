# In-App OPC UA Server v1 (WS19) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Dart OPC UA server hosted inside the app (Security `None`, anonymous): third-party OPC UA clients connect to `opc.tcp://<device>:<port>`, browse the per-project exposed tags, read live values, and write `ReadWrite` tags force-aware. No companion process, no FFI (ADR-010).

**Architecture:** Pure protocol layers in `mobile/lib/protocols/opcua/` (binary codec → transport framing → secure-channel/session state machine → services over an address space built from `OpcuaMap` + the live tag DB), with the only `dart:io` in `mobile/lib/services/opcua_host.dart` (ServerSocket, start/stop). Verified by codec fixtures (cross-checked against the Rust `opcua` crate source), socketless state-machine tests, and a Rust `opcua`-client E2E probe.

**Tech Stack:** Dart (`dart:typed_data`; `dart:io` only in the host), Flutter for UI, `flutter_test`; Rust `opcua` client (dev harness only, via `cargo`).

## Global Constraints

- No third-party/reference-editor branding. Dark theme; responsive; `flutter analyze` ZERO; no RenderFlex overflow at 360/320/1400. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- `mobile/lib/protocols/opcua/*` is PURE Dart: no Flutter imports, no `dart:io` (sockets live only in `services/opcua_host.dart`). The server must NEVER crash the app: connection handlers guarded; malformed input → clean `ERR`/close, never an uncaught throw.
- Writes go through the force-aware rule (forcing wins), `ReadWrite` map nodes only.
- Additive persistence: `OpcUaProtocolConfig` gains `port` (int, default 4840) — the WS6 round-trip guard must stay green. App byte-identical when hosting is stopped.
- All wire encodings are OPC UA Binary, little-endian, per OPC UA Part 6. Where in doubt, consult the local Rust reference implementation: `C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/` — mirror ITS byte layouts.
- Run cargo/flutter in the FOREGROUND with bounded timeouts; never leave hanging tests/processes.

**Sequencing:** Task 1 (codec+framing) → Task 2 (channel+session) → Task 3 (services+address space) → Task 4 (socket host + UI + Rust E2E) → Task 5 (validation + final review).

---

### Task 1: OPC UA binary codec + transport framing (pure, fixture-tested)

**Files:**
- Create: `mobile/lib/protocols/opcua/opcua_binary.dart`, `mobile/lib/protocols/opcua/opcua_transport.dart`
- Test: `mobile/test/opcua_binary_test.dart`, `mobile/test/opcua_transport_test.dart`

**Interfaces (consumed by Tasks 2-4):**
- `class OpcUaWriter { void boolean(bool); void uint8/int8/uint16/int16/uint32/int32/uint64/int64(...); void float32/float64(double); void string(String?); void byteString(List<int>?); void dateTime(DateTime?); void guid(...); void nodeId(OpcNodeId); void expandedNodeId(...); void statusCode(int); void qualifiedName(OpcQualifiedName); void localizedText(OpcLocalizedText); void variant(OpcVariant); void dataValue(OpcDataValue); void extensionObjectHeader(...); Uint8List take(); }` and the mirrored `class OpcUaReader { ... ; bool get atEnd; }` — little-endian, reader bounds-checked (`FormatException` on truncation — callers catch at the transport boundary).
- Value model classes: `OpcNodeId` (namespace + numeric/string identifier; encodings two-byte `0x00`, four-byte `0x01`, numeric `0x02`, string `0x03`), `OpcQualifiedName{ns,name}`, `OpcLocalizedText{locale?,text?}`, `OpcVariant{typeId,value,isArray}` (scalars: Boolean 1, SByte 2, Byte 3, Int16 4, UInt16 5, Int32 6, UInt32 7, Int64 8, UInt64 9, Float 10, Double 11, String 12, DateTime 13, StatusCode 19, NodeId 17, QualifiedName 20, LocalizedText 21; arrays = `0x80` flag + Int32 length), `OpcDataValue{variant?,status?,sourceTs?,serverTs?}` (mask `0x01/0x02/0x04/0x08`), `RequestHeader`/`ResponseHeader` structs (encode/decode; authToken NodeId, timestamp, requestHandle, returnDiagnostics, auditEntryId, timeoutHint, additionalHeader = empty ExtensionObject; response: timestamp, requestHandle, serviceResult, empty DiagnosticInfo `0x00`, empty string table, empty ExtensionObject).
- `opcua_transport.dart`: connection-message codec — `HelloMessage{protocolVersion, receiveBufferSize, sendBufferSize, maxMessageSize, maxChunkCount, endpointUrl}`, `AcknowledgeMessage{...}`, `ErrorMessage{error, reason}` with `MessageHeader` = 3-byte type (`HEL`/`ACK`/`ERR`/`OPN`/`MSG`/`CLO`) + 1-byte chunk flag (`F` final; `C`/`A` rejected in v1) + UInt32 total size. Secure-conversation chunk codec: `parseChunk(Uint8List) -> OpcChunk{messageType, secureChannelId, securityHeader, sequenceNumber, requestId, body}` and `buildChunk(...)` — OPN uses the asymmetric header (`securityPolicyUri` = `http://opcfoundation.org/UA/SecurityPolicy#None`, null senderCertificate ByteString, null receiverCertificateThumbprint ByteString); MSG/CLO use the symmetric header (UInt32 tokenId); both followed by the sequence header (UInt32 sequenceNumber, UInt32 requestId); body = NodeId (the four-byte binary-encoding id) + struct bytes.
- DateTime: Int64 count of 100 ns ticks since 1601-01-01T00:00:00Z (0 = null); Guid: 16 bytes (UInt32+UInt16+UInt16 LE + 8 raw bytes).

- [ ] **Step 1: Write failing tests.** Round-trip EVERY type above through writer→reader (edge cases: null string (-1), empty string, non-ASCII UTF-8, all four NodeId encodings incl. two-byte for id ≤ 255/ns 0 and four-byte for id ≤ 65535, Variant scalar of each supported type + an Int32 array + a String array, every DataValue mask combination, LocalizedText 0x01/0x02/0x03 masks, DateTime null/epoch/now, ByteString null/empty/bytes). Known-byte FIXTURES for the tricky encodings — derive from OPC UA Part 6 §5.2 and CROSS-CHECK by reading the Rust reference (`opcua-0.12.0/src/types/node_id.rs`, `variant.rs`, `data_value.rs`, `date_time.rs`): e.g. `NodeId(ns:0, i:255)` encodes as `[0x00, 0xFF]`; `NodeId(ns:1, i:1000)` four-byte as `[0x01, 0x01, 0xE8, 0x03]`; a HEL frame fixture with its exact 8-byte header; an OPN chunk fixture with the `None` policy URI. Truncated input → `FormatException` (not a crash/hang).
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the two files per the interfaces (growable writer over `BytesBuilder`/`Uint8List`, bounds-checked reader). Keep them PURE (no dart:io/Flutter).
- [ ] **Step 4: Tests → PASS; `flutter analyze` clean; full suite passes (nothing else touched).**
- [ ] **Step 5: Commit** `feat(opcua): pure-Dart OPC UA binary codec + opc.tcp transport framing`.

---

### Task 2: Secure channel (None) + session state machine + GetEndpoints

**Files:**
- Create: `mobile/lib/protocols/opcua/opcua_session.dart`
- Test: `mobile/test/opcua_session_test.dart`

**Interfaces:** `class OpcUaServerSession { OpcUaServerSession({required OpcUaServerInfo info, required OpcUaServiceHandler services}); List<Uint8List> onBytes(Uint8List frame); bool get shouldClose; }` — a socketless state machine: each inbound framed message yields zero-or-more outbound frames. `OpcUaServerInfo{applicationName, applicationUri, endpointUrl(port), namespaceUri}`. `OpcUaServiceHandler` = the Task 3 callback interface (Browse/Read/Write given decoded requests); Task 2 stubs it.

Behaviour (per OPC UA Part 4/6, `None` policy):
- `HEL` → validate, reply `ACK` (negotiate buffers: min(client, 1 MB); protocolVersion 0). Oversize/multi-chunk (`C`) → `ERR` + close.
- `OPN` (OpenSecureChannelRequest, request type Issue) → allocate a secureChannelId + tokenId, reply OpenSecureChannelResponse (revisedLifetime; server nonce null for None). Renew (request type Renew on the same channel) → new tokenId, response. Track sequence numbers (server responses use their own monotonically increasing sequence).
- `MSG` service dispatch by request NodeId: `GetEndpointsRequest` → one endpoint (`None`/anonymous userIdentityTokens with an anonymous policy id, our endpointUrl, applicationDescription); `CreateSessionRequest` → CreateSessionResponse (sessionId NodeId, authenticationToken NodeId, revisedSessionTimeout, our endpoints again, null server certificate/signature for None); `ActivateSessionRequest` (anonymous identity token) → ActivateSessionResponse; `CloseSessionRequest` → response + mark session closed; Task 3 services forwarded to the handler ONLY when the session is activated and the authToken matches (else `ServiceFault Bad_SessionIdInvalid`/`Bad_SecureChannelIdInvalid` as appropriate); ANY unknown service NodeId → `ServiceFault` with `Bad_ServiceUnsupported` (echoing the requestHandle).
- `CLO` → CloseSecureChannel: mark `shouldClose`.
- EVERY decode wrapped: malformed frame → `ERR` frame + `shouldClose` (never an uncaught throw).

- [ ] **Step 1: Write failing tests** driving `onBytes` with frames BUILT VIA THE TASK 1 CODEC (no hand-rolled hex where the codec can build it): full happy path HEL→ACK, OPN→response (assert channel/token ids and that a Renew yields a NEW tokenId on the same channel), GetEndpoints (assert policy `None` + anonymous token in the endpoint), CreateSession→ActivateSession→CloseSession; a service call before ActivateSession → the right fault; an unknown service NodeId → `Bad_ServiceUnsupported` ServiceFault with the request's handle; a garbage frame → `ERR` + `shouldClose`; sequence numbers strictly increasing across responses.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.** Constants for the service NodeId encoding ids (from the Rust reference `supported_message.rs`/generated ids: OpenSecureChannel Request/Response 446/449, GetEndpoints 428/431, CreateSession 461/464, ActivateSession 467/470, CloseSession 473/476, ServiceFault 397, CloseSecureChannel 452 — VERIFY each against the Rust source, do not trust memory). StatusCodes as consts (Good 0, Bad_ServiceUnsupported 0x800B0000, Bad_SessionIdInvalid 0x80250000, etc. — verify in the Rust `status_code.rs`).
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(opcua): secure-channel(None) + session state machine + GetEndpoints`.

---

### Task 3: Address space + Browse/Read/Write services over the live tag DB

**Files:**
- Create: `mobile/lib/protocols/opcua/opcua_address_space.dart`, `mobile/lib/protocols/opcua/opcua_services.dart`
- Test: `mobile/test/opcua_services_test.dart`

**Interfaces:** `OpcUaAddressSpace.build(PlcProject project)` — from `project.protocols!.opcua!` (map + namespaceUri): standard skeleton (Root i=84 → Objects i=85; Server object minimal) + one Variable node per map entry (NodeId parsed from `node_id` e.g. `ns=1;s=Inputs/Start_PB`, BrowseName/DisplayName = tag name, DataType from the tag's dataType, AccessLevel per map access, organized under Objects). Implements the Task 2 `OpcUaServiceHandler`:
- **Browse**: for each requested node, return references (HierarchicalReferences/Organizes, forward) with the standard skeleton + our variables; unknown node → `Bad_NodeIdUnknown` per-result.
- **Read**: attribute Value → a `DataValue` with the LIVE tag value (`readPath(project, tag)` mapped to the right Variant type per dataType, serverTimestamp = now, status Good); NodeClass/BrowseName/DisplayName/DataType/AccessLevel/UserAccessLevel answered from the space; other attributes → `Bad_AttributeIdInvalid` per-result. Unknown node → `Bad_NodeIdUnknown` per-result (the RESPONSE is still Good).
- **Write**: Value attribute on a `ReadWrite` node → coerce the Variant to the tag's dataType and apply through the force-aware write (skip + `Good` semantics consistent with the app: if the root tag is forced, return `Bad_NotWritable`? NO — match the app's invariant: forcing wins silently in engines, but for an external client return `Bad_UserAccessDenied` so the client KNOWS the write was refused); `ReadOnly` node → `Bad_NotWritable`; unknown → `Bad_NodeIdUnknown`; type-mismatched variant → `Bad_TypeMismatch`. Service NodeIds: Browse 527/530, Read 631/634, Write 673/676 (VERIFY against the Rust source).

- [ ] **Step 1: Write failing tests** (socketless — call the handler directly with decoded request structs, AND one end-to-end-through-the-session test reusing Task 2's harness): build a small project with a 3-node map (bool RW, float RO, int RW); Browse Objects → the variables appear with right BrowseNames; Read live value then MUTATE the tag in the project and Read again → the NEW value (proves live tag DB, no snapshot); Write to the bool RW → `readPath` shows it; Write to the RO → `Bad_NotWritable`; Write to a FORCED tag → `Bad_UserAccessDenied` AND the tag value unchanged; Write a Float64 with an integer-typed variant → `Bad_TypeMismatch` (or coerced — pick ONE, assert it, document); unknown NodeId per-result codes.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes; round-trip guard green (no model change in this task).**
- [ ] **Step 5: Commit** `feat(opcua): address space + Browse/Read/Write over the live tag DB (force-aware)`.

---

### Task 4: Socket host + Outbound Protocols UI + Rust-client E2E probe

**Files:**
- Create: `mobile/lib/services/opcua_host.dart`, `mobile/tool/opcua_host_probe.dart` (a tiny CLI that hosts a fixture project for the E2E), `gateway/examples/opcua_probe.rs`, `tool/opcua_e2e.sh` (or `.ps1`)
- Modify: `mobile/lib/models/protocol_settings.dart` (`OpcUaProtocolConfig.port`, int, default 4840, additive serialization), `mobile/lib/screens/gateway_screen.dart` (host controls replace the gateway connection card; remove `GatewayClient` usage), `mobile/lib/screens/workspace_shell.dart` (own an `OpcUaHost`; drop the GatewayClient + scan sync hook)
- Test: `mobile/test/opcua_host_test.dart`, update `mobile/test/gateway_screen_test.dart`; DELETE `mobile/test/gateway_client_test.dart` with the client (see below)

- [ ] **Step 1: `OpcUaHost`** (`ChangeNotifier`): `start(PlcProject project)` binds a `ServerSocket` on `protocols.opcua.port`, per connection creates an `OpcUaServerSession` (Tasks 2-3) and pumps socket bytes ↔ frames (length-prefixed reassembly from the stream — accumulate until the UInt32 size in the header is available); `stop()` closes everything; status (stopped/running/error), client count, last error; EVERY handler try/caught (a client crash must never crash the app). Tests: bind an ephemeral port, connect a raw `Socket` from the test, run the Task-1-codec handshake bytes through it, assert ACK comes back; assert a malformed burst doesn't kill the host; start/stop lifecycle; two clients get independent sessions.
- [ ] **Step 2: UI rework** (`gateway_screen.dart`): the OPC UA card gains **Start/Stop hosting** controls + port field (bound to `protocols.opcua.port`) + status + the endpoint line (`opc.tcp://<localIp>:<port>`) — replacing the WebSocket connection card. REMOVE `GatewayClient` from the shell (drop the per-scan `syncTags` hook and the client field) and DELETE `mobile/lib/services/gateway_client.dart` + `mobile/lib/models/gateway_sync.dart` + their tests (`gateway_client_test.dart`, `gateway_sync_test.dart`) per ADR-010 — grep for remaining references (`kDefaultGatewayUrl` stays in `protocol_settings.dart` for the legacy `gatewayUrl` field's default). Widget tests updated: host controls render; toggling hosting calls the (injected/faked) host; port edits persist; no overflow 320/1400.
- [ ] **Step 3: Rust E2E probe.** `gateway/examples/opcua_probe.rs`: takes an endpoint URL arg; connects (SecurityPolicy None, anonymous — reuse the pattern from `gateway/tests/opcua_client_e2e.rs` on branch `feat/opcua-hardening`, or write fresh with the client dev-dependency), GetEndpoints, Browse Objects, Read a named node's value, Write a ReadWrite node, Read back and verify, print PASS/FAIL, exit 0/1. `mobile/tool/opcua_host_probe.dart`: a `dart run` CLI that builds a small fixture project (3 mapped tags), starts `OpcUaHost` on a port arg, prints `READY`, and serves until killed. `tool/opcua_e2e.sh`: starts the Dart host, waits for READY, runs `cargo run --example opcua_probe -- opc.tcp://127.0.0.1:<port>` (bounded timeout), kills the host, propagates the exit code. RUN IT and paste the output — this is the machine-proof that a real third-party OPC UA client browses/reads/writes the in-app Dart server.
- [ ] **Step 4: Gates.** `cd mobile && flutter test` (all pass incl. round-trip with the new `port` field) · `flutter analyze` → ZERO · `flutter build web --release` succeeds (protocol code must not break web compile — `dart:io` only in services; the host simply isn't started on web) · the E2E script PASSES · `cd gateway && cargo build --examples` green. Discard plugin churn.
- [ ] **Step 5: Commit** `feat(opcua): in-app OPC UA host + hosting UI + Rust-client E2E (gateway client retired)`.

---

### Task 5: Validation + docs + final review

- [ ] **Step 1:** Full gates (flutter test/analyze/web build; cargo build/examples; branding grep over `mobile/lib mobile/test gateway/src gateway/examples`) → all green; the E2E script run once more, output captured.
- [ ] **Step 2:** Rewrite `docs/protocols/opcua.md` for in-app hosting (start hosting in the app → connect UAExpert to `opc.tcp://<device-ip>:4840` → browse/read/write; v1 scope: None/anonymous, polling reads, subscriptions v2; iOS foreground note; Android same-LAN note). Update `ARCHITECTURE.md`'s Mode A/B section to reflect ADR-010 (in-app hosting primary; gateway retired to a dev harness).
- [ ] **Step 3:** Branch ready for the whole-branch review + merge.

---

## Self-review notes
- **Spec coverage:** codec+framing (T1), channel+session+GetEndpoints (T2), address space+Browse/Read/Write live+force-aware (T3), socket host+UI+port field+gateway-client removal+Rust E2E (T4), validation+docs (T5) — matches the v1 scope; subscriptions/encryption explicitly deferred.
- **Contract discipline:** all wire encodings cross-checked against the local Rust reference; service NodeIds/StatusCodes VERIFIED against its source, not memory; the E2E probe is a real third-party client.
- **App safety:** protocol code pure; sockets isolated in the host; every handler guarded; app byte-identical when not hosting; forcing wins (external writes to forced tags refused with a visible status code).
- **Persistence:** only `OpcUaProtocolConfig.port` added (additive, default 4840); round-trip guard green; `gatewayUrl` retained for back-compat reads.
- **Deferred:** subscriptions (v2 WS), encryption, multi-chunk, Modbus/MQTT/DNP3 hosts, deleting the gateway crate's server code (kept inert as harness source).
