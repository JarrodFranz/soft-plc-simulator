# Modbus RTU-over-TCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve Modbus **RTU framing over TCP** alongside the shipped Modbus TCP (MBAP) server, selectable per project, reusing every function code and the register file unchanged.

**Architecture:** A new pure `modbus_rtu.dart` (CRC-16, frame parse/build, and function-code-driven request-length derivation, since RTU carries no length field), an additive `ModbusProtocolConfig.framing` field, a framing branch in the host's reassembly loop, and a Framing dropdown on the Modbus card. `ModbusServer.handle` and the whole PDU layer are untouched.

**Tech Stack:** Flutter/Dart + a Rust `tokio-modbus` E2E probe. `flutter test`, `flutter analyze`, `flutter build web --release`, `tool/modbus_rtu_e2e.sh`.

> **Plan-time refinement:** the spec estimated 2 tasks; this plan uses **3**, splitting pure framing / integration / E2E+docs so each is independently reviewable.

## Global Constraints

- Pure Dart (no Flutter imports, no `dart:io`) in `mobile/lib/protocols/`; `dart:io` confined to `services/modbus_host.dart`.
- Deterministic: no clock, no randomness in the codec.
- **Additive/backward-compatible: `framing` defaults to `'tcp'`, and with that default the wire behaviour is byte-identical. The existing Modbus tests and `tool/modbus_e2e.sh` MUST pass unchanged — do not edit them.**
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering wording.

## Key facts (verified)

- `mobile/lib/protocols/modbus/modbus_pdu.dart` (pure): `class ModbusFrame { final int transactionId; final int unitId; final Uint8List pdu; ModbusFrame({required this.transactionId, required this.unitId, required this.pdu}); }`; `ModbusFrame? parseMbap(Uint8List frame)`; `Uint8List buildMbap(int transactionId, int unitId, Uint8List pdu)`; plus `encodeReadBitsResponse` / `encodeReadRegistersResponse` / `encodeExceptionResponse` and the register-file handler reached via `ModbusServer.handle`.
- `mobile/lib/services/modbus_host.dart` (the ONLY `dart:io` file here): `const int _maxFrameBytes = 260;`. `class _Connection` holds `final Uint8List? Function(ModbusFrame) handle;` and accumulates into `_buffer`, looping: needs ≥6 bytes → `length = (_buffer[4] << 8) | _buffer[5]` → `totalSize = 6 + length` → guard `length < 1 || totalSize > _maxFrameBytes` → wait until `_buffer.length >= totalSize` → slice → `parseMbap` → `handle(parsed)` → `buildMbap(parsed.transactionId, parsed.unitId, responsePdu)`. Constructed at ~`:221` as `_Connection(socket, server.handle)`.
- `mobile/lib/models/protocol_settings.dart` → `class ModbusProtocolConfig { bool enabled; int port; ModbusMap map; bool wordSwap; bool byteSwap; }` with json keys `enabled` / `port` / `map` / `word_swap` / `byte_swap`, `fromJson` using `?? false` defaults — the precedent for an additive wire-affecting option.
- `mobile/lib/screens/gateway_screen.dart` — the Modbus card. Word/byte-swap controls (~`:1625-1656`) are `Row(children: [Expanded(Text(...)), Switch(key: const Key('modbus_word_swap_switch'), value: modbus.wordSwap, onChanged: running ? null : _setModbusWordSwap)])`; setters `_setModbusWordSwap` / `_setModbusByteSwap` at ~`:681` / `:688` assign `widget.currentProject.protocols!.modbus!.<field> = value;`. Controls are disabled (`null` onChanged) while `running`.
- `mobile/tool/modbus_host_probe.dart` — the Dart fixture host, run as `dart run tool/modbus_host_probe.dart <port>`. **It deliberately does NOT import `services/modbus_host.dart`** (`ModbusHost extends ChangeNotifier` pulls in `dart:ui`, unavailable under plain `dart run`); it imports the **pure** codec and re-implements the small reassembly loop, mirroring `_Connection`. `mobile/tool/` is analyzer-excluded.
- `tool/modbus_e2e.sh` contract: start the Dart fixture host on a non-default port → wait for it to print `READY` → run the Rust probe → kill the host unconditionally on exit → propagate the probe's exit code.
- **Reference client confirmed** in the vendored `tokio-modbus 0.17.0` (`src/client/rtu.rs`): `pub fn attach_slave<T>(transport: T, slave: Slave) -> Context where T: AsyncRead + AsyncWrite + Unpin + Send + 'static` — a `TcpStream` therefore yields an RTU-over-TCP client. Already a `gateway/Cargo.toml` dependency; no new crate needed.

