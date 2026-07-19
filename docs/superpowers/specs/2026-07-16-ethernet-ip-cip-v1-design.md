# EtherNet/IP + CIP Explicit Messaging (v1) — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** Protocol expansion program, **workstream 2 of 6** (see
`2026-07-16-protocol-expansion-program-roadmap.md`).

## Goal

Host an **EtherNet/IP + CIP explicit messaging** server in-app on TCP 44818, so
a Logix-oriented client (Ignition's ControlLogix/CompactLogix driver, `pycomm3`,
etc.) can **read and write the app's tags by symbolic name**.

Symbolic addressing is the reason this protocol is the program's highest-value
target: CIP addresses tags by *name*, which maps onto the app's tag database far
more naturally than Modbus's register files or DNP3's point indices — a tag
called `Motor_Run` is simply `Motor_Run` on the wire.

## v1 scope, and what is deferred to v2

**In v1:** session registration, **both** unconnected (UCMM) and connected
(Forward Open) explicit messaging, Read Tag / Write Tag / Multiple Service
Packet, the atomic CIP data types, a `CipMap` exposure model, host + UI, and a
real third-party E2E.

**Deferred to a v2 workstream** (its own spec/plan/build):
- **Tag-directory browse** — Symbol Object (class `0x6B`) instance enumeration
  and Template Object (class `0x6C`) struct definitions, plus controller
  Identity, which together let a client *discover* tags. Without it a client
  must be told tag names (Ignition supports manual tag addressing; `pycomm3`'s
  full `LogixDriver` does not connect without the tag list, which is why v1's
  E2E targets its lower-level generic-messaging API instead).
- **`STRING`** — a Logix `STRING` is a *struct* (`LEN` DINT + `DATA` SINT[82]),
  not an atomic type; encoding it correctly requires the Template Object that v2
  introduces. **v1 therefore refuses to expose `STRING` tags** (see Component 5)
  rather than half-encoding them.
- Class 1 implicit (cyclic I/O) messaging — permanently out of scope per the
  program roadmap: Ignition's driver uses explicit messaging, and real-time
  cyclic I/O over UDP 2222 is not viable on mobile.

## Current behaviour (as-found)

- Four protocols ship on the same anatomy: pure codec in
  `mobile/lib/protocols/<name>/`, socket host in
  `mobile/lib/services/<name>_host.dart` (the only `dart:io` file), a map model
  in `mobile/lib/models/<name>_map.dart`, a `ProtocolSettings` entry + an
  Outbound Protocols card, and a `tool/<name>_e2e.sh` real-client proof.
- `OpcuaMap` is the closest template: a list of exposed entries carrying
  `tagName` + `access` (`'ReadOnly'` | `'ReadWrite'`), auto-populated from the
  project, where `root?.ioType == 'SimulatedOutput' || root?.access == 'ReadOnly'`
  forces `ReadOnly`.
- `OpcUaProtocolConfig` holds `enabled` / `port` (default 4840) / `map`, read
  additively (`(j['port'] as num?)?.toInt() ?? 4840`).
- The OPC UA host is the closest host template because OPC UA is likewise
  **length-prefixed** — unlike the Modbus RTU work, framing here is explicit.
- Tag data types in the app: `BOOL`, `INT16`, `INT32`, `INT64`, `FLOAT64`,
  `STRING`.
- Force-aware external writes: OPC UA **refuses** a write to a forced tag with a
  visible status (`Bad_UserAccessDenied`) rather than silently discarding, on the
  principle that "the client must SEE the refusal".
