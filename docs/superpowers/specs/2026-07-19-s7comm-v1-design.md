# Siemens S7comm (device side) — Design Spec

**Date:** 2026-07-19
**Status:** Approved (design)
**Workstream:** Protocol expansion program, **workstream 3 of 6** (see
`2026-07-16-protocol-expansion-program-roadmap.md`).

## Goal

Host **S7comm on TCP 102** in-process so a SCADA S7 driver can read and write
the app's tags by **memory area + byte offset**. Sixth protocol in the pure-Dart
suite, after OPC UA, Modbus TCP, MQTT/Sparkplug B, DNP3 and EtherNet/IP.

S7comm is widely deployed in European process plants, and SCADA and HMI
packages commonly ship a driver for it, so serving it materially widens the
range of clients that can talk to this simulator.

## Reference client — CONFIRMED BEFORE PLANNING

The program roadmap requires each protocol's spec to confirm its reference
client *before* the plan is written. Verified on this machine, not assumed:

- `python-snap7==3.1.0` installs from PyPI and imports cleanly on Windows.
- **Correction, established during implementation:** this spec originally
  recorded that a *bundled native snap7 C library* loads on Windows, and treated
  that as the main risk. That was wrong. Inspecting the installed 3.1.0 package
  shows a `py3-none-any` wheel with `Root-Is-Purelib: true`, no `.dll`/`.so`/
  `.dylib` in its RECORD, an ordinary `socket.socket` in `snap7/connection.py`,
  and `snap7/s7protocol.py` building and parsing S7 PDUs itself with `struct`.
  `ctypes` appears only for buffer types in a legacy API signature — there is no
  `LoadLibrary` anywhere. **It is a pure-Python reimplementation.**
  This *strengthens* the proof rather than weakening it: the bytes our host is
  judged against come from a genuinely independent second implementation of the
  wire format, not from a C core we might both be deriving from.
- `snap7.client.Client` exposes exactly the operations v1 needs:
  - `connect(address: str, rack: int, slot: int, tcp_port: int = 102)`
  - `read_area(area, db_number, start, size, word_len=None) -> bytearray`
  - `write_area(area, db_number, start, data, word_len=None) -> int`
  - `db_read` / `db_write`
- `snap7.type.Area` provides `DB`, `MK`, `PE`, `PA`, `TM`, `CT`.

This reuses the **Python probe lane** established by WS2 (`tool/py/`), which is
the second of the four protocols the roadmap provisioned it for.

## The central difficulty (and what makes this unlike the shipped five)

The five shipped protocols address data **granularly**: OPC UA and CIP by name,
Modbus by discrete register, DNP3 by point. **S7 addresses a byte range**, and
real S7 drivers issue *optimized block reads* — a driver asks for "DB1 bytes
0..40" in a single request rather than one request per tag.

So the host must **materialize a packed byte image** of each area from the
app's named tags, serve slices of it, and decode written slices back onto the
tags they overlap. No shipped protocol has needed this. It is the highest-risk
component and gets its own pure, independently testable unit.

## Decisions taken (user-approved)

1. **Areas in v1: DB, M, I, Q.** These are what SCADA drivers actually poll and
   they map onto the app's tag database and its Simulated I/O concept. Timers
   (T) and counters (C) are deferred: they use S5TIME/BCD word encodings with
   no natural equivalent in this app.
2. **Unmapped bytes inside a requested range read as `0x00`, and writes to them
   are discarded.** This mirrors a real PLC, where a DB is a fixed-size buffer
   whose unused bytes hold zero. Refusing ranges that cover unmapped bytes
   would break the standard block-read pattern and most drivers would fail to
   poll at all.
3. **The real-client probe runs EARLY** — task 3 of 5, immediately after
   framing and negotiation, before any read/write logic exists. This inverts
   the plan template deliberately. In WS2 a fundamental wire bug (Forward Open
   returning the two connection ids in the wrong direction) hid behind a fully
   green 25-test unit suite until the final task.

## Non-goals / YAGNI

- **No S7 STRING** in v1 — an S7 `STRING` is a struct with max-length and
  actual-length header bytes. Same deferral, for the same reason, as CIP's
  STRING in WS2.
- **No timers/counters (T/C) areas.**
- **No PLC control services** — no start/stop, no block upload/download, no
  directory listing. This is a data-access target, not a programming target.
- **No S7-1500 optimized-block access** (that path needs a different addressing
  model entirely). v1 presents a classic, non-optimized address layout.
- **No serial/MPI/PPI transport** — out of scope for all six protocols per the
  roadmap; effectively impossible on iOS.

## Global Constraints

