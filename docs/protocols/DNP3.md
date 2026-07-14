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
 dnp3.exe, ...)                                     - Class 1/2/3 events + unsolicited
                                                     - force-aware
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
points). A tag can appear at most once in the map. A composite (struct/array)
tag is not mapped as a single unit — **Regenerate** instead expands it into
its scalar leaf members (the shared `scalarLeaves` resolver; e.g. the
reserved `System` UDT expands to `System.Fault`, `System.ScanTimeMs`, ...)
and maps each dotted-path leaf like any other scalar tag. `TIMER`/`COUNTER`/
`STRING` **leaves** (including `System.DateTime`) are still skipped entirely
(matching Modbus's scalar-leaf-only scope; OPC UA and MQTT do expose STRING
leaves — see `docs/protocols/opcua.md`/`docs/protocols/MQTT.md`).

## Class 0 integrity polling

A READ that names no class objects, or explicitly names `g60v1` (Class 0),
is answered with a full **Class 0** grouped scan: one object header per
(point type, variation) bucket present in the map, covering that bucket's
index range with any gap index zero/offline-filled. A master's conventional
"integrity poll" (`g60v1`/Class 0 read) is the intended and fully-supported
use case. A READ that additionally names `g60v2`/`g60v3`/`g60v4` (Class
1/2/3) also appends any buffered events for those classes — see "Event
classes, events, and unsolicited reporting" below.

Every static object's flags byte carries `ONLINE` (bit 0); a forced point's
value is read through the same force-aware `readPath` resolver the scan
engine, OPC UA server, Modbus register handler, and MQTT publisher all
share — a forced tag's Class 0 value always reflects its **forced** value,
never its live underlying value.

## Event classes, events, and unsolicited reporting

Every point — **input** (`binaryInput`/`analogInput`) **and output**
(`binaryOutput`/`analogOutput`) — carries a per-point **event class** in
`{0, 1, 2, 3}`, editable on the point-map row (the DNP3 card's event-Class
dropdown, shown on every point type) and stored as the additive `event_class`
field on each map entry:

- **0** (default, and the back-compatible behavior) — static-only: the point
  never generates events; it is reported only via Class 0.
- **1 / 2 / 3** — the point's changes are captured into event Class 1 / 2 / 3.

Output points generate events on the **same any-change trigger** as inputs:
whether the value changed because of a master command (SELECT/OPERATE/
DIRECT_OPERATE) or because logic/simulation wrote the underlying tag, the
change is detected the same way and emitted into the point's event class.

A periodic tick (the host's ~500 ms `tickForTest`; ~300 ms in the E2E
fixture) runs force-aware **change detection**: each participating point's
current value (via the same `readPath` resolver, so forced values win) is
compared to its last-reported value, and any change appends one event to
that point's class buffer. The **first** observation of a point records its
baseline without emitting (so startup does not flood).

**Event objects** carry the point's own index (qualifier `0x28`: 2-byte
count + a 2-byte index prefix per point) and a **48-bit absolute timestamp**
(ms since the DNP3 epoch), grouped by type:

| Event | Object | Notes |
|---|---|---|
| Binary Input event | **g2v2** | with absolute time |
| Binary Output event | **g11v2** | output-status change, with absolute time |
| Analog Input event (int) | **g32v3** | 32-bit, with absolute time |
| Analog Input event (float) | **g32v7** | single-precision, with absolute time |
| Analog Output event (int) | **g42v3** | 32-bit output-status change, with absolute time |
| Analog Output event (float) | **g42v7** | single-precision output-status change, with absolute time |

All **four** point types now report change events: the outstation groups a
mixed event batch into per-type buckets so binary/analog and input/output
events each carry their correct object group (g2/g11 for binary
input/output, g32/g42 for analog input/output). Output events ride the exact
same Class-poll (solicited `g60v2/v3/v4`) and unsolicited-reporting paths as
input events.