- **Reference client lane confirmed before planning** (per the roadmap's rule):
  no EtherNet/IP Rust crate is vendored locally and none can be API-verified
  offline, so adding one would be an unverifiable dependency. **Python 3.12.10 is
  present**; `pycomm3` is the industry-standard Logix client and is
  pip-installable. EtherNet/IP is therefore the **first user of the Python probe
  lane** the roadmap provisioned.

## Global Constraints

- **ADR-010**: hosted in-process, pure Dart, no companion process, no FFI.
- Pure Dart (no Flutter imports, no `dart:io`) in `mobile/lib/protocols/enip/`;
  `dart:io` confined to `mobile/lib/services/enip_host.dart`.
- Deterministic: no wall clock or randomness in codec logic. (Connection and
  session identifiers are allocated from a monotonic counter, **not** randomness,
  so a test can predict them.)
- Additive/backward-compatible: a project without an `ethernetIp` protocol block
  loads with the feature disabled; no existing project's serialized form or scan
  sequence changes; default-projects round-trip/scan-equivalence stays green.
- Force-aware writes: a write to a forced tag is **refused with a visible CIP
  status**, mirroring the OPC UA precedent.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"/"ControlLogix"/"CompactLogix"
  branding in code, UI, or docs — describe the capability generically
  ("EtherNet/IP + CIP explicit messaging", "Logix-style symbolic tags" only where
  technically necessary to name the addressing style). No reverse-engineering
  wording: implemented from public EtherNet/IP and CIP specification material.

> **Wire-detail caveat.** The constants and layouts below are stated to make the
> plan concrete, but CIP is a large specification. Every wire detail must be
> validated by the real-client E2E (Component 6) — that probe, not this
> document, is the authority. Where an implementer finds this spec disagrees with
> observed client behaviour, the client wins and the deviation is reported.

## Component 1 — Encapsulation layer (`protocols/enip/enip_encap.dart`, pure)

The 24-byte encapsulation header (`command` u16, `length` u16, `sessionHandle`
u32, `status` u32, `senderContext` 8 bytes, `options` u32) followed by
command-specific data, plus **CPF** (Common Packet Format) item lists.

Commands handled:
- `RegisterSession (0x65)` — protocol version 1; reply carries the allocated
  session handle.
- `UnRegisterSession (0x66)` — drops the session; no reply.
- `SendRRData (0x6F)` — unconnected/UCMM request-reply; CPF = Null Address item
  (`0x0000`) + Unconnected Data item (`0x00B2`).
- `SendUnitData (0x70)` — connected; CPF = Connected Address item (`0x00A1`,
  carrying the connection id) + Connected Data item (`0x00B1`, carrying a
  sequence count then the CIP message).
- `ListIdentity (0x63)` — a minimal identity reply (vendor/device/product name)
  so discovery tools see *something*; the full Identity object lands in v2.
- `NOP (0x00)` — accepted and ignored.

Unknown commands return an encapsulation-level error status rather than closing
the connection. Because the header carries an explicit `length`, the host's
reassembly is length-driven (like OPC UA, unlike Modbus RTU).

## Component 2 — CIP messaging + EPATH (`protocols/enip/cip.dart`, pure)

- **CIP request**: service byte, request-path size (in 16-bit words), request
  path (EPATH), service data. **CIP response**: `service | 0x80`, reserved,
  general status, additional-status size/words, response data.
- **EPATH** encode/parse, covering: Class (`0x20`/`0x21`), Instance
  (`0x24`/`0x25`), Attribute (`0x30`/`0x31`), and — the one that matters most —
  the **ANSI Extended Symbol segment (`0x91`)**, which carries a tag name as
  `0x91, len, name bytes, pad-to-even`. Nested/member paths (e.g. a struct
  member) parse into an ordered list of name segments.
- **Data type codes**: `BOOL 0xC1`, `INT 0xC3`, `DINT 0xC4`, `LINT 0xC5`,
  `REAL 0xCA`. Mapping to app types: `BOOL→BOOL`, `INT16→INT`, `INT32→DINT`,
  `INT64→LINT`, `FLOAT64→REAL` (encoded as IEEE-754 **single**, the Logix `REAL`
  width — the app's double is narrowed on the wire and this narrowing is
  documented). `STRING` is **not** encodable in v1 (see v2 deferral).
- **General status codes** used: `0x00` success, `0x04` path segment error,
  `0x05` path destination unknown (unknown tag name), `0x08` service not
  supported, `0x0A` embedded/attribute list error, `0x13` not enough data,
  `0x1E` embedded service error, plus a privilege-violation status for a refused
  write to a forced tag.

## Component 3 — Connection manager (`protocols/enip/cip_connection.dart`, pure)

Connection Manager object (class `0x06`, instance 1) over UCMM:
- **Forward Open (`0x54`)** — parse the request (connection serial number,
  vendor id, originator serial, timeout ticks, O→T and T→O connection
  parameters/RPIs, and the connection path). Allocate a T→O connection id from a
  **monotonic counter** (determinism), echo the O→T id, and reply with both ids,
  the serial numbers, and the actual RPIs.
- **Forward Close (`0x4E`)** — release the connection by serial number/vendor id.
- **Routing**: `SendUnitData` traffic is matched to an open connection by
  connection id; the connected data item's **sequence count** is tracked and
  echoed. Unknown connection id → an error status, not a crash.
- Connections are per-session; dropping a session or the socket releases them.

## Component 4 — Tag services (`protocols/enip/cip_tags.dart`, pure)

- **Read Tag (`0x4C`)** — path = symbol segment(s); data = element count (u16).
  Reply = type code + packed value(s).
- **Write Tag (`0x4D`)** — path = symbol segment(s); data = type code + element
  count + value(s). Type must match the mapped tag's CIP type, else
  `0x13`/type-mismatch status.
- **Multiple Service Packet (`0x0A`)** — path = Message Router (class `0x02`,
  instance 1); data = a count + per-service offsets + embedded requests. Each
  embedded request is dispatched independently and its reply packed back in
  order; one embedded failure does not fail the batch (it returns its own
  status). Ignition batches reads this way, so it matters.
- Resolution: symbol name → `CipMap` entry → tag path → `readPath`/`writePath`.
  Unknown or unexposed name → `0x05` (path destination unknown). A write to a
  `ReadOnly` entry or to a **forced** tag → refused with a visible status.

## Component 5 — Model, host, UI

- **`models/cip_map.dart`** — mirrors `OpcuaMap`: a list of exposed entries
  (`tagName`, `access`), auto-populated from the project, with
  `SimulatedOutput` / `System` / `access == 'ReadOnly'` tags forced to
  `ReadOnly`. **Tags whose data type is `STRING` are skipped** during
  auto-population in v1 (with the reason documented), because Logix strings are
  structs requiring the v2 Template Object.
- **`CipProtocolConfig`** in `ProtocolSettings` — additive: `enabled` (default
  false), `port` (default **44818**), `map`. Read defensively
  (`(j['port'] as num?)?.toInt() ?? 44818`); a project with no `ethernet_ip` key
  loads disabled.
- **`services/enip_host.dart`** — the only `dart:io` file: length-prefixed
  reassembly from arbitrary TCP chunks (bounded by a max frame size), per-socket
  session state, connection registry, start/stop with the same lifecycle as the
  other hosts (stopped on every project switch), and status counters for the UI.
- **UI** — an **EtherNet/IP** card in Outbound Protocols mirroring the Modbus/OPC
  UA cards: enable toggle, port field, session/connection counters, and a link
  into the exposed-tag map editor.

## Component 6 — Python E2E lane (new shared infrastructure)

EtherNet/IP is the lane's first user, so this workstream **establishes the
pattern** for S7comm/FINS/SLMP/BACnet later:

- `tool/py/requirements.txt` — pinned (`pycomm3==<pinned>`).
- `tool/py/enip_probe.py` — a real **`pycomm3`** client. v1 targets its
  lower-level generic CIP messaging (`CIPDriver` / `generic_message`), which does
  **not** require the tag-list upload that v2 will add; v2 graduates this to the
  full `LogixDriver`.
- `tool/enip_e2e.sh` — honours the **existing** contract exactly: create/reuse a
  venv, `pip install -r`, start `mobile/tool/enip_host_probe.dart <port>`, wait
  for `READY`, run the probe, kill the Dart host unconditionally (trap), and
  propagate the probe's exit code.
- The Dart fixture host follows the established constraint: it **must not**
  import `services/enip_host.dart` (hosts extend `ChangeNotifier`, pulling in
  `dart:ui`, unavailable under plain `dart run`); it imports the **pure** codec
  and re-implements only the small reassembly loop, as the Modbus and OPC UA
  fixture hosts do.

The probe proves: register session → Forward Open → **read** a tag → **write** it
→ **independently read back** the exact written value → Forward Close.

## Data flow

TCP bytes → `enip_host` length-prefixed reassembly → encapsulation decode →
session lookup → (UCMM → CIP dispatch) or (connected → connection lookup →
sequence → CIP dispatch) → Connection Manager **or** tag service → `CipMap` →
`readPath`/`writePath` (force-aware) → CIP response → encapsulation encode →
socket. Nothing else in the app is aware EtherNet/IP exists.

## Error handling / edge cases

- Malformed encapsulation header / bad length → drop the connection's buffer or
  close, never throw.
- Request on an unregistered session handle → encapsulation error status.
- Unknown tag name / unexposed tag → CIP `0x05`.
- Write to a `ReadOnly` entry or a forced tag → refused with a visible status
  (never a silent success).
- Type mismatch on write → error status, tag unchanged.
- `SendUnitData` for an unknown connection id → error status.
- Oversized frame (beyond the configured max) → buffer cleared / connection
  closed rather than unbounded growth.
- Every codec entry point returns an error rather than throwing on garbage
  input — the host must never crash on hostile bytes.

## Testing

- **Pure:** encapsulation header + CPF round-trips for each command; EPATH
  symbol-segment encode/parse including **odd-length names (pad byte)** and
  multi-segment member paths; each CIP type's encode/decode incl. the
  FLOAT64→REAL narrowing; Forward Open allocating a deterministic connection id
  and Forward Close releasing it; Read/Write/Multiple-Service against a fixture
  tag database; unknown tag → `0x05`; **write to a forced tag refused**; write to
  a `ReadOnly` entry refused; malformed/truncated input never throws.
- **Host:** length-prefixed reassembly across fragmented and coalesced TCP
  chunks; two sessions isolated from each other; connected vs unconnected routing;
  session/connection cleanup on socket close.
- **Round-trip:** `CipProtocolConfig` additive — a project without the key loads
  disabled with port 44818; a configured one round-trips; default-projects
  round-trip/scan-equivalence unchanged.
- **Widget:** the EtherNet/IP card renders, toggles, and shows counters; no
  overflow at 320/360/1400.
- **E2E:** the `pycomm3` probe completes register → Forward Open → read → write →
  independent read-back (exact value) → Forward Close.
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`.

## Files

- **Create:** `mobile/lib/protocols/enip/enip_encap.dart`, `cip.dart`,
  `cip_connection.dart`, `cip_tags.dart`; `mobile/lib/models/cip_map.dart`;
  `mobile/lib/services/enip_host.dart`; `mobile/tool/enip_host_probe.dart`;
  `tool/py/requirements.txt`, `tool/py/enip_probe.py`, `tool/enip_e2e.sh`; plus
  their tests.
- **Modify:** `mobile/lib/models/protocol_settings.dart` (`CipProtocolConfig`),
  the Outbound Protocols screen (EtherNet/IP card), and the shell's
  protocol-lifecycle wiring (start/stop on project switch).
- **Docs:** `docs/protocols/ethernet-ip.md` (v1 scope, addressing, the v2
  deferrals and why, the E2E proof, the Python lane); `ROADMAP.md` (a new phase
  or a protocol-program section); `README.md` protocol bullet.

## Decomposition (plan-time)

**~6 tasks:** (1) encapsulation codec; (2) CIP + EPATH + types; (3) connection
manager (Forward Open/Close + routing); (4) tag services (Read/Write/Multiple)
+ `CipMap`; (5) `CipProtocolConfig` + host + UI + shell lifecycle; (6) Python
E2E lane + probe + full gate + docs.
