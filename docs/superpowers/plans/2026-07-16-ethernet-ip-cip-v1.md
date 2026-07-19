# EtherNet/IP + CIP Explicit Messaging (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host EtherNet/IP + CIP explicit messaging on TCP 44818 so a Logix-oriented client can read and write the app's tags **by symbolic name**.

**Architecture:** Pure codec layers (`enip_encap` → `cip` → `cip_connection` / `cip_tags`) under `protocols/enip/`, a `CipMap` exposure model mirroring `OpcuaMap`, a length-prefixed socket host mirroring the OPC UA host, an Outbound Protocols card, and the program's first **Python (pycomm3)** E2E probe.

**Tech Stack:** Flutter/Dart + a Python `pycomm3` E2E probe. `flutter test`, `flutter analyze`, `flutter build web --release`, `tool/enip_e2e.sh`.

## Global Constraints

- **ADR-010**: in-process, pure Dart, no companion process, no FFI.
- Pure Dart (no Flutter imports, no `dart:io`) in `mobile/lib/protocols/enip/`; `dart:io` confined to `mobile/lib/services/enip_host.dart`.
- **Deterministic**: no wall clock, no randomness in codec logic. Session handles and connection ids come from a **monotonic counter** so tests can predict them.
- Additive/backward-compatible: a project with no `ethernet_ip` key loads with the feature disabled (port 44818); no existing project's serialized form or scan sequence changes; default-projects round-trip/scan-equivalence stays green.
- **Force-aware writes**: a write to a forced tag is REFUSED with a visible CIP status (never a silent success), mirroring the OPC UA precedent.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- **No vendor branding** in code, UI, or docs: no "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"/"ControlLogix"/"CompactLogix"/"Allen-Bradley"/"Rockwell". Describe it as "EtherNet/IP + CIP explicit messaging"; "Logix-style symbolic tag" is acceptable only where naming the addressing style is technically necessary. No reverse-engineering wording — implemented from public EtherNet/IP + CIP specification material.
- **Codecs must never throw** on malformed/hostile input — return an error status instead. The host must not crash on garbage bytes.

## Key facts (verified)

- Protocol anatomy (all four shipped protocols): pure codec in `protocols/<name>/`, host in `services/<name>_host.dart` (only `dart:io`), map in `models/<name>_map.dart`, a `ProtocolSettings` entry + Outbound Protocols card, `tool/<name>_e2e.sh` real-client proof.
- **Host template — `mobile/lib/services/opcua_host.dart`** (length-prefixed, same shape as EtherNet/IP): `class _Connection` holds `final OpcUaServerSession session;` and `final List<int> _buffer = [];`; `onData` does `_buffer.addAll(data)` then loops: `if (_buffer.length < kMessageHeaderLen) break;` → read the little-endian size at bytes 4-7 → `if (_buffer.length < size) break;` → `final frame = Uint8List.fromList(_buffer.sublist(0, size)); _buffer.removeRange(0, size);` → dispatch. **Mirror this structure.**
- **Map template — `mobile/lib/models/opcua_map.dart`**: entries carry `tagName` + `access` (`'ReadOnly'` | `'ReadWrite'`), `fromJson` defaults `access` to `'ReadWrite'`; auto-population marks `root?.ioType == 'SimulatedOutput' || root?.access == 'ReadOnly'` as `ReadOnly`.
- **Config template — `OpcUaProtocolConfig`**: `enabled: j['enabled'] == true`, `port: (j['port'] as num?)?.toInt() ?? 4840`, `map`, all always emitted in `toJson`.
- App tag data types: `BOOL`, `INT16`, `INT32`, `INT64`, `FLOAT64`, `STRING`.
- Force-aware precedent (`protocols/opcua/opcua_services.dart` ~:585): an external write to a forced root tag returns `badUserAccessDenied` — deliberately visible, unlike the engines' silent skip.
- **Fixture-host constraint**: `mobile/tool/*_host_probe.dart` must **not** import `services/*_host.dart` (hosts extend `ChangeNotifier` → `dart:ui`, unavailable under plain `dart run`). They import the **pure** codec and re-implement only the small reassembly loop. `mobile/tool/` is analyzer-excluded.
- **E2E script contract** (`tool/modbus_e2e.sh`, `tool/opcua_e2e.sh`): start the Dart fixture host on a non-default port → wait for `READY` → run the probe → kill the host unconditionally (trap) → propagate the probe's exit code.
- **Reference client**: no EtherNet/IP Rust crate is vendored and none is API-verifiable offline. **Python 3.12.10 is present**; `pycomm3` is pip-installable. This workstream is the **first user of the Python probe lane**.

