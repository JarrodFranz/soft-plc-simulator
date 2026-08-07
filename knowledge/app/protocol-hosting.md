---
id: knowledge:app/protocol-hosting
title: Protocol Hosting
domain: app
version: "2026-08"
topics: [adr-010, in-process-hosting, no-autostart, hardening, drop-log-gate, logging-sources, port-configuration]
summary: ADR-010's in-process pure-Dart protocol hosting decision, the explicit opt-in-only start lifecycle proven by a real no-autostart guard test, the fragment-bound/fail-loud/budget hardening program shared across all nine hosts, the kLogSource logging rule, and DropLogGate's first-occurrence WARN policy.
related:
  - knowledge:app/index
  - knowledge:app/tag-model
  - knowledge:industry/protocols/index
learnings: [CL-14]
---

# Protocol Hosting

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `DECISIONS.md` ADR-010, `mobile/lib/services/{modbus,opcua,s7,fins,
> slmp,enip,dnp3,bacnet,mqtt}_host.dart`, `drop_log_gate.dart`, `app_logger.dart`,
> `mobile/lib/models/app_log.dart`, `mobile/lib/models/protocol_settings.dart`, and
> `mobile/test/defaults/flagship_gateway_no_autostart_test.dart`.
> **Read this before:** adding a new protocol host, debugging why a host "isn't running" or
> "won't stop", changing hardening bounds, or adding a new logging source.

---

## 1. The headline rule

**All nine industrial protocol servers run in-process, in pure Dart, inside this app - no
companion process, no FFI - and none of them ever starts itself; every host's `start()` is
reached exclusively from an explicit UI toggle, proven by a test that boots the app, activates
a project shipping enabled protocol configs, and confirms both the log stream and the raw OS
socket stay silent.**

`DECISIONS.md` ADR-010 (lines 105-118) records the decision and its rationale:

> "Implement the protocol servers **in pure Dart, inside the app**, reading the tag database
> directly (force-aware writes)... Pure Dart is the only path satisfying all three constraints
> at once - single app (no companion, no FFI), runs on Android + iOS + desktop from one
> codebase, and fully machine-testable in this environment... iOS hosts servers only while the
> app is foregrounded (OS constraint, independent of implementation)."

ADR-010 supersedes ADR-003's "Mode B" companion-gateway architecture; ADR-003 is explicitly
marked superseded in `DECISIONS.md:37`. The `gateway/` Rust crate survives only as a dev-time
test-client harness, not a runtime component.

## 2. All nine protocols are hosted, not eight

`mobile/lib/services/` contains nine complete `*_host.dart` files, each with a full
`start()`/`stop()` socket lifecycle: `modbus_host.dart`, `opcua_host.dart`, `s7_host.dart`,
`fins_host.dart`, `slmp_host.dart`, `enip_host.dart` (EtherNet/IP-CIP), `dnp3_host.dart`,
`bacnet_host.dart`, `mqtt_host.dart`. `bacnet_host.dart` (417 lines) is fully implemented, not
a stub - it has a complete UDP `start()`/`stop()` lifecycle, its own `kLogSourceBacnet`, and is
wired into the Gateway/Outbound Protocols screen exactly like every other host. ADR-010's own
text (§1) names only OPC UA/Modbus/MQTT/DNP3 explicitly, because S7/FINS/SLMP/EtherNet-IP/
BACnet were added by a later expansion program the ADR predates - the ADR is a historical
record of the original decision, not a living status document. Any claim that a protocol
"remains" unhosted should be re-verified against the `services/` directory rather than the ADR
text or older notes.

## 3. No-autostart, proven

Every host's file header states the invariant directly (e.g. `modbus_host.dart:11-13`): *"The
app is byte-identical when hosting is stopped: nothing here runs unless `start` is called (an
explicit, opt-in action from the Outbound Protocols screen)."* The Gateway screen is the only
call site for any host's `.start()`, each gated behind its own toggle switch.

`mobile/test/defaults/flagship_gateway_no_autostart_test.dart` is the concrete proof. The
Flagship default project ships Modbus **and** OPC UA with `enabled: true` in its protocol
config (so the Gateway screen shows live content immediately) - which is only safe because
loading that project cannot itself start a host. The test:

1. Confirms `flagship.protocols.modbus.enabled` and `.opcua.enabled` are both `true` (sanity
   check that the scenario is real).
2. Boots the shell (which activates a *different* default, the conveyor), then explicitly
   switches to the Flagship project and runs five scan ticks.
3. Asserts **no** log entries under `kLogSourceOpcUa`/`kLogSourceModbus` were emitted.
4. As direct evidence (in case a host logs below the default level), attempts a real
   `ServerSocket.bind` on the Flagship's configured Modbus/OPC UA ports inside
   `tester.runAsync` - a started host would be holding the port and the bind would throw. Port
   502's privileged-bind-denied case (`EACCES`/`WSAEACCES`) is classified as inconclusive and
   skipped rather than failed, per the privileged-port classification rule (CL-11).

## 4. Hardening: fragment bounds, fail-loud, budgets

Every stream-framed host enforces an explicit maximum frame/fragment size and closes just the
offending connection on violation - never the whole host:

| Host | Bound |
|---|---|
| Modbus | `_maxFrameBytes = 260` |
| OPC UA | `_maxFrameBytes = 16 MiB` |
| MQTT | `_maxFrameBytes = 4 MiB` |
| SLMP | length-prefix + `0xFFFF` |
| EtherNet/IP | header length + `0xFFFF` |
| S7 | `0xFFFF` |
| DNP3 | link-layer `_maxSegmentPayload = 249` bytes, plus a `_maxPendingBytes = 4096` reassembly cap |

