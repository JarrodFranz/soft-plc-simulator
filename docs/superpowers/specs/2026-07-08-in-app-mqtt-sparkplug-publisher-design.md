# In-App MQTT + Sparkplug B Publisher (Phase 6 / WS25) Design

**Date:** 2026-07-08
**Status:** Approved by user (chat, 2026-07-08): full scope — JSON **and** Sparkplug B in v1; pure-Dart MQTT 3.1.1 client built from scratch (no package); TCP-native transport (mobile + desktop; web not supported, same as the OPC UA/Modbus hosts); broker password kept **in-memory only**, never persisted; remote writes gated behind an opt-in "Allow remote writes" toggle defaulting **OFF**.
**Builds on:** WS19–20 (in-app pure-Dart OPC UA server + subscriptions), WS24 (in-app Modbus TCP server), and ADR-010 (single app hosts everything in-process; no companion). Reuses the `OpcUaHost`/`ModbusHost` `ChangeNotifier` + socket + 20 Hz tick pattern, the `ProtocolSettings` additive config, the `ModbusMap`/`OpcuaMap` per-project mapping + `autoGenerate` pattern, force-aware writes through `TagResolver.writePath`, the Outbound Protocols screen card layout, and the `gateway/examples/*_probe.rs` machine-proof E2E pattern.

## Goal

Host a pure-Dart **MQTT 3.1.1 client** inside the app that connects **outbound** to any standard broker (Mosquitto, HiveMQ, EMQX, Ignition/Cirrus Link), **publishes** the project's tag values as telemetry, and optionally **accepts remote writes** on a command topic. Two selectable payload formats — a simple **JSON** topic hierarchy and **Sparkplug B** (Eclipse Tahu-compatible protobuf on the `spBv1.0` namespace). Opt-in from the Outbound Protocols screen alongside OPC UA and Modbus; runs on Android/iOS/desktop (web compiles but cannot open a raw TCP socket — same `dart:io` limitation as the two servers). Machine-verified by a real third-party MQTT broker + subscriber.

## Architectural inversion vs. the two existing protocols

OPC UA (WS19) and Modbus (WS24) are **servers**: the app binds a `ServerSocket` and waits for masters to poll. An MQTT publisher is a **client**: the app opens a `Socket` **to** a broker, pushes on its own schedule, and subscribes for commands. The reused shape (pure codec + pure session logic + one `dart:io` host + `ChangeNotifier` + 20 Hz tick + additive config + map editor + Rust E2E) is identical; only the socket direction and the push-vs-pull data flow invert.

Consequences unique to a client:
- **When to publish** is our decision (servers only answer when polled). Two triggers, both on by default: **report-by-exception** (publish a tag only when its value changed since last publish) and a **periodic heartbeat** (every tag republished every N seconds regardless, so a late-joining subscriber and Sparkplug rebirth stay consistent).
- **Connection lifecycle** is outbound: CONNECT → CONNACK, keepalive PINGREQ/PINGRESP, reconnect with backoff on drop. Birth message on (re)connect; broker publishes our **LWT will** on unexpected disconnect.
- **No inbound accept loop**; a single long-lived socket, not per-connection sessions.

## Scope

**In (v1):**
- MQTT **3.1.1** (protocol level 4) over plain **TCP** (port 1883) and **TLS** (port 8883, `SecureSocket`).
- Control packets: CONNECT (clean session, keepalive, optional username/password, LWT will), CONNACK, PUBLISH (QoS 0 and 1, retain flag), PUBACK, SUBSCRIBE, SUBACK, PINGREQ, PINGRESP, DISCONNECT.
- **JSON format**: telemetry, command (`/set`), and retained status (birth/LWT) topics under a configurable base topic.
- **Sparkplug B format**: `spBv1.0/{group_id}/{NBIRTH|NDATA|NDEATH|NCMD}/{edge_node_id}` — the controller modeled as one **Edge Node**, each mapped tag a node **metric** (name + alias + datatype + value), with `bdSeq` (birth/death pairing) and rolling `seq` (0–255). NBIRTH retained; NDEATH is the LWT will payload.
- **Remote writes** (JSON `/set`, Sparkplug `NCMD`) → force-aware `TagResolver.writePath`, **gated behind an "Allow remote writes" toggle defaulting OFF**.
- Per-project `MqttProtocolConfig` + `MqttMap` (additive `mqtt` key), auto-generated from scalar tags, editable + Regenerate.
- Outbound Protocols **MQTT card**: enable, broker host/port, TLS, format picker, base-topic / group-id / edge-node-id, QoS, heartbeat interval, allow-remote-writes, username, **password (in-memory field, never persisted)**, Connect/Disconnect, status + endpoint (`mqtt://host:port` / `mqtts://host:port`), and the map editor.
- Machine-proof Rust E2E: real `rumqttd` broker + `rumqttc` subscriber, asserting exact JSON payloads and (via vendored Tahu `sparkplug_b.proto` + `prost`) exact Sparkplug metrics, plus a remote-write round-trip.