> **Wire-detail caveat (applies to every task):** CIP is a large specification. The constants and layouts below make the work concrete, but the **real-client E2E in Task 6 is the authority**. If an implementer finds observed client behaviour disagrees with this plan, the client wins — fix the code and report the deviation.

---

### Task 1: Encapsulation layer

**Files:**
- Create: `mobile/lib/protocols/enip/enip_encap.dart`
- Test: `mobile/test/enip_encap_test.dart`

**Interfaces:**
- Produces: `EnipHeader` (`command`, `length`, `sessionHandle`, `status`, `senderContext` (8 bytes), `options`), `EnipHeader? parseEnipHeader(Uint8List)`, `Uint8List buildEnipFrame(EnipHeader, Uint8List data)`, CPF item helpers (`CpfItem { int typeId; Uint8List data; }`, `List<CpfItem>? parseCpf(Uint8List)`, `Uint8List buildCpf(List<CpfItem>)`), plus command constants and `const int kEnipHeaderLen = 24;`.

**Context:** Header is **little-endian** throughout: `command` u16, `length` u16 (bytes of data AFTER the header), `sessionHandle` u32, `status` u32, `senderContext` 8 raw bytes (echoed verbatim in the reply), `options` u32. Commands: `NOP 0x00`, `ListIdentity 0x63`, `RegisterSession 0x65`, `UnRegisterSession 0x66`, `SendRRData 0x6F`, `SendUnitData 0x70`. CPF = item count u16, then per item: `typeId` u16, `length` u16, data. Item types: Null Address `0x0000`, Connected Address `0x00A1`, Connected Data `0x00B1`, Unconnected Data `0x00B2`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/enip_encap_test.dart` covering:
- `parseEnipHeader` on a hand-built 24-byte header returns the exact field values (little-endian), and `senderContext` is the exact 8 bytes.
- `buildEnipFrame` round-trips through `parseEnipHeader`, and sets `length` to the data length.
- `parseEnipHeader` returns `null` for a buffer shorter than 24 bytes (no throw).
- `parseCpf`/`buildCpf` round-trip a 2-item list (Null Address + Unconnected Data); `parseCpf` returns `null` on a truncated item (no throw).
- A `RegisterSession` request body (protocol version u16 = 1, options u16 = 0) parses, and the built reply echoes the session handle and sender context.

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/enip_encap_test.dart`