**Per-class ring buffers** are bounded (`event_buffer_per_class`, default
200). When a class buffer is full the oldest event is dropped and the
**event-buffer-overflow** IIN2 bit (bit 3) is set on responses until the
buffer drains and a CONFIRM clears it.

**Solicited Class 1/2/3 polls.** A READ naming `g60v2`/`g60v3`/`g60v4`
returns the buffered events for those classes, appended after the static
scan if Class 0 was also named. When events are present the response sets
the application **CON** bit, asking the master to CONFIRM; the events are
**flushed** (removed from the buffer) only when a matching CONFIRM (same
application sequence) arrives. A response whose events are never confirmed
keeps them buffered — they are **deferred, not lost**, and re-reported on
the next poll.

**Unsolicited reporting.** A master enables/disables unsolicited event
reporting per class with **ENABLE_UNSOLICITED** (fc 20) / **DISABLE_
UNSOLICITED** (fc 21), each naming classes via `g60v2/v3/v4`. On enable, the
outstation queues a one-shot **null unsolicited** announcement (fc 130, no
objects) — the standard "I am now reporting" signal. Thereafter, when a
change produces events for an enabled class, the outstation pushes an
**unsolicited response** (fc 130, `UNS`+`CON`) carrying those events and
waits for the master's CONFIRM:

- On CONFIRM (matching the unsolicited application sequence), the carried
  events are flushed and the sequence advances.
- If no CONFIRM arrives within `unsol_confirm_timeout_ms` (default 5000),
  the host **retries** the exact same fragment, up to `unsol_max_retries`
  (default 3) times, then gives up (`failUnsolicited`) — the events stay
  buffered (sequence unchanged) and are retried on the next change/tick.

**IIN bits.** IIN1 bits 1/2/3 (**Class 1/2/3 events available**) are set
whenever the corresponding class buffer is non-empty, so even a
static-only master learns events are waiting. IIN2 bit 3
(**event-buffer-overflow**) reports a dropped-event overflow as above.

### v1 event simplifications

- **Any-change events, no deadband** — every value change emits an event;
  there is no analog deadband/threshold (a v2 refinement).
- **Timestamps are always absolute** (g2v2/g32v3/g32v7, 48-bit time); the
  relative/no-time event variations are not emitted.
- **Unsolicited is broadcast to every connected master**, from one shared
  outstation, rather than tracked per-master. A typical DNP3 TCP deployment
  has exactly one master connected, so this is a simplification, not a
  behavioral gap in practice.
- **Single-slot solicited pending-flush** — one solicited event batch awaits
  its CONFIRM at a time; an un-confirmed batch's events are deferred (kept
  buffered and re-reported), never silently lost.
- All four point types (`binaryInput`/`binaryOutput`/`analogInput`/
  `analogOutput`) generate events; counters and double-bit-binary event
  objects are out of scope (see "v1 scope").

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
reads, Class 1/2/3 event polls, unsolicited event reporting,
SELECT/OPERATE/DIRECT_OPERATE control) DNP3 outstation over plain TCP, 4
point types (Binary Input, Binary Output, Analog Input, Analog Output) with
their conventional static/control object variations, per-point event classes
on all four point types (Class 1/2/3, g2v2/g11v2/g32v3/g32v7/g42v3/g42v7
events with 48-bit absolute time) plus solicited and unsolicited event
reporting, force-aware reads and force-aware
control rejection, configurable outstation/master link addresses, and the
auto-map/manual-map editor described above.

**Deferred (v2+):**
- **Analog deadbands** — events fire on *any* change; there is no
  deadband/threshold to suppress small analog fluctuations.
- **Relative/no-time event variations** — only the absolute-time event
  objects (g2v2/g11v2/g32v3/g32v7/g42v3/g42v7) are emitted.
- **Counter and double-bit-binary events** (g20/g22/g4) — counters and
  double-bit binaries are not supported point types in v1.
