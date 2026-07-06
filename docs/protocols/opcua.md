# OPC UA (In-App Server)

The app itself is the OPC UA server — no companion process, no second
machine. A hand-rolled, pure-Dart OPC UA server subset runs inside the
Flutter app (`mobile/lib/protocols/opcua/` + `mobile/lib/services/
opcua_host.dart`), reads the project's tag database live at Read time, and
applies writes through the same force-aware rule the scan engine uses. Any
OPC UA client (UAExpert, a SCADA historian, a custom `opcua` client) connects
directly to the phone/tablet/desktop running the app.

```
OPC UA client (UAExpert, SCADA, ...)  --opc.tcp/binary-->  the app itself
                                                              - runs the scan
                                                              - owns the tag DB
                                                              - hosts opc.tcp
                                                              - force-aware writes
```

Full design rationale: `docs/superpowers/specs/2026-07-06-in-app-opcua-server-design.md`
(and `ARCHITECTURE.md`'s Mode A/B section, and `DECISIONS.md` ADR-010, which
retired the previous companion-gateway approach).

## Using it

1. Open **Outbound Protocols** from the app's shell nav.
2. Enable the **OPC UA** switch on the OPC UA card — this reveals the
   hosting controls, namespace field, and node map editor.
3. Set the **port** (default `4840`, the IANA-registered OPC UA port most
   clients including UAExpert default to). The field is editable only while
   stopped.
4. Tap **Start hosting**. The card shows live status (Stopped / Running /
   Error), the exposed-tag count, connected client count, and — once
   running — the endpoint URL (`opc.tcp://<device-ip>:<port>`).
5. Point any OPC UA client at that endpoint: Security Policy **None**,
   **Anonymous** authentication (v1 has no certificates/encryption/user
   tokens — see "v1 scope" below).
6. Browse the address space: every mapped tag appears as a `Variable` node
   directly under the standard **Objects** folder, named by its tag's short
   name, with a node id of the form `ns=1;s=<tag_name>` (or `ns=1;i=<n>` for
   numeric ids) — whichever the node map assigns.
7. **Read** any node — the value comes live from the running soft PLC at the
   moment of the read (there is no mirror/cache to go stale).
8. **Write** a `ReadWrite` node — it applies through the same force-aware
   path as any other write. Writing a `ReadOnly` node returns
   `Bad_NotWritable`; writing a tag that is currently **forced** in the app
   returns `Bad_UserAccessDenied` and the value is left unchanged (forcing
   always wins over an external client).
9. Tap **Stop hosting** to close the listener; the app is otherwise
   byte-identical to a build with OPC UA never enabled.

