# In-App Modbus TCP Server (WS24 / Phase 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure-Dart Modbus TCP server hosted inside the app: any Modbus master reads/writes the project's tags over the four Modbus tables (coils, discrete inputs, holding & input registers), full read+write function-code set, big-endian word order. No companion process (ADR-010).

**Architecture:** Additive per-project config + map (`ModbusProtocolConfig`/`ModbusMap`, mirroring `OpcUaProtocolConfig`/`OpcuaMap`); a PURE MBAP/PDU codec + register-file handler in `mobile/lib/protocols/modbus/`; the only `dart:io` in `mobile/lib/services/modbus_host.dart` (`ServerSocket`, start/stop); a Modbus TCP card in the Outbound Protocols screen; verified by codec fixtures, socketless handler tests, and a Rust `tokio-modbus` client E2E probe.

**Tech Stack:** Dart (`dart:typed_data`; `dart:io` only in the host), Flutter for UI, `flutter_test`; Rust `tokio-modbus` client (dev E2E harness via `cargo`).

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); "Modbus" + standard Modbus terms are fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- `mobile/lib/protocols/modbus/*` is PURE Dart (no Flutter, no `dart:io`); sockets live ONLY in `services/modbus_host.dart`. The server must NEVER crash the app: malformed input → a clean Modbus exception response or a dropped connection, never an uncaught throw.
- Writes are force-aware (forcing wins) via `writePath`; read-only tables/entries reject writes with exception 0x02.
- Additive persistence: new `modbus` config key omitted from `toJson` when null; the WS6 lossless round-trip guard MUST stay green. App byte-identical when hosting is stopped; hosting is explicit opt-in.
- All wire encodings big-endian per Modbus; keep the codec dart2js-compilable (do NOT use `ByteData.getInt64`/`setInt64`; `getFloat64`/`setFloat64` ARE web-safe and allowed).
- Run cargo/flutter in the FOREGROUND with bounded timeouts; discard plugin-registrant churn before commits (`git checkout -- mobile/linux/flutter mobile/macos/Flutter mobile/windows/flutter`).

## Current-state facts (verified this session — build on these)

- `ProtocolSettings` (`protocol_settings.dart:76`): `{ String gatewayUrl, OpcUaProtocolConfig? opcua }`; `toJson` emits `gateway_url` + (if non-null) `opcua`; `fromJson` reads them; `defaults(p)` sets `opcua: OpcUaProtocolConfig.defaults(p)`. **Mirror exactly** for a new `ModbusProtocolConfig? modbus` under JSON key `modbus`.
- `OpcUaProtocolConfig` (`protocol_settings.dart:25`): `{ bool enabled=false, String namespaceUri, OpcuaMap map, int port=4840 }` + `fromJson`/`toJson`/`defaults(p)`. Model for `ModbusProtocolConfig { bool enabled=false, int port=502, ModbusMap map }`.
- `OpcuaMap`/`OpcuaNode` (`opcua_map.dart`): `OpcuaNode{ nodeId, tag, access }`; `OpcuaMap.autoGenerate(p)` walks `p.tags`, sets `access = tag.ioType == 'SimulatedOutput' ? 'ReadOnly' : 'ReadWrite'`, `nodeId = 'ns=1;s=${tag.path}'`. Model for `ModbusMap`/`ModbusMapEntry`.
- `PlcTag` (`project_model.dart:6`): `{ name, path, dataType ('BOOL'|'INT16'|'INT32'|'FLOAT64'|'STRING'|'TIMER'), value (dynamic), ioType ('SimulatedInput'|'SimulatedOutput'|'Internal'), isForced, forcedValue, ... }`.
- Force-aware write pattern (from `opcua_services.dart`): find the root tag for a path; if `rootTag.isForced && rootTag.name == path` then SKIP the write. `writePath(project, path, value)` / `readPath(project, path)` from `tag_resolver.dart` do the actual I/O and type coercion.
- `OpcUaHost` (`services/opcua_host.dart`): `ChangeNotifier`; `start(PlcProject Function() projectProvider)` binds `ServerSocket.bind(InternetAddress.anyIPv4, port)`, per-connection buffer reassembly (reads a size field, slices when buffer ≥ full frame, loops), `stop()`, `status`/`lastError`/`clientCount`, `_disposed` guard, never-crash try/catch. **Model for `ModbusHost`** (Modbus frame length = the UInt16 big-endian at buffer bytes 4–5; total frame = 6 + that length).
- `gateway_screen.dart`: the OPC UA card (enable Switch, port TextField, Start/Stop hosting, status pill, endpoint `SelectableText`, node-map editor with Regenerate) + the WS23 `hostingSupported` (`!kIsWeb`) gate + native-only note. **Model for the Modbus TCP card.**
- `workspace_shell.dart`: owns `OpcUaHost`, calls `_opcuaHost.stop()` on all project-identity changes. Add a parallel `ModbusHost`.