- [ ] **Step 3: Implement** `enip_encap.dart` (pure; imports `dart:typed_data` only). All parse functions return nullable and never throw. Document the little-endian convention and that `length` excludes the header.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
cd mobile && flutter analyze lib/protocols/enip/enip_encap.dart test/enip_encap_test.dart
git add mobile/lib/protocols/enip/enip_encap.dart mobile/test/enip_encap_test.dart
git commit -m "feat(enip): EtherNet/IP encapsulation header + CPF codec (pure)"
```

---

### Task 2: CIP messaging + EPATH + data types

**Files:**
- Create: `mobile/lib/protocols/enip/cip.dart`
- Test: `mobile/test/cip_test.dart`

**Interfaces:**
- Produces: `CipRequest { int service; List<CipPathSegment> path; Uint8List data; }`, `CipResponse { int service; int generalStatus; Uint8List data; }`, `CipRequest? parseCipRequest(Uint8List)`, `Uint8List buildCipResponse(CipResponse)`, EPATH: `CipPathSegment` (symbol name | class | instance | attribute), `List<CipPathSegment>? parseEpath(Uint8List, int wordLen)`, `Uint8List buildEpath(List<CipPathSegment>)`, type helpers `int? cipTypeForTagType(String)`, `Uint8List? encodeCipValue(int typeCode, dynamic value)`, `dynamic decodeCipValue(int typeCode, Uint8List)`, plus service + status constants.

**Context:**
- CIP request: `service` u8, `pathWords` u8 (path length in **16-bit words**), path bytes, then service data.
- CIP response: `service | 0x80` u8, reserved `0x00` u8, `generalStatus` u8, `additionalStatusWords` u8 (0 here), then data.
- **EPATH ANSI Extended Symbol segment**: `0x91`, `nameLen` u8, name bytes, **pad byte if `nameLen` is odd**. Logical segments: Class `0x20` + u8 (or `0x21` + u16), Instance `0x24` + u8 (or `0x25` + u16), Attribute `0x30` + u8.
- Type codes: `BOOL 0xC1`, `INT 0xC3`, `DINT 0xC4`, `LINT 0xC5`, `REAL 0xCA`. App-type mapping: `BOOL→0xC1`, `INT16→0xC3`, `INT32→0xC4`, `INT64→0xC5`, `FLOAT64→0xCA` (encoded as IEEE-754 **single** — document the narrowing). `STRING → null` (unsupported in v1).
- Statuses: `0x00` success, `0x04` path segment error, `0x05` path destination unknown, `0x08` service not supported, `0x0A` embedded list error, `0x13` not enough data, `0x1E` embedded service error, `0x0F` privilege violation (used for a refused write).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/cip_test.dart` covering:
- `parseCipRequest` on a hand-built Read Tag request (service `0x4C`, symbol path `Motor_Run`, data = element count 1) returns service `0x4C`, one symbol segment with name `Motor_Run`, and the data bytes.
- **Odd-length name padding**: a symbol segment for a 9-character name round-trips through `buildEpath`/`parseEpath` and occupies an even byte count.
- Multi-segment member path (`Tank.Level`) parses to two ordered symbol segments.
- `buildCipResponse` sets `service | 0x80` and the general status; round-trips.
- `cipTypeForTagType` mapping for all six app types, with `STRING` → `null`.
- `encodeCipValue`/`decodeCipValue` round-trip each supported type; `REAL` narrows a double to single precision (assert `closeTo`); wrong-length input decodes to `null` rather than throwing.
- `parseCipRequest` / `parseEpath` return `null` on truncated input (no throw).

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/cip_test.dart`

- [ ] **Step 3: Implement** `cip.dart` (pure; imports `dart:typed_data` and `dart:convert` for ASCII names only). Never throw.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/enip/cip.dart mobile/test/cip_test.dart
git commit -m "feat(enip): CIP request/response, EPATH symbol segments, and data-type codec"
```

---

### Task 3: Connection manager (Forward Open / Forward Close)

**Files:**
- Create: `mobile/lib/protocols/enip/cip_connection.dart`
- Test: `mobile/test/cip_connection_test.dart`

**Interfaces:**
- Produces: `CipConnection { int connectionIdOT; int connectionIdTO; int connectionSerial; int vendorId; int originatorSerial; int sequenceCount; }`, `class CipConnectionManager { CipResponse forwardOpen(CipRequest); CipResponse forwardClose(CipRequest); CipConnection? byTargetId(int); void releaseAll(); }`.

**Context:** Connection Manager is class `0x06`, instance 1. **Forward Open service `0x54`**, **Forward Close `0x4E`**, reached over UCMM (`SendRRData`). The Forward Open request carries priority/tick time, timeout ticks, O→T and T→O connection ids, connection serial number, originator vendor id, originator serial number, timeout multiplier, reserved, O→T RPI + params, T→O RPI + params, transport class/trigger, and a connection path. The reply carries O→T and T→O connection ids, connection serial, vendor id, originator serial, actual O→T and T→O RPIs, and an application-reply size.