The node map (which tags are exposed, their `node_id`s, and
`ReadOnly`/`ReadWrite` access) is edited from the OPC UA card's map editor,
or auto-generated from the project's tags (**Regenerate** — `Simulated
Inputs`/`Internal` tags default to `ReadWrite`; `Simulated Outputs` default
to `ReadOnly`). It is stored per-project under the additive `protocols`
field (`protocols.opcua`), alongside the `port` (additive, default `4840`)
and `namespaceUri`.

## v1 scope (and what's deferred to v2+)

**v1 delivers:** `opc.tcp` transport (Hello/Acknowledge/Error framing),
`OpenSecureChannel` with Security Policy **None** (including token renewal),
`CreateSession`/`ActivateSession` (anonymous) + `CloseSession`,
`GetEndpoints`, `Browse` (the exposed-tag address space, flat under
Objects), `Read` (Value + core attributes, server timestamps), `Write`
(force-aware, `ReadWrite` nodes only). Unsupported/unknown services answer a
proper `ServiceFault` (`Bad_ServiceUnsupported`) rather than dropping the
connection.

**Deferred (v2+):**
- **Subscriptions/MonitoredItems** — v1 clients poll via `Read`; there is no
  server-push/monitored-item support yet.
- **Encryption** (`Basic256Sha256` etc.) — v1 is Security Policy `None` only,
  appropriate for LAN commissioning/training, not a certified/secure
  deployment.
- **Multi-chunk reassembly** — v1 negotiates generous (~1 MB) single-chunk
  buffers, ample for the address spaces this app builds; an oversize message
  is rejected cleanly rather than crashing.
- User-token authentication, `TranslateBrowsePaths`, and other optional
  services (all answer `ServiceFault`).

## Platform notes

- **iOS**: the app can only accept inbound connections while it is in the
  **foreground** — an OS constraint on background sockets, not a limitation
  of this server. Backgrounding the app stops accepting new connections.
- **Android**: works the same as desktop while the app is running, but the
  client must be on the **same LAN** — there is no port-forwarding/NAT
  traversal, and mobile carriers/most Wi-Fi networks block unsolicited
  inbound connections from outside the local network anyway.
- The port is a normal (non-privileged, user-space) TCP port on every
  platform — no elevated permissions are required to bind it.
- The app remains byte-identical when OPC UA hosting is disabled or stopped
  — this is strictly an opt-in feature.
- **Web:** OPC UA hosting is a **native-platform feature only** (Android,
  iOS, desktop). The web build compiles fine, but a browser tab cannot host
  an inbound TCP server (no `ServerSocket` in the browser sandbox), so OPC UA
  serving is unavailable when the app runs as a web build.

## What is machine-verified vs. manual

**Machine-verified (`flutter test` in `mobile/`):**
- Binary codec round-trips + known-byte fixtures for every OPC UA built-in
  type used (NodeId forms, Variant, DataValue, LocalizedText, ...),
  cross-checked against the vendored Rust `opcua` crate source as the
  reference implementation — `mobile/test/opcua_binary_test.dart` (and
  sibling codec tests).
- The secure-channel/session state machine driven with byte frames (no
  sockets): Hello/Acknowledge, `OpenSecureChannel` (incl. renewal),
  `CreateSession`/`ActivateSession`/`CloseSession`, malformed frames, unknown
  services → `ServiceFault` — `mobile/test/opcua_session_test.dart`.
- The address space + `Browse`/`Read`/`Write` services over a live project's
  tag DB: exposed-tag enumeration, per-attribute reads, force-aware writes
  (a write to a forced tag is refused, value unchanged), type coercion
  rules, `Bad_IndexRangeInvalid`/`Bad_NodeIdUnknown`/`Bad_NotWritable`/
  `Bad_TypeMismatch` on the appropriate inputs, and dangling map-tag
  references (a node whose `tag` no longer exists in the project is skipped
  from Browse and answers `Bad_NodeIdUnknown` on Read/Write) —
  `mobile/test/opcua_services_test.dart`.
- The hosting UI (Start/Stop, port field, status, endpoint display, the
  port-field refresh on a project switch): `mobile/test/gateway_screen_test.dart`.
- Additive persistence: the new `port` field round-trips; `protocols`/`opcua`
  serialization is otherwise unchanged — `mobile/test/protocol_settings_test.dart`,
  `mobile/test/serialization_roundtrip_test.dart`.

**Machine-verified end-to-end, with a REAL third-party OPC UA client
(`tool/opcua_e2e.sh`):**

This is the strongest proof available short of a human running UAExpert: a
genuine Rust `opcua` crate **client** (`gateway/examples/opcua_probe.rs`,
kept as a dev-time verification harness per ADR-010) connects over the real
`opc.tcp` binary protocol to the Dart server hosted by a small fixture
runner (`mobile/tool/opcua_host_probe.dart`), and exercises
`GetEndpoints` → `Browse` (Objects) → `Read` → `Write` → `Read`-back-verify.

Run it from the repo root (bash/Git Bash):

```bash
tool/opcua_e2e.sh
```

It starts the Dart fixture host on a non-default port, waits for it to
report `READY`, runs the Rust probe against it, and unconditionally kills
the Dart host on exit (propagating the probe's exit code). A successful run
ends with:

```
PROBE PASS
```

**Requires a human with a real OPC UA client (manual, documented here, not
automatable in CI):**
- Actually opening `opc.tcp://<device-ip>:4840` from UAExpert (or any other
  OPC UA stack) running on a **different device** on the LAN, to confirm
  real network reachability (the E2E probe above runs over `127.0.0.1`,
  proving the protocol implementation but not physical network/firewall
  behavior).
- Confirming the iOS-foreground and Android-same-LAN behavior described
  above on physical devices.

## Out of scope / positioning

This is a **simulator/training tool, not a safety-certified or
OPC-Foundation-certified product**. The hand-rolled server targets client
*compatibility* (UAExpert and common SCADA stacks talking Security Policy
`None`), not formal certification. Do not use it to control real safety-
critical equipment. Historical access and method nodes are not implemented;
scalar leaf tags only (struct/array members are not individually addressable
as separate nodes in v1).