**Modbus wire reference (implement exactly — big-endian):**
- **MBAP header (7 bytes):** transactionId UInt16, protocolId UInt16 (=0x0000), length UInt16 (= 1 + PDU length, i.e. unitId + PDU), unitId UInt8. PDU follows.
- **PDU = functionCode UInt8 + data.** Response echoes transactionId/protocolId/unitId with its own length.
- **FC01 Read Coils / FC02 Read Discrete Inputs:** req `startAddr UInt16, quantity UInt16` (quantity 1–2000); resp `byteCount UInt8, coilBytes[]` (bits packed LSB-first: bit 0 of byte 0 = first coil).
- **FC03 Read Holding / FC04 Read Input Registers:** req `startAddr UInt16, quantity UInt16` (1–125); resp `byteCount UInt8 (=2·quantity), registers[]` (each UInt16 big-endian).
- **FC05 Write Single Coil:** req `addr UInt16, value UInt16` (0xFF00 = ON, 0x0000 = OFF, else 0x03); resp echoes req.
- **FC06 Write Single Register:** req `addr UInt16, value UInt16`; resp echoes req.
- **FC15 Write Multiple Coils:** req `startAddr UInt16, quantity UInt16, byteCount UInt8, coilBytes[]`; resp `startAddr UInt16, quantity UInt16`.
- **FC16 Write Multiple Registers:** req `startAddr UInt16, quantity UInt16, byteCount UInt8 (=2·quantity), registers[]`; resp `startAddr UInt16, quantity UInt16`.
- **Exception response:** `(functionCode | 0x80) UInt8, exceptionCode UInt8`. Codes: 0x01 Illegal Function, 0x02 Illegal Data Address, 0x03 Illegal Data Value, 0x04 Server Device Failure.
- **Multi-register value packing (big-endian, high-word-first):** INT16 → 1 reg; INT32 → reg N = high 16 bits, N+1 = low 16 bits; FLOAT64 → 8 bytes big-endian across regs N..N+3 (N = most-significant word).

**Sequencing:** T1 (map model + config, additive) → T2 (PDU codec + register-file handler, pure) → T3 (socket host + Outbound Protocols UI + shell lifecycle) → T4 (Rust E2E probe + validation + docs + final review).

---

### Task 1: `ModbusMap` model + `ModbusProtocolConfig` (additive, round-trip-safe)

**Files:**
- Create: `mobile/lib/models/modbus_map.dart`
- Modify: `mobile/lib/models/protocol_settings.dart` (add `ModbusProtocolConfig` + wire `modbus` into `ProtocolSettings`)
- Test: `mobile/test/modbus_map_test.dart`, extend `mobile/test/serialization_roundtrip_test.dart`

**Interfaces produced:**
- `class ModbusMapEntry { String tag; String table; int address; String access; }` — `table ∈ {'coil','discrete','holding','input'}`, `access ∈ {'ReadOnly','ReadWrite'}`; `fromJson`/`toJson` (keys `tag`,`table`,`address`,`access`).
- `class ModbusMap { List<ModbusMapEntry> entries; }` — `fromJson`/`toJson` (`{'entries': [...]}`); `static int regsForType(String dataType)` → `INT16`:1, `INT32`:2, `FLOAT64`:4, else 1; `static ModbusMap autoGenerate(PlcProject p)`.
- `class ModbusProtocolConfig { bool enabled=false; int port=502; ModbusMap map; }` — `fromJson`/`toJson` (keys `enabled`,`port`,`map`); `static ModbusProtocolConfig defaults(PlcProject p)`.
- `ProtocolSettings` gains `ModbusProtocolConfig? modbus` (JSON key `modbus`, omitted when null; `defaults(p)` sets it).

