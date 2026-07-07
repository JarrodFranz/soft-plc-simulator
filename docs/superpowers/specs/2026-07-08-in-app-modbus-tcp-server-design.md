# In-App Modbus TCP Server (Phase 5 / WS24) Design

**Date:** 2026-07-08
**Status:** Approved by user (chat, 2026-07-08): full read+write function-code set; big-endian (high-word-first) multi-register order.
**Builds on:** WS19–20 (in-app pure-Dart OPC UA server + subscriptions) and ADR-010 (single app hosts everything in-process; no companion). Reuses the `OpcUaHost`/socket pattern, the `ProtocolSettings` additive config, the `OpcuaMap` per-project mapping pattern, force-aware writes, and the Outbound Protocols screen.

## Goal

Host a pure-Dart **Modbus TCP server** inside the app so any Modbus master (SCADA, PLC, `pymodbus`, ModScan, Rust `tokio-modbus`) can poll and write the project's tags over the four Modbus tables. Opt-in from the Outbound Protocols screen alongside OPC UA; runs on Android/desktop/iOS (web compiles but cannot host — same `dart:io` socket limitation as OPC UA). Machine-verified by a real third-party Modbus client E2E.

## Scope

**Function codes (full standard set):**

| FC | Name | Table |
|---|---|---|
| 0x01 | Read Coils | Coils (RW bits) |
| 0x02 | Read Discrete Inputs | Discrete Inputs (RO bits) |
| 0x03 | Read Holding Registers | Holding Registers (RW 16-bit) |
| 0x04 | Read Input Registers | Input Registers (RO 16-bit) |
| 0x05 | Write Single Coil | Coils |
| 0x06 | Write Single Register | Holding Registers |
| 0x0F | Write Multiple Coils | Coils |
| 0x10 | Write Multiple Registers | Holding Registers |

Any unsupported FC → exception 0x01 (Illegal Function). Out-of-range address → 0x02 (Illegal Data Address). Illegal quantity/value → 0x03 (Illegal Data Value). Internal failure → 0x04 (Server Device Failure).

**Out (v-next):** Modbus RTU/serial, FC other than the above (0x07 diagnostics, 0x16 mask-write, 0x17 read/write-multiple, file/FIFO), per-config word-swap toggle, multi-unit-id routing (v1 accepts any unit id and serves the one project).

## The four-table data model + tag mapping

Modbus exposes four separate address spaces. Tags map by **type** and **access**, mirroring the OPC UA node map:

