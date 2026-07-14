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
5. Point any OPC UA client at that endpoint. Two security options are
   offered (whichever ones you enable on the card — see "Security
   (Basic256Sha256 + user auth)" below):
   - Security Policy **None** + **Anonymous** — for LAN
     commissioning/training, no certificates or encryption.
   - Security Policy **Basic256Sha256** with **Sign** or **SignAndEncrypt**
     message security, authenticating either **Anonymous** or with a
     configured **username/password** — an encrypted, authenticated session.
6. Browse the address space: every mapped tag appears as a `Variable` node
   directly under the standard **Objects** folder, named by its tag's short
   name, with a node id of the form `ns=1;s=<tag_name>` (or `ns=1;i=<n>` for
   numeric ids) — whichever the node map assigns. A strict client (not just
   this repo's own probe) can discover the whole space top-down: browsing
   `RootFolder` (`i=84`) surfaces the standard `Objects` (`i=85`) and
   `Server` (`i=2253`) children, and browsing `Objects` from there reaches
   every mapped tag — no client needs to hardcode `i=85` to find anything.
   The standard `Server_NamespaceArray` variable (`ns=0;i=2255`) is also
   readable, with index 0 the fixed OPC Foundation namespace URI and index 1
   this project's namespace URI, so a client can resolve what a `ns=1;...`
   node id actually means instead of assuming it. `GetEndpoints` also echoes
   back whatever host the client dialed (from its request's `endpointUrl`)
   in the returned `EndpointDescription`, so a client connecting through a
   different hostname/NAT than the server's own self-reported address still
   gets an endpoint URL it can actually reach.
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

## Folder browsing

A tag's `folder` (the same flat grouping label the Memory Manager and every
protocol map editor use — see `docs/simulated-test-tags.md`) is also
reflected in the address space: a tag with a non-empty `folder` is browsed
as a child of a synthesized **FolderType** Object node (browse name = the
folder name, node id `ns=1;s=__folder__/<folder>` — a reserved prefix that
can never collide with a real tag's `ns=1;s=<tagName>`) organized directly
under the standard **Objects** folder, alongside the folder-node references
themselves. A root tag (`folder: ''`) still sits directly under Objects — a
project with no folders browses exactly as it always did before this
feature existed (byte-identical reference count and shape). Reading a
folder node's `NodeClass`/`BrowseName`/`DisplayName` answers like any other
Object node; it has no `Value` attribute.

This is machine-verified end-to-end against a real third-party client — the
Rust `opcua` crate (`tool/opcua_e2e.sh`): the probe browses Objects, locates
the folder reference, confirms `NodeClass::Object`, browses into the folder,
and reads a tag inside it. Any generic FolderType/Organizes-aware OPC UA
client (Ignition/Eclipse Milo, already confirmed elsewhere in this doc for
Basic256Sha256 interop, included) is expected to render the same
`Objects ▸ <folder> ▸ <tag>` hierarchy, since folder nodes use only the
standard Organizes reference and `FolderType` type definition every OPC UA
client already understands.

## Composite/struct tag exposure (dotted leaf paths)

A composite tag (a struct-typed tag, an array, or the reserved `System`
diagnostics UDT — see `docs/task-scheduling.md`) is never exposed as one
node; **Regenerate** instead walks every tag's scalar leaves (the shared
`scalarLeaves` resolver in `mobile/lib/models/tag_resolver.dart`) and adds
one `Variable` node per leaf, addressed by its **dotted/indexed path** —
`System.Fault`, `System.ScanTimeMs`, `Recipe_Steps[0]`, `Motor.Speed`, and so
on. The address space's `Browse`/`Read`/`Write` handlers (`mobile/lib/
protocols/opcua/opcua_address_space.dart`) resolve that dotted path through
the same force-aware `readPath`/`writePath` resolver every other adapter and
the scan engine share, so a leaf node reads/writes exactly like a top-level
scalar tag — the only difference is the node id's path segment. A plain
scalar tag is unaffected (its "leaf path" is just its own name), so a
project with no composite tags regenerates byte-identically to before this
feature existed.

The node id's addressable prefix still comes from the **root** tag's
folder-qualified `path` (not the resolver-key name) — e.g. a `Start_PB` tag
living in the `Inputs` folder keeps `ns=1;s=Inputs/Start_PB` even though its
dotted resolver key is `Start_PB`; a `System.Fault` leaf becomes
`ns=1;s=System.Fault` because the `System` tag's own `path` is `System`.
This preserves every previously-shipped scalar node id (see "Out of scope"
below) while making composite leaves addressable at all.

**STRING leaves are exposed here** (unlike Modbus/DNP3, which skip
`STRING`/`TIMER`/`COUNTER` leaves entirely — see `docs/protocols/modbus.md`/
`docs/protocols/DNP3.md`): `System.DateTime`, for example, appears as a
readable `String` node. `TIMER`/`COUNTER`-typed leaves are still skipped
(no OPC UA `Variant` mapping is defined for them).

**`System.*` is read-only on the wire, always.** The reserved `System` tag
carries an explicit `access: 'ReadOnly'` on the `PlcTag` itself (independent
of `ioType`), and every map's leaf-expansion checks both signals
(`root.ioType == 'SimulatedOutput' || root.access == 'ReadOnly'`) — so every
`System.*` leaf node (`System.Fault`, `System.ScanTimeMs`, ...) is generated
`ReadOnly` and a write attempt gets the same `Bad_NotWritable` any other
`ReadOnly` node returns. The one exception is `System.AlarmReset`, which
stays outside `scalarLeaves`'s composite expansion of the diagnostics fields
an operator can legitimately write (see `docs/task-scheduling.md`) — it is
not part of this dotted-leaf mechanism.

This is machine-verified end-to-end against the real Rust `opcua` client
(`tool/opcua_e2e.sh`): the probe reads the auto-generated `System.Fault`
(`Boolean`) and `System.ScanTimeMs` (`Double`) nodes live off the running
fixture host — proof the dotted-path resolution works over the real wire,
not just in a unit test (`mobile/test/opcua_address_space_leaf_test.dart`).

## v1 scope (and what's deferred to v2+)

**v1 delivers:** `opc.tcp` transport (Hello/Acknowledge/Error framing),
`OpenSecureChannel` with Security Policy **None** (including token renewal),
`CreateSession`/`ActivateSession` (anonymous) + `CloseSession`,
`GetEndpoints` (echoing the client's own dialed host back in the returned
endpoint, so it's reachable behind NAT/alternate hostnames), `Browse` (the
exposed-tag address space under Objects, reachable **top-down from
`RootFolder`** — not only by addressing Objects directly — plus the
standard `Server` object), the standard `Server_NamespaceArray` variable
(`ns=0;i=2255`, index 1 = this project's namespace URI), `Read` (Value +
core attributes, server timestamps), `Write` (force-aware, `ReadWrite` nodes
only). Unsupported/unknown services answer a proper `ServiceFault`
(`Bad_ServiceUnsupported`) rather than dropping the connection.

**Deferred (v2+):**
- **Subscriptions/MonitoredItems** — v1 clients poll via `Read`; there is no
  server-push/monitored-item support yet. **Shipped in v2 — see
  "Subscriptions (v2)" below.**
- **Encryption** (`Basic256Sha256` etc.) — v1 is Security Policy `None` only.
  **Shipped in v3 — see "Security (Basic256Sha256 + user auth)" below.**
- **User-token authentication** — v1 is Anonymous only. **Shipped in v3
  (username/password) — see "Security (Basic256Sha256 + user auth)" below.**
- **Multi-chunk reassembly** — v1 negotiates generous (~1 MB) single-chunk
  buffers, ample for the address spaces this app builds; an oversize message
  is rejected cleanly rather than crashing.
- `TranslateBrowsePaths` and other optional services (all answer
  `ServiceFault`).

## Subscriptions (v2)

v2 adds real server-push: a client can subscribe to a set of nodes and
receive **DataChangeNotifications** whenever a value changes, instead of
having to poll with `Read`. All nine subscription-related services are
implemented:

- `CreateSubscription` / `ModifySubscription` / `DeleteSubscriptions` /
  `SetPublishingMode`
- `CreateMonitoredItems` / `ModifyMonitoredItems` / `DeleteMonitoredItems`
  (`SetMonitoringMode` is not implemented; per-item mode is set at
  create/modify time, and calling it returns `Bad_ServiceUnsupported`)
- `Publish` / `Republish` (retransmission of a notification the client
  missed, by sequence number)

**What's monitored:** data-change monitored items on the **Value**
attribute only (no Event monitored items). Change detection uses an
**absolute deadband** (a numeric monitored item only reports when its value
moves by more than the configured deadband; boolean/string/enum values
report on any change). Each subscription has its own **keep-alive** and
**lifetime** counters — a subscription that goes `max_keep_alive_count`
publishing intervals without anything to report sends an empty keep-alive
`PublishResponse`; one that goes `lifetime_count` intervals with no
`Publish` request outstanding from the client is deleted server-side, same
as the spec requires.

**Caps** (fixed, not client-negotiable, sized for a single-app/LAN
simulator rather than an industrial-scale historian):
- **10 subscriptions per session**
- **500 monitored items per subscription**
- **10 parked (queued) Publish requests per session**
- **20 retransmission messages retained per subscription** (for
  `Republish`)

Exceeding a cap returns the appropriate `Bad_*` status (e.g.
`Bad_TooManySubscriptions`, `Bad_TooManyMonitoredItems`) rather than
silently truncating.

**Seeing it in UAExpert:** drag a mapped tag from the address space into
the **Data Access View** (or any view that subscribes, such as dragging
onto the graph view) — UAExpert automatically creates a subscription and a
monitored item on that node, and its value column starts updating live as
the app's scan changes it, with no manual "Read" needed. The OPC UA card in
**Outbound Protocols** also surfaces this at a glance: once a client has an
active subscription, the card's status line reads `Subscriptions: N ·
Monitored items: M`, alongside the existing connected-client count.

**v2 simplifications** (documented deliberately, not implementation gaps
that will silently bite you):
- **Sampling mode is reported like Reporting.** The spec's `Sampling`
  monitoring mode (value is sampled and queued but notifications are
  suppressed until the mode changes back to `Reporting`) is accepted and
  stored, but this server currently reports the same as `Reporting` — there
  is no server-side notification suppression while a monitored item sits in
  `Sampling` mode.
- **`TimestampsToReturn` is ignored.** Every `DataValue` the server produces
  (from `Read`, monitored-item creation, and Publish notifications) always
  carries server timestamps; the client's requested
  `Neither`/`Source`/`Server`/`Both` selection has no effect. This mirrors
  v1's `Read` behavior.
- **Keep-alives continue while publishing is disabled.** After
  `SetPublishingMode(enabled: false)`, data-change notifications stop, but
  the subscription's keep-alive/lifetime counters keep ticking and
  keep-alive `PublishResponse`s still go out — the subscription itself
  stays alive and does not silently expire just because publishing was
  paused.
- No sequence-number wraparound handling (not reachable in any session
  short-lived enough for a training/simulator deployment).

## Security (Basic256Sha256 + user auth) (v3)

v3 adds a real, hand-rolled, **pure-Dart** OPC UA security stack — no crypto
FFI, no companion process. A client can now open an **encrypted, signed,
authenticated** session instead of the plaintext `None`/Anonymous one.

### Policies offered

Endpoint advertisement is driven by the per-project
`protocols.opcua.securityModes` list (additive persistence, default
`['None']`). The recognized tokens are:

- `None` — plaintext (the v1/v2 behavior; still offered for LAN
  commissioning).
- `Basic256Sha256/Sign` — messages are signed (HMAC-SHA256) but not
  encrypted (integrity/authenticity, no confidentiality).
- `Basic256Sha256/SignAndEncrypt` — messages are signed **and** encrypted
  (AES-256-CBC). This is the mode a Basic256Sha256 client uses by default
  and the mode the live E2E exercises.

Both secured modes are implemented; `SignAndEncrypt` is the exercised/target
mode. Authentication is configured independently: `allowAnonymous` (default
true) and a list of username/password `credentials` (passwords are **not**
persisted to project JSON — they are re-entered per session config).

### The handshake

1. **Asymmetric `OpenSecureChannel` (OPN).** When the policy is not `None`,
   the OPN request/response are secured with RSA: the body is
   **RSA-OAEP-SHA1-encrypted** to the peer's certificate public key and
   **RSA-PKCS#1-v1.5-SHA256-signed** with the sender's private key. Each side
   contributes a 32-byte nonce.
2. **`P_SHA256` key derivation.** From the two nonces the OPC UA
   `P_SHA256(secret, seed)` PRF derives the symmetric key material — separate
   signing key, encrypting key, and IV for each direction (client→server keys
   use `secret = serverNonce, seed = clientNonce`; server→client the reverse).
3. **Symmetric `MSG`/`CLO`.** All subsequent chunks are secured with the
   derived keys: **HMAC-SHA256** signatures and (for `SignAndEncrypt`)
   **AES-256-CBC** encryption, with PKCS#7-style padding sized to the AES
   block. `Sign`-only mode signs but does not encrypt.
4. **Session + user auth.** `CreateSession`/`ActivateSession` run over the
   secured channel. On a secured channel the `CreateSessionResponse` returns
   the server's application-instance **certificate** and a **server nonce**
   (a strict client rejects the session with `Bad_CertificateInvalid` if the
   certificate is absent, and uses the returned server nonce as the OAEP
   nonce for the user password — so both must be echoed). A
   `UserNameIdentityToken` password is **RSA-OAEP-encrypted** by the client
   as `UInt32-LE length ++ passwordBytes ++ serverNonce`; the server
   OAEP-decrypts it, verifies the trailing nonce matches the channel's
   server nonce, then constant-time-compares the password against the
   configured credential.

### The application certificate + auto-trust

The app's identity is a single **RSA-2048 keypair + self-signed X.509
certificate**, generated once on first run and persisted to app-local
storage (`services/opcua_cert_store.dart` — the only OPC UA security file
allowed to touch `dart:io`/`path_provider`). The private key never leaves
the device, is never logged, and is never written into project JSON. The
certificate's `SubjectAltName` carries the server's `applicationUri`
(`urn:softplc:<projectId>`), and the OPC UA card shows its SHA-1 thumbprint
with a **Regenerate** action (fresh keypair + cert). Clients are expected to
**trust-on-first-use** (auto-trust) this self-signed cert, exactly as the
E2E probe does.

### Known limitations (v3, documented deliberately)

The three strict-client conformance gaps below (cert `KeyUsage`/
`ExtendedKeyUsage`, `CreateSession` `serverSignature`, `ActivateSession`
client-signature verification) are now **CLOSED**:

- **The app certificate now carries `KeyUsage`/`ExtendedKeyUsage`
  extensions.** Every self-signed app-instance certificate (generated by
  `buildSelfSignedCertificate`) includes, in addition to the
  `applicationUri` SAN: a `critical` `KeyUsage` extension with
  `digitalSignature`, `nonRepudiation`, `keyEncipherment`,
  `dataEncipherment`, **and `keyCertSign`** (bits 0-3 + 5; BIT STRING
  `03 02 02 F4`), and an `ExtendedKeyUsage` extension with
  `serverAuth`/`clientAuth`. **`keyCertSign` is required** even though this
  is a leaf cert: a self-signed cert is validated as its own trust anchor,
  and a strict validator (Eclipse Milo, the stack Ignition uses) rejects an
  anchor lacking `keyCertSign` with `Bad_CertificateUseNotAllowed`
  ("required KeyUsage 'keyCertSign' not found") — confirmed live against
  Ignition 8.3. This matches the vendored Rust `x509.rs`.
  **Operational note — existing certs are NOT retroactively upgraded:** an
  app-local certificate generated *before* this change lacks these
  extensions (it predates the code that adds them) and will not gain them
  automatically. A strict client that demands `KeyUsage`/`ExtendedKeyUsage`
  requires a **regenerated** certificate — use the OPC UA card's
  **Regenerate** action (or a fresh install) to force a new keypair/cert
  with the extensions before testing against a strict client.
- **`Sign` vs `SignAndEncrypt`.** Both are implemented; `SignAndEncrypt` is
  the exercised/target mode (the live E2E proves it). `Sign`-only is
  available but not covered by the live client leg.
- **A single app-wide certificate is reused across projects.** There is one
  identity per app install, not one per project — so the `applicationUri`
  must be app-wide-stable. (The server advertises the current project's
  `urn:softplc:<projectId>`; the persisted cert's SAN must match whatever
  `applicationUri` the endpoint reports, which the host keeps consistent.)
- **The `CreateSession` `serverSignature` is now populated.** The server
  signs `clientCertificateDer ++ clientNonce` with **RSA-PKCS#1-v1.5-SHA256**
  over its own private key and returns it as the `CreateSessionResponse`'s
  `serverSignature`. A strict client that verifies this signature against
  the server's certificate (rather than treating it as a no-op) now gets a
  valid signature to check.
- **The `ActivateSession` client signature is now verified.** The server
  checks the client's `clientSignature` — proof-of-possession of the client
  certificate's private key, computed as an RSA-PKCS#1-v1.5-SHA256 signature
  over `serverCertificateDer ++ serverNonce` (the **same server nonce issued
  at `CreateSession`**, not a fresh per-`ActivateSession` nonce — see the
  note below). An invalid or missing signature on a secured channel is
  rejected with `Bad_ApplicationSignatureInvalid`; this is the live Rust
  `opcua` client E2E's regression guard, since that client sends a genuine
  signature that the server must now accept.
  **v1 note (kept):** the server reuses the `CreateSession`-issued
  `serverNonce` for the `ActivateSession` signature check rather than
  minting a fresh nonce per activation — fresh-per-activation nonce
  rotation is deferred to a later pass.
- **Deferred:** deprecated policies (`Basic128Rsa15`, `Basic256`),
  `Aes*Sha256*` policies, `X509IdentityToken` user auth, and a managed
  trust-list / rejected-cert store (v3 is trust-on-first-use only).

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
- Dotted-path leaf resolution for composite/`System` tags (`System.Fault`
  resolves to `BOOL`, live `readVariant` returns the current value; a bare
  scalar tag's root-path node id is unchanged) —
  `mobile/test/opcua_address_space_leaf_test.dart`. The scalar-only
  regression (a folder-qualified tag keeps its pre-existing
  `ns=1;s=Inputs/Start_PB`-style node id rather than being renamed to the
  resolver-key name) is covered by `mobile/test/opcua_map_test.dart` and
  `mobile/test/models/composite_map_expansion_test.dart`.
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
`GetEndpoints` → **`Read` `NamespaceArray` (`ns=0;i=2255`) and assert index 1
equals the project's namespace URI** → **`Browse` top-down from `RootFolder`
(`i=84`), discover `Objects` as a reference off Root (not by hardcoding its
node id), and assert every fixture tag is reachable that way** → `Browse`
(Objects, addressed directly) → `Read` → `Write` → `Read`-back-verify →
**`CreateSubscription` + `CreateMonitoredItems`, then waits for a real
pushed `DataChangeNotification`**. The fixture host mutates a tag
server-side on its own timer (T+4s after `READY`, entirely independent of
the probing client) so the notification the probe observes can only have
come from the server's own publish loop — proof that a third-party client
receives pushed data changes, not just polled reads.

Then, as the **security machine-proof (v3)**, the same probe opens a
**second session** at Security Policy **`Basic256Sha256`** with
**`SignAndEncrypt`** message security, authenticated with a
**username/password** (`UserNameIdentityToken`), and runs
`Browse` → `Read` → `Write` → `Read`-back-verify **over the fully encrypted
channel**. This exercises the entire asymmetric OPN (RSA-OAEP encrypt +
RSA-PKCS#1-SHA256 sign) + `P_SHA256` key derivation + symmetric AES-256/
HMAC-SHA256 channel + OAEP-encrypted password path end-to-end: if any of
that byte layout or the app certificate were wrong, the real client would
reject the channel here (`Bad_SecurityChecksFailed` /
`Bad_CertificateInvalid` / a decrypt failure), not silently pass. The probe
auto-trusts the server's self-signed cert (trust-on-first-use). A successful
secure leg prints `OPCUA SECURITY PROBE PASS`.

Run it from the repo root (bash/Git Bash):

```bash
tool/opcua_e2e.sh
```

It starts the Dart fixture host on a non-default port, waits for it to
report `READY`, runs the Rust probe against it, and unconditionally kills
the Dart host on exit (propagating the probe's exit code). A successful run
ends with:

```
SUBSCRIPTION PASS
PROBE PASS
...
OPCUA SECURITY PROBE PASS
```

**Honest fallback:** if `cargo`/the `opcua` crate can't run in the
environment (no toolchain, offline crate fetch), the script does **not** fake
a pass — it compile-checks the probe (`cargo build --example opcua_probe`),
runs the Dart unit suite as the in-process proof of the same crypto/
secure-channel codec, and reports the live-master leg as **SKIPPED** with the
reason (its exit code reflects the unit suite, never a probe that didn't
run).

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
`None` **or** `Basic256Sha256` with username/password), not formal
certification. Its self-signed application certificate now carries the
KeyUsage/ExtendedKeyUsage extensions a strict client demands (see "Known
limitations" above), but a strict client still requires a **regenerated**
cert if the on-device identity predates that change — use the OPC UA
card's Regenerate action first. Do not use it to control real
safety-critical equipment. Historical access and method nodes are not
implemented. Struct/array members **are** individually addressable — each
scalar leaf of a composite tag becomes its own dotted-path node (see
"Composite/struct tag exposure" above) — but a composite tag is never
addressable as a single aggregate/structured-value node; there is no
`Structure`-encoded Variant that reads a whole struct or array in one Read.
