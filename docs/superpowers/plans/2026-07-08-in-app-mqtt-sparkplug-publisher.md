# In-App MQTT + Sparkplug B Publisher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host a pure-Dart MQTT 3.1.1 client in the app that publishes project tags to any broker as JSON *or* Sparkplug B, and (opt-in) accepts remote writes — opt-in from the Outbound Protocols screen alongside OPC UA/Modbus, machine-verified against a real broker.

**Architecture:** Inverts the OPC UA/Modbus server pattern — a *client* Socket connecting outbound to a broker, pushing on a ~20 Hz tick (report-by-exception + heartbeat) instead of answering polls. Pure codec (`mqtt_codec.dart`) + pure Sparkplug protobuf encoder (`mqtt_sparkplug.dart`) + pure session logic (`mqtt_publisher.dart`); the only `dart:io` is `mqtt_host.dart`. Config is additive (`mqtt` key); the broker password is in-memory only. Reads/writes go through the existing `readPath`/`writePath` (already force-aware after the interop workstream).

**Tech Stack:** Flutter/Dart (pure model/codec + Flutter host/UI), Rust E2E (`rumqttd` broker + `rumqttc` subscriber + `prost`-decoded Sparkplug). Spec: `docs/superpowers/specs/2026-07-08-in-app-mqtt-sparkplug-publisher-design.md`.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); "MQTT", "Sparkplug B", `spBv1.0`, and standard MQTT/Sparkplug terms are fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/mqtt/**` is PURE Dart (no Flutter/`dart:io`); the ONLY `dart:io` file is `mobile/lib/services/mqtt_host.dart`. The client must NEVER crash the app: malformed broker input → clean drop/reconnect, never an uncaught throw.
- **Secrets:** the broker **password is never persisted or committed** — in-memory only, entered per session. `username` (non-sensitive) may persist. Nothing sensitive in project JSON.
- Remote writes are **opt-in** (`allowRemoteWrites` default false) and go through `writePath` (already force-aware).
- Additive persistence: the `mqtt` config key is omitted when null; the WS6 lossless round-trip guard stays green. App byte-identical when disconnected; connecting is explicit opt-in.
- All MQTT wire integers big-endian; protobuf per its wire spec (varint + little-endian `fixed64`/`double`); codecs stay dart2js-compilable — never use `getInt64`/`setInt64`; `getFloat64`/`setFloat64` are allowed.
- Default broker port 1883 (plain) / 8883 (TLS). Run Flutter from `mobile/`, Rust from `gateway/`, git from repo root.
- Sparkplug defaults: `group_id = "SoftPLC"`, `edge_node_id` falls back to the controller/project name. Remote writes default OFF.

---

### Task 1: MqttMap + MqttProtocolConfig (additive config)

**Files:**
- Create: `mobile/lib/models/mqtt_map.dart`
- Modify: `mobile/lib/models/protocol_settings.dart` (add `MqttProtocolConfig` + `ProtocolSettings.mqtt`)
- Test: `mobile/test/mqtt_map_test.dart`, and extend the existing protocol-settings round-trip test

**Interfaces:**
- Consumes: `PlcProject`, `PlcTag` (name/dataType/ioType/value), the additive `ProtocolSettings` pattern from `OpcUaProtocolConfig`/`ModbusProtocolConfig`.
- Produces: `MqttMapEntry{String tag, String metric, bool writable}`, `MqttMap{List<MqttMapEntry> entries}` with `fromJson`/`toJson`/`autoGenerate`, `MqttProtocolConfig{enabled, host, port, tls, format, baseTopic, groupId, edgeNodeId, qos, heartbeatSeconds, allowRemoteWrites, username, MqttMap map}` (NO password field), and `ProtocolSettings.mqtt` under JSON key `mqtt`.

- [ ] **Step 1: Write the failing tests**

`mobile/test/mqtt_map_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';

void main() {
  test('autoGenerate maps scalar tags, metric=name, writable from ioType', () {
    final p = PlcProject(/* match real ctor */); // add BOOL SimulatedInput 'A', FLOAT64 SimulatedOutput 'B', a struct/composite 'C'
    final m = MqttMap.autoGenerate(p);
    expect(m.entries.map((e) => e.tag), containsAll(['A', 'B']));
    expect(m.entries.any((e) => e.tag == 'C'), isFalse); // composites skipped
    expect(m.entries.firstWhere((e) => e.tag == 'A').writable, isTrue);   // SimulatedInput -> writable
    expect(m.entries.firstWhere((e) => e.tag == 'B').writable, isFalse);  // SimulatedOutput -> read-only
    expect(m.entries.firstWhere((e) => e.tag == 'A').metric, 'A');
  });

  test('MqttMap json round-trips', () {
    final m = MqttMap(entries: [MqttMapEntry(tag: 'A', metric: 'A', writable: true)]);
    final r = MqttMap.fromJson(m.toJson());
    expect(r.entries.single.tag, 'A');
    expect(r.entries.single.writable, isTrue);
  });
}
```

Extend the existing protocol-settings round-trip test (find it under `mobile/test/`) with a case asserting: a `ProtocolSettings` carrying an `MqttProtocolConfig` round-trips through `toJson`/`fromJson` losslessly; a `ProtocolSettings` with `mqtt == null` omits the `mqtt` key entirely (`toJson().containsKey('mqtt')` is false); and NO `password` key ever appears in the serialized config.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mobile && flutter test test/mqtt_map_test.dart`
Expected: FAIL (mqtt_map.dart doesn't exist).

- [ ] **Step 3: Implement**

Create `mqtt_map.dart` mirroring `modbus_map.dart`'s structure: `MqttMapEntry` (tag/metric/writable) with fromJson/toJson; `MqttMap` (entries) with fromJson/toJson; `MqttMap.autoGenerate(PlcProject p)` — for each top-level scalar tag (dataType in `{'BOOL','INT16','INT32','FLOAT64'}`, skip composites/TIMER/COUNTER/STRING exactly like `ModbusMap.autoGenerate`), add `MqttMapEntry(tag: t.name, metric: t.name, writable: t.ioType != 'SimulatedOutput')`.

In `protocol_settings.dart` add `MqttProtocolConfig` mirroring `ModbusProtocolConfig` but with the fields listed in Interfaces and **no password field**; `toJson`/`fromJson` with a default on every field (enabled=false, host='', port=1883, tls=false, format='json', baseTopic='softplc', groupId='SoftPLC', edgeNodeId='', qos=0, heartbeatSeconds=5, allowRemoteWrites=false, username='', map). Add `MqttProtocolConfig? mqtt` to `ProtocolSettings` with `if (mqtt != null) 'mqtt': mqtt!.toJson()` in toJson, `mqtt: j['mqtt'] != null ? MqttProtocolConfig.fromJson(...) : null` in fromJson, and `mqtt: MqttProtocolConfig.defaults(p)` in `defaults`. `MqttProtocolConfig.defaults(p)` sets `edgeNodeId: ''` (host resolves the fallback to project name at connect time) and `map: MqttMap.autoGenerate(p)`.

- [ ] **Step 4: Run tests**

Run: `cd mobile && flutter test test/mqtt_map_test.dart test/` (the map test + the round-trip suite)
Expected: PASS. `cd mobile && flutter analyze lib/models/mqtt_map.dart lib/models/protocol_settings.dart` → zero issues.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/mqtt_map.dart mobile/lib/models/protocol_settings.dart mobile/test/mqtt_map_test.dart mobile/test/<roundtrip_test>.dart
git commit -m "feat(mqtt): MqttMap + MqttProtocolConfig (additive, no persisted password)"
```

---

### Task 2: MQTT 3.1.1 control-packet codec (pure)

**Files:**
- Create: `mobile/lib/protocols/mqtt/mqtt_codec.dart`
- Test: `mobile/test/mqtt_codec_test.dart`

**Interfaces:**
- Produces (all pure, dart2js-safe): remaining-length varint `encodeRemainingLength(int)`/`decodeRemainingLength`; UTF-8 string framing `encodeMqttString(String)` (2-byte big-endian length + bytes); packet builders `encodeConnect({clientId, keepAliveSecs, cleanSession, username, password, willTopic, willPayload, willRetain, willQos})`, `encodePublish({topic, payload, qos, retain, packetId})`, `encodeSubscribe({packetId, topicFilters})`, `encodePingReq()`, `encodeDisconnect()`; parsers `parseConnack(bytes) -> MqttConnack{sessionPresent, returnCode}`, `parsePuback -> packetId`, `parseSuback`, and an inbound PUBLISH decoder `parsePublish -> MqttPublish{topic, payload, qos, packetId, retain}`; a streaming reassembler `MqttFrameBuffer` that `add(bytes)` and yields complete packets (`fixed header type/flags + remaining-length + body`), tolerating split/coalesced TCP chunks. Nothing here throws on garbage — a bad length or short buffer yields "need more" / a drop signal.

**MQTT 3.1.1 wire facts (verify against the OASIS MQTT 3.1.1 spec):** fixed header byte = `(packetType << 4) | flags`; packet types CONNECT=1, CONNACK=2, PUBLISH=3, PUBACK=4, SUBSCRIBE=8 (flags `0b0010`), SUBACK=9, PINGREQ=12, PINGRESP=13, DISCONNECT=14. Remaining-length is 1–4 bytes, 7 bits each, high bit = continuation. CONNECT variable header: protocol name `"MQTT"` (as an MQTT string), protocol level `0x04`, connect flags byte (username<<7 | password<<6 | willRetain<<5 | willQos<<3 | willFlag<<2 | cleanSession<<1), keepAlive u16; then payload: clientId, [willTopic, willPayload], [username], [password] each as MQTT strings/binary. PUBLISH variable header: topic string, then (QoS>0) packetId u16, then payload bytes (remaining). All lengths big-endian.

- [ ] **Step 1: Write the failing tests**

`mobile/test/mqtt_codec_test.dart` — byte-exact fixtures. Cover:
- `encodeRemainingLength` at boundaries 0→`[0x00]`, 127→`[0x7F]`, 128→`[0x80,0x01]`, 16383→`[0xFF,0x7F]`, 16384→`[0x80,0x80,0x01]`; and `decodeRemainingLength` inverse (incl. "need more bytes" when truncated).
- A CONNECT with clientId "plc", keepAlive 30, cleanSession true, a will (`softplc/plc/status` = "OFFLINE", retain, QoS0), username "u", password "p" → assert the exact byte sequence (hand-derive the header + flags byte `0b1100_1110` = username+password+willRetain+willFlag+clean).
- A PUBLISH QoS0 retain to `softplc/plc/status` payload "ONLINE" → exact bytes (no packetId). A PUBLISH QoS1 packetId 7 → includes the u16 packetId.
- SUBSCRIBE packetId 1 to `softplc/plc/tags/+/set` QoS0 → exact bytes; parseSuback/parsePuback/parseConnack for canonical response bytes; PINGREQ = `[0xC0,0x00]`, DISCONNECT = `[0xE0,0x00]`.
- `MqttFrameBuffer`: feed a CONNACK split across two `add()` calls → one packet emitted only after the second; feed two PUBLISHes concatenated → two packets; feed a packet with a remaining-length claiming more than arrives → nothing emitted (waits); never throws on random bytes.

- [ ] **Step 2: Run to verify fail**

Run: `cd mobile && flutter test test/mqtt_codec_test.dart` → FAIL (codec absent).

- [ ] **Step 3: Implement** `mqtt_codec.dart` per the wire facts above. Use `BytesBuilder`/`Uint8List`/`ByteData` (16-bit big-endian via `setUint16`); no `getInt64`. The reassembler reads the fixed header, decodes remaining-length incrementally (return "need more" if the varint or body is incomplete), and slices the whole packet. Every parser guards length and returns a nullable/"drop" result rather than throwing.

- [ ] **Step 4: Run** `cd mobile && flutter test test/mqtt_codec_test.dart` → PASS; `flutter analyze lib/protocols/mqtt/mqtt_codec.dart` → zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/mqtt/mqtt_codec.dart mobile/test/mqtt_codec_test.dart
git commit -m "feat(mqtt): pure MQTT 3.1.1 control-packet codec + streaming reassembler"
```

---

### Task 3: Sparkplug B protobuf codec (pure)

**Files:**
- Create: `mobile/lib/protocols/mqtt/mqtt_sparkplug.dart`
- Test: `mobile/test/mqtt_sparkplug_test.dart`

**Interfaces:**
- Produces (pure, dart2js-safe): a hand-rolled protobuf encoder for the Eclipse Tahu `Payload`/`Metric` schema — `SparkplugPayload{int timestampMs, int seq, List<SparkplugMetric> metrics}`; `SparkplugMetric{String? name, int? alias, int datatype, Object value}`; `encodePayload(SparkplugPayload) -> Uint8List`; datatype constants `Int8=1,Int16=2,Int32=3,Int64=4,UInt64=8,Float=9,Double=10,Boolean=11,String=12`; a `SparkplugDatatype.forTag(String dataType)` mapping BOOL→Boolean, INT16→Int16, INT32→Int32, FLOAT64→Double; and a **test-only** `decodePayload(Uint8List) -> SparkplugPayload` used by the tests (production only encodes). Also a small `SparkplugSeq` counter (0→255→0) and `bdSeq` bookkeeping helper.

**Protobuf wire facts (Tahu sparkplug_b Payload; verify against the official schema):** wire types — varint=0, 64-bit=1, length-delimited=2. Field tag byte = `(fieldNumber << 3) | wireType`. `Payload`: field 1 `timestamp` (uint64, varint), field 2 `metrics` (repeated message, length-delimited), field 3 `seq` (uint64, varint). `Metric`: field 1 `name` (string), field 2 `alias` (uint64, varint), field 3 `timestamp` (uint64), field 4 `datatype` (uint32, varint), and the value one-of by datatype: `int_value` field 5 (uint32 varint) for Int8/16/32 & Boolean(0/1), `long_value` field 6 (uint64 varint) for Int64/UInt64, `float_value` field 7 (32-bit), `double_value` field 8 (64-bit little-endian via `setFloat64(..., Endian.little)`), `boolean_value` field 9 (varint 0/1), `string_value` field 10 (string). Use `boolean_value`(9) for BOOL, `int_value`(5) for Int16/Int32, `double_value`(8) for Double, `long_value`(6) for the `bdSeq` UInt64. bdSeq stays small (a birth counter) so it never exceeds the 53-bit safe integer range — document this; do not use `setInt64`.

- [ ] **Step 1: Write the failing tests**

`mobile/test/mqtt_sparkplug_test.dart`:
- Encode a minimal `Payload{timestamp:0, seq:0, metrics:[Metric{name:'A', alias:1, datatype:Boolean, value:true}]}` and assert the exact protobuf bytes (hand-derive: `0x08 00` timestamp, `0x12 <len> ...` metric submessage with `0x0A 01 'A'` name, `0x10 01` alias, `0x20 0B` datatype=11, `0x48 01` boolean_value=true, `0x18 00` seq).
- Round-trip every datatype through `decodePayload(encodePayload(x))`: Boolean true/false, Int16 (−5 via int_value semantics), Int32 (70000), Double (3.5), plus a UInt64 `bdSeq` via long_value.
- `SparkplugDatatype.forTag` mapping for BOOL/INT16/INT32/FLOAT64.
- `SparkplugSeq` rolls 255→0; NBIRTH uses seq 0.

- [ ] **Step 2: Run to verify fail** → `cd mobile && flutter test test/mqtt_sparkplug_test.dart` FAILs.

- [ ] **Step 3: Implement** `mqtt_sparkplug.dart`: varint encoder (`_writeVarint(int)` — loop 7 bits + continuation; values are non-negative here), length-delimited helper (`_writeField(fieldNum, wireType)` + length prefix for submessages), `double_value` via `ByteData(8)..setFloat64(0, v, Endian.little)`. `encodePayload` builds Payload fields in order; `encodeMetric` emits name (only in NBIRTH), alias, datatype, and the value field for the datatype. The test-only `decodePayload` walks the tag/wiretype stream. All non-negative varints; document the bdSeq 53-bit note.

- [ ] **Step 4: Run** `cd mobile && flutter test test/mqtt_sparkplug_test.dart` PASS; `flutter analyze lib/protocols/mqtt/mqtt_sparkplug.dart` zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/mqtt/mqtt_sparkplug.dart mobile/test/mqtt_sparkplug_test.dart
git commit -m "feat(mqtt): pure Sparkplug B protobuf Payload/Metric encoder (+ test decoder)"
```

---

### Task 4: Publisher session logic (pure, format-agnostic)

**Files:**
- Create: `mobile/lib/protocols/mqtt/mqtt_publisher.dart`
- Test: `mobile/test/mqtt_publisher_test.dart`

**Interfaces:**
- Consumes: `MqttProtocolConfig`, `MqttMap`, `PlcProject`, `readPath` (force-aware), the codecs from Tasks 2–3.
- Produces: `MqttPublisher` holding per-connection state (alias table, seq/bdSeq, last-published cache). Methods (all pure — they return descriptors, the host does the socket I/O): `birthMessages(project)` → the retained birth publish(es) (JSON: `{base}/{controller}/status`="ONLINE"; Sparkplug: NBIRTH with all metrics+aliases+bdSeq, seq 0); `willMessage(project)` → the LWT descriptor (JSON status "OFFLINE"; Sparkplug NDEATH with bdSeq); `changedPublishes(project)` → report-by-exception telemetry for tags whose value changed since last call (JSON per-tag; Sparkplug NDATA alias-only, seq++); `heartbeatPublishes(project)` → all mapped tags regardless of change; `commandTopicFilters(project)` → the `/set` (JSON) or NCMD (Sparkplug) subscriptions (empty when `allowRemoteWrites` false); `decodeCommand(topic, payload, project)` → `List<({String tagPath, Object value})>` to apply (JSON `/set` raw-or-`{"value":x}`; Sparkplug NCMD metrics by name/alias), skipping non-writable/unknown, never throwing. A publish descriptor = `{String topic, Uint8List payload, int qos, bool retain}`.

- [ ] **Step 1: Write the failing tests** covering, against a mapped fixture project (JSON and Sparkplug configs):
  - `birthMessages` JSON = retained `softplc/<ctrl>/status` "ONLINE"; Sparkplug NBIRTH topic `spBv1.0/SoftPLC/NBIRTH/<node>`, seq 0, contains a metric per mapped tag with a stable alias + a `bdSeq` metric.
  - `changedPublishes`: unchanged tag → no publish; change one tag → exactly that tag/metric republished (Sparkplug alias-only, seq incremented); `heartbeatPublishes` → all tags.
  - JSON telemetry payload shape `{"value","quality","timestamp","forced"}` (assert value + forced fields; timestamp may be injected).
  - `decodeCommand`: JSON `/set` raw "true" and `{"value":true}` → `(tag, true)`; Sparkplug NCMD metric by alias → the right tag; non-writable metric / unknown topic / garbage payload → empty list, no throw. `commandTopicFilters` empty when `allowRemoteWrites` false.
  - **Force-aware:** the publisher reads via `readPath`, so a forced tag publishes its forced value — assert a forced tag's telemetry reflects the force (this exercises the interop seam end-to-end at the publisher level).

- [ ] **Step 2: Run to verify fail** → FAIL.

- [ ] **Step 3: Implement** `mqtt_publisher.dart`. Sanitize the controller name for topics (spaces→`_`, strip `/#+`). Keep a `Map<String,Object?> _lastPublished` for report-by-exception, an alias table `Map<String,int>` assigned in map order at birth, and `_seq`/`_bdSeq`. Values read through `readPath(project, entry.tag)`. Timestamps are passed in by the host (keep the pure unit deterministic — accept a `nowMs` param). Command decode routes to `entry.tag` only for `writable` entries when `allowRemoteWrites`.

- [ ] **Step 4: Run** `cd mobile && flutter test test/mqtt_publisher_test.dart` PASS; analyze zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/mqtt/mqtt_publisher.dart mobile/test/mqtt_publisher_test.dart
git commit -m "feat(mqtt): pure publisher session (birth/telemetry/command, report-by-exception, force-aware)"
```

---

### Task 5: Socket host + Outbound Protocols UI + shell lifecycle

**Files:**
- Create: `mobile/lib/services/mqtt_host.dart` (only `dart:io` in MQTT)
- Modify: `mobile/lib/screens/gateway_screen.dart` (MQTT card + `_setMqttEnabled`)
- Modify: `mobile/lib/screens/workspace_shell.dart` (own an `MqttHost`; disconnect on project-identity change + dispose)
- Test: `mobile/test/mqtt_host_test.dart`

**Interfaces:**
- Consumes: the codecs + publisher, `MqttProtocolConfig`, `writePath` (force-aware).
- Produces: `MqttHost extends ChangeNotifier` with `connect(PlcProject Function() projectProvider, {required String password})` / `disconnect()`, status/lastError/connected/publishCount surface (mirror `OpcUaHost`/`ModbusHost`); `Socket`/`SecureSocket.connect` to `host:port`; CONNECT with LWT will + optional auth; keepalive PINGREQ timer; ~20 Hz tick driving `changedPublishes` + periodic `heartbeatPublishes`; QoS-1 PUBACK tracking; inbound PUBLISH → `decodeCommand` → force-aware `writePath`; reconnect/backoff; never throws (guarded). Password held in-memory only.

- [ ] **Step 1: Write the failing test** `mobile/test/mqtt_host_test.dart`: stand up a minimal in-test TCP server (dart:io `ServerSocket` bound to an ephemeral port) that accepts a connection, replies CONNACK(accepted) to the client's CONNECT, and captures subsequent PUBLISH bytes. Assert the host: connects and sends a well-formed CONNECT (protocol "MQTT"/level 4, keepAlive, will flags set); publishes the birth (retained status/NBIRTH) then a telemetry change; applies an inbound command PUBLISH (verify a `writePath` target changed); disconnect/reconnect lifecycle updates status. Feed the host garbage bytes and assert it drops the connection without throwing. (Model harness/timeouts on `mobile/test/*opcua_host*`/`*modbus_host*` tests.)

- [ ] **Step 2: Run to verify fail** → FAIL.

- [ ] **Step 3: Implement**
  1. `mqtt_host.dart` mirroring `modbus_host.dart`/`opcua_host.dart`: `Socket.connect` (or `SecureSocket.connect` when `tls`), feed inbound bytes to an `MqttFrameBuffer`, dispatch CONNACK/PUBLISH/PINGRESP/PUBACK, own a keepalive `Timer` (keepAlive/2) and a 50 ms publish tick, backoff reconnect on socket error/done. Resolve `edgeNodeId` fallback to the project name here. Hold `password` only as a field set in `connect`.
  2. `gateway_screen.dart`: an MQTT card mirroring the OPC UA/Modbus cards — enable toggle (`_setMqttEnabled`), host/port fields, TLS switch, format dropdown (json/sparkplugB), format-conditional fields (baseTopic for JSON; groupId/edgeNodeId for Sparkplug), QoS + heartbeat + allow-remote-writes toggles, username field, a **password field bound to in-memory state (never written to the project)**, Connect/Disconnect, status + endpoint (`mqtt://host:port` / `mqtts://…`), and the map editor (reuse the Modbus editable-row pattern: tag/metric/writable rows + Add + Regenerate, dotted-path tag options). Web shows the same "hosting needs desktop/mobile" note as the other cards (`hostingSupported`/`kIsWeb`).
  3. `workspace_shell.dart`: construct an `MqttHost`, `disconnect()` it at every project-identity-change site where `_opcuaHost`/`_modbusHost` are stopped, and in `dispose`.

- [ ] **Step 4: Run** `cd mobile && flutter test test/mqtt_host_test.dart test/` PASS; `flutter analyze` zero across touched files; confirm no overflow at 320/360/1400 in the MQTT card (add a widget overflow check if the other cards have one).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/services/mqtt_host.dart mobile/lib/screens/gateway_screen.dart mobile/lib/screens/workspace_shell.dart mobile/test/mqtt_host_test.dart
git commit -m "feat(mqtt): dart:io MQTT client host + Outbound Protocols card + shell lifecycle"
```

---

### Task 6: Rust broker E2E (JSON + Sparkplug) + validation + docs + final review

**Files:**
- Create: `gateway/examples/mqtt_probe.rs`, `mobile/tool/mqtt_host_probe.dart`, `tool/mqtt_e2e.sh`
- Modify: `gateway/Cargo.toml` (add `rumqttc`, `rumqttd`, `prost`; vendor the Tahu `sparkplug_b.proto` + `prost-build` or a checked-in generated module), `docs/protocols/MQTT.md`, `ROADMAP.md`

**Interfaces:**
- Consumes: the running Dart MQTT publisher (via `mqtt_host_probe.dart`) and a real broker + subscriber.
- Produces: `MQTT PROBE PASS` only if a real subscriber receives the exact JSON birth/telemetry AND a `prost`-decoded Sparkplug NBIRTH/NDATA with the expected metric values, and a remote-write round-trips.

- [ ] **Step 1: Add deps + Sparkplug proto.** Add `rumqttc` (subscriber), `rumqttd` (embedded broker), `prost` (+ build the vendored official Eclipse Tahu `sparkplug_b.proto`, or check in a minimal generated `Payload`/`Metric` module) to `gateway/Cargo.toml`. Use SCOPED paths only when inspecting the cargo registry (`-maxdepth`), NEVER `find /` or `find ~` unbounded. `cd gateway && cargo build --examples` to confirm the deps resolve.

- [ ] **Step 2: Write `mqtt_host_probe.dart`.** A headless Dart entrypoint that builds a fixture project (a couple of scalar tags, one **forced**), configures `MqttProtocolConfig` (broker localhost:<port>, one run JSON + one run Sparkplug), and drives `MqttHost.connect` to publish — mirror `mobile/tool/modbus_host_probe.dart`.

- [ ] **Step 3: Write `mqtt_probe.rs` + `tool/mqtt_e2e.sh`.** Spin an embedded `rumqttd` broker, connect a `rumqttc` subscriber to `softplc/#` and `spBv1.0/#`, start the Dart host probe, then assert: JSON birth `ONLINE` (retained) + a telemetry JSON payload with the forced tag's forced value; Sparkplug NBIRTH decodes (via prost) to the expected metrics/aliases + `bdSeq`, and NDATA carries a changed metric; publish a JSON `/set` and a Sparkplug NCMD and confirm (by reading the next telemetry) the tag changed. End with `MQTT PROBE PASS`. If the environment cannot fetch/build `rumqttd`/`rumqttc`/`prost`, SAY SO EXPLICITLY and fall back to: `cargo build --examples` + the Dart codec/publisher/host unit tests as the proof — do NOT print `MQTT PROBE PASS` unless the real broker path actually ran.

- [ ] **Step 4: Full regression gate** — run and paste REAL output: `cd mobile && flutter test`; `cd mobile && flutter analyze` (zero); `cd mobile && flutter build web --release` (compiles — codecs pure/dart2js-safe, host `dart:io` not started on web); `cd gateway && cargo build --examples`.

- [ ] **Step 5: Docs + roadmap.** Rewrite `docs/protocols/MQTT.md` to match what shipped (JSON + Sparkplug B, in-memory password, opt-in remote writes, TCP native, force-aware); mark ROADMAP Phase 6 ✅. No vendor branding.

- [ ] **Step 6: Commit.**

```bash
git add gateway/ mobile/tool/mqtt_host_probe.dart tool/mqtt_e2e.sh docs/protocols/MQTT.md ROADMAP.md
git commit -m "test(mqtt): rumqttd/rumqttc + Sparkplug E2E; docs; Phase 6 complete"
```

- [ ] **Step 7: Whole-branch review** — the controller dispatches the final code reviewer (most capable model) over the full branch diff, then uses superpowers:finishing-a-development-branch to merge.