- **Coils** (read/write bits) ← RW `BOOL` tags.
- **Discrete Inputs** (read-only bits) ← RO `BOOL` tags (`ioType == 'SimulatedOutput'`, matching `OpcuaMap.autoGenerate`'s RO rule).
- **Holding Registers** (read/write 16-bit words) ← RW numeric tags: `INT16` (1 reg), `INT32` (2 regs), `FLOAT64` (4 regs).
- **Input Registers** (read-only 16-bit words) ← RO numeric tags.

### `ModbusMap` (additive, mirrors `OpcuaMap`)

`ModbusProtocolConfig{ enabled (default false), port (default 502), ModbusMap map }`, added to `ProtocolSettings` under an additive JSON key `modbus` (omitted when null; back-compat unchanged). `ModbusMap{ List<ModbusMapEntry> entries }`; `ModbusMapEntry{ String tag, String table ('coil'|'discrete'|'holding'|'input'), int address, String access ('ReadOnly'|'ReadWrite') }`.

`ModbusMap.autoGenerate(PlcProject p)`: walk `p.tags`; for each, pick the table from (BOOL vs numeric) × (RW vs RO), assign the **next free address in that table** (sequential, starting at 0), and set `access` from `ioType`. A tag occupies **1 address** in a bit table, or **regsForType** consecutive addresses in a register table (`INT16`→1, `INT32`→2, `FLOAT64`→4). Composite/`TIMER`/`COUNTER` tags are skipped at the top level (their scalar members are not auto-mapped in v1 — documented; the user can hand-add member paths later, out of v1 scope). Editable + **Regenerate** in the UI, exactly like the OPC UA map.

### Register-file semantics (the pure handler operates on this)

At request time the handler builds a live view from `map` + the tag DB:

- **Reads** serve the current tag value, encoded per its type. A read spanning registers/coils not backed by any mapped tag returns **0 / false** for the gaps (lenient, so block-scan masters don't error), provided the request is otherwise legal. Illegal **quantity** (coils: 1–2000; registers: 1–125) or a range whose `start+quantity` overflows 0xFFFF → exception 0x03. Reading a table with no mapped entries still succeeds with zeros within a legal small range.
- **Writes** decode the wire value(s) to the target tag's type and apply via `writePath` — but a write whose address is **not mapped** or maps to a **read-only** entry → exception 0x02 (Illegal Data Address), so the master sees the refusal. A legal write echoes the standard response.
- **Force-aware:** if the target tag is forced, the write is **silently skipped** (forcing wins) and the standard echo response is still returned — the master simply reads back the unchanged forced value on its next poll. (This mirrors the engines' silent-skip; unlike OPC UA's explicit `Bad_UserAccessDenied`, Modbus has no per-write "refused-but-legal" status, so silent-skip + normal echo is the least-surprising behavior. Documented.)

### Multi-register encoding (big-endian, high-word-first)

- `INT16` → 1 register, bytes big-endian.
- `INT32` → 2 registers: register N = high 16 bits, N+1 = low 16 bits; bytes within each register big-endian ("ABCD").
- `FLOAT64` → 4 registers: IEEE-754 double, 8 bytes big-endian, mapped high-word-first into N..N+3.
- Coils / discrete inputs → 1 bit; read responses pack bits LSB-first per Modbus.

All wire integers (MBAP fields, addresses, quantities, register values) are big-endian per Modbus spec. Dart's `ByteData` int32/float64 accessors are avoided where dart2js-unsafe (per the OPC UA WS19 lesson: no `getInt64`/`setInt64`; 32-bit values via two 16-bit halves; `FLOAT64` via `ByteData.getFloat64`/`setFloat64`, which ARE web-safe — verified acceptable since hosting is native-only anyway, but the codec stays dart2js-compilable).

## Architecture (mirrors OPC UA)

| Unit | File | Responsibility |
|---|---|---|
| Codec + handler (NEW, pure) | `mobile/lib/protocols/modbus/modbus_pdu.dart` | MBAP header parse/build; PDU decode/encode for all 8 FCs; the request→response handler over a `ModbusRegisterView` built from `map` + live tags; exception responses. No `dart:io`/Flutter. |
| Register view (NEW, pure) | same file or `modbus_registers.dart` | Resolve (table,address)→(tag, wordIndex); read/write tag values with big-endian word packing; force-aware writes. |
| Socket host (NEW, only `dart:io`) | `mobile/lib/services/modbus_host.dart` | `ModbusHost extends ChangeNotifier`: `start(projectProvider)`/`stop()`, `ServerSocket.bind`, per-connection MBAP frame reassembly (read the 2-byte length at offset 4, slice when buffer ≥ 6+length), dispatch to the pure handler, write responses. Never crashes the app (guarded); `anyIPv4` native-only. Status/lastError/clientCount like `OpcUaHost`. |
| Config model (MODIFIED, additive) | `mobile/lib/models/protocol_settings.dart` + new `mobile/lib/models/modbus_map.dart` | `ModbusProtocolConfig` + `ModbusMap`/`ModbusMapEntry` + `autoGenerate`. |
| Outbound Protocols UI (MODIFIED) | `mobile/lib/screens/gateway_screen.dart` | A **Modbus TCP** card: enable toggle, port field (default 502), Start/Stop hosting, status + endpoint (`modbus-tcp://<ip>:<port>`), and the map editor (entry rows: tag picker, table, address, access) with Regenerate. Web shows the same "hosting needs desktop/mobile" note as OPC UA. |
| Host lifecycle (MODIFIED) | `mobile/lib/screens/workspace_shell.dart` | Own a `ModbusHost`; stop it on every project-identity change (mirror the `OpcUaHost` teardown). |
| E2E harness (NEW) | `gateway/examples/modbus_probe.rs`, `mobile/tool/modbus_host_probe.dart`, `tool/modbus_e2e.sh` | Real Rust `tokio-modbus` client vs the in-app Dart server: read/write coils + registers, assert exact values. Mirrors `opcua_probe`. |

## Testing (same bar as OPC UA)

1. **Codec fixtures** (`modbus_pdu_test.dart`): every FC request/response encoded byte-for-byte against hand-derived Modbus frames (incl. a full MBAP header, bit-packing LSB-first, big-endian registers, INT32 hi-word-first, FLOAT64 4-register layout, and each exception response 0x8x+code). Truncated/garbage frame → clean error, never a throw.
2. **Socketless handler tests** (`modbus_registers_test.dart`): each FC against a mapped project — read a coil/register reflects the live tag; write a coil/register updates the tag (`readPath` confirms); INT32/FLOAT64 round-trip through registers; unmapped read → 0-fill, unmapped/read-only write → 0x02; illegal quantity → 0x03; **force-aware** write to a forced tag is skipped (tag unchanged) with a normal echo.
3. **Host test** (`modbus_host_test.dart`): bind ephemeral port, raw `Socket`, drive a real MBAP framed request, assert the response; malformed burst drops only that connection; start/stop lifecycle; two clients independent.
4. **Machine-proof E2E** (`tool/modbus_e2e.sh`): Dart host serves a fixture project → Rust `tokio-modbus` client connects, reads holding registers + coils, writes a register + coil, reads back exact values → `MODBUS PROBE PASS`. Merge gate, runnable in-environment (mirrors the OPC UA probe).
5. **Regression:** full `flutter test`, `flutter analyze` ZERO, `flutter build web --release` compiles (codec is pure/dart2js-safe; host `dart:io` isn't started on web), WS6 round-trip guard green (additive `modbus` config), `cargo build --examples` green.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); "Modbus" and standard Modbus terms are protocol terms and fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/modbus/*` is PURE Dart (no Flutter/`dart:io`); the only `dart:io` is `modbus_host.dart`. The server must NEVER crash the app: malformed input → clean exception response or dropped connection, never an uncaught throw.
- Writes are force-aware (forcing wins) and go through `writePath`; read-only tables/entries reject writes with 0x02.
- Additive persistence: new `modbus` config key omitted when null; WS6 lossless round-trip guard stays green. App byte-identical when hosting is stopped; hosting is explicit opt-in.
- All wire encodings big-endian per Modbus; the codec stays dart2js-compilable (avoid `getInt64`/`setInt64`).
- Default port 502 (the Modbus standard clients expect). Note in docs: binding a port < 1024 may require elevated privileges on some OSes; the port is user-editable, so a non-privileged port (e.g. 5020) is available if bind fails — the host surfaces the bind error clearly (same status/lastError surface as OPC UA).

## Phasing (one spec → plan tasks)

1. **Map model + config** — `ModbusMap`/`ModbusMapEntry`/`autoGenerate`, `ModbusProtocolConfig`, additive `ProtocolSettings` wiring + round-trip test.
2. **PDU codec + register view** — pure MBAP/PDU codec for all 8 FCs + the register-file handler with big-endian packing + force-aware writes + exceptions; fixtures + handler tests.
3. **Socket host + Outbound Protocols UI** — `ModbusHost` + shell lifecycle + the Modbus TCP card (enable/port/start-stop/endpoint/map editor) + host test.
4. **Rust `tokio-modbus` E2E probe + validation + docs + final review** — machine-proof, all gates, `docs/protocols/modbus.md`, ROADMAP Phase 5 update, whole-branch review, merge.
