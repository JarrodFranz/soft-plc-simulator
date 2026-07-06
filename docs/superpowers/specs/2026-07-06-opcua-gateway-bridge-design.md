# OPC UA Companion Gateway Bridge (WS16) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation — user chose **thin Rust gateway (app runs the
logic)** + **OPC UA first** when scoping the bridge options.
**Author:** Claude (pairing with Jarrod)

Wires the Flutter app to a **companion gateway** (ADR-003 Mode B) that exposes the
running project's tags over **OPC UA**. The app keeps executing the logic in the
Dart engine and owning the tag database; the gateway is a *thin protocol shell*
that mirrors the tag values (synced over WebSocket) into an OPC UA address space
and forwards OPC-client writes back to the app. This is the first protocol on a
**reusable tag-sync layer** that later protocols (Modbus/MQTT/DNP3) plug into.

## Why this shape (recap of the scoping decision)
Protocol *servers* can't run inside the app on mobile (OS blocks inbound server
ports) or web (no raw TCP), so they must live in a native companion process. The
Dart engine is already complete and shipping, so rather than re-implement the
engine in Rust (divergence risk per ADR-009), the app stays authoritative and the
gateway does only what Rust is uniquely good at — hosting a long-running OPC UA
server. FFI (Mode A) is out of scope: it wouldn't unlock protocols on mobile/web.

## Architecture

```
Flutter app (Dart engine, tag DB)  ──WebSocket (JSON tag-sync)──►  Rust gateway
  - runs the scan pipeline                                          - tag mirror
  - streams tag snapshot + deltas  ◄──writes (OPC client wrote)──   - OPC UA server
  - applies inbound writes (force-aware)                            - address space from map
```

The app is the single source of execution truth. The gateway's OPC UA variables
reflect the last-synced value; an OPC UA client write travels back to the app,
which applies it (force-aware) and recomputes on the next scan, streaming the
result back — a one-scan round-trip consistent with the app's existing model.

## The tag-sync layer (protocol-agnostic foundation, reused by every protocol)

A small JSON message protocol over one WebSocket connection (app is the client,
gateway is the ws server on `ws://<host>:<port>`):

- **app → gateway**
  - `hello` `{ project, controller, scanMs }` — on connect.
  - `snapshot` `{ tags: [ { path, dataType, value, access } ] }` — the full
    exposed-tag set, on connect and whenever the project/map changes.
  - `delta` `{ changes: [ { path, value } ] }` — only changed exposed tags, each
    scan (changed-only; skip if empty).
  - `pong` — reply to `ping`.
- **gateway → app**
  - `ready` `{}` — address space built, server listening.
  - `write` `{ path, value }` — an OPC client wrote a node; the app applies it via
    the force-aware tag write and lets the scan recompute.
  - `ping` — keepalive.

Semantics: values are JSON scalars (bool / number / string). v1 exposes **scalar
leaf tags** only (struct/array members deferred). Reconnect: the app retries with
backoff and re-sends `hello`+`snapshot` on reconnect (gateway rebuilds the address
space). The gateway never executes logic; it only mirrors and relays.

The **codec** (encode/decode of these messages, and tag value↔JSON with the IEC
data types) is pure and unit-tested on both sides (Dart and Rust) so the wire
contract is locked independent of the sockets.

## OPC UA mapping (reuses the existing map format)

Reuse `examples/protocol-maps/opcua_map_example.json`:
`{ opcua_map: { namespace_uri, nodes: [ { node_id, tag, access } ] } }`.
- Each node → an OPC UA `Variable` node under namespace index 1, `node_id` as its
  string identifier (e.g. `ns=1;s=Inputs.Start_PB`), value/type from the mirror.
- `access`: `ReadOnly` (Current-Read) or `ReadWrite` (Read+Write); a write on a
  `ReadWrite` node emits a `write` back to the app; writes to `ReadOnly` are
  rejected.
- The app can **auto-generate** a default map from the project tags (Simulated
  Inputs/Internals → `ReadWrite`, Outputs → `ReadOnly`, `node_id = ns=1;s=<path>`)
  and let the user edit it. The map is stored on the project (a new optional
  `opcuaMap` field, serialized — additive, back-compat default empty).

## App side (`mobile/`)