`autoGenerate` rules: iterate `p.tags` in order; skip composite/`TIMER`/`COUNTER`/`STRING` types (only `BOOL`/`INT16`/`INT32`/`FLOAT64`); per tag compute `rw = tag.ioType != 'SimulatedOutput'` (RO only for SimulatedOutput, matching OPC UA), `access = rw ? 'ReadWrite' : 'ReadOnly'`; choose table: `BOOL` → `rw ? 'coil' : 'discrete'`, numeric → `rw ? 'holding' : 'input'`; assign `address` = the running next-free counter for that table, then advance it by `1` (bit tables) or `regsForType(dataType)` (register tables).

- [ ] **Step 1: Write failing tests.**

```dart
// modbus_map_test.dart
test('regsForType maps widths', () {
  expect(ModbusMap.regsForType('INT16'), 1);
  expect(ModbusMap.regsForType('INT32'), 2);
  expect(ModbusMap.regsForType('FLOAT64'), 4);
  expect(ModbusMap.regsForType('BOOL'), 1);
});

test('autoGenerate assigns tables + sequential addresses by type/access', () {
  final p = PlcProject(id: 'x', name: 'X', controllerName: 'C', structDefs: const [],
    programs: const [], tasks: const [], hmis: const [], tags: [
      PlcTag(name: 'Run', path: 'Run', dataType: 'BOOL', value: false, ioType: 'Internal'),        // RW bool -> coil 0
      PlcTag(name: 'Lamp', path: 'Lamp', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),// RO bool -> discrete 0
      PlcTag(name: 'Speed', path: 'Speed', dataType: 'INT16', value: 0, ioType: 'Internal'),        // RW int16 -> holding 0
      PlcTag(name: 'Count', path: 'Count', dataType: 'INT32', value: 0, ioType: 'Internal'),        // RW int32 -> holding 1..2
      PlcTag(name: 'Level', path: 'Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput'), // RO f64 -> input 0..3
    ]);
  final m = ModbusMap.autoGenerate(p);
  ModbusMapEntry e(String t) => m.entries.firstWhere((x) => x.tag == t);
  expect([e('Run').table, e('Run').address, e('Run').access], ['coil', 0, 'ReadWrite']);
  expect([e('Lamp').table, e('Lamp').address, e('Lamp').access], ['discrete', 0, 'ReadOnly']);
  expect([e('Speed').table, e('Speed').address], ['holding', 0]);
  expect([e('Count').table, e('Count').address], ['holding', 1]); // after the 1-reg INT16
  expect([e('Level').table, e('Level').address, e('Level').access], ['input', 0, 'ReadOnly']);
});

test('ModbusProtocolConfig round-trips and ProtocolSettings omits modbus when null', () {
  final cfg = ModbusProtocolConfig(enabled: true, port: 5020,
    map: ModbusMap(entries: [ModbusMapEntry(tag: 'Run', table: 'coil', address: 3, access: 'ReadWrite')]));
  final back = ModbusProtocolConfig.fromJson(cfg.toJson());
  expect(back.enabled, true);
  expect(back.port, 5020);
  expect(back.map.entries.single.address, 3);
  final ps = ProtocolSettings(); // no modbus
  expect(ps.toJson().containsKey('modbus'), isFalse);
});
```