- **Time synchronization** (`DELAY_MEASUREMENT`/`RECORD_CURRENT_TIME`/WRITE
  g50) — not implemented; a master's automatic time-sync procedure will not
  receive the responses it expects. (Event timestamps are the outstation's
  own absolute wall-clock, not master-synchronized.)
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
  control rejection, unmapped/unsupported-object handling, the g80v1
  restart-clear WRITE, Class 1/2/3 event reads (CON + flush-on-CONFIRM),
  ENABLE/DISABLE_UNSOLICITED, and the unsolicited take/confirm/fail API —
  `mobile/test/dnp3_outstation_test.dart`.
- The event engine: per-class ring buffers, force-aware change detection
  (across all four point types, input and output), baseline-without-emit,
  overflow/drop-oldest, and the g2v2/g11v2/g32v3/g32v7/g42v3/g42v7
  48-bit-time event encoders — `mobile/test/dnp3_events_test.dart`.
- The `dart:io` socket host (start/stop lifecycle, link-frame dispatch over
  a real loopback socket, destination-address filtering, malformed/hostile-
  frame connection isolation, and the periodic change-detection tick +
  unsolicited push/CONFIRM/retry loop) — `mobile/test/dnp3_host_test.dart`.
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
5. Polls **Class 1/2/3 events** (`g60v2/v3/v4`) in a bounded loop against
   four dedicated, fixture-driven event points (a Class 1 `binaryInput`
   flipped, a Class 2 `analogInput` incremented, a Class 3 `binaryOutput`
   flipped, and a Class 3 `analogOutput` incremented, every ~1 s), and
   asserts the master receives at least one **g2 binary-input event**, one
   **g32 analog-input event**, one **g11 binary-OUTPUT event**, and one
   **g42 analog-OUTPUT event** — proving change detection across all four
   point types, the per-class event buffers, and the solicited Class-read +
   CON/CONFIRM-flush path against a real master.
6. Brings up a second master association configured to **ENABLE unsolicited**
   for Class 1/2/3 during startup, and asserts it receives outstation-
   **initiated** unsolicited g2/g32 (input) **and g11/g42 (output)** events
   (captured via the crate's `ReadType::Unsolicited`), which the `dnp3` crate
   auto-CONFIRMs — proving the unsolicited enable → push → CONFIRM path end to
   end for both input and output events.

Run it from the repo root (bash/Git Bash):

```bash
tool/dnp3_e2e.sh
```

Mirrors `tool/modbus_e2e.sh`'s orchestration direction (the Dart fixture is
a *server* here, started first; the harness waits for its own `READY` line
before running the Rust master probe as the client). A successful run ends
with:

```
DNP3 EVENTS PROBE PASS
```

If the environment can't run the live Rust master (no `cargo` on PATH, or
the `dnp3` crate can't be fetched/built offline), the script does **not**
fake a pass: it compile-checks the probe (`cargo build --example
dnp3_probe`), runs the Dart unit suite as the in-process proof, and reports
the live-master leg as **SKIPPED** with the reason, exiting on the unit
suite's result.

**Requires a human with a real master (manual, documented here, not
automatable in CI):**
- Pointing the app at a real SCADA head-end or RTU test tool over a real
  network, to confirm reachability/firewall behavior beyond `127.0.0.1`.
- Confirming a master's automatic time-synchronization handshake degrades
  gracefully against this outstation (v1 does not implement time sync — see
  "v1 scope" above); the E2E probe's static/control leg deliberately
  configures its own master association to skip that default automatic
  sequence, while its unsolicited leg does exercise the real
  disable → integrity-scan → enable-unsolicited startup handshake.

## Out of scope / positioning

This is a **simulator/training tool, not a safety-certified or
conformance-tested product**. The outstation implementation targets DNP3
master *compatibility* (a real third-party master library, real SCADA
head-ends), not formal DNP3 Conformance Test Procedure certification. Do
not use it to control real safety-critical equipment. Analog deadbands,
relative-time event variations, counters, time synchronization, timed CROB
pulses, serial/UDP transport, and data-link confirmation are not
implemented (see "v1 scope" above).
