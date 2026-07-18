# Modbus RTU-over-TCP — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** Protocol expansion program, **workstream 1 of 6** (see
`2026-07-16-protocol-expansion-program-roadmap.md`).

## Goal

Serve Modbus **RTU framing over a TCP socket** alongside the shipped Modbus TCP
(MBAP) server, selectable per project. Only the framing layer changes: every
function code, the register file, word/byte swapping, unit-id filtering, and
force-aware writes are reused unchanged.

Ignition's Modbus driver (and most Modbus masters) can speak RTU-over-TCP, which
is common when a serial device sits behind a terminal server — so this widens
interop for near-zero marginal cost, and re-validates the "add a protocol" path
before the expensive workstreams.

## Current behaviour (as-found)

- `mobile/lib/protocols/modbus/modbus_pdu.dart` (pure, no `dart:io`) cleanly
  separates **framing** from **PDU handling**:
  - Framing: `class ModbusFrame { int transactionId; int unitId; Uint8List pdu; }`,
    `ModbusFrame? parseMbap(Uint8List)`, `Uint8List buildMbap(int transactionId, int unitId, Uint8List pdu)`.
  - PDU: `encodeReadBitsResponse`, `encodeReadRegistersResponse`,
    `encodeExceptionResponse`, and the register-file handler exposed as
    `ModbusServer.handle` — signature `Uint8List? Function(ModbusFrame)`.
- `mobile/lib/services/modbus_host.dart` is the only `dart:io` file. Its
  `_Connection` reassembles frames from arbitrary TCP chunks using the **MBAP
  length field** (`length = buf[4]<<8 | buf[5]`; `totalSize = 6 + length`),
  capped by `const int _maxFrameBytes = 260`, then calls
  `handle(parsed)` and writes `buildMbap(...)` back.
- `ModbusProtocolConfig` (`mobile/lib/models/protocol_settings.dart`) holds
  `enabled`, `port`, `map`, `wordSwap`, `byteSwap` — the latter two are the
  established precedent for **additive** wire-affecting options that default to
  the original behaviour and are simply absent from older saved JSON.
- E2E precedent: `mobile/tool/modbus_host_probe.dart` (Dart fixture host) +
  `gateway/examples/modbus_probe.rs` (real `tokio-modbus` client) +
  `tool/modbus_e2e.sh` (start → wait `READY` → probe → unconditional teardown →
  propagate exit code).
- **Reference client confirmed** (not assumed): the vendored
  `tokio-modbus 0.17.0` exposes
  `pub fn attach_slave<T>(transport: T, slave: Slave) -> Context where T: AsyncRead + AsyncWrite + Unpin + Send + 'static`
  in `src/client/rtu.rs`, so handing it a `TcpStream` yields a genuine
  RTU-over-TCP client. No new crate dependency is required.

## Non-goals / YAGNI

- **No serial transport.** Modbus RTU over an actual serial port needs a
  platform plugin, breaks the pure-Dart story, and is effectively impossible on
  iOS. RTU-**over-TCP** is the sanctioned path (per the program roadmap).
- No Modbus ASCII framing.
- No second listening port: a project serves **one** framing mode on its
  configured port at a time (selectable), not both simultaneously.
- No change to the register file, function-code coverage, map model, or
  word/byte-swap semantics.

## Global Constraints

- Pure Dart (no Flutter imports, no `dart:io`) in `mobile/lib/protocols/`;
  `dart:io` confined to `services/modbus_host.dart`.
- Deterministic; no clock, no randomness in the codec.
- **Additive/backward-compatible: `framing` defaults to `'tcp'`, and with that
  default every existing project's wire behaviour is byte-identical.** The
  existing Modbus tests and `tool/modbus_e2e.sh` must pass **unchanged**.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering
  wording — implemented from the public Modbus specification.

## Component 1 — Pure RTU framing (`mobile/lib/protocols/modbus/modbus_rtu.dart`)

New pure file (imports `dart:typed_data` and `modbus_pdu.dart` only).