- [ ] **Step 2: Run → FAIL.** `cd mobile && flutter test test/modbus_map_test.dart`.
- [ ] **Step 3: Implement** `modbus_map.dart` + the `ModbusProtocolConfig` class in `protocol_settings.dart`; add `ModbusProtocolConfig? modbus` to `ProtocolSettings` (constructor param, `toJson` conditional `if (modbus != null) 'modbus': modbus!.toJson()`, `fromJson` `modbus: j['modbus'] != null ? ModbusProtocolConfig.fromJson(...) : null`, and `defaults(p)` sets `modbus: ModbusProtocolConfig.defaults(p)`). Pure Dart (import `project_model.dart` only).
- [ ] **Step 4: Tests → PASS**; add a round-trip case in `serialization_roundtrip_test.dart` (a project whose `protocols` has both `opcua` and `modbus` survives `toJson`/`fromJson`); WS6 guard green (default projects still have no `protocols` unless set); `flutter analyze` ZERO; full suite green.
- [ ] **Step 5: Commit** `feat(modbus): ModbusMap + ModbusProtocolConfig (additive per-project config)`.

---

### Task 2: MBAP/PDU codec + register-file handler (pure, fixture-tested)

**Files:**
- Create: `mobile/lib/protocols/modbus/modbus_pdu.dart` (codec + handler + register view)
- Test: `mobile/test/modbus_pdu_test.dart`, `mobile/test/modbus_registers_test.dart`

**Interfaces produced (consumed by Task 3):**
- `class ModbusFrame { int transactionId; int unitId; Uint8List pdu; }` and `ModbusFrame? parseMbap(Uint8List frame)` (returns null on malformed/short — protocolId must be 0), plus `Uint8List buildMbap(int transactionId, int unitId, Uint8List pdu)`.
- `class ModbusServer { ModbusServer({required PlcProject Function() projectProvider}); Uint8List handle(ModbusFrame req); }` — decodes the PDU, resolves against `projectProvider()`'s `protocols.modbus.map` + live tags, returns the response PDU (data only; the host MBAP-wraps it). Never throws — internal errors → exception PDU 0x04.
- Exception constants `class ModbusEx { static const illegalFunction=1, illegalDataAddress=2, illegalDataValue=3, serverFailure=4; }`.