**Fail-loud**: every host wraps its per-connection frame handler in a try/catch that logs at
WARN/ERROR and drops only that one connection - a crash while reassembling or dispatching a
request must never take the whole host down. Bind failures are always logged and surfaced as
an error status with an explanatory message (privileged-port-specific guidance for ports
below 1024). Write refusals (illegal address, read-only, forced tag) are always-on WARN, never
silent - "a SCADA write that never lands is the same class of failure as a silently dropped
request."

**Budgets**: DNP3's reassembly cap bounds unbounded buffering from a malformed/malicious
stream; EtherNet/IP's CIP Multi-Service-Packet dispatch takes an explicit `responseBudget`
argument so one MSP request cannot demand unbounded response space; `DropLogGate`'s
`kMaxDropWarnsPerReason` (§6) is itself a budget on log-level escalation.

## 5. Logging rule

Every protocol host logs under its own `kLogSource*` constant, declared in
`mobile/lib/models/app_log.dart:23-36` (nine protocol sources - `kLogSourceOpcUa`,
`kLogSourceModbus`, `kLogSourceMqtt`, `kLogSourceDnp3`, `kLogSourceEnip`, `kLogSourceS7`,
`kLogSourceFins`, `kLogSourceSlmp`, `kLogSourceBacnet` - plus five subsystem sources `Scan`,
`Project`, `Sim`, `Historian`, `Scheduler`). All fourteen appear in `kAllLogSources`
(`app_log.dart:47-62`) - the list the Logs screen builds its source filter and per-source
verbosity toggles from. The rule is enforced mechanically, not just by convention: a
`kLogSource*` constant declared but missing from `kAllLogSources` fails
`test/app_log_test.dart` ("`kAllLogSources` covers every `kLogSource` constant"). Every one of
the nine host files was confirmed to reference its own constant.

DEBUG/TRACE frame detail is off by default (`AppLogger.kDefaultMinLevel = LogLevel.info`,
`app_logger.dart:52`) - a deliberate product choice so hosts can log liberally at DEBUG without
flooding the buffer, while WARN/ERROR (announcements, not detail) always show.

## 6. `DropLogGate`: first-occurrence severity, not full suppression

`drop_log_gate.dart` solves a specific failure mode: a host that *parses* a request but does
not *serve* it (an unsupported command, an address it doesn't map) used to log nothing, so an
operator had no way to notice a client silently getting every request discarded. The fix is a
level-demotion scheme, not a mute:

- The **first** drop of a given `reason` on a given connection logs at WARN (visible by
  default); every repeat of that reason on that same connection logs at DEBUG (off by default).
- A **host-wide budget**, `kMaxDropWarnsPerReason = 3`, bounds a reconnect-loop flood: a client
  that reopens a fresh connection every cycle would otherwise re-arm the per-connection WARN
  indefinitely. Once three WARNs have fired for a reason across *all* connections, every further
  drop of that reason logs DEBUG regardless of how many new sockets appear.
- The budget resets only when the host itself calls `reset()` from `start()` - never from
  traffic, and deliberately not on a successfully served request (a healthy client's traffic
  would otherwise mask a concurrently-broken client's flood).
- `specSilence()` is a separate, always-DEBUG path for silences the protocol *itself* requires
  (an RTU broadcast, an EtherNet/IP NOP, a DNP3 CONFIRM) - correct behavior, never promoted to
  WARN, so an operator isn't trained to ignore warnings that matter.
- With a `null` logger, every method is a no-op touching no state - a host built without a
  logger behaves byte-for-byte as it did before this class existed; this changes only the log
  **level**, never protocol behavior.

## 7. Port configuration

Each protocol's config class in `mobile/lib/models/protocol_settings.dart` carries a mutable
`port` with a protocol-standard default, overridable per project and persisted in project JSON:
OPC UA `4840`, Modbus `502`, MQTT `1883`, DNP3 `20000`, EtherNet/IP `44818`, S7 `102`, FINS
`9600`, SLMP `5007`, BACnet/IP `47808`. A host reads `port`/`enabled` **once**, at `start()`
time - a bound socket cannot change port mid-connection - while the project object itself (the
tag data being served) is re-read fresh on every request, so a live tag edit takes effect
immediately without a host restart.

---

## What this means practically

### "I loaded a project with protocols pre-enabled and nothing seems to be listening - is that broken?"
No - that's the intended behavior (§3). A project's `enabled: true` protocol config only means
the Gateway screen is ready to start that host with one toggle; it never starts a host by
itself on load.

### "I'm building a new protocol host - what do I need to wire up to match the others?"
A `kLogSource*` constant in `kAllLogSources` (§5), a `DropLogGate` for parsed-but-unserved
requests (§6), an explicit frame-size bound with fail-loud per-connection error handling (§4),
and a `start()`/`stop()` reachable only from the Gateway screen, never from project load (§3).

### "A client in a reconnect loop is spamming a `NOT_SUPPORTED` warning every time it connects - why did the flood stop after three?"
`DropLogGate`'s host-wide `kMaxDropWarnsPerReason = 3` budget (§6) - after three WARNs for that
reason across all connections, further drops of the same reason log at DEBUG (off by default)
until the host is restarted.

---

## Related

- [tag-model.md](./tag-model.md) - `isExternallyWritable` (CL-14), the write-time backstop
  every host's write handler consults.
- [scan-engine.md](./scan-engine.md) - why protocol hosts are not part of the scan tick.
- [../industry/protocols/index.md](../industry/protocols/index.md) - per-protocol wire formats
  for what these hosts actually speak on the wire.
- [index.md](./index.md) - domain hub.
