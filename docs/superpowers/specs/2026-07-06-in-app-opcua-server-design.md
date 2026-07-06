# In-App OPC UA Server v1 (WS19) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by the user ("I want the single mobile app to host
everything (no companion service or app)" … "I really need a solution that is
all in one app, all testable here and runs on android, desktop and iOS" …
"start implementing v1"). Architecture recorded as ADR-010.
**Author:** Claude (pairing with Jarrod)

Implements an **OPC UA server in pure Dart, inside the app** — the app itself is
the host. A third-party SCADA system or any OPC UA client connects to
`opc.tcp://<device>:4840`, browses the tags the user chose to expose (the WS17
per-project map), reads them live from the running soft PLC, and writes
`ReadWrite` tags back (force-aware). No companion process, no FFI, no native
toolchain — one Dart codebase serving Android, iOS, and desktop.

## Why hand-rolled pure Dart (ADR-010 recap)
No Dart OPC UA library exists (verified). FFI to native stacks fails "testable
here" (native Flutter builds are toolchain-gated in this environment) and adds
permanent per-platform build complexity. The minimal OPC UA profile the goal
needs — Security `None`, anonymous, browse/read/write — requires **no
cryptography** and is a bounded binary-codec + state-machine effort, the same
discipline as the four in-app language engines. The Rust `opcua` **client**
(already proven E2E against the retired gateway) is kept as a dev-time
third-party verification harness runnable here via `cargo`.

## v1 scope (and what's deferred)
**v1 delivers:** `opc.tcp` transport (Hello/Acknowledge/Error, single-chunk
messages with generously negotiated buffers), OpenSecureChannel with
SecurityPolicy `None` (incl. token renewal), CreateSession/ActivateSession
(anonymous) + CloseSession, GetEndpoints, Browse (the exposed-tag address
space), Read (Value + core attributes, server timestamps), Write (force-aware,
`ReadWrite` nodes only). Unknown/unsupported services answer a proper
`ServiceFault` (`Bad_ServiceUnsupported`) — never a dropped connection or crash.

**Deferred:** Subscriptions/MonitoredItems (v2 — live monitoring; v1 clients
poll via Read), encryption/`Basic256Sha256` (needs Dart PKI work),
multi-chunk reassembly (v1 negotiates ~1 MB buffers, ample for our address
spaces; oversize → clean `ERR`), TranslateBrowsePaths and other optional
services (ServiceFault).

## Architecture

```
mobile/lib/protocols/opcua/   ← pure Dart, NO dart:io, NO Flutter (unit-testable)
  opcua_binary.dart      built-in type codec (LE): all OPC UA built-ins used
  opcua_transport.dart   HEL/ACK/ERR + OPN/MSG/CLO chunk framing, sequence hdrs
  opcua_session.dart     secure-channel(None)+session state machine:
                         bytes-in → bytes-out, no sockets
  opcua_services.dart    GetEndpoints/Browse/Read/Write over an AddressSpace
  opcua_address_space.dart  built from OpcuaMap + PlcProject (reads tag DB live,
                         force-aware writes via tag_resolver)
mobile/lib/services/
  opcua_host.dart        the dart:io ServerSocket host: start/stop(port),
                         per-connection transport loop feeding the state machine
```

- The server reads tag values **live from the project's tag DB at Read time**
  and writes through the same force-aware rule the engines use — no mirror, no
  sync layer (in-process is the whole point).
- Per-project config: the WS17 `ProtocolSettings.opcua` carries on (enabled,
  namespaceUri, map) **plus a new `port` field** (int, default 4840, additive
  serialization). `gatewayUrl` becomes unused (kept for back-compat reads).
- UI: the Outbound Protocols OPC UA card becomes **host controls** — Start/Stop
  hosting, port, live status (stopped/running/error + client count), endpoint
  display (`opc.tcp://<ip>:<port>`), plus the existing enable toggle, namespace,
  and node-map editor. The gateway connection card and `GatewayClient` are
  removed (ADR-010).
- The app remains byte-identical when hosting is stopped (opt-in, like before).

## Testing strategy (all machine-verifiable here)
1. **Codec unit tests** — encode↔decode round-trips + known-byte fixtures for
   every built-in type (NodeId forms, Variant, DataValue masks, LocalizedText…),
   cross-checked against the Rust `opcua` crate source (local cargo cache) as
   the reference implementation.
2. **State-machine tests** — drive `opcua_session.dart` with byte frames (no
   sockets): full handshake → session → browse/read/write happy paths, plus
   malformed frames, unknown services (ServiceFault), token renewal.
3. **Rust-client E2E harness** — `gateway/examples/opcua_probe.rs` (uses the
   crate's client, a dev-dependency): connects to a given endpoint, GetEndpoints,
   browses, reads a value, writes a ReadWrite node, verifies the read-back;
   exits 0/1. A script starts the Dart server (a small `tool/` runner hosting a
   fixture project) and runs the probe — a genuine third-party OPC UA client
   verifying the Dart server, runnable in this environment via `cargo`.
4. **Widget tests** — host controls (start/stop/port/status) with the socket
   layer faked; the app unchanged when not hosting; round-trip guard green
   (the new `port` field is additive).
5. **Manual (documented)** — UAExpert to `opc.tcp://<host>:4840`, Security
   `None`, anonymous: browse, read, write.

## Global constraints
No third-party/reference-editor branding. Dark theme; responsive; `flutter
analyze` zero; no RenderFlex overflow at 360/320/1400. Pure Dart protocol code
UI-free and socket-free (host isolates dart:io). Force-aware writes (forcing
always wins). Additive persistence (round-trip guard green). The server must
NEVER crash the app: every connection handler guarded; malformed input →
clean error/close. Simulator/training positioning unchanged.

## Out of scope (v2+)
Subscriptions/MonitoredItems; encryption + certificates; multi-chunk;
user-token auth; Modbus TCP / MQTT / DNP3 in-app hosts (same pattern, own
workstreams); removal of the retired `gateway/` ws-server code (kept inert
until the harness refactor).