- **ADR-010**: hosted in-process, pure Dart, no companion process, no FFI.
- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/protocols/s7/`; `dart:io`
  confined to `mobile/lib/services/s7_host.dart`.
- Deterministic: no wall clock, no randomness in codec logic.
- **Additive/backward-compatible**: a project with no `s7comm` key loads with
  the feature disabled at port 102; no existing serialized form or scan
  behaviour changes; default-projects round-trip and scan-equivalence stay green.
- **Force-aware writes**: a write landing on a *forced* or `ReadOnly` tag is
  refused, tag unchanged. (See the WS2 lesson under "Risks".)
- Codecs must **never throw** on malformed or hostile input.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No competitor-tooling branding in code, UI, or docs: no "OpenPLC"/"Beremiz"/
  "CODESYS"/"RSLogix"/"SIMATIC"/"STEP 7"/"TIA Portal". No reverse-engineering
  wording — implemented from public S7comm/RFC 1006 specification material.
  **Carve-out, matching the "Logix-style" precedent from WS2:** `S7comm` is a
  protocol name and is used freely, as `Modbus`, `DNP3`, `OPC UA` and
  `EtherNet/IP` already are. Naming a controller family (`S7-300`, `S7-1500`)
  is acceptable **only** where a technical distinction genuinely requires it —
  e.g. explaining why optimized-block access is out of scope — and never as a
  claim of compatibility with, or endorsement by, any vendor. Prefer describing
  the addressing generically as "memory area + byte offset".

> **ENDIANNESS WARNING — the single most likely source of a wire bug.**
> **S7comm is BIG-ENDIAN throughout**: the TPKT length, every multi-byte S7
> header and parameter field, and all encoded values. The immediately preceding
> workstream (EtherNet/IP) was little-endian everywhere, and Modbus RTU before
> it mixed conventions. Every codec function must state its endianness in its
> doc comment, and tests must assert byte order explicitly against hand-built
> buffers rather than only round-tripping.

## Component 1 — TPKT + COTP framing (`protocols/s7/tpkt_cotp.dart`)

Pure; `dart:typed_data` only.

- **TPKT (RFC 1006)**: `version 0x03`, `reserved 0x00`, `length` u16
  **big-endian** counting the *whole* packet including the 4-byte TPKT header.
  This length field is what the socket host uses to delimit frames — the same
  length-prefixed reassembly shape as the OPC UA and EtherNet/IP hosts.
- **COTP (ISO 8073)**:
  - **Connection Request (CR)**, PDU type `0xE0`: length indicator, dest ref
    u16, src ref u16, class/option, then variable parameters — `0xC1` source
    TSAP, `0xC2` destination TSAP, `0xC0` TPDU size.
  - **Connection Confirm (CC)**, PDU type `0xD0`: same shape, echoing TSAPs.
  - **Data (DT)**, PDU type `0xF0`: length indicator `0x02`, then the
    TPDU-number/EOT byte (`0x80` = last unit).

**Rack/slot handling:** the destination TSAP encodes rack and slot. v1 **accepts
any rack/slot permissively** and echoes the client's TSAPs in the CC. This is a
simulator; rejecting a mismatched rack/slot produces a confusing "connection
refused" failure mode with no diagnostic value. The accepted values are surfaced
in the host's status for visibility.

## Component 2 — S7 PDU + Setup Communication (`protocols/s7/s7_pdu.dart`)

Pure. All fields **big-endian**.

- **Header**: `protocolId 0x32`, `rosctr` (`0x01` Job, `0x02` Ack, `0x03`
  Ack_Data, `0x07` Userdata), `redundancyId` u16, `pduReference` u16,
  `parameterLength` u16, `dataLength` u16 — **plus `errorClass` u8 and
  `errorCode` u8 present ONLY on `Ack_Data`** (a 12-byte header instead of 10).
  Getting that conditional length wrong shifts every following byte.
- **Setup Communication** (`0xF0`): reserved byte, max AmQ calling u16, max AmQ
  called u16, **PDU length** u16. The server negotiates **down** to the smaller
  of its own maximum and the client's proposal, and every later response must
  respect the agreed size.
- **Read Var** (`0x04`) / **Write Var** (`0x05`) parameter framing: function
  code, item count u8, then per-item specifications.
- **Item specification**: `0x12` (variable specification), length of what
  follows (`0x0A`), syntax id `0x10` (S7ANY), transport size, count u16, DB
  number u16, area u8, and a **24-bit (3-byte) address** encoding
  `byteOffset * 8 + bitOffset`.
- **Area codes**: `PE (inputs) 0x81`, `PA (outputs) 0x82`, `MK (merker) 0x83`,
  `DB 0x84`.
- **Item transport sizes**: `BIT 0x01`, `BYTE 0x02`, `CHAR 0x03`, `WORD 0x04`,
  `INT 0x05`, `DWORD 0x06`, `DINT 0x07`, `REAL 0x08`.
- **Response data-item encoding**: return code u8, transport size u8, length
  u16, then data padded to an even byte count. **The length field's UNIT
  depends on the transport size** — bits for `0x03` (BIT) and `0x04`
  (BYTE/WORD), bytes for `0x09` (octet string). This unit switch is a classic
  S7 implementation error and must be tested both ways.
- **Return codes**: `0xFF` success, `0x0A` object does not exist, `0x05`
  address out of range, `0x03` access denied.

**A read exceeding the negotiated PDU size returns an S7 error rather than
silently truncating** — silent truncation would hand a driver short data it
would interpret as real values.

## Component 3 — Real-client probe, EARLY (`tool/py/s7_probe.py`, `tool/s7_e2e.sh`)

Runs as **task 3 of 5**, proving the connect path before read/write logic
exists. At this stage it asserts: TCP connect → COTP CR/CC → S7 Setup
Communication negotiation completes, i.e. `python-snap7`'s `Client.connect()`
returns successfully and `get_connected()` is true. Task 5 extends the same
probe to read → write → independent read-back.

Reuses WS2's lane and contract exactly: venv under `tool/py/`, **exactly pinned**
`python-snap7==3.1.0` added to `requirements.txt`, and `tool/s7_e2e.sh` doing
start fixture host → wait `READY` → run probe → unconditional teardown (trap) →
propagate exit code.

The Dart fixture host `mobile/tool/s7_host_probe.dart` **must not import
`services/s7_host.dart`** (hosts extend `ChangeNotifier` → `dart:ui`, which is
unavailable under plain `dart run`); it imports the pure codec and re-implements
the small reassembly loop, exactly as the three existing probes do.

## Component 4 — Area image + `S7Map` (`protocols/s7/s7_area_image.dart`, `models/s7_map.dart`)

**`S7MapEntry { tag, area, dbNumber, byteOffset, bitOffset, access }`** —
mirroring `ModbusMapEntry`'s established shape (`tag`/`table`/`address`/`access`),
since Modbus solves the same named-tag ↔ numeric-address problem.
`access` is `'ReadOnly'` | `'ReadWrite'`, defaulting to `'ReadWrite'` when
absent from JSON. `S7Map.autoGenerate(project)` packs tags densely into `DB1`
with natural alignment (2-byte types on even offsets, 4- and 8-byte types on
4-byte boundaries), marks `SimulatedOutput` / `System` / `ReadOnly` tags as
`ReadOnly`, and **skips `STRING`** tags.

**`s7_area_image.dart`** is the new unit, and pure:

- `Uint8List readAreaImage(project, map, area, dbNumber, startByte, length)` —
  materializes the requested slice, encoding each overlapping mapped tag at its
  offset. **Unmapped bytes are `0x00`.**
- `List<S7WriteResult> applyAreaWrite(project, map, area, dbNumber, startByte, Uint8List data)`
  — decodes the slice and writes each fully-covered mapped tag. Bytes covering
  no tag are **discarded**. A tag only **partially** covered by the range is
  **not** written (a partial write would corrupt a multi-byte value), and that
  is reported rather than silently skipped.
- Force-aware: a write landing on a **forced** or `ReadOnly` tag is refused and
  the tag left unchanged. **The refusal is checked against the ROOT tag** so a
  member path cannot bypass it — this is the WS2 Critical, restated as a
  requirement rather than left to be rediscovered.

**Type mapping** (app type → S7):

| App | S7 | Bytes |
|---|---|---|
| `BOOL` | BOOL | 1 bit |
| `INT16` | INT | 2 |
| `INT32` | DINT | 4 |
| `INT64` | LINT | 8 |
| `FLOAT64` | REAL | 4 |
| `STRING` | *(skipped in v1)* | — |

**`FLOAT64 → REAL` is a narrowing conversion** to IEEE-754 single precision, as
in CIP. It must be documented and asserted with a tolerance *and* an
`isNot(equals(...))` check, so a non-narrowing implementation fails the test.

## Component 5 — Config, host, UI (`services/s7_host.dart`)

- **`S7ProtocolConfig { enabled, port, map }`**, JSON key `s7comm`, default port
  **102**, following `OpcUaProtocolConfig`/`CipProtocolConfig` exactly
  (`enabled: j['enabled'] == true`, `port: (j['port'] as num?)?.toInt() ?? 102`,
  all fields always emitted in `toJson`).
- **`S7Host extends ChangeNotifier`** — the only `dart:io` file. Length-prefixed
  reassembly driven by the TPKT length field, mirroring `enip_host.dart` /
  `opcua_host.dart`: accumulate, break if fewer than 4 bytes, read the
  big-endian length, break if the frame is incomplete, slice, `removeRange`,
  dispatch. Bounded by a documented max frame size. Per-socket state: the COTP
  connection state and the negotiated PDU size.
- An **Outbound Protocols** card (enable, port, counters) matching the existing
  five, and shell lifecycle wiring so the host is **stopped on every project
  switch** — all six paths, as EtherNet/IP does.

> **Port 102 is privileged on Linux/macOS** (<1024). Desktop hosting there may
> require elevation. The UI must surface a bind failure clearly rather than
> appearing to start, and the docs must state it. Android/Windows are unaffected
> in practice. The port is user-editable, so a non-privileged port is available
> as a workaround.

## Data flow

TCP bytes → TPKT/COTP reassembly (`s7_host`) → COTP CR handled inline, DT
payload → S7 PDU parse → Setup Communication *or* Read/Write Var → for
Read/Write, `s7_area_image` materializes or applies the byte range against the
project's tags via `S7Map` → response PDU → COTP DT → TPKT → socket.

## Error handling / edge cases

- Malformed TPKT/COTP/S7 → no throw; drop the frame or return an S7 error PDU,
  connection kept usable where the framing is still trustworthy.
- Hostile TPKT length (larger than the max frame) → connection closed rather
  than allocating.
- Fragmented and coalesced TCP delivery → handled by the accumulate-then-slice
  loop; both must be tested, with an exact reply-count assertion to catch
  double-dispatch.
- Read/write of an unmapped or out-of-range address → per-item return code
  (`0x0A` / `0x05`), not a whole-PDU failure: **one bad item must not fail the
  other items in a multi-item request.**
- A write refused for force/read-only → `0x03` access denied, tag unchanged.
- Request exceeding the negotiated PDU size → S7 error.

## Testing

- **Pure unit tests** per component, asserting **byte order explicitly** against
  hand-built big-endian buffers (not only round-trips, which cancel endianness
  errors).
- The `Ack_Data` 12-byte vs 10-byte header conditional, and the transport-size
  length-unit switch (bits vs bytes), each get dedicated tests.
- Area image: unmapped gaps read zero; writes to gaps discarded; partially
  covered tags not written; bit addressing; each type's width and encoding; the
  `FLOAT64 → REAL` narrowing asserted so a non-narrowing implementation fails.
- Force/read-only refusal, **including via a member path beneath a forced root**.
- Host: fragmented and coalesced frames, two isolated sockets, malformed input.
- Persistence: a project JSON with no `s7comm` key loads disabled at port 102.
- **Real client**: `python-snap7==3.1.0` connect + negotiate (task 3), extended
  to read → write → independent read-back (task 5).
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`,
  plus re-running `tool/enip_e2e.sh`, `tool/modbus_e2e.sh`, `tool/opcua_e2e.sh`
  to confirm no regression.