---

### Task 1: Pure RTU framing (`modbus_rtu.dart`)

**Files:**
- Create: `mobile/lib/protocols/modbus/modbus_rtu.dart`
- Test: `mobile/test/modbus_rtu_test.dart`

**Interfaces:**
- Produces: `kModbusFramingTcp`, `kModbusFramingRtuOverTcp`, `int crc16Modbus(Uint8List bytes)`, `int? rtuRequestLength(Uint8List buf)`, `ModbusFrame? parseRtu(Uint8List frame)`, `Uint8List buildRtu(int unitId, Uint8List pdu)`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/modbus_rtu_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_rtu.dart';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

void main() {
  test('crc16Modbus matches the CRC catalogue check value', () {
    // CRC-16/MODBUS check value for the ASCII string "123456789" is 0x4B37.
    final data = _b('123456789'.codeUnits);
    expect(crc16Modbus(data), 0x4B37);
  });

  test('buildRtu appends CRC low byte first and parseRtu round-trips', () {
    final pdu = _b([0x03, 0x00, 0x00, 0x00, 0x01]); // read 1 holding register
    final frame = buildRtu(0x11, pdu);
    expect(frame.length, 1 + pdu.length + 2);
    expect(frame[0], 0x11);
    final crc = crc16Modbus(_b(frame.sublist(0, frame.length - 2)));
    expect(frame[frame.length - 2], crc & 0xFF, reason: 'CRC low byte first');
    expect(frame[frame.length - 1], (crc >> 8) & 0xFF);

    final parsed = parseRtu(frame);
    expect(parsed, isNotNull);
    expect(parsed!.unitId, 0x11);
    expect(parsed.pdu, pdu);
    expect(parsed.transactionId, 0, reason: 'RTU has no transaction id');
  });

  test('parseRtu rejects a corrupted CRC and a truncated frame', () {
    final frame = buildRtu(0x01, _b([0x03, 0x00, 0x00, 0x00, 0x01]));
    final bad = Uint8List.fromList(frame)..[frame.length - 1] ^= 0xFF;
    expect(parseRtu(bad), isNull);
    expect(parseRtu(_b(frame.sublist(0, 3))), isNull);
  });

  test('rtuRequestLength: fixed-size function codes are 8 bytes total', () {
    for (final fc in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) {
      expect(rtuRequestLength(_b([0x01, fc])), 8, reason: 'fc 0x${fc.toRadixString(16)}');
    }
  });

  test('rtuRequestLength: 0x0F/0x10 need byteCount, then 9 + byteCount', () {
    // unit, fc, addrHi, addrLo, qtyHi, qtyLo, byteCount
    expect(rtuRequestLength(_b([0x01, 0x10, 0x00, 0x00, 0x00, 0x02])), isNull,
        reason: 'byteCount not buffered yet');
    expect(rtuRequestLength(_b([0x01, 0x10, 0x00, 0x00, 0x00, 0x02, 0x04])), 13,
        reason: '9 + byteCount(4)');
    expect(rtuRequestLength(_b([0x01, 0x0F, 0x00, 0x00, 0x00, 0x08, 0x01])), 10);
  });

  test('rtuRequestLength: null while undecidable, -1 for unsupported fc', () {
    expect(rtuRequestLength(_b([0x01])), isNull, reason: 'no function code yet');
    expect(rtuRequestLength(_b([])), isNull);
    expect(rtuRequestLength(_b([0x01, 0x63])), -1, reason: 'unsupported fc');
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`modbus_rtu.dart` missing).

Run: `cd mobile && flutter test test/modbus_rtu_test.dart`

- [ ] **Step 3: Implement**

Create `mobile/lib/protocols/modbus/modbus_rtu.dart` — pure Dart, importing only `dart:typed_data` and `modbus_pdu.dart` (for `ModbusFrame`):

- `const String kModbusFramingTcp = 'tcp';` / `const String kModbusFramingRtuOverTcp = 'rtuOverTcp';`
- `int crc16Modbus(Uint8List bytes)` — reflected CRC-16, polynomial `0xA001`, init `0xFFFF`: for each byte, `crc ^= byte`, then 8× `crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1`. Mask to 16 bits.
- `Uint8List buildRtu(int unitId, Uint8List pdu)` — `unitId` + `pdu` + CRC **low byte first**.
- `ModbusFrame? parseRtu(Uint8List frame)` — needs ≥4 bytes (unit + fc + CRC); recompute CRC over all but the last two bytes and compare against the trailing little-endian CRC; on mismatch or short frame return `null`; else `ModbusFrame(transactionId: 0, unitId: frame[0], pdu: frame.sublist(1, frame.length - 2))`.
- `int? rtuRequestLength(Uint8List buf)` — `null` if `buf.length < 2`; then switch on `buf[1]`: `0x01,0x02,0x03,0x04,0x05,0x06` → `8`; `0x0F,0x10` → `null` if `buf.length < 7` else `9 + buf[6]`; default → `-1`.

Document in the file header that RTU carries no length field, so the reassembler must derive the request length from the function code, and that `transactionId` is a synthetic `0` purely so `ModbusFrame` and the shared PDU handler can be reused.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

Run: `cd mobile && flutter analyze lib/protocols/modbus/modbus_rtu.dart test/modbus_rtu_test.dart` (zero warnings; no Flutter/`dart:io` import).

```bash
git add mobile/lib/protocols/modbus/modbus_rtu.dart mobile/test/modbus_rtu_test.dart
git commit -m "feat(modbus): pure RTU framing — CRC-16, frame parse/build, request-length derivation"
```

---

### Task 2: Config field + host framing branch + UI

**Files:**
- Modify: `mobile/lib/models/protocol_settings.dart`, `mobile/lib/services/modbus_host.dart`, `mobile/lib/screens/gateway_screen.dart`
- Test: `mobile/test/` — add cases to the existing Modbus host/serialization/gateway-screen tests (grep for the files that already cover `modbus_host` and `ModbusProtocolConfig`)

**Interfaces:**
- Consumes: `kModbusFramingTcp`/`kModbusFramingRtuOverTcp`, `parseRtu`, `buildRtu`, `rtuRequestLength` (Task 1).
- Produces: `ModbusProtocolConfig.framing` (String, default `'tcp'`, json key `framing`).

- [ ] **Step 1: Write the failing tests**

1. **Round-trip / default** (in whichever test file covers `ModbusProtocolConfig` serialization): a config JSON **without** `framing` loads as `'tcp'`; a config with `framing: 'rtuOverTcp'` round-trips through `toJson`/`fromJson`.
2. **Host RTU reassembly** (mirror the existing Modbus host test's style): with framing `'rtuOverTcp'`, (a) a request split across two TCP chunks yields exactly one correct response; (b) two coalesced requests in one chunk yield two responses in order; (c) a frame with a corrupted CRC yields **no** response and leaves the connection usable (a subsequent valid request still answers).
3. **Widget**: the Modbus card shows a **Framing** dropdown; a project already set to `'rtuOverTcp'` displays *RTU over TCP* (**not** *Modbus TCP* — guards the same coercion class of bug seen elsewhere); changing it updates `config.framing`; the control is disabled while `running`; no overflow at 320/360/1400.

Write these failing-first, run to confirm FAIL, then implement.

- [ ] **Step 2: Run — expect FAIL.**

Run: `cd mobile && flutter test test/modbus_rtu_test.dart` plus the modified test files.

- [ ] **Step 3: Add the config field**

In `ModbusProtocolConfig`: field `String framing;`, constructor `this.framing = kModbusFramingTcp` (or the literal `'tcp'` to avoid importing the protocol layer into the model — match how `wordSwap`/`byteSwap` are declared), `fromJson: framing: j['framing'] ?? 'tcp'`, `toJson: 'framing': framing`.

- [ ] **Step 4: Branch the host reassembly**

In `modbus_host.dart`, thread the framing mode into `_Connection` (add a `final String framing;` constructor param; pass it where `_Connection(socket, server.handle)` is built at ~`:221`, reading the project's `ModbusProtocolConfig.framing`).

In the reassembly loop, branch:
- `framing == kModbusFramingTcp` → **the existing code path, unmodified**.
- `kModbusFramingRtuOverTcp` →
  ```
  final total = rtuRequestLength(buffer);
  if (total == null) { return; }               // need more bytes
  if (total < 0 || total > _maxFrameBytes) { buffer.clear(); return; }  // unsupported/oversized -> resync
  if (buffer.length < total) { return; }
  final frame = slice(buffer, 0, total); consume(total);
  final parsed = parseRtu(frame);
  if (parsed == null) { buffer.clear(); continue/return; }   // bad CRC -> drop, stay connected
  final responsePdu = handle(parsed);
  if (responsePdu != null) { socket.add(buildRtu(parsed.unitId, responsePdu)); }
  ```
  Keep the existing loop shape so multiple frames in one chunk are drained. Braces on all control flow.

- [ ] **Step 5: Add the Framing dropdown**

In `gateway_screen.dart`'s Modbus card, above/below the word-swap row, add a labelled `DropdownButtonFormField<String>` (or a `Row` + dropdown matching the card's style) with `key: const Key('modbus_framing_dropdown')`, items *Modbus TCP* → `'tcp'` and *RTU over TCP* → `'rtuOverTcp'`, `value`/`initialValue` reflecting `modbus.framing` **with a whitelist fallback to `'tcp'` for an unknown string** (do not coerce `'rtuOverTcp'` to `'tcp'`), `onChanged: running ? null : _setModbusFraming`, plus a `_setModbusFraming` setter mirroring `_setModbusWordSwap` at ~`:681`. Add a short caption: RTU-over-TCP suits masters expecting a serial-style frame (e.g. behind a terminal server). Dark theme; no overflow.

- [ ] **Step 6: Run — expect PASS + byte-identity guards green**

Run: `cd mobile && flutter test test/modbus_rtu_test.dart` and the modified test files, then **`cd mobile && flutter test`** and confirm the pre-existing Modbus TCP tests pass **unchanged** (you must not have edited them).

- [ ] **Step 7: analyze + commit**

```bash
git add mobile/lib/models/protocol_settings.dart mobile/lib/services/modbus_host.dart mobile/lib/screens/gateway_screen.dart mobile/test/
git commit -m "feat(modbus): selectable RTU-over-TCP framing (config, host branch, UI)"
```

---

### Task 3: E2E probe + full gate + docs

**Files:**
- Modify: `mobile/tool/modbus_host_probe.dart`
- Create: `gateway/examples/modbus_rtu_probe.rs`, `tool/modbus_rtu_e2e.sh`
- Docs: `docs/protocols/modbus.md`, `ROADMAP.md`, `README.md`

- [ ] **Step 1: Teach the fixture host RTU framing**

`mobile/tool/modbus_host_probe.dart` takes `<port>` today. Add an optional second argument (e.g. `dart run tool/modbus_host_probe.dart <port> [tcp|rtuOverTcp]`, defaulting to `tcp`).

**It must NOT import `services/modbus_host.dart`** — `ModbusHost extends ChangeNotifier` pulls in `dart:ui`, which is unavailable under plain `dart run` (the file's own header explains this). It **may** import the pure `protocols/modbus/modbus_rtu.dart`, so re-implement only the small RTU reassembly loop, mirroring `_Connection`'s — exactly as it already mirrors the MBAP one. Keep printing `READY` on the same contract.

- [ ] **Step 2: Write the Rust RTU probe**

`gateway/examples/modbus_rtu_probe.rs`, modelled on `gateway/examples/modbus_probe.rs`: open a `TcpStream` to the fixture host, then
`let mut ctx = tokio_modbus::client::rtu::attach_slave(stream, Slave(<unit>));`
and perform read-holding-registers → write-single-register → independent read-back (assert the exact written value) → write-single-coil → read-coils (assert). Bound every await with `tokio::time::timeout` so it cannot hang. Exit non-zero with a clear message on any mismatch. No new crate dependency (`tokio-modbus` 0.17 is already in `gateway/Cargo.toml`).

- [ ] **Step 3: Write the E2E script**

`tool/modbus_rtu_e2e.sh`, modelled on `tool/modbus_e2e.sh` and following the identical contract: start `mobile/tool/modbus_host_probe.dart <port> rtuOverTcp` on a non-default port, wait for `READY`, run `cargo run --example modbus_rtu_probe`, kill the Dart host unconditionally on exit (trap), and propagate the probe's exit code. Make it executable. Header comment explaining what it proves.

- [ ] **Step 4: Run the E2E**

Run: `bash tool/modbus_rtu_e2e.sh`
Expected: the probe completes read → write → read-back → coil write → coil read with exact values and exits 0. If `rtu::attach_slave` needs a different construction than expected, adjust the probe (the API was verified present in `tokio-modbus 0.17.0`); report verbatim if it genuinely cannot drive RTU-over-TCP.

Also re-run the existing `bash tool/modbus_e2e.sh` and confirm it still passes **unchanged** (the TCP path is untouched).

- [ ] **Step 5: Full gate**

Run: `cd mobile && flutter analyze` (whole project, zero warnings); `cd mobile && flutter test` (ALL pass — record the exact count; `gateway_screen_test.dart`'s "Start hosting…" is known-flaky, pre-existing only if it passes in isolation); `cd mobile && flutter build web --release`. Report any real failure verbatim.

- [ ] **Step 6: Docs**

- `docs/protocols/modbus.md`: an **RTU over TCP** section — the framing difference (no MBAP; `unitId + PDU + CRC-16`, CRC low byte first), that RTU has no length field so the server derives the request length from the function code, the bad-CRC/unsupported-FC resync behaviour, when to use it (masters expecting a serial-style frame, e.g. behind a terminal server), that it is selected per project on the Modbus card and only one framing is served at a time, and the E2E proof (`tool/modbus_rtu_e2e.sh` with a real `tokio-modbus` RTU client). Note serial RTU is out of scope and why.
- `ROADMAP.md`: a Phase 5 (Modbus) post-ship bullet for RTU-over-TCP.
- `README.md`: extend the Modbus bullet if it enumerates modes.
- No forbidden branding / reverse-engineering wording.

- [ ] **Step 7: Commit**

```bash
git add mobile/tool/modbus_host_probe.dart gateway/examples/modbus_rtu_probe.rs tool/modbus_rtu_e2e.sh docs ROADMAP.md README.md
git commit -m "test+docs(modbus): real tokio-modbus RTU-over-TCP E2E proof; docs"
```

---

## Self-Review

**Spec coverage:**
- Component 1 pure RTU framing (CRC-16, parse/build, length derivation) → Task 1. ✓
- Component 2 `framing` config field (additive, default `'tcp'`) → Task 2. ✓
- Component 3 host framing branch (TCP path unmodified) → Task 2. ✓
- Component 4 Framing dropdown → Task 2. ✓
- Pure/host/round-trip/widget tests + byte-identity guard → Tasks 1-2. ✓
- Real third-party RTU E2E + full gate + docs → Task 3. ✓

**Placeholder scan:** Task 1 ships complete test code and a precise algorithm (polynomial, init, bit order, per-FC length table). Tasks 2-3 describe changes against verified line-anchored call sites and the existing `modbus_e2e.sh` contract; test *intents* are stated with their assertions rather than full bodies where they extend files whose helpers must be matched — the assertions are binding, the mechanics are the implementer's to fit.

**Type consistency:** `parseRtu` returns the same `ModbusFrame` the MBAP path produces, so `ModbusServer.handle`'s `Uint8List? Function(ModbusFrame)` signature is unchanged and the PDU layer needs no edits. `rtuRequestLength` returns `int?` with the documented tri-state (`null` = need more, `-1` = unsupported, else total). `framing` is a plain `String` on the model (no protocol-layer import into `protocol_settings.dart`), matching how `wordSwap`/`byteSwap` are declared.

**Note for the executor:** the binding properties are (a) **`'tcp'` framing stays byte-identical** — the existing Modbus tests and `tool/modbus_e2e.sh` must pass untouched; (b) CRC-16 matches the catalogue check value `0x4B37` for `"123456789"`; (c) the reassembler survives fragmented, coalesced, bad-CRC and unsupported-FC input without wedging the connection; (d) a real `tokio-modbus` RTU client completes write → independent read-back. The fixture host must not import the Flutter-dependent `ModbusHost`.
