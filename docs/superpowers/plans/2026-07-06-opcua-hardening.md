# OPC UA Server Hardening + Protocol Tabs (WS18) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the OPC UA gateway a correctly-configured, client-verified OPC UA server (self-signed cert + real security endpoints + graceful bind), prove it with a real OPC UA client test, add protocol tabs to the Outbound Protocols section, and make Connect failures legible.

**Architecture:** Server-level OPC UA settings (cert, security endpoints, ports, identity, limits) become gateway configuration (env + defaults) applied in `build_server`; a Rust `opcua` **client** integration test connects to the running server and reads/writes. The app gains a `TabBar` (OPC UA tab), surfaces the OPC UA endpoint/security (informational), and shows a friendly "gateway not running" message on socket failure. Per-project namespace/map/enabled (WS17) unchanged.

**Tech Stack:** Rust (`opcua 0.12` server+client, `tokio`), Flutter/Dart, `cargo test` + `flutter_test`.

## Global Constraints

- No third-party/reference-editor branding; keep the "NOT safety certified" banner in the gateway. Gateway executes NO PLC logic.
- Dark theme; responsive; `flutter analyze` zero; no RenderFlex overflow at 360/320/1400. App unchanged when disconnected.
- Additive persistence — no new REQUIRED app-serialized field (server-level OPC UA settings live in gateway config, not the project); the WS6 round-trip guard stays green.
- Idiomatic warning-clean Rust; existing gateway 38 cargo tests + runtime 43 + flutter 440 stay green. Build/test the gateway from INSIDE `gateway/` (standalone crate). Run cargo in the FOREGROUND with bounded timeouts (`timeout 180 cargo test`) — never leave a hanging test/process.

**Sequencing:** Task 1 (gateway correctness + client E2E) is the core. Task 2 (app tabs + endpoint surface + connect UX) is independent. Task 3 validates + docs.

---

### Task 1: Correctly-configured OPC UA server + real client E2E test

**Files:**
- Modify: `gateway/src/opcua_server.rs` (full `ServerBuilder` config + a `GatewayOpcuaConfig`), `gateway/src/main.rs` (read config from env; graceful port pre-check)
- Test: `gateway/src/opcua_server.rs` (endpoint/config unit tests) + `gateway/tests/opcua_client_e2e.rs` (or a `#[tokio::test]`) — the real OPC UA client round-trip

