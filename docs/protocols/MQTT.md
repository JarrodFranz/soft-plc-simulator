# MQTT / Sparkplug B (In-App Publisher)

The app itself is the MQTT **client** — a pure-Dart MQTT 3.1.1 publisher
(`mobile/lib/protocols/mqtt/mqtt_codec.dart` + `mqtt_publisher.dart` +
`mqtt_sparkplug.dart`, zero Flutter dependency) driven by a `dart:io` socket
host (`mobile/lib/services/mqtt_host.dart`, the only MQTT file allowed to
import `dart:io`). Unlike the OPC UA and Modbus TCP adapters (Phases 4/5,
ADR-010's "one app hosts everything" pattern, where the app is the
*server*), MQTT inverts the direction: the app *dials out* to a broker you
already run or point it at (HiveMQ, Mosquitto, EMQX, AWS IoT Core, Ignition
Cirrus Link, or any MQTT 3.1.1-compliant broker) and publishes tag telemetry
there for any number of subscribers to consume.

```
the app itself  --MQTT 3.1.1 TCP/1883 (or TLS/8883)-->  your broker  --> any subscriber(s)
   - runs the scan                                      (HiveMQ,         (SCADA historian,
   - owns the tag DB                                     Mosquitto,       Ignition, a
   - publishes birth/                                     EMQX, ...)       dashboard, ...)
     telemetry/heartbeat
   - force-aware reads
   - opt-in remote writes
```

## Using it

1. Open **Outbound Protocols** from the app's shell nav.
2. Enable the **MQTT** switch on the MQTT card — this reveals the broker
   connection fields, payload-format selector, and tag<->metric map editor.
3. Set **host**, **port** (default `1883`; use `8883` and enable **TLS**
   for a broker requiring encrypted connections), and optionally
   **username**/**password**. The **password** field is held only in
   memory for the lifetime of the connection attempt — see "Password
   handling" below; it is never written into the project file.
4. Pick the **payload format**: **JSON** (flat per-tag topics, human/browser
   friendly) or **Sparkplug B** (compact protobuf, the IIoT/SCADA-standard
   Eclipse Tahu encoding — see "Sparkplug B" below).
5. Set **base topic** (JSON mode, default `softplc`), **group id**/**edge
   node id** (Sparkplug B mode, default group `SoftPLC`, edge node id
   defaults to the project name if left blank), and **heartbeat** interval
   (seconds; `0` disables the periodic full-map republish, keeping only
   report-by-exception telemetry).
6. Leave **Allow remote writes** off unless you intend to accept `/set`/NCMD
   commands from the broker side — see "Remote writes are opt-in" below.
7. Tap **Connect**. The card shows live status (Stopped / Connecting /
   Running / Error), the endpoint, and a running publish count.
8. Tap **Disconnect** to send a clean MQTT `DISCONNECT` and tear the
   connection down; the app is otherwise byte-identical to a build with
   MQTT never enabled.

The tag<->metric map (which tags are published, under what metric name, and
whether they accept a remote write) is **hand-editable** from the MQTT
card's map editor, or auto-generated from the project's tags (**Regenerate**
— `Simulated Inputs`/`Internal` tags default writable, `Simulated Outputs`
default publish-only), mirroring the Modbus/OPC UA auto-map convention. It
is stored per-project under the additive `protocols.mqtt` field.

## Topic layout

### JSON format

| Purpose | Topic | Payload |
|---|---|---|
| Birth (retained) | `{base_topic}/{controller_name}/status` | `"ONLINE"` |
| Will/death (retained) | `{base_topic}/{controller_name}/status` | `"OFFLINE"` |
| Telemetry | `{base_topic}/{controller_name}/tags/{metric}` | `{"value":..., "quality":"Good", "timestamp":<ms>, "forced":<bool>}` |
| Remote write (subscribed only if enabled) | `{base_topic}/{controller_name}/tags/{metric}/set` | a raw scalar (`777`, `true`) or `{"value":...}` |

### Sparkplug B format