```dart
/// Modbus CRC-16 (reflected, polynomial 0xA001, init 0xFFFF), transmitted
/// low byte first — per the Modbus over Serial Line specification.
int crc16Modbus(Uint8List bytes, [int start = 0, int end = -1]);

/// Total expected RTU **request** frame length (unitId + PDU + CRC) for the
/// function code at buf[1], or null when [buf] does not yet hold enough bytes
/// to decide, or -1 when the function code is not one this server supports
/// (caller drops the buffer rather than stalling).
int? rtuRequestLength(Uint8List buf);

/// Parses one complete RTU request frame (unitId + PDU + CRC16). Returns null
/// on a bad CRC or a malformed/short frame. `transactionId` is reported as 0 —
/// RTU has no transaction identifier; the field exists only so the decoded
/// result can reuse [ModbusFrame] and the shared PDU handler.
ModbusFrame? parseRtu(Uint8List frame);

/// Builds unitId + PDU + CRC16 (CRC low byte first).
Uint8List buildRtu(int unitId, Uint8List pdu);
```

**Request length by function code** (the crux — RTU carries no length field, so
the reassembler derives it):

| FC | Request | Total bytes (unit + PDU + CRC) |
|---|---|---|
| 0x01,0x02,0x03,0x04 | read: addr(2) + qty(2) | 8 |
| 0x05,0x06 | write single: addr(2) + value(2) | 8 |
| 0x0F,0x10 | write multiple: addr(2) + qty(2) + byteCount(1) + data(N) | `9 + byteCount` (needs ≥7 bytes buffered to read byteCount) |
| other | unsupported | `-1` → drop buffer |

`rtuRequestLength` returns `null` while fewer than the bytes needed to decide
are buffered (2 for the fixed-size codes, 7 for 0x0F/0x10).

## Component 2 — Config field (`ModbusProtocolConfig`)

One additive field, mirroring the `wordSwap`/`byteSwap` precedent:

- `String framing;` — `'tcp'` (default) | `'rtuOverTcp'`.
- `fromJson`: `framing: j['framing'] ?? 'tcp'` (older projects → `'tcp'`).
- `toJson`: `'framing': framing` (always emitted, matching the class's style).

Constants live in `modbus_rtu.dart`: `const String kModbusFramingTcp = 'tcp';`
`const String kModbusFramingRtuOverTcp = 'rtuOverTcp';`

## Component 3 — Host framing branch (`services/modbus_host.dart`)

`_Connection` gains the framing mode (threaded from the host's config). Its
reassembly loop branches:

- **`'tcp'` (unchanged):** MBAP length field → `parseMbap` → `handle` →
  `buildMbap`. Byte-for-byte the current code path.
- **`'rtuOverTcp'`:** ask `rtuRequestLength(buffer)`; `null` → wait for more
  bytes; `-1` → clear the buffer (unsupported FC — cannot know its length, so
  resyncing is the only safe action); otherwise once `buffer.length >= total`,
  slice the frame → `parseRtu` → on null (bad CRC) **drop the frame and clear
  the buffer** (a corrupt CRC means the stream position is untrustworthy) →
  otherwise `handle(frame)` → reply `buildRtu(unitId, responsePdu)`.

`_maxFrameBytes` (260) still bounds both paths. Unit-id filtering, the register
file, and force-aware writes are untouched — they live behind `handle`.

## Component 4 — UI (Outbound Protocols → Modbus card)

A **Framing** `DropdownButtonFormField<String>`: *Modbus TCP* (`'tcp'`) /
*RTU over TCP* (`'rtuOverTcp'`), bound to `config.framing`, styled like the
existing word/byte-swap controls. A short caption noting RTU-over-TCP suits
masters expecting a serial-style frame (e.g. behind a terminal server).
Changing it while hosting requires a stop/start, consistent with the port field.

## Data flow

TCP bytes → `_Connection` reassembly (MBAP length **or** RTU derived length +
CRC) → `ModbusFrame` → **`ModbusServer.handle` (unchanged)** → response PDU →
`buildMbap` **or** `buildRtu` → socket. Nothing else in the stack is aware of
the framing mode.

## Error handling / edge cases

- **Bad CRC** → frame dropped, buffer cleared, connection kept open (no reply;
  RTU masters time out and retry, which is the specified behaviour).
- **Unsupported function code** → `rtuRequestLength` returns `-1`; buffer
  cleared. (An exception response cannot be safely framed without knowing the
  request length, and replying to a frame we cannot delimit risks desync.)
- **Oversized claim** (> `_maxFrameBytes`) → buffer cleared, matching the
  existing TCP path's guard.
- **Fragmented / coalesced TCP delivery** → handled by the same accumulate-then-
  slice loop as the TCP path; multiple back-to-back RTU frames in one chunk are
  processed in sequence.
- Exception responses produced by `handle` are framed with RTU + CRC like any
  other response.

## Testing

- **Pure (`modbus_rtu_test.dart`):**
  - `crc16Modbus` against published Modbus test vectors (at minimum the classic
    `01 04 02 FF FF` → `0xB880` style check), and CRC placement (low byte first)
    verified via `buildRtu`.
  - `buildRtu` → `parseRtu` round-trip for each supported FC; `parseRtu` returns
    null on a flipped CRC bit and on a truncated frame.
  - `rtuRequestLength`: correct total for every supported FC; `null` for
    partial buffers (including a 0x10 frame that stops before `byteCount`);
    `-1` for an unsupported FC.
- **Host (`modbus_host` test):** RTU mode reassembles a request split across two
  TCP chunks, and two coalesced requests in one chunk, producing two responses;
  a bad-CRC frame produces no reply and does not wedge the connection.
- **Backward compatibility:** `framing` defaults to `'tcp'`; a `SimRule`-style
  round-trip test asserts a config without `framing` in its JSON loads as
  `'tcp'`; **the existing Modbus TCP tests and `tool/modbus_e2e.sh` pass
  unchanged** (byte-identity of the default path).
- **Widget:** the Framing dropdown appears on the Modbus card, reflects a
  project already set to `'rtuOverTcp'` (not silently showing "Modbus TCP"),
  and updates the config; no overflow at 320/360/1400.
- **E2E (`tool/modbus_rtu_e2e.sh` + `gateway/examples/modbus_rtu_probe.rs`):**
  the Dart fixture host is started in `rtuOverTcp` mode on a non-default port;
  a **real `tokio-modbus` RTU client** (`rtu::attach_slave(TcpStream, Slave)`)
  performs read-holding-registers → write-single-register → independent
  read-back → write-single-coil → read-coils, asserting exact values. Same
  script contract as `modbus_e2e.sh` (READY handshake, unconditional teardown,
  exit-code propagation).
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`.

## Files

- **Create:** `mobile/lib/protocols/modbus/modbus_rtu.dart` + `mobile/test/modbus_rtu_test.dart`;
  `gateway/examples/modbus_rtu_probe.rs`; `tool/modbus_rtu_e2e.sh`.
- **Modify:** `mobile/lib/models/protocol_settings.dart` (`framing` field),
  `mobile/lib/services/modbus_host.dart` (framing branch),
  `mobile/lib/screens/…` Modbus card (Framing dropdown),
  `mobile/tool/modbus_host_probe.dart` (accept a framing argument),
  plus the relevant existing test files.
- **Docs:** extend `docs/protocols/modbus.md` with an RTU-over-TCP section
  (framing difference, CRC, the no-length-field derivation, when to use it);
  `ROADMAP.md` Phase 5 note; `README.md` protocol bullet if it enumerates modes.

## Decomposition (plan-time)

**2 tasks**: (1) pure `modbus_rtu.dart` + config field + host framing branch +
UI dropdown, with the pure/host/round-trip/widget tests and the byte-identity
guard; (2) the Rust RTU probe + `tool/modbus_rtu_e2e.sh`, full gate, and docs.
