# DNP3 (In-App Outstation)

The app itself is a DNP3 **outstation** (server) — a pure-Dart IEEE 1815
data-link/transport/application-layer implementation
(`mobile/lib/protocols/dnp3/dnp3_link.dart` + `dnp3_transport.dart` +
`dnp3_app.dart` + `dnp3_outstation.dart`, zero Flutter dependency) driven by
a `dart:io` socket host (`mobile/lib/services/dnp3_host.dart`, the only DNP3
file allowed to import `dart:io`). Like the OPC UA and Modbus TCP adapters
(ADR-010's "one app hosts everything" pattern), a real DNP3 **master** —
electric utility, water/wastewater, or SCADA head-end software — connects
*to* the app over TCP.

```
a DNP3 master  --TCP/20000 (0x0564 link frames)-->  the app itself
(SCADA head-end,                                    - owns the tag DB
 an RTU test tool,                                  - answers Class 0 reads
 dnp3.exe, ...)                                     - force-aware
                                                     - SELECT/OPERATE/DIRECT_OPERATE control
```

## Using it

1. Open **Outbound Protocols** from the app's shell nav.
2. Enable the **DNP3** switch on the DNP3 card — this reveals the hosting
   controls, link-address fields, and the point map editor.
3. Set **Port** (default `20000`, the conventional DNP3 TCP port),
   **Outstation address** (default `1024` — this app's own DNP3 link
   address), and **Master address** (default `1` — the address this
   outstation stamps as `DESTINATION` on every response; see "Link
   addressing" below).
4. Tap **Start hosting**. The card shows live status (Stopped / Running /
   Error), the bound endpoint (`dnp3://<host>:<port>`), and a connected
   client count.
5. Tap **Stop hosting** to close every connection and the listening socket;
   the app is otherwise byte-identical to a build with DNP3 never enabled.

The tag<->point map (which tags are exposed, as which DNP3 point type, at
which index) is **hand-editable** from the DNP3 card's map editor, or
auto-generated from the project's tags (**Regenerate** — `BOOL` tags map to
Binary Input/Binary Output, numeric tags to Analog Input/Analog Output,
`SimulatedOutput` tags read-only, everything else read-write), mirroring the
Modbus/OPC UA/MQTT auto-map convention. It is stored per-project under the
additive `protocols.dnp3` field.

## Point type mapping

| DNP3 Point Type | Static Object (response) | Control Object (request) | Tag Data Type |
|---|---|---|---|
| Binary Input | g1v2 (w/ flags) | — (read-only) | `BOOL` |
| Binary Output | g10v2 (status, w/ flags) | g12v1 (CROB) | `BOOL` |
| Analog Input | g30v1 (32-bit w/ flags) or g30v5 (float w/ flags) | — (read-only) | `INT16`/`INT32` -> g30v1; `FLOAT64` -> g30v5 |
| Analog Output | g40v1 (32-bit status) or g40v3 (float status) | g41v1 (32-bit block) or g41v3 (float block) | `INT16`/`INT32` -> g40v1/g41v1; `FLOAT64` -> g40v3/g41v3 |

Each point type has its own independently-numbered, 0-based index space (an
Analog Input at index 0 and a Binary Output at index 0 are unrelated
points). A tag can appear at most once in the map. Composite (struct/array)
tags and `TIMER`/`COUNTER`/`STRING` tags are not supported (matching the
Modbus/OPC UA/MQTT adapters' scalar-only scope).

## Class 0 integrity polling

Every READ request (regardless of which specific objects/qualifiers it
names) is answered with a full **Class 0** grouped scan: one object header
per (point type, variation) bucket present in the map, covering that
bucket's index range with any gap index zero/offline-filled. This v1
outstation does not support scoped reads (a single-point read, an
event-class-specific poll, or `g60v*` event-class objects) — see "v1 scope"
below. A master's conventional "integrity poll" (`g60v1`/Class 0 read) is
the intended and fully-supported use case.

Every static object's flags byte carries `ONLINE` (bit 0); a forced point's
value is read through the same force-aware `readPath` resolver the scan
engine, OPC UA server, Modbus register handler, and MQTT publisher all
share — a forced tag's Class 0 value always reflects its **forced** value,
never its live underlying value.

## Control: SELECT / OPERATE / DIRECT_OPERATE

Binary Output points accept a CROB (g12v1): `LATCH_ON`/`LATCH_OFF` write the
point's boolean tag; `PULSE_ON`/`PULSE_OFF` are treated the same as
`LATCH_ON`/`LATCH_OFF` (no timed pulse-then-revert — this is a v1
simplification, see below); `NUL` is a no-op success. Analog Output points
accept an Analog Output Block (g41v1 32-bit or g41v3 float, matching the
point's own variation) that writes the tag's numeric value directly.

- **DIRECT_OPERATE** applies the control immediately.
- **SELECT** followed by **OPERATE** requires the OPERATE's control
  object(s) to be byte-identical to the preceding SELECT's (same
  group/variation/qualifier/range/indices/payload) and arrive within a
  5-second window; anything else (no prior SELECT, a mismatched OPERATE, an
  expired SELECT) is rejected with control status `NO_SELECT` (2).
- A control targeting an unmapped index, or naming a point type this
  outstation doesn't support control for, is rejected `NOT_SUPPORTED` (4).
- A control targeting a point whose root tag is **forced** is **silently
  discarded** (the write never reaches the tag) and reported
  `NOT_AUTHORIZED` (9) — the forcing engineer's value always wins, the same
  policy the Modbus/MQTT adapters apply, made externally visible here via
  DNP3's control-status response (unlike Modbus/MQTT, which have no
  response channel to report a refusal).

## Force-aware, end to end

A forced tag's value:
- Reads through Class 0 as its **forced** value (never the live value),
  matching every other protocol adapter in this app.
- Cannot be changed by any DNP3 control — SELECT/OPERATE/DIRECT_OPERATE on a
  forced point's root tag is rejected `NOT_AUTHORIZED`, and the write is
  never applied, even if the response were somehow ignored by the master.

## Link addressing and restart indication

- **Outstation address**: this app's own DNP3 link address (`DESTINATION`
  on inbound frames, `SOURCE` on outbound). A frame addressed to any other
  destination is silently ignored — no response is sent.
