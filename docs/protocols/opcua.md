# OPC UA Companion Gateway

The app itself cannot host an inbound server on mobile (OS-blocked) or web (no
raw TCP), so OPC UA is served by a small companion process: the **Rust
gateway** (`gateway/`). The gateway is a thin protocol shell — it runs no PLC
logic. The Flutter app stays authoritative: it executes the scan, owns the
tag database, and streams tag values to the gateway over a WebSocket. The
gateway mirrors those values into an OPC UA address space and forwards any
OPC UA client write back to the app, which applies it (force-aware) and lets
the next scan recompute.

```
Flutter app (Dart engine, tag DB)  --WebSocket (JSON tag-sync)-->  Rust gateway
  - runs the scan pipeline                                          - tag mirror
  - streams snapshot + deltas   <--writes (OPC client wrote)--      - OPC UA server
  - applies inbound writes (force-aware)                            - address space from map
```

Full design rationale: `docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md`.

## Running the gateway

```
cd gateway
cargo run
```

This starts two listeners on the same process:

- **WebSocket tag-sync server**: `ws://0.0.0.0:4855` (the app connects to
  this as a client). Override with the `GATEWAY_WS_PORT` env var.
- **OPC UA server**: `opc.tcp://127.0.0.1:4840` (port `4840` is the
  conventional OPC UA port most clients, including UAExpert, default to).
  Override with `GATEWAY_OPCUA_PORT`.

Anonymous/no-security only in v1 (see "Out of scope" below) — expect log
lines about a missing application certificate; they're harmless for local
`None`-security testing and don't stop the server from listening.

Before any app connects, the OPC UA address space is pre-populated from a
bundled sample project (`examples/projects/basic_motor_start_stop.json`) and
its matching map (`examples/protocol-maps/opcua_map_example.json`) — three
nodes: `Start_PB`, `Stop_PB` (both `ReadWrite`), `Motor_Run` (`ReadOnly`). This
is just so the server isn't empty on first boot; those values are frozen
until a real app connects and sends its own `snapshot`, at which point the
mirror (and every OPC UA read) reflects the app's real project instead.

## Connecting the app

In the mobile app, open the **Gateway** panel from the shell nav. The URL
field defaults to `ws://localhost:4855` (`kDefaultGatewayUrl` in
`mobile/lib/services/gateway_client.dart`) — matching the gateway's default
WebSocket port. Click **Connect**. On connect the app sends `hello` then a
full `snapshot` of its exposed tags; from then on it sends a `delta` each
scan for changed tags only. The panel shows live status
(disconnected/connecting/connected/error), the exposed-tag count, and the
last error.

The OPC UA node map (which tags are exposed, under what `node_id`, and
whether they're `ReadOnly`/`ReadWrite`) is edited from the same panel's map
editor, or auto-generated from the project's tags (`Simulated Inputs`/
`Internal` tags default to `ReadWrite`; `Simulated Outputs` default to
`ReadOnly`). The map is stored on the project as an additive, optional field.

## Verifying with an external OPC UA client (e.g. UAExpert)

1. Start the gateway (`cd gateway && cargo run`) and connect the app to it
   from the Gateway panel (or just rely on the bundled default map/project —
   no app connection is required to see the three default nodes).
2. In UAExpert (or any OPC UA client), **Add Server** →
   `opc.tcp://localhost:4840` → security policy `None`, anonymous
   authentication.
3. Browse the address space: nodes live directly under the **Objects**
   folder, one per mapped tag, named by their tag path (e.g. `Start_PB`,
   `Motor_Run`), with node ids of the form `ns=1;s=<tag_path>`.
4. **Read** any node — you'll see the app's last-synced value (or the bundled
   default's value if no app is connected).
5. **Write** a `ReadWrite` node (e.g. `Start_PB`) — the value change is
   forwarded to the app over the WebSocket as a `write` message; if the app
   is connected, it applies the write (force-aware) and the tag updates on
   the app's next scan. `ReadOnly` nodes (e.g. `Motor_Run`) have no write
   access exposed at all — a write attempt is rejected by the OPC UA server
   itself (no setter is wired for that node).

## What is machine-verified vs. manual

**Machine-verified (`cargo test` in `gateway/`, 37 tests, plus the app-side
Dart tests):**
- Wire codec parity between the Rust and Dart tag-sync encodings for every
  message type (`hello`/`snapshot`/`delta`/`write`/`ready`/`ping`/`pong`),
  including malformed/unknown-input handling (never panics) and whole-number
  float fidelity (a `FLOAT64` tag holding e.g. `10.0` stays a float, never
  silently becomes an integer) — `gateway/src/sync.rs`.
- Tag mirror semantics: snapshot replace, delta update-known-paths-only,
  type coercion on delta — `gateway/src/mirror.rs`.
- OPC UA map → address-space builder: one `Variable` node per mapped tag
  present in the mirror, `ReadOnly` nodes get no write access, `ReadWrite`
  nodes forward a write — `gateway/src/opcua_map.rs`, `gateway/src/opcua_server.rs`.
- The OPC UA read path returns the Variant type matching the tag's *declared*
  `DataType` (not a JSON-shape guess) — including the specific regression
  case of a whole-number `FLOAT64` value reading back as `Variant::Double`,
  not `Variant::Int64` (`float64_whole_number_reads_back_as_double_not_int`,
  `float64_fractional_value_reads_back_as_double` in `opcua_server.rs`).
- The full WebSocket transport hop against a real `tokio-tungstenite`
  client: `ready` greeting, `hello`/`snapshot` ingestion into the mirror, and
  a simulated OPC-write arriving at the app-side socket as a `write` frame
  (`gateway/src/ws_server.rs`).
- App-side: `GatewayClient` against a fake channel (connect/hello/snapshot,
  delta-only-on-change, force-aware inbound write, reconnect re-snapshots,
  status transitions) and the OPC UA map model's serialization round-trip
  (`mobile/test/gateway_client_test.dart`, `mobile/test/opcua_map_test.dart`,
  `mobile/test/gateway_sync_test.dart`).
- The gateway binary itself starts, prints the safety banner, and both
  listeners come up without panicking (`cargo run`, confirmed manually with
  a bounded run during development — not a `cargo test`, since the binary is
  a long-running process).

**Requires a live external OPC UA client (manual, not automatable in CI):**
- Actually opening `opc.tcp://localhost:4840` from a real client (UAExpert or
  any other OPC UA stack) and reading/writing a node over the real OPC UA
  binary protocol — the Rust tests exercise the setter/getter wiring
  directly (the same internal path a real client's Read/Write service call
  invokes), which covers every hop except the OPC UA TCP/binary framing
  itself.
- Any native mobile transport path (the app connecting to a gateway over a
  real network from an Android/iOS device rather than `localhost`).

## Out of scope (v1)

Anonymous/`None` security only — no certificates, encryption, or user
authentication. Scalar leaf tags only (struct/array members deferred).
Historical access and method nodes are not implemented. The gateway never
executes PLC logic; it only mirrors and relays.
