# OPC UA Server Hardening + Protocol Tabs (WS18) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "lets lock down the opc ua server
working correctly … tabs up the top to select the protocol … more settings …
make sure all the configurations are implemented correctly … connect to the
server with an OPC UA client"). Design made autonomously from a live diagnosis +
`opcua 0.12` `ServerBuilder` audit.
**Author:** Claude (pairing with Jarrod)

Makes the OPC UA companion gateway a **correctly-configured, verified** OPC UA
server (a running-gateway diagnosis showed it had no application-instance
certificate — only an insecure `None` endpoint — no product URI, and a hard
panic on a port-in-use), proves it with a **real OPC UA client** integration
test, adds **protocol tabs** to the Outbound Protocols section, and makes the
app's Connect failure legible.

## Live diagnosis (what's actually wrong today)
Running `gateway/` (`cargo run`) revealed:
1. The app's "Failed to connect WebSocket" = **the companion gateway wasn't
   running** (the app is a client; the gateway must be up on `:4855`). Correct
   behaviour, but the app gives no hint that the gateway must be started.
2. **No OPC UA application-instance certificate** → `"Encrypted endpoints will
   not function correctly"`; the server offers only the insecure `None`
   security endpoint. Also `WARN No product uri was set`.
3. **Port-in-use → hard panic** (`AddrInUse`, os 10048) instead of a clean
   "port already in use — is another gateway running?" message.

## `opcua 0.12` ServerBuilder audit (available config, currently unused)
- Identity: `application_name`, `application_uri`, **`product_uri`**.
- Security/PKI: **`create_sample_keypair(true)`** (auto-generates a self-signed
  app-instance cert on first run), `certificate_path`, `private_key_path`,
  `pki_dir`, `trust_client_certs`.
- Endpoints/tokens: **`endpoint`/`endpoints`** (define endpoints per security
  policy/mode), `user_token` (add users beyond `ANONYMOUS`).
- Network: `host_and_port`, `discovery_urls`, `discovery_server_url`.
- Limits: `max_subscriptions`, `max_monitored_items_per_sub`, `max_array_length`,
  `max_string_length`, `max_message_size`, `max_chunk_count`,
  `send/receive_buffer_size`.
- Behaviour: `clients_can_modify_address_space`, `single/multi_threaded_executor`.