Handler behavior (per the wire reference + register-file semantics in the spec):
- Read FCs: validate quantity bounds (coils/discrete 1–2000, registers 1–125) and `start+quantity ≤ 0x10000` → else 0x03; build the response from the register view (mapped value, else 0/false); coils packed LSB-first, registers big-endian.
- Write FCs: for each target address, look up the map entry; unmapped or `access=='ReadOnly'` → 0x02; decode the wire value to the tag's type; force-aware skip if the root tag is forced; else `writePath`; return the standard echo. FC05 value must be 0xFF00/0x0000 else 0x03.
- Register view: `INT32` occupies 2 regs (hi word first), `FLOAT64` 4 regs; a register write must cover a whole tag's span (a partial write to one of a multi-register tag's words → 0x03 Illegal Data Value, documented) — OR accept and merge words across a multi-register FC16 that spans the tag. **Decision (implement):** FC06 (single register) to an address that is part of a multi-register tag → 0x03 (can't half-write). FC16 covering exactly a tag's full register span writes it; a range that partially overlaps a multi-register tag → 0x03.

- [ ] **Step 1: Write failing codec tests** (`modbus_pdu_test.dart`): byte-exact fixtures — parse a known MBAP+FC03 request `00 01 00 00 00 06 01 03 00 00 00 02` → transactionId 1, unitId 1, pdu `03 00 00 00 02`; build a FC03 response for registers `[0x1234, 0x5678]` → pdu `03 04 12 34 56 78`; FC01 response for coils `[true,false,true]` → `01 01 05` (0b101); an exception → `83 02`; a truncated frame → `parseMbap` returns null. INT32 `0x0001E240` → regs `[0x0001, 0xE240]`; FLOAT64 round-trips through 4 regs.
- [ ] **Step 2: Write failing handler tests** (`modbus_registers_test.dart`): build a project + `ModbusMap` (a RW coil at 0, RO discrete at 0, a RW INT16 holding at 0, a RW INT32 holding at 1, a RO FLOAT64 input at 0); FC03 read holding [0,3] returns the INT16 then the INT32's two words from live tags; FC06 write holding 0 updates the INT16 tag (`readPath`); FC05 write coil 0 ON sets the bool tag; write to the RO discrete/input table or an unmapped address → 0x02; write a forced tag → tag unchanged + normal echo; FC06 to holding address 1 (mid-INT32) → 0x03; quantity 0 or 126 registers → 0x03.
- [ ] **Step 3: Run → FAIL. Step 4: Implement** `modbus_pdu.dart` (pure; `dart:typed_data` only; big-endian via `ByteData`; `getFloat64`/`setFloat64` allowed; NO `getInt64`). Force-aware write mirrors `opcua_services.dart`.
- [ ] **Step 5: Tests → PASS**; `flutter analyze` ZERO; full suite green; `flutter build web --release` still compiles (pure codec).
- [ ] **Step 6: Commit** `feat(modbus): MBAP/PDU codec + register-file handler (all 8 FCs, force-aware)`.

---

### Task 3: Socket host + Outbound Protocols "Modbus TCP" card + shell lifecycle

**Files:**
- Create: `mobile/lib/services/modbus_host.dart`
- Modify: `mobile/lib/screens/gateway_screen.dart` (Modbus TCP card), `mobile/lib/screens/workspace_shell.dart` (own + tear down a `ModbusHost`)
- Test: `mobile/test/modbus_host_test.dart`, extend `mobile/test/gateway_screen_test.dart`

**Interfaces consumed:** `ModbusServer`/`parseMbap`/`buildMbap` (T2); `ModbusProtocolConfig` (T1).

- [ ] **Step 1: `ModbusHost`** (`ChangeNotifier`, the ONLY `dart:io` in modbus): `start(PlcProject Function() projectProvider)` reads `projectProvider().protocols?.modbus` (must be non-null + `enabled`, else `error` status + message, no bind); binds `ServerSocket.bind(InternetAddress.anyIPv4, port)`; per connection accumulates bytes, and while the buffer has ≥ 6 bytes, reads `length = (buf[4]<<8)|buf[5]`, waits until buffer ≥ `6+length`, slices that frame, `parseMbap` → `ModbusServer.handle` → `buildMbap` → `socket.add`; drops a connection on any error; hostile length guard (cap frame at e.g. 260 bytes, the Modbus TCP max ADU). `stop()` closes all; `status`/`lastError`/`clientCount`/`endpointUrl` (`modbus-tcp://<ip>:<port>`); `_disposed` guard; every path try/caught so a bad client never crashes the app. Test with a raw ephemeral-port `Socket`: send a real FC03 request, assert the framed response; a garbage burst drops only that connection; start/stop lifecycle.
- [ ] **Step 2: UI** (`gateway_screen.dart`): add a **Modbus TCP** card below the OPC UA card — enable `Switch` (creates `protocols.modbus` via a `_ensureModbus()` mirroring `_ensureProtocols`), port `TextField` (default 502), Start/Stop hosting (gated by `hostingSupported`, same web note), status pill + endpoint `SelectableText`, and a map editor: a list of `ModbusMapEntry` rows (tag `TagAutocompleteField`, table dropdown coil/discrete/holding/input, address number field, access dropdown) + a **Regenerate** button calling `ModbusMap.autoGenerate`. Wire a `ModbusHost` param into `GatewayScreen` (like `host`). Widget tests: card renders; toggling enable reveals controls; Regenerate populates entries; no overflow 320/1400; hosting disabled + note on web (`hostingSupported: false`).
- [ ] **Step 3: Shell** (`workspace_shell.dart`): construct a `ModbusHost`, pass it to `GatewayScreen`, and call `_modbusHost.stop()` everywhere `_opcuaHost.stop()` is called (all 6 project-identity changes) + dispose it.
- [ ] **Step 4: Gates.** full `flutter test` green · `flutter analyze` ZERO · `flutter build web --release` compiles · no overflow. Discard plugin churn.
- [ ] **Step 5: Commit** `feat(modbus): in-app ServerSocket host + Outbound Protocols Modbus card + shell lifecycle`.

---

### Task 4: Rust `tokio-modbus` E2E probe + validation + docs + final review

**Files:**
- Create: `gateway/examples/modbus_probe.rs`, `mobile/tool/modbus_host_probe.dart`, `tool/modbus_e2e.sh`
- Modify: `gateway/Cargo.toml` (dev-dep `tokio-modbus` + `tokio`), `docs/protocols/modbus.md` (new), `ROADMAP.md`

- [ ] **Step 1: Dart host probe** (`mobile/tool/modbus_host_probe.dart`): a `dart run` CLI that builds a fixture project (a RW coil, a RW holding INT16, a RO input) with an enabled `ModbusProtocolConfig`, starts `ModbusHost` on a port arg, prints `READY`, serves until killed; mutates the INT16 tag to a known value (e.g. 4242) shortly after READY so the probe can also observe a server-side change.
- [ ] **Step 2: Rust probe** (`gateway/examples/modbus_probe.rs`): using `tokio-modbus` client (TCP), connect to `127.0.0.1:<port>`, `read_holding_registers(0, 1)` and assert it equals the seeded value; `write_single_register(0, 7777)` then read-back == 7777; `write_single_coil(0, true)` then `read_coils(0,1)` == [true]; print `MODBUS PROBE PASS` / exit 1 on mismatch or timeout. Add `tokio-modbus` + `tokio` (rt, macros) to `gateway/Cargo.toml` dev-dependencies.
- [ ] **Step 3: Script** (`tool/modbus_e2e.sh`): start the Dart host (`dart run tool/modbus_host_probe.dart <port>`), wait for `READY`, `cargo run --example modbus_probe -- 127.0.0.1 <port>` (bounded timeout), kill the host, propagate the exit code. **RUN IT** and paste the output — require `MODBUS PROBE PASS`.
- [ ] **Step 4: Gates.** `cd mobile && flutter test` (all green incl. round-trip) · `flutter analyze` ZERO · `flutter build web --release` compiles · `cd gateway && cargo build --examples` green · branding grep `grep -riE "openplc|beremiz|codesys|rslogix" mobile/lib mobile/test gateway/examples tool docs/protocols` clean. Discard plugin churn.
- [ ] **Step 5: Docs.** `docs/protocols/modbus.md`: the 4-table mapping, the full FC set, big-endian word order, force-aware behavior, the 502/privileged-port note, how to connect a master (`pymodbus`/ModScan/UAExpert-equiv), and the v1 simplifications (no RTU, top-level composites unmapped, silent-skip on forced writes). `ROADMAP.md`: mark Phase 5 (Modbus TCP) ✅ shipped with the Rust-client E2E proof; keep MQTT/DNP3 ⏳.
- [ ] **Step 6: Commit** `feat(modbus): Rust tokio-modbus E2E probe + docs`, then hand the branch to the final whole-branch review (superpowers:requesting-code-review) and merge via superpowers:finishing-a-development-branch.

---

## Self-review notes
- **Spec coverage:** map model + additive config (T1); pure MBAP/PDU codec + register handler for all 8 FCs + big-endian packing + force-aware + exceptions (T2); socket host + Modbus card + shell lifecycle (T3); Rust E2E + validation + docs + ROADMAP (T4). Matches the spec's 4-phase plan.
- **Type consistency:** `ModbusMapEntry{tag,table,address,access}`, `ModbusMap.regsForType/autoGenerate`, `ModbusProtocolConfig{enabled,port,map}`, `ProtocolSettings.modbus`, `ModbusFrame{transactionId,unitId,pdu}`, `parseMbap`/`buildMbap`, `ModbusServer.handle`, `ModbusEx` used consistently across tasks.
- **Additive persistence:** only the `modbus` config key (omitted when null); WS6 round-trip guard asserted T1 + T4. No engine/scan changes.
- **Never-crash + pure boundary:** codec/handler pure and throw-free (exceptions → PDU); `dart:io` only in the host; force-aware writes; web build compiles (host not started on web).
- **YAGNI:** no RTU, no extra FCs, no word-swap toggle, top-level composites unmapped in v1 — all deferred per spec.
