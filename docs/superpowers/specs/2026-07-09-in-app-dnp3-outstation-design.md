# In-App DNP3 Outstation (Phase 8 / WS26) Design

**Date:** 2026-07-09
**Status:** Approved by user (chat, 2026-07-09): v1 = **static polling (Class 0 integrity reads) + output control**, deferring events/unsolicited; **4 core point types** (Binary Input, Binary Output, Analog Input, Analog Output), no counters; **both** SELECT/OPERATE and DIRECT_OPERATE control models.
**Builds on:** WS19–20 (OPC UA server), WS24 (Modbus TCP server), WS25 (MQTT), and ADR-010 (single app hosts everything in-process; no companion). Reuses the `ModbusHost`/`ServerSocket` pattern, `ProtocolSettings` additive config, the `ModbusMap`/`autoGenerate` per-project mapping, force-aware writes through `writePath`, the Outbound Protocols screen card + editable-row map editor, and the `gateway/examples/*_probe.rs` machine-proof E2E pattern.

## Goal

Host a pure-Dart **DNP3 outstation** (slave) inside the app so any DNP3 master (utility/water SCADA, Step Function I/O `dnp3`, opendnp3) can poll the project's tags and operate its outputs over DNP3 TCP/IP (port 20000). Opt-in from Outbound Protocols alongside OPC UA/Modbus/MQTT; runs on Android/desktop/iOS (web compiles but cannot bind a `ServerSocket` — same native-only limitation as the other servers). Machine-verified by a real third-party DNP3 master.

## Scope