## Architecture: what's gateway-level vs. per-project
The OPC UA **server** is built once at gateway startup (before the app
connects), so its server-level settings (**security policies, certificate,
ports, application identity, limits**) are **gateway configuration** — they
cannot be hot-reconfigured per-project by an app message without restarting the
server (the crate doesn't support that cleanly). What streams per-project over
the WebSocket stays per-project: **namespace, the node map (which tags, node ids,
access), and the per-protocol enable toggle** (WS17). So:
- Gateway config (env vars + an optional `gateway.toml`, with correct defaults)
  drives the server-level OPC UA settings.
- The app's OPC UA card keeps its per-project settings and additionally **surfaces**
  the gateway's OPC UA endpoint + security info (informational), so the user knows
  what to point a client at.

## Gateway changes (`gateway/`)

1. **Correctly-configured OPC UA server** (`opcua_server.rs` `build_server` + a
   `GatewayOpcuaConfig`):
   - `create_sample_keypair(true)` + `pki_dir` (a stable path under the gateway,
     e.g. `./pki`) + `certificate_path`/`private_key_path` so the self-signed
     app-instance cert is generated on first run (fixes issue #2).
   - Define endpoints for **`None`** and **`Basic256Sha256`** in **`Sign`** and
     **`SignAndEncrypt`** modes (so encrypted connections work), with
     `ANONYMOUS` user tokens (and, config-gated, a username/password token).
   - `product_uri`, `application_uri`, `application_name` (config-driven,
     defaulting to the current gateway name) — fixes the product-uri warning.
   - Sensible limits (leave crate defaults unless a reason to change).
   - All tunables read from `GatewayOpcuaConfig` (env: `GATEWAY_OPCUA_PORT`
     [exists], `GATEWAY_OPCUA_SECURITY` [on/off — whether to add the encrypted
     endpoints], `GATEWAY_OPCUA_APP_NAME`, `GATEWAY_OPCUA_ALLOW_ANONYMOUS`, an
     optional user/pass, `GATEWAY_PKI_DIR`), with correct defaults so a bare
     `cargo run` yields a proper server.
2. **Graceful bind** (`main.rs`): before starting each server, pre-check the port
   by attempting a `TcpListener` bind; if taken, print a clear actionable line
   (`"OPC UA port 4840 is already in use — is another gateway already running?"`)
   and exit non-zero cleanly instead of the raw crate panic (fixes issue #3).
   Keep the "NOT safety certified" banner.
3. **Real OPC UA client E2E test** (the machine-proof "connect with a client"):
   an integration test (`gateway/tests/opcua_client_e2e.rs` or a `#[tokio::test]`)
   that starts the gateway's OPC UA server on an ephemeral port with a seeded
   mirror, connects the `opcua` crate's **client** to
   `opc.tcp://127.0.0.1:<port>` (security `None`, anonymous), **reads** a mapped
   node's value (asserts it equals the seeded value), and **writes** a
   `ReadWrite` node (asserts a `PendingWrite`/forwarded `write` is produced). If
   an in-process client+server test proves infeasible (runtime nesting), fall
   back to a two-process scripted check (run the server binary on an ephemeral
   port, run a small client example binary) and document it — but prefer the
   in-process integration test. This is the deliverable that proves the server
   actually accepts an OPC UA client.

## App changes (`mobile/`)

1. **Protocol tabs**: the Outbound Protocols section gets a `TabBar` at the top to
   select the protocol to view/configure. Today one tab: **OPC UA** (structured
   so Modbus/MQTT/DNP3 become tabs later). The connection card (gateway endpoint +
   Connect/Disconnect/status) stays above the tabs (it's shared across protocols).
2. **OPC UA tab content**: the existing per-project settings (enable toggle,
   namespace, node-map editor) PLUS an informational **"OPC UA endpoint"** block
   showing `opc.tcp://<host>:<opcuaPort>` and the security modes the gateway
   offers (so the user knows what to connect UAExpert to). Ports/security are
   gateway-config (shown, with a note they're set at the gateway), not editable
   per-project (documented).
3. **Legible Connect failure**: when `connect` fails with a socket/connection
   error, the status shows a clear message ("Couldn't reach the gateway at
   <url> — is the companion gateway running? Start it with `cd gateway && cargo
   run`.") instead of the raw `WebSocketChannelException`. (Map the exception to a
   friendly message in `GatewayClient`/the section.)

## Testing

- **Gateway (`cargo test`):** the existing 38 pass; NEW: the OPC UA client E2E
  test (connect + read + write); a test that `build_server` with security enabled
  produces the expected endpoints (None + Basic256Sha256 Sign/SignAndEncrypt);
  the graceful-bind pre-check reports cleanly on a taken port (unit-test the
  port-check helper). `cargo build`/`cargo clippy` clean.
- **App (`flutter test`):** the section renders a `TabBar` with an OPC UA tab; the
  OPC UA endpoint block shows the `opc.tcp://` URL; a friendly connection-error
  message is shown on a simulated socket failure; no overflow at 320/1400; the
  per-project settings still work; `serialization_roundtrip_test.dart` green.
- **Manual (documented):** connect UAExpert to `opc.tcp://localhost:4840`
  (security `None`, then `Basic256Sha256`), browse the `ns=1` tags, read/write a
  ReadWrite node — the machine-verified slice is the automated OPC UA client test;
  external UAExpert is the human confirmation.
- `flutter analyze` zero; `flutter build web --release`; `cargo build`.

## Global constraints
No third-party/reference-editor branding; keep the "NOT safety certified" banner.
Gateway executes NO PLC logic. Dark theme; responsive; `flutter analyze` zero;
no RenderFlex overflow. App unchanged when disconnected. Additive persistence —
no new required app-serialized field beyond what WS17 has (server-level OPC UA
settings live in gateway config, not the project); round-trip guard green.
Idiomatic warning-clean Rust.

## Out of scope (deferred)
- Per-project push of server-level OPC UA settings (security/ports) from the app
  to a live gateway (would need server restart-on-reconfigure).
- Client certificate trust management UI; OPC UA user-management UI.
- Modbus/MQTT/DNP3 tabs+servers (each its own workstream; the tabs are ready).