**Determinism requirement:** allocate the T→O connection id from a **monotonic counter starting at a documented constant** — never randomness — so tests assert exact ids.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/cip_connection_test.dart` covering:
- `forwardOpen` on a well-formed request returns success, echoes the O→T id, connection serial, vendor id and originator serial, and allocates a **predictable** T→O id; a second Forward Open allocates the next id.
- `byTargetId` resolves the allocated connection; an unknown id returns `null`.
- `forwardClose` matching serial/vendor/originator releases it (`byTargetId` then returns `null`) and returns success; closing an unknown connection returns a non-zero status rather than throwing.
- A truncated Forward Open request returns an error status (no throw).
- `releaseAll` clears everything (used on session/socket teardown).

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement** (pure). **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/enip/cip_connection.dart mobile/test/cip_connection_test.dart
git commit -m "feat(enip): CIP connection manager — Forward Open/Close with deterministic ids"
```

---

### Task 4: Tag services + `CipMap`

**Files:**
- Create: `mobile/lib/protocols/enip/cip_tags.dart`, `mobile/lib/models/cip_map.dart`
- Test: `mobile/test/cip_tags_test.dart`, `mobile/test/cip_map_test.dart`

**Interfaces:**
- Produces: `CipMapEntry { String tagName; String access; }`, `class CipMap { List<CipMapEntry> entries; CipMap.fromJson/toJson; static CipMap autoPopulate(PlcProject); }`; and `CipResponse dispatchCipService(PlcProject project, CipMap map, CipRequest req)` handling Read Tag `0x4C`, Write Tag `0x4D`, and Multiple Service Packet `0x0A`.

**Context:**
- `CipMap` mirrors `models/opcua_map.dart` exactly (entries with `tagName` + `access`, `fromJson` defaulting `access` to `'ReadWrite'`, auto-population forcing `ReadOnly` for `ioType == 'SimulatedOutput'`, the reserved `System` tag, or `access == 'ReadOnly'`). **v1 additionally SKIPS tags whose data type is `STRING`** during auto-population — Logix strings are structs needing the v2 Template Object — and documents why in the file header.
- **Read Tag `0x4C`**: path = symbol segment(s); data = element count u16. Reply = type code u16 + packed value(s).
- **Write Tag `0x4D`**: path = symbol segment(s); data = type code u16 + element count u16 + value bytes.
- **Multiple Service Packet `0x0A`**: path = Message Router (class `0x02`, instance `0x01`); data = service count u16, then `count` u16 offsets (relative to the start of the offset list), then the embedded requests. Reply mirrors that layout with each embedded **response**. One embedded failure returns its own status without failing the batch.
- Resolution: symbol name → `CipMap` entry → `readPath`/`writePath` (`models/tag_resolver.dart`). Unknown or unexposed name → `0x05`. Write to a `ReadOnly` entry → `0x0F`. **Write to a forced tag → `0x0F` (visible refusal, never a silent success)** — check the root tag's `isForced` exactly as `opcua_services.dart` does.

- [ ] **Step 1: Write the failing tests**

`cip_map_test.dart`: auto-population marks `SimulatedOutput`/`System`/`ReadOnly` tags as `ReadOnly` and others `ReadWrite`; **`STRING` tags are excluded**; `fromJson`/`toJson` round-trip; a JSON entry without `access` defaults to `ReadWrite`.