- **Master address**: the address this outstation stamps as `DESTINATION`
  on every outbound (response) frame. v1 does not filter inbound frames by
  their `SOURCE` — only the destination-address match above gates whether a
  frame is processed.
- **IIN1 DEVICE_RESTART**: set on every response from process start, until
  the master issues a WRITE (function code 2) clearing g80v1 index 7 — the
  conventional "acknowledge the outstation restarted" handshake. Until
  cleared, every response's IIN1 continues to report the restart, matching
  real outstation behavior after a power-up/reset.
- Every outbound response frame's link-layer CONTROL byte is a fixed
  "unconfirmed user data" value (`0x44`); this v1 outstation does not
  implement the data-link confirmation/FCB (frame-count-bit) state machine.

## v1 scope (and what's deferred)

**v1 delivers:** a full data-link (CRC-16/DNP, `0x0564` framing) + transport
(segment reassembly) + application layer (object headers, Class 0 grouped
reads, SELECT/OPERATE/DIRECT_OPERATE control) DNP3 outstation over plain
TCP, 4 point types (Binary Input, Binary Output, Analog Input, Analog
Output) with their conventional static/control object variations, force-
aware reads and force-aware control rejection, configurable outstation/
master link addresses, and the auto-map/manual-map editor described above.

**Deferred (v2+):**
- **Unsolicited responses** — this outstation only ever answers a request;
  it never spontaneously reports a change.
- **Event classes / event buffers** (Class 1/2/3, g2/g4/g11/g22/g32/g42
  event objects) — only the current (static) value is ever reported, via
  Class 0.
- **Scoped/single-point reads** — every READ is answered as a full Class 0
  scan regardless of the specific objects/qualifiers requested.