**In (v1):**
- **DNP3 over TCP/IP**, outstation role, default port **20000**. One master connection at a time is enough for v1 (accept additional connections but each is independent, like the Modbus host).
- **Data Link Layer**: `0x0564` frame, u16 little-endian source/destination link addresses, control octet, and **CRC-16/DNP** on the 8-byte header block and every subsequent ≤16-byte data block. Address filtering: serve only frames whose destination == our outstation address; responses go dest=master, src=outstation.
- **Transport Function**: the 1-byte transport header (FIN/FIR/SEQUENCE) with segmentation/reassembly (v1 fragments are small — a single segment usually suffices, but reassembly is implemented for correctness).
- **Application Layer**: request/response fragments (application control FIR/FIN/CON/UNS/SEQ), **function codes** READ(1), SELECT(3), OPERATE(4), DIRECT_OPERATE(5), plus responses (RESPONSE=129) carrying the 2-byte **IIN** (Internal Indications). Object headers by **group/variation/qualifier/range**.
- **Class 0 integrity poll**: master READ of object **g60v1 (Class 0 data)**, qualifier `0x06` (all points) → outstation responds with every mapped static point grouped by type using range qualifiers.
- **Four point types + default static variations**:
  - **Binary Input** ← RO `BOOL` → **g1v2** (with flags octet).
  - **Binary Output status** ← RW `BOOL` → **g10v2**; controlled via **CROB g12v1** (SELECT/OPERATE + DIRECT_OPERATE).
  - **Analog Input** ← RO numeric → **g30v1** (32-bit int, with flags) for INT16/INT32, **g30v5** (single-precision float, with flags) for FLOAT64.
  - **Analog Output status** ← RW numeric → **g40v1**(int)/**g40v3**(float); controlled via **Analog Output Block g41v1**(int)/**g41v3**(float).
- **Control** (force-aware): decode CROB (g12v1: control code, count, on/off time, status) and analog-output-block (g41) objects with qualifier `0x17`/`0x28` (count + 1/2-byte index prefix); apply via `writePath` unless the target tag is forced (then reject the operate with status `NOT_SUPPORTED`/reflect the unchanged value — documented). SELECT stores the pending control and OPERATE executes it (with a SELECT/OPERATE match check + timeout); DIRECT_OPERATE executes immediately. Echo the standard control response with per-point status codes.
- **IIN handling**: set **DEVICE_RESTART** (IIN1.7) on the first response after (re)start until the master clears it (write to g80v1 index 7), and set **NEED_TIME** off (no time sync in v1). Unknown/unsupported requests → set the appropriate IIN2 bits (e.g. NO_FUNC_CODE_SUPPORT / OBJECT_UNKNOWN / PARAMETER_ERROR) rather than dropping.
- Per-project `DnpProtocolConfig` + `DnpMap` (additive `dnp3` key), auto-generated from scalar tags, editable + Regenerate.
- Outbound Protocols **DNP3 card**: enable, port (20000), **outstation link address** + **master link address**, Start/Stop hosting, status + endpoint (`dnp3://<ip>:<port>`), and the point-map editor.
- Machine-proof Rust E2E: a real `dnp3` master reads Class 0 and operates an output against the in-app Dart outstation.

**Out (v-next):** Class 1/2/3 **events** + event variations + solicited event reads; **unsolicited responses**; **counters** (g20/g22); time synchronization (g50) and NEED_TIME; file transfer (g70); dataset/octet-string objects; secure authentication (SAv5); frozen counters; multi-drop link-layer confirmed service (v1 uses unconfirmed link service).

## The point map (`DnpMap`, mirrors `ModbusMap`)

`DnpMapEntry{ String tag, String pointType ('binaryInput'|'binaryOutput'|'analogInput'|'analogOutput'), int index }` — `index` is the DNP3 point index within that type's space (each of the four types has its own 0-based index space, exactly like Modbus's four tables). `DnpMap{ List<DnpMapEntry> entries }` with `fromJson`/`toJson` like `ModbusMap`.

`DnpMap.autoGenerate(PlcProject p)`: walk `p.tags`; for each top-level **scalar leaf** of type `BOOL`/`INT16`/`INT32`/`FLOAT64` (skip composites + `TIMER`/`COUNTER`/`STRING`, matching `ModbusMap.autoGenerate`), pick the point type from (BOOL vs numeric) × (RO vs RW): RO `BOOL`→binaryInput, RW `BOOL`→binaryOutput, RO numeric→analogInput, RW numeric→analogOutput (RO == `ioType == 'SimulatedOutput'`, matching the OPC UA/Modbus convention). Assign the **next free index in that type**, sequential from 0. Editable + Regenerate in the UI. The analog variation (int vs float) is derived from the tag's data type at response time, not stored.

## Config model (`DnpProtocolConfig`, additive)

Added to `ProtocolSettings` under an additive JSON key `dnp3` (omitted when null; back-compat unchanged), mirroring `opcua`/`modbus`/`mqtt`:

```
class DnpProtocolConfig {
  bool enabled;             // default false
  int port;                 // default 20000
  int outstationAddress;    // this outstation's DNP3 link address, default 1024
  int masterAddress;        // the master's link address responses are sent to, default 1
  DnpMap map;
}
```

`toJson`/`fromJson` follow `ModbusProtocolConfig` (every field additive with a default on read). `DnpProtocolConfig.defaults(p)` = `enabled:false, port:20000, outstationAddress:1024, masterAddress:1, map: DnpMap.autoGenerate(p)`.

## Wire encoding (verify against IEEE 1815 + the vendored Rust `dnp3` crate)

- **CRC-16/DNP** (link-layer block CRC): reflected CRC with polynomial `0x3D65`, computed per the DNP3 spec over the header (first 8 bytes) and each data block (≤16 bytes), appended little-endian. Implement table-driven; the codec stays dart2js-compilable (byte-wise `int` ops, no `getInt64`/`setInt64`).
- **Link addresses / lengths**: little-endian u16. The link `LENGTH` field counts the control octet + address octets + user data (not CRCs), per spec.
- **Application data**: object counts/indexes/ranges are little-endian; g30v5/g41v3 floats are IEEE-754 single-precision (`ByteData.setFloat32`, dart2js-safe); g30v1/g40v1/g41v1 are 32-bit signed ints written via `ByteData.setInt32(..., Endian.little)` (32-bit accessors are dart2js-safe; only the 64-bit integer accessors are not).
- All multi-byte DNP3 fields are **little-endian** (note: opposite of Modbus's big-endian) — the codec must be explicit about endianness at every field.

## Architecture

| Unit | File | Responsibility |
|---|---|---|
| Link codec (NEW, pure) | `mobile/lib/protocols/dnp3/dnp3_link.dart` | CRC-16/DNP; frame header build/parse; block-CRC wrap/unwrap; link-address filtering. No `dart:io`/Flutter. |
| Transport codec (NEW, pure) | `mobile/lib/protocols/dnp3/dnp3_transport.dart` | Transport header (FIR/FIN/SEQ) + segmentation/reassembly of app fragments. |
| App codec (NEW, pure) | `mobile/lib/protocols/dnp3/dnp3_app.dart` | Application fragment header + function codes + IIN; object-header (group/variation/qualifier/range) encode/decode; encode static BI/BO/AI/AO objects; decode CROB g12 + analog-output g41. |
| Outstation handler (NEW, pure) | `mobile/lib/protocols/dnp3/dnp3_outstation.dart` | Request→response over `DnpMap` + live tags: Class 0 integrity READ builds a response; SELECT/OPERATE/DIRECT_OPERATE decode → force-aware `writePath`; IIN + app sequence + restart bookkeeping. Never throws. |
| Config model (MODIFIED + NEW) | `mobile/lib/models/protocol_settings.dart` + `mobile/lib/models/dnp3_map.dart` | `DnpProtocolConfig` + `DnpMap`/`DnpMapEntry` + `autoGenerate`. |
| Socket host (NEW, only `dart:io`) | `mobile/lib/services/dnp3_host.dart` | `DnpHost extends ChangeNotifier`: `start`/`stop`, `ServerSocket.bind`, per-connection link-frame reassembly, dispatch to the pure outstation, write responses. Status/lastError/clientCount like `ModbusHost`; never crashes the app. |
| Outbound Protocols UI (MODIFIED) | `mobile/lib/screens/gateway_screen.dart` | A **DNP3** card: enable, port, outstation/master addresses, Start/Stop, status + endpoint, point-map editor (tag/pointType/index rows + Add + Regenerate). Web shows the same native-only note. Enable-off auto-stops the host (matching the WS-autostop behavior). |
| Host lifecycle (MODIFIED) | `mobile/lib/screens/workspace_shell.dart` | Own a `DnpHost`; stop it on every project-identity change + dispose (mirror the other hosts). |
| E2E harness (NEW) | `gateway/examples/dnp3_probe.rs`, `mobile/tool/dnp3_host_probe.dart`, `tool/dnp3_e2e.sh` | Real Rust `dnp3` master vs the in-app Dart outstation: Class 0 read of BI/AI, operate a binary + analog output, assert exact values. Mirrors the other probes. |

## Testing (same bar as the other protocols)

1. **Link-layer fixtures** (`dnp3_link_test.dart`): CRC-16/DNP against known spec test vectors; a full frame header + block-CRC layout encoded byte-for-byte; parse rejects a bad CRC / wrong destination cleanly (never throws); reassembly of a frame split across TCP chunks.
2. **App-codec fixtures** (`dnp3_app_test.dart`): object-header encode/decode for each qualifier used; a Class 0 response encoding BI (g1v2), AI int (g30v1) + float (g30v5), BO (g10v2), AO (g40) byte-exact; decode a CROB (g12v1) and an analog-output-block (g41) request; IIN bit packing; each function-code request/response shape.
3. **Outstation handler tests** (`dnp3_outstation_test.dart`): a Class 0 integrity read reflects live tag values across all four types; DIRECT_OPERATE of a CROB flips a BOOL output (`readPath` confirms); SELECT-then-OPERATE flips it (and OPERATE without a matching SELECT is rejected); analog-output-block writes a numeric tag; **force-aware** — an operate on a forced tag does not change it and returns the documented status; DEVICE_RESTART IIN set on first response, cleared on the g80v1 write; unknown function code → NO_FUNC_CODE_SUPPORT IIN, no crash.
4. **Host test** (`dnp3_host_test.dart`): bind ephemeral port, raw `Socket`, drive a real framed Class 0 read, assert the response frame (valid CRCs); malformed burst drops only that connection; start/stop lifecycle; two masters independent.
5. **Machine-proof E2E** (`tool/dnp3_e2e.sh`): Dart host serves a fixture project → Rust `dnp3` master connects, runs a Class 0 integrity poll (asserts BI + AI values), operates a binary output (CROB) and an analog output, reads back the changed values → `DNP3 PROBE PASS`. Merge gate; if the environment can't fetch/build the `dnp3` crate, report explicitly and fall back to `cargo build --examples` + the Dart suites (do not print PASS unless the real master ran).
6. **Regression:** full `flutter test`, `flutter analyze` ZERO, `flutter build web --release` compiles (codec pure/dart2js-safe; host `dart:io` not started on web), WS6 lossless round-trip guard green (additive `dnp3` config), `cargo build --examples` green.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); "DNP3", "IEEE 1815", and standard DNP3 terms are protocol terms and fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/dnp3/**` is PURE Dart (no Flutter/`dart:io`); the only `dart:io` is `dnp3_host.dart`. The outstation must NEVER crash the app: malformed input → clean error/dropped connection, never an uncaught throw.
- Control writes are force-aware (forcing wins) and go through `writePath`; RO point types reject control.
- Additive persistence: new `dnp3` config key omitted when null; WS6 lossless round-trip guard stays green. App byte-identical when hosting is stopped; hosting is explicit opt-in.
- All DNP3 wire integers little-endian; floats via `setFloat32`/`setInt32` (dart2js-safe); avoid `getInt64`/`setInt64`.
- Default port 20000; a port < 1024 note is irrelevant here but the bind error surfaces clearly (same status/lastError surface as the other hosts).

## Phasing (one spec → plan tasks)

1. **Map model + config** — `DnpMap`/`DnpMapEntry`/`autoGenerate`, `DnpProtocolConfig`, additive `ProtocolSettings` wiring + round-trip test.
2. **Data Link Layer** — CRC-16/DNP + frame header + block-CRC wrap/unwrap + address filtering + reassembly; link fixtures.
3. **Transport + Application codec** — transport header/segmentation; app fragment header + function codes + IIN + object headers; encode static BI/BO/AI/AO; decode CROB g12 + analog-output g41; app fixtures.
4. **Outstation handler** — Class 0 integrity READ + SELECT/OPERATE/DIRECT_OPERATE (force-aware) + IIN/sequence/restart; handler tests.
5. **Socket host + Outbound Protocols UI + shell lifecycle** — `DnpHost` + the DNP3 card (enable/port/addresses/start-stop/endpoint/map editor, auto-stop-on-disable) + shell teardown; host test.
6. **Rust `dnp3` master E2E + validation + docs + final review** — machine-proof, all gates, `docs/protocols/DNP3.md` rewrite, ROADMAP Phase 8 update, whole-branch review, merge.
