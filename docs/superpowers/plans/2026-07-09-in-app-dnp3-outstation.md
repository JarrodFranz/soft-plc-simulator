# In-App DNP3 Outstation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host a pure-Dart DNP3 outstation in the app that exposes project tags to any DNP3 master (Class 0 static polling of Binary/Analog Inputs & Outputs, plus SELECT/OPERATE/DIRECT_OPERATE control) over DNP3 TCP/IP — opt-in from Outbound Protocols, machine-verified against the reference Rust `dnp3` master.

**Architecture:** Mirrors the Modbus/OPC UA in-app servers but implements DNP3's three-layer stack: a pure Data Link codec (CRC-16/DNP per-block framing), a pure Transport codec (FIR/FIN/SEQ segmentation), a pure Application codec (function codes + IIN + object/variation/qualifier), and a pure outstation handler over `DnpMap` + live tags. The only `dart:io` is `dnp3_host.dart`. Config is additive (`dnp3` key). Control writes go through the existing force-aware `writePath`.

**Tech Stack:** Flutter/Dart (pure codecs + Flutter host/UI), Rust E2E (`dnp3` crate master). Spec: `docs/superpowers/specs/2026-07-09-in-app-dnp3-outstation-design.md`.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); "DNP3"/"IEEE 1815"/standard DNP3 terms are fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/dnp3/**` is PURE Dart (no Flutter/`dart:io`); the ONLY `dart:io` file is `mobile/lib/services/dnp3_host.dart`. The outstation must NEVER crash the app: malformed input → clean error / dropped connection, never an uncaught throw.
- All DNP3 wire integers are **little-endian** (opposite of Modbus). Floats via `ByteData.setFloat32`/32-bit ints via `setInt32` (dart2js-safe); NEVER `getInt64`/`setInt64`.
- Control writes are force-aware (forcing wins) via `writePath`; read-only point types reject control.
- Additive persistence: `dnp3` key omitted when null; WS6 lossless round-trip guard stays green. App byte-identical when hosting is stopped.
- Cross-check every wire detail against IEEE 1815 and, once it's a gateway dependency (Task 6), the Rust `dnp3` crate. Do not invent CRC/object bytes — derive fixtures from an authoritative reference.
- Dart package name is `soft_plc_mobile`. Run Flutter from `mobile/`, Rust from `gateway/`, git from repo root. Do NOT stage generated_plugin_registrant churn under `mobile/{linux,macos,windows}`.

---

### Task 1: DnpMap + DnpProtocolConfig (additive config)

**Files:**
- Create: `mobile/lib/models/dnp3_map.dart`
- Modify: `mobile/lib/models/protocol_settings.dart` (add `DnpProtocolConfig` + `ProtocolSettings.dnp3`)
- Test: `mobile/test/dnp3_map_test.dart`; extend the existing `mobile/test/protocol_settings_test.dart` round-trip suite

**Interfaces:**
- Consumes: `PlcProject`, `PlcTag` (name/dataType/ioType), the additive pattern from `ModbusProtocolConfig`/`ModbusMap`.
- Produces: `DnpMapEntry{String tag, String pointType, int index}` (pointType ∈ `binaryInput|binaryOutput|analogInput|analogOutput`), `DnpMap{List<DnpMapEntry> entries}` with fromJson/toJson/autoGenerate, `DnpProtocolConfig{enabled, port, outstationAddress, masterAddress, DnpMap map}`, and `ProtocolSettings.dnp3`.

- [ ] **Step 1: Write the failing tests**

`mobile/test/dnp3_map_test.dart` (match the real `PlcProject`/`PlcTag` ctors — read `project_model.dart` first):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';

void main() {
  test('autoGenerate maps BOOL/numeric x RO/RW into the 4 point types with per-type indexes', () {
    // Build a project with: RO BOOL (SimulatedOutput), RW BOOL (SimulatedInput),
    // RO numeric (SimulatedOutput FLOAT64), RW numeric (Internal INT32), a composite (skipped).
    final p = /* ... */;
    final m = DnpMap.autoGenerate(p);
    // RO BOOL -> binaryInput index 0; RW BOOL -> binaryOutput index 0;
    // RO numeric -> analogInput index 0; RW numeric -> analogOutput index 0.
    expect(m.entries.where((e) => e.pointType == 'binaryInput').length, 1);
    expect(m.entries.where((e) => e.pointType == 'analogOutput').single.index, 0);
    expect(m.entries.any((e) => /* composite tag */ false), isFalse);
  });

  test('DnpMap json round-trips', () {
    final m = DnpMap(entries: [DnpMapEntry(tag: 'A', pointType: 'binaryInput', index: 0)]);
    final r = DnpMap.fromJson(m.toJson());
    expect(r.entries.single.pointType, 'binaryInput');
  });
}
```

Extend `protocol_settings_test.dart`: a `ProtocolSettings` with `DnpProtocolConfig` round-trips losslessly; `dnp3 == null` omits the `dnp3` key.

- [ ] **Step 2: Run to verify fail** — `cd mobile && flutter test test/dnp3_map_test.dart` → FAIL.

- [ ] **Step 3: Implement** `dnp3_map.dart` mirroring `modbus_map.dart`: `DnpMapEntry`/`DnpMap` (fromJson/toJson) and `DnpMap.autoGenerate` — same scalar selection as `ModbusMap.autoGenerate` (BOOL/INT16/INT32/FLOAT64, skip composites/TIMER/COUNTER/STRING), point type by (BOOL vs numeric)×(RO vs RW) where RO == `ioType == 'SimulatedOutput'`, next-free index per point-type (four independent 0-based counters). In `protocol_settings.dart` add `DnpProtocolConfig` mirroring `ModbusProtocolConfig` with the fields above (defaults: enabled=false, port=20000, outstationAddress=1024, masterAddress=1); wire `dnp3` additively into `ProtocolSettings` toJson/fromJson/defaults.

- [ ] **Step 4: Run** `cd mobile && flutter test test/dnp3_map_test.dart test/protocol_settings_test.dart` → PASS; `flutter analyze lib/models/dnp3_map.dart lib/models/protocol_settings.dart` → zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/dnp3_map.dart mobile/lib/models/protocol_settings.dart mobile/test/dnp3_map_test.dart mobile/test/protocol_settings_test.dart
git commit -m "feat(dnp3): DnpMap + DnpProtocolConfig (additive)"
```