| Purpose | Topic |
|---|---|
| Birth (retained) | `spBv1.0/{group_id}/NBIRTH/{edge_node_id}` |
| Will/death (retained) | `spBv1.0/{group_id}/NDEATH/{edge_node_id}` |
| Telemetry (report-by-exception + heartbeat) | `spBv1.0/{group_id}/NDATA/{edge_node_id}` |
| Remote write (subscribed only if enabled) | `spBv1.0/{group_id}/NCMD/{edge_node_id}` |

Device-level (`DBIRTH`/`DDATA`/`DDEATH`) messages are not emitted — every
mapped tag is published as a Node (`N*`)-level metric of one Edge Node per
project. `DDATA`/device-level Sparkplug is deferred (see "v1 scope" below).

## Sparkplug B

Payloads are a hand-rolled, pure-Dart protobuf encoder
(`mqtt_sparkplug.dart`) implementing the subset of the Eclipse Tahu
`sparkplug_b.proto` `Payload`/`Metric` messages this app needs: `timestamp`,
`seq`, and a flat metric list with `name`/`alias`/`datatype` plus exactly
one scalar value field (`int_value` for `BOOL`→Boolean/`INT16`/`INT32`,
`long_value` for the `bdSeq` counter, `double_value` for `FLOAT64`,
`boolean_value` for `BOOL`, `string_value` unused by this app's tag types).
A vendored, trimmed reference copy of the upstream `.proto` (for field-number
traceability) lives at `gateway/proto/sparkplug_b.proto`.

- **NBIRTH** carries one aliased metric per mapped tag (name **and** alias,
  so a subscriber can build its alias table) plus a `bdSeq` metric (no
  alias, UInt64), and resets the Sparkplug message sequence counter
  (`seq`) to `0`.
- **NDATA** (report-by-exception, or the full map on a heartbeat tick)
  carries **alias-only** metrics (no `name`, saving bytes) and advances
  `seq` by one each time, wrapping `255` back to `0`.
- **bdSeq** (birth/death sequence) is a monotonically increasing counter
  that **never resets for the app's lifetime**, not even across
  reconnects: each (re)connect's MQTT Will (registered at CONNECT time,
  before a single byte of the session's own traffic) carries an NDEATH with
  `bdSeq` advanced by one, and the NBIRTH that follows once the broker
  accepts the connection reads that *same* value — the pairing convention
  Sparkplug B subscribers use to tell a stale NDEATH from the current
  session's and detect a rebirth.
- Every value is read through the same force-aware `readPath` resolver the
  scan engine, OPC UA server, and Modbus register handler all share — a
  forced tag's telemetry (JSON or Sparkplug alike) always reflects its
  forced value, never its live underlying value.

## Composite/struct tag exposure (dotted leaf paths, incl. STRING)

Like the OPC UA/Modbus/DNP3 adapters, a composite tag (a struct, an array,
or the reserved `System` diagnostics UDT) is never published as one metric —
**Regenerate** instead walks every tag's scalar leaves (the shared
`scalarLeaves` resolver) and adds one metric entry per leaf, keyed by its
dotted/indexed path (`System.Fault`, `Recipe_Steps[0]`, `Motor.Speed`, ...).
A plain scalar tag is unaffected, so a scalar-only project's map regenerates
unchanged.

MQTT is the **one adapter of the four that publishes `STRING` leaves** —
`System.DateTime`, for example, is published as a JSON string value or a
Sparkplug `string_value` metric. Modbus and DNP3 skip `STRING`/`TIMER`/
`COUNTER` leaves entirely (no wire representation defined for them there —
see `docs/protocols/modbus.md`/`docs/protocols/DNP3.md`); OPC UA also
exposes `STRING` leaves (see `docs/protocols/opcua.md`).

`System.*` is always published **non-writable** (`writable: false`): the
reserved `System` tag carries an explicit `access: 'ReadOnly'` independent of
`ioType`, and the auto-map's writable/read-only rule checks both signals
(`root.ioType == 'SimulatedOutput' || root.access == 'ReadOnly'`) — so even
with **Allow remote writes** enabled, a `.../System.Fault/set` (JSON) or
NCMD write targeting a `System.*` metric is rejected by the map's `writable`
check the same way any other read-only tag's remote write is.