- **`GatewayClient`** (`lib/models/` for the pure sync/codec; `lib/services/` for
  the socket) — connects via `web_socket_channel`, sends `hello`+`snapshot`, then
  a `delta` of changed exposed tags each scan, applies inbound `write`s through the
  existing force-aware tag write, exposes a `ValueNotifier`/status
  (disconnected / connecting / connected / error). Testable against a fake
  `StreamChannel` (no real socket in tests).
- **Gateway panel** — a screen/section (URL+port, Connect/Disconnect, live status,
  exposed-tag count, last error) reachable from the shell nav, responsive, dark.
- **OPC UA map editor** — view/generate/edit the node↔tag↔access map (reuse the
  `TagAutocompleteField`); auto-generate default from tags.
- The app runs **exactly as today when not connected** — the gateway is strictly
  opt-in; no change to the scan pipeline's behaviour, only an optional observer
  that streams tag changes.

## Gateway side (`gateway/`, Rust)

Replace the demo `main.rs` with:
- A **WebSocket server** (`tokio` + `tokio-tungstenite`) accepting the app
  connection; parses the sync messages (shared codec).
- A **tag mirror** (in-memory `HashMap<path, TagValue>` + type/access) updated from
  `snapshot`/`delta`; reusing the runtime's typed `TagValue`.
- An **OPC UA server** (`opcua` crate) whose address space is built from the map;
  variable reads return the mirror value; writes to `ReadWrite` nodes emit a
  `write` back over the socket.
- Rust unit tests: codec parity (round-trip the sync messages), the mirror
  (snapshot/delta apply, type coercion), and the map→address-space builder. The
  live OPC UA server loop is integration-level (see Testing).

## Testing

- **Codec (both sides):** encode→decode round-trips every message type; tag
  value↔JSON for each IEC data type; malformed input rejected without panic.
- **App `GatewayClient` (widget/unit):** against a fake channel — sends
  hello+snapshot on connect, emits a delta only for changed exposed tags, applies
  an inbound `write` force-aware (a forced tag is not overwritten), reconnect
  re-snapshots, status transitions. No real network.
- **Gateway (Rust `cargo test`):** codec parity with the Dart encoding (shared
  fixtures), mirror apply, map→node builder.
- **End-to-end (documented + scripted where feasible):** a Rust integration test
  (or a scripted local run) that boots the gateway, connects a Rust `opcua`
  client, reads a mapped node and writes a `ReadWrite` node, asserting the write
  message is emitted — this is the machine-verifiable slice. Full external-client
  verification (UAExpert/Kepware) and native mobile transport are documented as
  manual/user steps (the CI/dev environment can't host every SCADA client). The
  spec/review will be explicit about what is machine-verified vs. documented.
- Existing suites stay green: `flutter test` (app unaffected when disconnected;
  round-trip guard green — the new optional `opcuaMap` field round-trips) and
  `cargo test` (runtime unchanged; gateway gains tests).
- `flutter analyze` zero; `flutter build web --release` succeeds; `cargo build`
  (and `cargo test`) succeed for the gateway.

## Global constraints

No third-party/reference-editor branding. Dark theme; responsive. `flutter
analyze` zero. Pure sync/codec logic in `mobile/lib/models` (UI-free). The app is
unchanged when no gateway is connected (opt-in observer only). Lossless
persistence preserved — the new `opcuaMap` project field is additive with a
back-compat default; the round-trip guard stays green. Gateway is a
simulator/training tool (keep the existing "not safety certified" banner). No new
inbound network behaviour in the app itself (it is a WebSocket *client*, outbound).

## Decomposition (for the plan)
1. **Sync codec + OPC UA map model** (pure Dart, fully tested) — the wire contract
   and the map data model + auto-generate + serialization.
2. **App `GatewayClient` + gateway panel + map editor** — the WebSocket client,
   status UI, and map editor; tested against a fake channel.
3. **Rust gateway** — ws server + tag mirror + OPC UA server from the map +
   write-back; `cargo` unit tests + a scripted local client round-trip.
4. **Validation + final review** (cross-language) + documented E2E + merge.

## Out of scope (deferred)
- Modbus/MQTT/DNP3 (they reuse this tag-sync layer — later workstreams).
- OPC UA security (certificates, encryption, user auth) beyond anonymous/None for
  v1; struct/array member nodes; historical access; method nodes.
- FFI/Mode A embedding; bringing the Rust *execution* engine to parity.
- Automated external-SCADA-client E2E in CI (documented manual verification).