- **Counters** (g20/g22) — not a supported point type in v1.
- **Time synchronization** (`DELAY_MEASUREMENT`/`RECORD_CURRENT_TIME`/WRITE
  g50) — not implemented; a master's automatic time-sync procedure will not
  receive the responses it expects (see the E2E probe's note on disabling
  a master's default automatic task sequence against this outstation).
- **Timed CROB pulses** — `PULSE_ON`/`PULSE_OFF` behave identically to
  `LATCH_ON`/`LATCH_OFF` (an immediate, permanent set), not a timed
  on-then-revert.
- **Serial/UDP transport** — TCP only.
- **Data-link confirmation (FCB state machine)** — every response uses a
  fixed "unconfirmed user data" link CONTROL byte.

## What is machine-verified vs. manual

**Machine-verified (`flutter test` in `mobile/`):**
- `DnpMap`/`DnpMapEntry`/`DnpProtocolConfig` model round-trips and
  `autoGenerate` behavior — `mobile/test/dnp3_map_test.dart`.
- CRC-16/DNP (cross-checked against Python's `crcmod` and an independent
  from-scratch bit-by-bit implementation) and the `0x0564` link-frame
  codec/reassembler (`DnpLinkBuffer`, arbitrary TCP chunking, resync on
  corrupt/false-start data) — `mobile/test/dnp3_link_test.dart`.
- The transport-segment header and `DnpTransportReassembler` (single- and
  multi-segment fragments, out-of-sequence/duplicate handling) and the
  application-layer object-header/static-object/control-object codec
  (g1v2/g10v2/g30v1/g30v5/g40v1/g40v3/g12v1/g41v1/g41v3, IIN packing) —
  `mobile/test/dnp3_app_test.dart`.
- The outstation handler: Class 0 grouped-read construction (run
  coalescing, gap-filling, mixed int/float Analog buckets), force-aware
  reads, SELECT/OPERATE matching and expiry, DIRECT_OPERATE, force-aware
  control rejection, unmapped/unsupported-object handling, and the g80v1
  restart-clear WRITE — `mobile/test/dnp3_outstation_test.dart`.
- The `dart:io` socket host (start/stop lifecycle, link-frame dispatch over
  a real loopback socket, destination-address filtering, malformed/hostile-
  frame connection isolation) — `mobile/test/dnp3_host_test.dart`.
- Additive persistence: the new `protocols.dnp3` key round-trips
  end-to-end alongside the unchanged `opcua`/`modbus`/`mqtt`/`gatewayUrl`
  keys — `mobile/test/protocol_settings_test.dart`,
  `mobile/test/serialization_roundtrip_test.dart`.

**Machine-verified end-to-end, with a REAL third-party DNP3 master
(`tool/dnp3_e2e.sh`):**

This is the strongest proof available short of pointing the app at a human
-run SCADA head-end: a genuine **Step Function I/O `dnp3`** crate master
(`gateway/examples/dnp3_probe.rs`) connects to the Dart outstation (driven
headlessly by `mobile/tool/dnp3_host_probe.dart`, which reimplements
`DnpHost`'s connection/framing loop directly against the pure link/
transport/outstation modules — `DnpHost` itself can't run under a plain
`dart run` process because it extends Flutter's `ChangeNotifier`, which
transitively needs `dart:ui`) and:

1. Runs a Class 0 integrity poll and asserts a Binary Input, an Analog
   Input (32-bit int) and an Analog Input (float) all read back correctly
   — **and** that a forced Binary Output reads back its forced value
   (`true`) even though its live value is `false`.
2. DIRECT_OPERATEs a CROB (`LATCH_ON`) targeting that same forced Binary
   Output and asserts the master's own `operate()` call is rejected with
   `BadStatus(NotAuthorized)` — the outstation's force-aware control-skip
   path, proven against a real master's command, not a hand-rolled test
   double.
3. DIRECT_OPERATEs an analog-output-block onto a non-forced Analog Output
   and, on re-poll, confirms the new value landed.
4. Issues a SELECT-then-OPERATE (two real, separate DNP3 fragments) onto
   the same Analog Output with a different value and, on re-poll, confirms
   *that* value landed too — proving the outstation's byte-identical
   SELECT/OPERATE object-matching logic against a real master's two-pass
   command sequence, not just DIRECT_OPERATE's single-pass path.

Run it from the repo root (bash/Git Bash):

```bash
tool/dnp3_e2e.sh
```

Mirrors `tool/modbus_e2e.sh`'s orchestration direction (the Dart fixture is
a *server* here, started first; the harness waits for its own `READY` line
before running the Rust master probe as the client). A successful run ends
with:

```
DNP3 PROBE PASS
```

**Requires a human with a real master (manual, documented here, not
automatable in CI):**
- Pointing the app at a real SCADA head-end or RTU test tool over a real
  network, to confirm reachability/firewall behavior beyond `127.0.0.1`.
- Confirming a master's automatic time-synchronization or unsolicited-
  response-enabling handshake degrades gracefully against this outstation
  (v1 implements neither — see "v1 scope" above); the E2E probe above
  deliberately configures its own master association to skip that default
  automatic sequence rather than exercise it.

## Out of scope / positioning

This is a **simulator/training tool, not a safety-certified or
conformance-tested product**. The outstation implementation targets DNP3
master *compatibility* (a real third-party master library, real SCADA
head-ends), not formal DNP3 Conformance Test Procedure certification. Do
not use it to control real safety-critical equipment. Unsolicited
responses, event classes, counters, time synchronization, timed CROB
pulses, serial/UDP transport, and data-link confirmation are not
implemented (see "v1 scope" above).