**Out (v-next):** MQTT 5.0 (properties, reason codes, topic aliases), QoS 2 (exactly-once), WebSocket transport (the one path that could make MQTT web-capable — deferred to keep v1 scoped), persistent-session/offline queueing, Sparkplug **device**-level messages (DBIRTH/DDATA/DDEATH — v1 is node-level only), Sparkplug metric historical/dataset/template types, client-cert (mTLS) auth, multi-broker failover.

## The tag mapping (`MqttMap`, mirrors `ModbusMap`)

`MqttMapEntry{ String tag, String metric, bool writable }` — `tag` is the project tag path; `metric` is the published leaf name (JSON topic suffix and Sparkplug metric name), defaulting to the tag name; `writable` decides whether a `/set`/NCMD for it is honored (only meaningful when the card's "Allow remote writes" is on).

`MqttMap{ List<MqttMapEntry> entries }` with `fromJson`/`toJson` exactly like `ModbusMap`.

`MqttMap.autoGenerate(PlcProject p)`: walk `p.tags`; for each **scalar leaf** of type `BOOL`/`INT16`/`INT32`/`FLOAT64` (skip `TIMER`/`COUNTER`/`STRING` and composites, matching `ModbusMap.autoGenerate`), add an entry with `metric = tag.name` and `writable = tag.ioType != 'SimulatedOutput'` (RO for simulated outputs, matching the Modbus/OPC UA convention). Sparkplug metric datatype is derived from the tag type at publish time, not stored.

## Config model (`MqttProtocolConfig`, additive)

Added to `ProtocolSettings` under an additive JSON key `mqtt` (omitted when null; back-compat unchanged), mirroring `opcua`/`modbus`:

```
class MqttProtocolConfig {
  bool enabled;              // default false
  String host;               // default '' (user enters broker host)
  int port;                  // default 1883 (8883 when tls flips — but stored value is authoritative)
  bool tls;                  // default false
  String format;             // 'json' | 'sparkplugB', default 'json'
  String baseTopic;          // JSON base, default 'softplc'
  String groupId;            // Sparkplug, default 'SoftPLC'
  String edgeNodeId;         // Sparkplug, default '' -> falls back to controller/project name
  int qos;                   // 0 | 1, default 0
  int heartbeatSeconds;      // periodic republish, default 5
  bool allowRemoteWrites;    // default false
  String username;           // default '' (persisted; NOT sensitive)
  MqttMap map;
  // NOTE: password is deliberately NOT a field here — never persisted.
}
```

`toJson`/`fromJson` follow the `ModbusProtocolConfig` shape (every field additive with a default on read). **`password` is never in this model, never serialized, never written to disk** — it lives only as an in-memory field on the host/UI, entered per session. `MqttProtocolConfig.defaults(p)` returns `enabled:false, host:'', port:1883, tls:false, format:'json', baseTopic:'softplc', groupId:'SoftPLC', edgeNodeId:'', qos:0, heartbeatSeconds:5, allowRemoteWrites:false, username:'', map: MqttMap.autoGenerate(p)`.

## Topic & payload semantics

Let `controller = project.name` sanitized for MQTT topics (spaces→`_`, strip `/#+`).

### JSON format
- **Telemetry** (publish): `{baseTopic}/{controller}/tags/{metric}` → `{"value": <typed>, "quality": "Good", "timestamp": "<ISO-8601 UTC>", "forced": <bool>}`. QoS + retain per config (telemetry retain = false; last value isn't sticky). Booleans as JSON `true/false`, integers as JSON numbers, `FLOAT64` as JSON number.
- **Status/birth** (publish, retained): `{baseTopic}/{controller}/status` → `ONLINE` on connect.
- **LWT will** (set in CONNECT, retained): `{baseTopic}/{controller}/status` → `OFFLINE` — broker publishes it if we drop.
- **Command** (subscribe, only if `allowRemoteWrites`): `{baseTopic}/{controller}/tags/{metric}/set` → raw scalar string **or** `{"value": <x>}`; decoded to the tag's type and applied via `writePath` (force-aware: skipped silently if the tag is forced). Non-writable metric / unknown metric / unparseable payload → ignored (logged to `lastError`), never a throw.

### Sparkplug B format
- **NBIRTH** (publish on connect, retained, `seq=0`): a `Payload{ timestamp, seq:0, metrics:[ {name, alias, datatype, value} for every mapped tag ] + {name:"bdSeq", datatype:UInt64, value:<bdSeq>} }`. Assigns each metric a stable integer **alias** (1..N in map order) for the connection's lifetime.
- **NDATA** (publish on change/heartbeat, `seq` rolls 1..255→0): `Payload{ timestamp, seq, metrics:[ {alias, datatype, value} for changed tags ] }` — alias-only (no name) after birth, per Sparkplug.
- **NDEATH** (LWT will, set in CONNECT): `Payload{ timestamp, metrics:[ {name:"bdSeq", datatype:UInt64, value:<bdSeq>} ] }` — pairs with the NBIRTH `bdSeq`.
- **NCMD** (subscribe, only if `allowRemoteWrites`): `spBv1.0/{group_id}/NCMD/{edge_node_id}` → `Payload` with metrics addressed by name or alias → `writePath` (force-aware). Non-writable/unknown → ignored.
- **Datatype map:** `BOOL→Boolean(11)`, `INT16→Int16(2)`, `INT32→Int32(3)`, `FLOAT64→Double(10)`; `bdSeq→UInt64(8)`.
- **`bdSeq`** increments each (re)connect and is echoed in the paired NDEATH; **`seq`** is per-message 0–255 rolling starting at 0 for NBIRTH.

## Multi-value & wire encoding (dart2js-safe)

- **MQTT framing:** fixed header (packet type + flags) + **remaining-length varint** (1–4 bytes, 7-bit continuation) + variable header + payload. Strings are 2-byte big-endian length + UTF-8 bytes. All hand-encoded with `int` bit ops and `Uint8List` — no `getInt64`/`setInt64`.
- **Sparkplug protobuf:** the fixed Tahu `Payload`/`Metric` schema is hand-encoded on the protobuf wire format — varint (field tags, int/bool/enum values, `seq`), length-delimited (strings, nested messages, the `metrics` repeated field), and 64-bit `double` via `ByteData.setFloat64` (little-endian per protobuf `fixed64`/`double`; `getFloat64`/`setFloat64` are the dart2js-safe accessors). `UInt64` `bdSeq` uses varint (values are small — the birth counter — so 53-bit `int` range is never exceeded; documented). No `Int64`/`setInt64`.
- A tiny Dart-side protobuf **decoder** for `Payload` lives in test code only (to assert round-trips without the socket); production only encodes.

## Architecture (mirrors OPC UA / Modbus)

| Unit | File | Responsibility |
|---|---|---|
| MQTT codec (NEW, pure) | `mobile/lib/protocols/mqtt/mqtt_codec.dart` | MQTT 3.1.1 control-packet encode/decode: CONNECT/CONNACK/PUBLISH/PUBACK/SUBSCRIBE/SUBACK/PINGREQ/PINGRESP/DISCONNECT; remaining-length varint; UTF-8 string framing; a streaming frame reassembler (`MqttFrameBuffer`) that slices whole packets out of arbitrary TCP chunking. No `dart:io`/Flutter. Never throws on garbage — returns a "need more bytes"/"drop" signal. |
| Sparkplug codec (NEW, pure) | `mobile/lib/protocols/mqtt/mqtt_sparkplug.dart` | Hand-rolled protobuf encoder for the Tahu `Payload`/`Metric` schema; datatype mapping; alias table; `seq`/`bdSeq` counters. Encode-only in production; a decoder in tests. No `dart:io`/Flutter. |
| Publisher session (NEW, pure) | `mobile/lib/protocols/mqtt/mqtt_publisher.dart` | Format-agnostic session logic over a `MqttMap` + live tag reads: build birth/telemetry/command topics + payloads for both formats; report-by-exception change detection (last-published cache); decode inbound command → (tagPath, value) pairs for the host to apply via `writePath`. No `dart:io`/Flutter. |
| Config model (MODIFIED, additive) | `mobile/lib/models/protocol_settings.dart` + new `mobile/lib/models/mqtt_map.dart` | `MqttProtocolConfig` (no password field) + `MqttMap`/`MqttMapEntry` + `autoGenerate`. |
| Socket host (NEW, only `dart:io`) | `mobile/lib/services/mqtt_host.dart` | `MqttHost extends ChangeNotifier`: `connect(projectProvider, {password})`/`disconnect()`, `Socket`/`SecureSocket.connect` to broker, CONNECT with LWT + auth, keepalive PINGREQ timer, ~20 Hz sample tick driving report-by-exception + heartbeat publishes, QoS-1 PUBACK tracking, reconnect/backoff, inbound command dispatch → force-aware `writePath`. In-memory password only. Status/lastError/connected/publishCount like the other hosts. Never crashes the app. |
| Outbound Protocols UI (MODIFIED) | `mobile/lib/screens/gateway_screen.dart` | The **MQTT** card + `_setMqttEnabled` handler; format-conditional fields; password field bound to the host's in-memory value; Connect/Disconnect; endpoint surface; map editor + Regenerate; web shows the same "needs desktop/mobile" note. |
| Host lifecycle (MODIFIED) | `mobile/lib/screens/workspace_shell.dart` | Own a `MqttHost`; `disconnect()` on every project-identity change + dispose (mirror the `OpcUaHost`/`ModbusHost` teardown at all the same sites). |
| E2E harness (NEW) | `gateway/examples/mqtt_probe.rs`, `mobile/tool/mqtt_host_probe.dart`, `tool/mqtt_e2e.sh` | Real `rumqttd` broker + `rumqttc` subscriber vs the in-app Dart publisher: assert JSON birth+telemetry, Sparkplug NBIRTH/NDATA (decoded via vendored `sparkplug_b.proto`+`prost`), and a remote-write round-trip. Mirrors `modbus_probe`. |

## Testing (same bar as OPC UA / Modbus)

1. **MQTT codec fixtures** (`mqtt_codec_test.dart`): every control packet encoded byte-for-byte against hand-derived MQTT 3.1.1 frames (CONNECT with will + auth flags + keepalive; PUBLISH QoS0/QoS1 with packet id + retain; SUBSCRIBE/SUBACK; PINGREQ/PINGRESP; DISCONNECT); remaining-length varint boundaries (0, 127, 128, 16383, 16384); UTF-8 topic framing; truncated/garbage bytes → clean "need more"/"drop", never a throw; multi-packet reassembly out of split/coalesced TCP chunks.
2. **Sparkplug codec fixtures** (`mqtt_sparkplug_test.dart`): NBIRTH/NDATA/NDEATH/NCMD `Payload`s encode to exact protobuf bytes (hand-derived), then round-trip through the test decoder; datatype mapping for each tag type; alias table stability; `seq` roll 255→0; `bdSeq` birth/death pairing; `Double` little-endian fixed64.
3. **Publisher logic tests** (`mqtt_publisher_test.dart`): birth/telemetry topics+payloads for both formats against a mapped fixture project; report-by-exception (unchanged tag not republished, changed tag republished, heartbeat republishes all); JSON `/set` and Sparkplug NCMD decode to the right (tag,value); non-writable/unknown/unparseable command ignored; **force-aware** — a command to a forced tag yields no write (asserted via the applied-writes list).
4. **Host test** (`mqtt_host_test.dart`): stand up a minimal in-test TCP server speaking just enough MQTT (accept CONNECT→CONNACK, capture PUBLISH), assert the host connects, sends a well-formed CONNECT (with LWT + keepalive), publishes birth + a telemetry change, answers PINGREQ cadence, and applies an inbound command; disconnect/reconnect-backoff lifecycle; TLS path constructed but exercised only against the plain server (SecureSocket covered by the E2E). Never throws on a hostile server (garbage bytes → dropped connection).
5. **Machine-proof E2E** (`tool/mqtt_e2e.sh`): Dart host publishes a fixture project to a real `rumqttd` broker; a `rumqttc` subscriber reads `softplc/#` (JSON: asserts birth `ONLINE` + telemetry JSON) and `spBv1.0/#` (Sparkplug: `prost`-decodes NBIRTH/NDATA, asserts metric values), then publishes a `/set` and an NCMD and the probe confirms the tag changed → `MQTT PROBE PASS`. Merge gate, runnable in-environment (mirrors the OPC UA/Modbus probes).
6. **Regression:** full `flutter test`, `flutter analyze` ZERO, `flutter build web --release` compiles (codecs are pure/dart2js-safe; the `dart:io` host isn't started on web), WS6 lossless round-trip guard green (additive `mqtt` config), `cargo build --examples` green.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); "MQTT", "Sparkplug B", `spBv1.0`, and standard MQTT/Sparkplug terms are protocol terms and fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/mqtt/*` is PURE Dart (no Flutter/`dart:io`); the only `dart:io` is `mqtt_host.dart`. The client must NEVER crash the app: malformed broker input → clean drop/reconnect, never an uncaught throw.
- **Secrets:** the broker **password is never persisted or committed** — in-memory only, entered per session. `username` (non-sensitive) may persist. Nothing sensitive in project JSON. TLS via `SecureSocket`; no cert/keystore committed (existing `gateway/pki/` gitignore stands).
- Remote writes are **opt-in** (`allowRemoteWrites` default false) and force-aware (forcing wins) through `writePath`; non-writable map entries reject silently.
- Additive persistence: new `mqtt` config key omitted when null; WS6 lossless round-trip guard stays green. App byte-identical when the client is disconnected; connecting is explicit opt-in.
- All MQTT wire integers big-endian; protobuf per its wire spec (varint + little-endian fixed64); codecs stay dart2js-compilable (avoid `getInt64`/`setInt64`; `getFloat64`/`setFloat64` allowed).
- Default broker port 1883 (plain) / 8883 (TLS) — user-editable; the host surfaces bind/connect errors clearly (same status/lastError surface as the other hosts).

## Phasing (one spec → plan tasks)

1. **Map model + config** — `MqttMap`/`MqttMapEntry`/`autoGenerate`, `MqttProtocolConfig` (no password field), additive `ProtocolSettings` wiring + round-trip test.
2. **MQTT 3.1.1 control-packet codec** — pure encode/decode for all needed packets + remaining-length varint + UTF-8 framing + streaming reassembler; codec fixtures.
3. **Sparkplug B protobuf codec** — pure `Payload`/`Metric` encoder + datatype/alias/seq/bdSeq + test decoder; codec fixtures.
4. **Publisher session logic** — format-agnostic birth/telemetry/command builder + report-by-exception + command decode; publisher-logic tests (incl. force-aware).
5. **Socket host + Outbound Protocols UI + shell lifecycle** — `MqttHost` (connect/keepalive/tick/reconnect/in-memory password/force-aware writes) + the MQTT card + `workspace_shell` teardown; host test.
6. **Rust `rumqttd`/`rumqttc` E2E probe (JSON + Sparkplug) + validation + docs + final review** — machine-proof, all gates, `docs/protocols/MQTT.md` update, ROADMAP Phase 6 update, whole-branch review, merge.