- [ ] **Step 1: Audit + write failing tests.** Read the `opcua 0.12` `ServerBuilder` (`~/.cargo/registry/.../opcua-0.12.0/src/server/builder.rs`, esp. `new_sample()` at line ~55 for the reference config, and `endpoint`/`endpoints`/`ServerEndpoint`/`SecurityPolicy` in `src/server/config.rs`) and the client prelude (`src/client/`). Then:
  - `opcua_server.rs` tests: `build_server` with a `GatewayOpcuaConfig { security_enabled: true, allow_anonymous: true, app_name, pki_dir, ... }` yields a server whose config lists endpoints for `None` AND `Basic256Sha256` (`Sign` + `SignAndEncrypt`); with `security_enabled: false`, only `None`. A `product_uri` is set (non-empty). Assert against the built `ServerConfig` (read what's inspectable — endpoint count/policies).
  - Port pre-check helper test: a helper `fn port_available(host, port) -> bool` (attempt a `std::net::TcpListener::bind`) returns false when a listener already holds the port, true otherwise.
  - `gateway/tests/opcua_client_e2e.rs`: seed a mirror + a small map, `build_server(...)` on an EPHEMERAL port (0 or a high test port), spawn the server task, connect the `opcua` crate CLIENT to `opc.tcp://127.0.0.1:<port>` (SecurityPolicy::None, anonymous), READ a mapped node → assert the value equals the seeded mirror value; WRITE a `ReadWrite` node → assert the write is forwarded (a `PendingWrite` arrives on the write channel). Use bounded `tokio::time::timeout` on every client await so the test can NEVER hang. (If in-process client+server nesting is infeasible, implement a two-process scripted variant and DOCUMENT — but try in-process first; the opcua crate supports client+server in one process.)
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `GatewayOpcuaConfig` (struct + `from_env()` with correct defaults: `security_enabled: true`, `allow_anonymous: true`, `app_name: "Mobile Soft PLC Companion Gateway"`, `pki_dir: "./pki"`, optional user/pass).
  - `build_server`: use `ServerBuilder::new()` (not `new_anonymous`), set `application_name`/`application_uri`/`product_uri`, `create_sample_keypair(true)` + `pki_dir`/`certificate_path`/`private_key_path`, and `.endpoints(...)` covering `None` + (when `security_enabled`) `Basic256Sha256` Sign & SignAndEncrypt, each with the configured user tokens (ANONYMOUS when `allow_anonymous`; a username token when a user/pass is set). Keep the existing map→address-space + read/write-forward wiring intact.
  - `main.rs`: build `GatewayOpcuaConfig::from_env()`, pass it in; before starting the OPC UA and WS servers, `port_available` pre-check each and, if not, print `"<proto> port <n> is already in use — is another gateway already running?"` and `std::process::exit(1)` cleanly (no panic). Keep the banner + the runnable wiring from WS16.
- [ ] **Step 4: `cd gateway && timeout 180 cargo test` → all pass (incl. the client E2E), TERMINATES. `cargo build` + `cargo clippy --all-targets` clean. `cd ../runtime && cargo test` still 43.** Manually run `RUST_LOG=info timeout 6 cargo run` once and CONFIRM the log now shows a generated cert + `Basic256Sha256` endpoints + no product-uri warning (paste the relevant lines in the report). Ensure any generated `pki/` is gitignored (add to `.gitignore` if needed — do NOT commit generated certs).
- [ ] **Step 5: Commit** `feat(gateway): correctly-configured OPC UA server (cert + security endpoints + graceful bind) + client E2E test`.

---

### Task 2: Protocol tabs + OPC UA endpoint surface + legible Connect failure

**Files:**
- Modify: `mobile/lib/screens/gateway_screen.dart` (TabBar + OPC UA endpoint block), `mobile/lib/services/gateway_client.dart` (friendly connection-error message)
- Test: `mobile/test/gateway_screen_test.dart`, `mobile/test/gateway_client_test.dart`

- [ ] **Step 1: Write failing tests.**
  - `gateway_screen_test.dart`: the section renders a `TabBar` with an "OPC UA" tab; the OPC UA tab shows an endpoint block containing an `opc.tcp://` URL and the offered security modes text; the per-project settings (enable toggle, namespace, map editor) are inside the OPC UA tab and still function (toggle updates `protocols.opcua.enabled`); no overflow at 320/1400; `takeException()` null.
  - `gateway_client_test.dart`: when the injected channel factory throws / the socket errors on connect, `GatewayClient.status` becomes `error` and `lastError` is a FRIENDLY message that mentions the gateway may not be running (not a raw `WebSocketChannelException` toString). (Assert the message contains a human hint like "gateway" and the url.)
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
  - `gateway_screen.dart`: wrap the protocol area in a `DefaultTabController`/`TabBar` + `TabBarView` with one tab ("OPC UA"). Keep the connection card ABOVE the tabs (shared). Move the OPC UA card content into the OPC UA tab and add an informational **OPC UA endpoint** block: `opc.tcp://<host>:<opcuaPort>` (derive host from the gateway URL; default OPC UA port 4840, shown as gateway-config with a small note) + a line listing the security modes (`None`, `Basic256Sha256 Sign/SignAndEncrypt`). Responsive; dark; no overflow.
  - `gateway_client.dart`: in the connect error handler, map socket/connection exceptions to a friendly `lastError` string, e.g. `"Couldn't reach the gateway at <url> — is the companion gateway running? Start it with: cd gateway && cargo run"`. Keep the actual error available if useful, but surface the friendly one.
- [ ] **Step 4: Tests → PASS; `flutter analyze` clean; full suite passes; `flutter build web --release` succeeds.** Discard plugin-registrant churn.
- [ ] **Step 5: Commit** `feat(protocols): protocol tabs + OPC UA endpoint info + legible gateway-connect error`.

---

### Task 3: Validation + docs + final review

- [ ] **Step 1:** `cd gateway && cargo test` (all pass) · `cargo build`/`clippy` clean · `cd ../mobile && flutter test` (all pass, round-trip green) · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz\|codesys\|rslogix" mobile/lib mobile/test gateway/src` → no matches.
- [ ] **Step 2:** Update `docs/protocols/opcua.md`: the security/cert setup (self-signed app-instance cert auto-generated in `pki/`), the gateway config env vars (`GATEWAY_OPCUA_PORT`/`_SECURITY`/`_APP_NAME`/`_ALLOW_ANONYMOUS`/`GATEWAY_PKI_DIR`), the offered endpoints, the "start the gateway first" note, connecting UAExpert (None + Basic256Sha256), and what's machine-verified (the OPC UA client E2E test) vs manual (UAExpert). Ensure `.gitignore` excludes the generated `pki/`.
- [ ] **Step 3:** Confirm end-to-end: `cargo run` yields a proper server (cert + security endpoints), the automated OPC UA client test connects+reads+writes, the app shows the endpoint + a friendly error when the gateway is down. Branch ready for the whole-branch review + merge.

---

## Self-review notes

- **Spec coverage:** correctly-configured server (cert + security endpoints + product uri) + graceful bind + real OPC UA client E2E (Task 1) ✓; protocol tabs + endpoint surface + legible connect failure (Task 2) ✓; validation + docs (Task 3) ✓.
- **Architecture honesty:** server-level settings are gateway config (can't hot-reconfigure a running server per-project); per-project namespace/map/enabled stream as before; the app surfaces the endpoint informationally.
- **Testability:** the client E2E is the machine-proof "connect with a client"; UAExpert is documented manual. Cargo runs bounded; generated certs gitignored.
- **Deferred:** per-project push of server settings; client-cert trust UI; Modbus/MQTT/DNP3 tabs+servers.