## Files

- **Create:** `mobile/lib/protocols/s7/tpkt_cotp.dart`, `s7_pdu.dart`,
  `s7_area_image.dart`; `mobile/lib/models/s7_map.dart`;
  `mobile/lib/services/s7_host.dart`; `mobile/tool/s7_host_probe.dart`;
  `tool/py/s7_probe.py`; `tool/s7_e2e.sh`; matching tests.
- **Modify:** `mobile/lib/models/protocol_settings.dart` (`S7ProtocolConfig`),
  the Outbound Protocols screen (new card/tab), the workspace shell (lifecycle),
  `tool/py/requirements.txt` (pin `python-snap7==3.1.0`).
- **Docs:** `docs/protocols/s7comm.md`; `ROADMAP.md`; `README.md`.

## Risks

- **Fidelity, not framing, is the risk** — as with every protocol in this
  program. The early probe (decision 3) exists precisely to surface this while
  it is still cheap.
- **The WS2 bug class will recur**: a codec that is perfectly self-consistent
  yet wrong on the wire, with a green unit suite. Mitigations: the early probe,
  explicit byte-order assertions against hand-built buffers, and the standing
  rule that **when the real client disagrees with our code, the client is
  right**.
- **The area-image unit is where the subtle bugs will live** — alignment,
  partial coverage, bit offsets, and the gap semantics. It is pure and
  independently testable specifically so it can be attacked hard in isolation.
- **Port 102 privilege** on Linux/macOS desktop (see Component 5).

## Decomposition (plan-time)

**5 tasks**, deliberately ordered to put the real client early:

1. TPKT + COTP framing (CR/CC/DT) with byte-order tests.
2. S7 PDU header + Setup Communication negotiation.
3. **Socket host skeleton + Dart fixture probe + `python-snap7` E2E proving
   connect and negotiate** — the early real-client gate.
4. `S7Map` + area image (materialize/apply, gaps, bits, types, force-aware) +
   Read Var / Write Var services.
5. `S7ProtocolConfig` + UI card + shell lifecycle + full E2E (read/write/
   read-back) + full gate + docs.