`cip_tags_test.dart` (against a fixture `PlcProject`): Read Tag returns the correct type code and value for each supported type; Write Tag updates the tag and a subsequent read returns the new value; unknown tag name → `0x05`; unexposed tag → `0x05`; write to a `ReadOnly` entry → `0x0F` with the tag unchanged; **write to a forced tag → `0x0F` with the tag unchanged**; type-mismatched write → error, tag unchanged; Multiple Service Packet with two reads returns both replies in order; a batch containing one bad embedded request still returns the good one's data with per-item statuses; malformed request data never throws.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.** **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/enip/cip_tags.dart mobile/lib/models/cip_map.dart mobile/test/cip_tags_test.dart mobile/test/cip_map_test.dart
git commit -m "feat(enip): CIP tag services (read/write/multi) + CipMap exposure model"
```

---

### Task 5: Config, socket host, UI card, shell lifecycle

**Files:**
- Create: `mobile/lib/services/enip_host.dart`
- Modify: `mobile/lib/models/protocol_settings.dart`, the Outbound Protocols screen (`mobile/lib/screens/gateway_screen.dart`), and the shell's protocol lifecycle wiring
- Test: `mobile/test/enip_host_test.dart`, plus cases in `protocol_settings_test.dart` and `gateway_screen_test.dart`

**Interfaces:**
- Produces: `CipProtocolConfig { bool enabled; int port; CipMap map; }` (json `ethernet_ip`: `enabled`/`port`/`map`), and `class EnipHost extends ChangeNotifier { Future<void> start(...); Future<void> stop(); }`.

**Context:** Mirror `services/opcua_host.dart`'s `_Connection` structure exactly — `List<int> _buffer`, `onData` accumulating then looping on the **length-prefixed** header (here: need ≥ `kEnipHeaderLen` (24) bytes → total = `24 + header.length` → wait → slice → `removeRange` → dispatch), bounded by a documented max frame size. Per-socket state: session handle (allocated from a monotonic counter) + a `CipConnectionManager`. Route `SendRRData` → UCMM dispatch (Connection Manager or tag service); `SendUnitData` → look up the connection by id, track/echo the sequence count, then dispatch. Release the session's connections on socket close. Follow the other hosts' start/stop lifecycle (stopped on every project switch) and expose status counters.

The UI card mirrors the Modbus/OPC UA cards (enable toggle, port field defaulting to 44818, counters, and a link to the exposed-tag map editor if the other cards have one).

- [ ] **Step 1: Write the failing tests**

- `protocol_settings_test.dart`: a project JSON without `ethernet_ip` loads with the feature disabled and port 44818; a configured block round-trips.
- `enip_host_test.dart` (drive a real `ServerSocket`, mirroring `modbus_host_test.dart`/`opcua_host_test.dart`): RegisterSession returns a session handle; an unconnected Read Tag over `SendRRData` returns the tag's value; a **fragmented** frame (split mid-header and mid-body) reassembles; two **coalesced** frames both answer; a request on an unregistered session handle gets an error status; two sockets get isolated sessions.
- `gateway_screen_test.dart`: the EtherNet/IP card renders with its enable toggle and port field; no overflow at 320 and 1400.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.** **Step 4: Run — expect PASS.**

- [ ] **Step 5: Full-suite check** — `cd mobile && flutter test` must be green (additive; no existing project or test altered). `cd mobile && flutter analyze` clean.

- [ ] **Step 6: commit**

```bash
git add mobile/lib/services/enip_host.dart mobile/lib/models/protocol_settings.dart mobile/lib/screens/gateway_screen.dart mobile/test/
git commit -m "feat(enip): socket host, EtherNet/IP protocol config, and Outbound Protocols card"
```

---

### Task 6: Python E2E lane + probe + gate + docs

**Files:**
- Create: `mobile/tool/enip_host_probe.dart`, `tool/py/requirements.txt`, `tool/py/enip_probe.py`, `tool/enip_e2e.sh`
- Docs: `docs/protocols/ethernet-ip.md`, `ROADMAP.md`, `README.md`

**Context:** This establishes the **Python probe lane** for the whole program (S7comm/FINS/SLMP/BACnet reuse it), so make the shape reusable and document it.

- [ ] **Step 1: Dart fixture host**

`mobile/tool/enip_host_probe.dart`, usage `dart run tool/enip_host_probe.dart <port>`. **It must NOT import `services/enip_host.dart`** (`ChangeNotifier` → `dart:ui`, unavailable under plain `dart run`) — import the **pure** codec and re-implement only the reassembly loop, exactly as `modbus_host_probe.dart` and `opcua_host_probe.dart` do (read their headers). Seed a small fixture project with tags of each supported type. Print `READY` on the established contract.

- [ ] **Step 2: Python lane + probe**

- `tool/py/requirements.txt` — **pin the exact `pycomm3` version you install** and record it in your report (do not leave it floating).
- `tool/py/enip_probe.py` — a real `pycomm3` client using its **lower-level generic CIP messaging** (`CIPDriver` / `generic_message`), NOT `LogixDriver` (which requires the tag-list upload deferred to v2). It must: register a session, **Forward Open**, **read** a tag, **write** it, **independently read back** the exact written value, and **Forward Close**. Print a clear `ENIP PROBE PASS` and exit 0 on success; exit non-zero with a specific message on any mismatch. Bound the socket operations with timeouts so it cannot hang.
- If `pycomm3`'s generic-messaging API cannot drive one of these steps as expected, **report it verbatim** rather than weakening the probe — the roadmap's whole point is real third-party verification.

- [ ] **Step 3: E2E script**

`tool/enip_e2e.sh` honouring the existing contract: create/reuse a venv under `tool/py/`, `pip install -r tool/py/requirements.txt` (quietly), start `mobile/tool/enip_host_probe.dart <port>` on a non-default port, wait for `READY`, run the probe, kill the Dart host unconditionally (trap), propagate the probe's exit code. Header comment explaining what it proves **and** that this is the shared Python-lane pattern for later protocols.

- [ ] **Step 4: Run the E2E** — `bash tool/enip_e2e.sh` must pass. Also re-run `bash tool/modbus_e2e.sh` and `bash tool/opcua_e2e.sh` to confirm nothing regressed.

- [ ] **Step 5: Full gate** — `cd mobile && flutter analyze` (zero warnings); `cd mobile && flutter test` (ALL pass — record the exact count; `gateway_screen_test.dart`'s "Start hosting…" is known-flaky, pre-existing only if it passes in isolation); `cd mobile && flutter build web --release`.

- [ ] **Step 6: Docs**

- `docs/protocols/ethernet-ip.md`: v1 scope; symbolic tag addressing; unconnected + Forward Open messaging; supported services and types (incl. the FLOAT64→REAL narrowing); the `CipMap` exposure model and force-aware write refusal; **what is deferred to v2 and why** (Symbol/Template browse, `STRING` as a struct, Identity); the E2E proof and how to run it; and the Python lane setup.
- `ROADMAP.md`: record the protocol-expansion program and this workstream.
- `README.md`: add EtherNet/IP to the protocol bullet.
- No vendor branding; no reverse-engineering wording.

- [ ] **Step 7: Commit**

```bash
git add mobile/tool/enip_host_probe.dart tool/py tool/enip_e2e.sh docs ROADMAP.md README.md
git commit -m "test+docs(enip): pycomm3 E2E proof, Python probe lane, and docs"
```

---

## Self-Review

**Spec coverage:** Component 1 encapsulation → Task 1 ✓; Component 2 CIP/EPATH/types → Task 2 ✓; Component 3 connection manager → Task 3 ✓; Component 4 tag services + `CipMap` → Task 4 ✓; Component 5 config/host/UI → Task 5 ✓; Component 6 Python lane + probe → Task 6 ✓. Deferrals (browse, `STRING`, implicit I/O) are stated in Tasks 4 and 6 and documented. Force-aware refusal, determinism, and additive persistence appear as binding test requirements in Tasks 3-5.

**Placeholder scan:** No TBDs. The one deliberately unresolved value — the pinned `pycomm3` version — is explicitly assigned to Task 6 Step 2 with an instruction to record the actual version rather than leave it floating. Wire constants are stated concretely, with a single global caveat that the real-client E2E is the authority (honest about CIP's size rather than pretending certainty).

**Type consistency:** `EnipHeader`/`CpfItem` (Task 1) are consumed by the host (Task 5). `CipRequest`/`CipResponse`/`CipPathSegment` + type helpers (Task 2) are consumed by the connection manager (Task 3), tag services (Task 4), and the host. `CipMap`/`CipMapEntry` (Task 4) are consumed by `CipProtocolConfig` (Task 5) and the map editor. `CipConnectionManager.byTargetId` (Task 3) is what the host's `SendUnitData` routing calls. `dispatchCipService(project, map, req)` (Task 4) is the single entry point the host uses for both UCMM and connected traffic.

**Note for the executor:** the binding properties are (a) codecs **never throw** on malformed input; (b) session handles and connection ids are **monotonic, not random**, so tests assert exact values; (c) a write to a **forced** or **ReadOnly** tag is refused with a visible status and leaves the tag unchanged; (d) the host reassembles fragmented and coalesced frames correctly; (e) persistence is additive (no `ethernet_ip` key → disabled, port 44818); and (f) **a real `pycomm3` client completes read → write → independent read-back**. Tasks 1-4 are pure and independently testable; if Task 6's probe contradicts a wire assumption, fix the codec and report it.