---

### Task 2: Data Link Layer — CRC-16/DNP + framing

**Files:**
- Create: `mobile/lib/protocols/dnp3/dnp3_link.dart`
- Test: `mobile/test/dnp3_link_test.dart`

**Interfaces:**
- Produces (pure, dart2js-safe): `int dnpCrc(List<int> bytes)` (CRC-16/DNP); `Uint8List buildLinkFrame({required int control, required int dest, required int src, required Uint8List userData})` (adds header CRC + per-16-byte data-block CRCs); `DnpLinkFrame? parseLinkFrame(Uint8List frame)` returning `{control, dest, src, Uint8List userData}` or null on bad start/length/CRC; a streaming `DnpLinkBuffer` that yields complete link frames from TCP chunks. Nothing throws on garbage.

**Wire facts (verify against IEEE 1815):** link frame = `0x05 0x64` start, `LENGTH` (1 byte: counts control + 2 addr + user data, i.e. `5 + userDataLen`, max 255), `CONTROL` (1 byte), `DESTINATION` (u16 LE), `SOURCE` (u16 LE), then the header's 2-byte CRC (LE) — that's the 10-byte header block. Then user data in blocks of up to 16 bytes, each followed by its own 2-byte CRC (LE).

**CRC-16/DNP algorithm** (reflected, poly `0x3D65` → shift constant `0xA6BC`, final one's-complement):
```dart
int dnpCrc(List<int> bytes) {
  int crc = 0x0000;
  for (final b in bytes) {
    crc ^= (b & 0xFF);
    for (int i = 0; i < 8; i++) {
      if ((crc & 0x0001) != 0) {
        crc = (crc >> 1) ^ 0xA6BC;
      } else {
        crc >>= 1;
      }
    }
  }
  return (~crc) & 0xFFFF;
}
```

- [ ] **Step 1: Write the failing tests** (`dnp3_link_test.dart`):
  - `dnpCrc` against an AUTHORITATIVE reference value. DERIVE the expected CRC of the header bytes `[0x05,0x64,0x05,0xC0,0x01,0x00,0x00,0x04]` from a trustworthy source (a published IEEE-1815 CRC vector, or compute it with the Rust `dnp3`/a known-good tool and paste the number) — do NOT invent it. Assert `dnpCrc(headerBytes) == <that reference>` and add at least one more vector.
  - `buildLinkFrame` produces the header block + correct block CRCs for a small userData; `parseLinkFrame(buildLinkFrame(...))` round-trips; a corrupted CRC → null; wrong start bytes → null.
  - `DnpLinkBuffer`: a frame split across two `add()`s emits once complete; two frames coalesced emit two; garbage never throws.

- [ ] **Step 2: Run to verify fail** → FAIL (link codec absent). Note: if your first CRC reference guess is wrong the test will fail for the RIGHT reason later — get the reference from an authoritative source before trusting the algorithm.

- [ ] **Step 3: Implement** `dnp3_link.dart` per the wire facts + the CRC above (table-driven optional). LENGTH validation, block-CRC wrap/unwrap, LE addresses. Guard every slice; never throw.

- [ ] **Step 4: Run** `cd mobile && flutter test test/dnp3_link_test.dart` → PASS; `flutter analyze lib/protocols/dnp3/dnp3_link.dart` → zero. If the CRC vector can't be independently confirmed, STOP and flag it — a self-derived CRC fixture is worthless (it would pass against a wrong algorithm).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/dnp3/dnp3_link.dart mobile/test/dnp3_link_test.dart
git commit -m "feat(dnp3): Data Link Layer CRC-16/DNP + block framing + reassembler"
```

---

### Task 3: Transport + Application codec

**Files:**
- Create: `mobile/lib/protocols/dnp3/dnp3_transport.dart`, `mobile/lib/protocols/dnp3/dnp3_app.dart`
- Test: `mobile/test/dnp3_app_test.dart`

**Interfaces:**
- Transport (pure): `Uint8List buildTransport(int seq, {required bool fir, required bool fin, required Uint8List appData})` (prepend the 1-byte transport header `FIR<<6 | FIN<<5 | (seq & 0x3F)`); a reassembler collecting app fragments across segments (v1 single-segment common, but handle multi).
- App (pure): `DnpAppRequest? parseAppRequest(Uint8List frag)` → `{appControl, functionCode, List<DnpObjectHeader> objects, rawObjectData}`; `Uint8List buildAppResponse({required int seq, required bool fir, required bool fin, required bool con, required int iin, required Uint8List objectData})`; object-header encode/decode by group/variation/qualifier/range; encoders for the static objects (g1v2 BI, g10v2 BO, g30v1/g30v5 AI, g40v1/g40v3 AO) and decoders for CROB (g12v1) and analog-output block (g41v1/v3). Constants for function codes (READ=1, SELECT=3, OPERATE=4, DIRECT_OPERATE=5, RESPONSE=129) and IIN bits.

**Wire facts (verify against IEEE 1815):**
- App request fragment: `APP_CONTROL` (1 byte: FIR/FIN/CON/UNS + 4-bit seq), `FUNCTION_CODE` (1 byte), then object headers. App response: `APP_CONTROL`, `FUNCTION_CODE`(=129), `IIN` (2 bytes), then objects.
- Object header: `GROUP` (1), `VARIATION` (1), `QUALIFIER` (1), then the range field per qualifier: `0x00` = 1-byte start & stop indexes; `0x01` = 2-byte start & stop; `0x06` = all points (no range); `0x17` = 1-byte count then per-object 1-byte index prefix; `0x28` = 2-byte count then per-object 2-byte index prefix.
- g1v2 (BI w/ flags): 1 byte per point = flags (bit0 ONLINE, … bit7 STATE). g10v2 (BO status): same 1-byte flags+state. g30v1 (AI 32-bit w/ flags): 1 flags byte + int32 LE. g30v5 (AI float w/ flags): 1 flags byte + float32 LE. g40v1/v3 (AO status): flags + int32/float32 LE.
- g12v1 (CROB): control code (1), count (1), on-time u32 LE (4), off-time u32 LE (4), status (1) = 11 bytes per point. g41v1 (AO block int): int32 LE (4) + status (1); g41v3 (float): float32 LE (4) + status (1).
- Class 0 read request: object g60v1, qualifier `0x06`.

- [ ] **Step 1: Write the failing tests** (`dnp3_app_test.dart`), byte-exact where derivable from the spec: build a transport segment for a small app response and assert the header byte; encode an object header for each qualifier (0x00/0x01/0x06/0x17/0x28) and round-trip; encode a Class 0 response fragment containing one BI (g1v2), one AI int (g30v1) and one AI float (g30v5) and assert the bytes; decode a CROB (g12v1) DIRECT_OPERATE request's control fields; decode a g41 analog-output request; IIN packing; parse a Class 0 read request (g60v1, qual 0x06). Truncated/garbage → clean null, never throw.

- [ ] **Step 2: Run to verify fail** → FAIL.

- [ ] **Step 3: Implement** `dnp3_transport.dart` + `dnp3_app.dart` per the wire facts. LE everywhere; float32 via `ByteData.setFloat32(..., Endian.little)`, int32 via `setInt32(..., Endian.little)`. Every parser guards bounds and returns null on malformed input.

- [ ] **Step 4: Run** `cd mobile && flutter test test/dnp3_app_test.dart` → PASS; `flutter analyze lib/protocols/dnp3/` → zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/dnp3/dnp3_transport.dart mobile/lib/protocols/dnp3/dnp3_app.dart mobile/test/dnp3_app_test.dart
git commit -m "feat(dnp3): Transport function + Application object/variation codec"
```

---

### Task 4: Outstation handler (Class 0 read + control, force-aware)

**Files:**
- Create: `mobile/lib/protocols/dnp3/dnp3_outstation.dart`
- Test: `mobile/test/dnp3_outstation_test.dart`

**Interfaces:**
- Consumes: `DnpMap`, `PlcProject`, `readPath`/`writePath` (force-aware), the Task 2/3 codecs.
- Produces: `DnpOutstation({required PlcProject Function() projectProvider, required int Function() outstationAddress...})` with `Uint8List? handleLinkFrame(DnpLinkFrame req)` (or a `handleAppFragment` returning the response app data the host wraps in transport+link). Class 0 integrity READ → response objects from live tags across all 4 types; SELECT stores a pending control keyed by (function, objects, seq) with a timeout, OPERATE matches+executes, DIRECT_OPERATE executes immediately; control decode → force-aware `writePath` (a forced target is not written and the point status reflects it); IIN with DEVICE_RESTART set until the master writes g80v1 index 7; unknown function code → NO_FUNC_CODE_SUPPORT IIN. Never throws (internal error → an IIN error response, not an exception).

- [ ] **Step 1: Write the failing tests** (`dnp3_outstation_test.dart`) against a mapped fixture project:
  - A Class 0 integrity read produces a response whose decoded BI/BO/AI/AO objects equal the live tag values (bool + int + float).
  - A DIRECT_OPERATE CROB (LATCH_ON) to a binaryOutput point flips the mapped BOOL (`readPath` confirms); LATCH_OFF clears it.
  - SELECT then OPERATE flips the output; OPERATE without a matching prior SELECT → rejected (no write, error status).
  - An analog-output-block (g41) write sets a numeric tag.
  - **Force-aware**: operate on a forced tag → tag unchanged, per-point status is the documented "declined" value.
  - DEVICE_RESTART IIN set on the first response; after a g80v1 index-7 write it clears.
  - Unknown function code → response with NO_FUNC_CODE_SUPPORT IIN, no throw.

- [ ] **Step 2: Run to verify fail** → FAIL.

- [ ] **Step 3: Implement** `dnp3_outstation.dart`. Keep pending-SELECT state with a monotonic-ish timeout (accept an injected `nowMs` for deterministic tests). Build Class 0 responses grouped by point type with range qualifiers. Route control to `writePath` only for RW point types and non-forced tags.

- [ ] **Step 4: Run** `cd mobile && flutter test test/dnp3_outstation_test.dart` → PASS; analyze zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/dnp3/dnp3_outstation.dart mobile/test/dnp3_outstation_test.dart
git commit -m "feat(dnp3): outstation handler — Class 0 read + SELECT/OPERATE/DIRECT_OPERATE (force-aware)"
```

---

### Task 5: Socket host + Outbound Protocols UI + shell lifecycle

**Files:**
- Create: `mobile/lib/services/dnp3_host.dart` (only `dart:io` in DNP3)
- Modify: `mobile/lib/screens/gateway_screen.dart` (DNP3 card + `_setDnpEnabled`), `mobile/lib/screens/workspace_shell.dart` (own a `DnpHost`; stop on project-identity change + dispose)
- Test: `mobile/test/dnp3_host_test.dart`; extend `mobile/test/gateway_screen_test.dart`

**Interfaces:**
- Consumes: the codecs + outstation, `DnpProtocolConfig`, `writePath`.
- Produces: `DnpHost extends ChangeNotifier` with `start(PlcProject Function())`/`stop()`, status/lastError/clientCount/endpointUrl (mirror `ModbusHost`); `ServerSocket.bind`, per-connection `DnpLinkBuffer` reassembly → outstation → response frames; never throws (guarded); a hostile/oversize frame drops just that connection.

- [ ] **Step 1: Write the failing test** (`dnp3_host_test.dart`): bind an ephemeral port, connect a raw `Socket`, send a real framed Class 0 read (valid CRCs, addressed to the outstation), assert a well-formed response frame back (start `0x0564`, valid header + block CRCs, dest=master); a malformed burst drops only that connection without throwing; start/stop lifecycle; frame addressed to a different outstation address is ignored. Model harness/timeouts on `mobile/test/*modbus_host*` tests.

- [ ] **Step 2: Run to verify fail** → FAIL.

- [ ] **Step 3: Implement**
  1. `dnp3_host.dart` mirroring `modbus_host.dart`: `ServerSocket.bind(InternetAddress.anyIPv4, port)`, per-socket `DnpLinkBuffer`, dispatch to a `DnpOutstation`, write framed responses; `endpointUrl = 'dnp3://<host>:<port>'`; hostile-frame guard; never crash.
  2. `gateway_screen.dart`: a DNP3 card mirroring the Modbus card — enable toggle (`_setDnpEnabled`, which ALSO stops the host when toggled off, matching the auto-stop behavior of the other cards), port field (20000), outstation + master link-address fields, Start/Stop hosting, status + endpoint, and the point-map editor (tag/pointType/index editable rows + Add + Regenerate, dotted-path tag options). Web shows the native-only note.
  3. `workspace_shell.dart`: construct a `DnpHost`, stop it at every project-identity-change site the other hosts are stopped, and in `dispose`.

- [ ] **Step 4: Run** `cd mobile && flutter test test/dnp3_host_test.dart test/gateway_screen_test.dart` → PASS; `flutter analyze` zero across touched files; no overflow at 320/360/1400 (add the DNP3 card to the existing overflow tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/services/dnp3_host.dart mobile/lib/screens/gateway_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/dnp3_host_test.dart mobile/test/gateway_screen_test.dart
git commit -m "feat(dnp3): dart:io outstation host + Outbound Protocols card + shell lifecycle"
```

---

### Task 6: Rust `dnp3` master E2E + validation + docs + final review

**Files:**
- Create: `gateway/examples/dnp3_probe.rs`, `mobile/tool/dnp3_host_probe.dart`, `tool/dnp3_e2e.sh`
- Modify: `gateway/Cargo.toml` (add the `dnp3` crate), `docs/protocols/DNP3.md`, `ROADMAP.md`

**Interfaces:**
- Consumes: the running Dart outstation (via `dnp3_host_probe.dart`) + a real `dnp3` master.
- Produces: `DNP3 PROBE PASS` only if a real master runs a Class 0 integrity poll asserting BI + AI values AND operates a binary + analog output and reads back the change.

- [ ] **Step 1: Add the `dnp3` crate.** Add Step Function I/O's `dnp3` to `gateway/Cargo.toml`. Use SCOPED cargo/paths only — NEVER `find /`/`find ~` unbounded (a prior agent left a whole-filesystem `find` running 23 minutes). `cd gateway && cargo build --examples` to confirm it resolves.

- [ ] **Step 2: Write `dnp3_host_probe.dart`.** Headless Dart entrypoint: build a fixture project (a BI, an AI int, an AI float, a binary output, an analog output; one tag **forced**), configure `DnpProtocolConfig` (outstation 1024, master 1, localhost:<port>), drive `DnpHost.start` to serve. Mirror `mobile/tool/modbus_host_probe.dart`. (If `DnpHost` can't be imported under `dart run` due to `dart:ui`, reimplement its wire logic against the pure codec/outstation modules, mirroring the Modbus/OPC UA/MQTT probe precedent — documented.)

- [ ] **Step 3: Write `dnp3_probe.rs` + `tool/dnp3_e2e.sh`.** A `dnp3` master connects to the Dart outstation, runs a Class 0 integrity poll and asserts the BI + AI (int and float) values, then DIRECT_OPERATEs a CROB on the binary output and an analog-output-block on the analog output, re-polls, and asserts the changed values; also assert the forced tag did NOT change on an operate. End with `DNP3 PROBE PASS`. If the environment can't fetch/build `dnp3`, say so explicitly and fall back to `cargo build --examples` + the Dart suites — do NOT print PASS unless the real master ran.

- [ ] **Step 4: Full regression gate** — run and paste REAL output: `cd mobile && flutter test`; `cd mobile && flutter analyze` (zero); `cd mobile && flutter build web --release` (compiles); `cd gateway && cargo build --examples`.

- [ ] **Step 5: Docs + roadmap.** Rewrite `docs/protocols/DNP3.md` to match what shipped (outstation, 4 point types + variations, Class 0 polling, SELECT/OPERATE/DIRECT_OPERATE control, force-aware, link addresses, native-only, events/unsolicited deferred); mark ROADMAP Phase 8 ✅. No vendor branding.

- [ ] **Step 6: Commit.**

```bash
git add gateway/ mobile/tool/dnp3_host_probe.dart tool/dnp3_e2e.sh docs/protocols/DNP3.md ROADMAP.md
git commit -m "test(dnp3): Rust dnp3 master E2E; docs; Phase 8 complete"
```

- [ ] **Step 7: Whole-branch review** — the controller dispatches the final code reviewer (most capable model) over the full branch diff, then uses superpowers:finishing-a-development-branch to merge.