## Password handling

The broker **password** is supplied fresh to `MqttHost.connect(...,
password: ...)` on every connection attempt and held only in an in-memory
field for that attempt's lifetime — `MqttProtocolConfig` (the persisted,
serialized project settings) has no password field at all, so it can never
end up written to a saved project file, a backup, or a shared/exported
project. Re-entering the password (or reusing whatever the UI last held in
memory) is required after restarting the app.

## Remote writes are opt-in, default OFF

`allowRemoteWrites` defaults to `false`. While off, the app **never
subscribes** to the `/set`/NCMD command topic at all — not "subscribes but
ignores," but no SUBSCRIBE packet is sent, so nothing from the broker can
ever reach a tag write regardless of what's published there. Turning it on
subscribes the connection to the JSON wildcard filter
(`{base_topic}/{controller_name}/tags/+/set`) or the Sparkplug NCMD topic,
and decodes inbound writes against the tag<->metric map's `writable` flag.
A write to a tag that is currently **forced** is silently dropped (no
response channel exists to report a refusal over MQTT, unlike OPC UA's
visible `Bad_UserAccessDenied`) — the forcing engineer's value always wins,
same policy as the Modbus adapter.

## Report-by-exception + heartbeat

Telemetry is published two ways, both configurable:

- **Report-by-exception**: on a fast internal tick, every mapped tag's
  current (force-aware) value is compared against the last value this
  session published for it; only tags that changed are re-published
  (one JSON publish per changed tag, or one Sparkplug NDATA batching every
  changed tag's alias+value).
- **Heartbeat**: every `heartbeatSeconds` (configurable, default 5s; `0`
  disables it), the **entire** mapped tag set is republished regardless of
  whether anything changed — a periodic full snapshot a subscriber can use
  to detect a missed report-by-exception publish or simply to poll on a
  fixed cadence.

Both mechanisms share the same "last published" baseline, which is (re)seeded
to every mapped tag's current value at each birth (fresh connection) — so
the very first tick after a (re)connect reports nothing until something
actually changes past that snapshot.

## Publish interval + analog deadband (perf tuning)

Two additive, per-project `protocols.mqtt` fields tune how much load the
report-by-exception tick above puts on the broker/network, useful once a
map has many tags or many connected instances:

- **Publish interval** (`publishIntervalMs`, default **250 ms**, floor
  **20 ms**) — how often the internal tick fires and compares mapped tags
  against their last-published baseline. It only takes effect on the next
  (re)connect (like the existing heartbeat field), so the interval field on
  the MQTT card is disabled while connected/connecting.
- **Analog deadband** (`deadband`, default **0.0**, meaning **off**) — a
  numeric tag's report-by-exception publish is suppressed while its value
  stays within `deadband` of the last value this session actually
  published, exactly like the OPC UA subscription deadband (see
  `docs/protocols/opcua.md`'s "Subscriptions (v2)"). The suppressed baseline
  does **not** drift — it stays pinned at the last **published** value, so
  several small sub-deadband moves don't silently accumulate into a large
  unreported change. Only applies to numeric (`num`) values; `BOOL`/`STRING`
  tags always publish on any change regardless of `deadband`. This field is
  read live on every tick (no reconnect needed), so it's editable on the MQTT
  card while connected.

Both fields round-trip through project serialization (missing keys back-fill
their defaults, so an older saved project loads unaffected) —
`mobile/test/protocol_settings_test.dart`. The deadband gate itself is
verified against the real publisher/birth/report-by-exception path (baseline
seeding, suppression, and baseline advancement on a publish) —
`mobile/test/models/mqtt_deadband_test.dart`.

### UI notification throttling

Independent of the wire-level interval/deadband above, `MqttHost`'s
`notifyListeners()` calls (which drive the Outbound Protocols card's live
publish-count/status display) are coalesced through a small shared
`NotifyThrottle` (`mobile/lib/services/notify_throttle.dart`) to a trailing
~250 ms window on the per-tick "published N tags" notification — a fast
tick interval no longer means the UI repaints every single tick. Status
transitions (connecting/running/error/stopped), an inbound Sparkplug
rebirth, and the manual **Rebirth** button all still notify **immediately**
(no throttling), so the card never looks stale on anything the user would
consider a state change — only the high-frequency "did we publish anything
this tick" signal is throttled. Verified in isolation (`mobile/test/
services/notify_throttle_test.dart`, using `fake_async`) and does not
change any publish/interval/deadband behavior itself.

## Transport: TCP native + TLS

Connections are plain TCP (`Socket.connect`) by default, or TLS
(`SecureSocket.connect`) when the project's MQTT config has **TLS**
enabled (port `8883` is the conventional TLS port, but any port works).
There is no WebSocket transport in v1 (see "v1 scope" below).

## v1 scope (and what's deferred)

**v1 delivers:** MQTT 3.1.1 CONNECT/PUBLISH/SUBSCRIBE/PINGREQ/DISCONNECT
over plain TCP or TLS, JSON and Sparkplug B (Node-level only) payload
formats, retained birth/will, report-by-exception + heartbeat telemetry,
opt-in force-aware remote writes, and the auto-map/manual-map editor
described above.

**Deferred (v2+):**
- **MQTT 5.0** — this client speaks 3.1.1 only.
- **WebSocket transport** — TCP/TLS only.
- **Sparkplug device-level messages** (`DBIRTH`/`DDATA`/`DDEATH`) — every
  tag is a Node-level metric of one Edge Node; no per-device sub-tree.
- **QoS 2** — the codec/host support QoS 0/1 (PUBACK); QoS 2's
  PUBREC/PUBREL/PUBCOMP four-way handshake is not implemented.
- **Broker-side retained-message inspection/clearing from the UI** — the
  app publishes retained birth/will messages but has no UI to browse or
  clear what a broker is currently retaining.
- **`TIMER`/`COUNTER`-typed tag telemetry** — the auto-map still skips these
  two data types entirely (no Sparkplug/JSON value shape is defined for
  them). `STRING` is **not** in this list any more — see "Composite/struct
  tag exposure" below.

## What is machine-verified vs. manual

**Machine-verified (`flutter test` in `mobile/`):**
- `MqttMap`/`MqttMapEntry`/`MqttProtocolConfig` model round-trips and
  `autoGenerate` behavior — `mobile/test/mqtt_map_test.dart`.
- The MQTT 3.1.1 control-packet codec byte-for-byte (CONNECT/PUBLISH/
  SUBSCRIBE/PINGREQ/DISCONNECT encoding, CONNACK/PUBACK/SUBACK/PUBLISH
  parsing, the remaining-length varint, and `MqttFrameBuffer`'s streaming
  TCP-chunk reassembly) — `mobile/test/mqtt_codec_test.dart`.
- The Sparkplug B protobuf `Payload`/`Metric` encoder byte-for-byte against
  a hand-computed fixture, plus round-trips of every datatype (including
  negative `Int64`/varint-terminates-on-negatives regressions) through a
  test-only decoder — `mobile/test/mqtt_sparkplug_test.dart`.
- The publisher session logic (birth/will/telemetry descriptors for both
  payload formats, report-by-exception change detection, heartbeat,
  command decoding, bdSeq pairing/monotonicity, force-awareness) —
  `mobile/test/mqtt_publisher_test.dart`.
- The `dart:io` socket host (connect/reconnect lifecycle with exponential
  backoff, keep-alive PINGREQ, oversized/hostile-frame connection
  isolation, force-aware remote-write gating, graceful DISCONNECT) —
  `mobile/test/mqtt_host_test.dart`.
- Additive persistence: the new `protocols.mqtt` key round-trips
  end-to-end alongside the unchanged `opcua`/`modbus`/`gatewayUrl` keys —
  `mobile/test/protocol_settings_test.dart`, `mobile/test/serialization_roundtrip_test.dart`.

**Machine-verified end-to-end, with a REAL third-party broker + subscriber
(`tool/mqtt_e2e.sh`):**

This is the strongest proof available short of pointing the app at a human
-run Mosquitto/HiveMQ instance: a genuine embedded **`rumqttd`** broker and
a genuine **`rumqttc`** subscriber client (`gateway/examples/mqtt_probe.rs`)
exercise the Dart publisher (driven headlessly by
`mobile/tool/mqtt_host_probe.dart`, which reimplements `MqttHost`'s
connect/publish/tick loop directly against the pure codec/publisher modules
— `MqttHost` itself can't run under a plain `dart run` process because it
extends Flutter's `ChangeNotifier`, which transitively needs `dart:ui`) in
**both** payload formats:

- **JSON**: a retained `status` birth `"ONLINE"` (proven retained by a
  second, freshly-subscribing client — MQTT's RETAIN flag is correctly
  cleared on a live delivery to an already-subscribed client per spec, so
  the retention proof deliberately uses a fresh subscribe, not the primary
  subscriber's live view); a `tags/Forced_Bool` telemetry publish whose
  `value` is `true` even though the tag's live value is `false` (the
  force-aware proof); a `tags/Counter` telemetry publish reflecting a value
  the fixture mutates **server-side** on its own timer, independent of any
  client (the live-not-frozen proof); then a JSON `/set` publish and
  observing the *next* `tags/Speed` telemetry reflects the written value
  (the remote-write round-trip proof).
- **Sparkplug B**: a retained NBIRTH, `prost`-decoded against a small
  checked-in `prost::Message`-derived module
  (`gateway/examples/support/sparkplug_pb.rs`) mirroring the wire subset
  this app's encoder produces, asserting the exact metrics/aliases (and
  the `bdSeq` metric) the fixture project defines; an NDATA reflecting the
  same server-side `Counter` mutation as above at its Sparkplug alias; then
  a Sparkplug NCMD write and observing the *next* NDATA reflects the
  written value at its alias (the Sparkplug remote-write round-trip proof).

Run it from the repo root (bash/Git Bash):

```bash
tool/mqtt_e2e.sh
```

Unlike `tool/modbus_e2e.sh`/`tool/opcua_e2e.sh` (which start the Dart
fixture — a *server* there — first and wait for its own `READY` line before
running the Rust probe as a client), the orchestration direction here is
inverted: the app is an outbound MQTT *client*, so the Rust binary itself
starts the embedded broker, then spawns the Dart fixture as a client
dialing into it (twice — once per payload format), and kills it when each
phase's assertions are done. A successful run ends with:

```
MQTT PROBE PASS
```

**Requires a human with a real broker (manual, documented here, not
automatable in CI):**
- Pointing the app at a real broker (Mosquitto/HiveMQ/EMQX/AWS IoT
  Core/Ignition) on the network, including a TLS-enabled endpoint, to
  confirm real network reachability and certificate handling (the E2E
  probe above runs over `127.0.0.1` with plain TCP, proving the protocol
  implementation but not physical network/TLS/firewall behavior).
- Confirming a genuine Sparkplug B-aware SCADA host (e.g. Ignition with
  the Cirrus Link MQTT Engine module) correctly rebirths/aliases against
  this app's NBIRTH/NDEATH bdSeq pairing.

## Out of scope / positioning

This is a **simulator/training tool, not a safety-certified or
conformance-tested product**. The hand-rolled client targets broker/
subscriber *compatibility* (Mosquitto, HiveMQ, EMQX, and Sparkplug B-aware
SCADA hosts talking MQTT 3.1.1), not formal OASIS MQTT or Eclipse Tahu
Sparkplug B conformance testing. Do not use it to control real
safety-critical equipment. MQTT 5.0, WebSocket transport, QoS 2, and
Sparkplug device-level messages are not implemented (see "v1 scope" above).
