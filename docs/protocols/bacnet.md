# BACnet/IP (device side, v1)

The app hosts a **BACnet/IP server device** in-process, in pure Dart, over
**UDP** on port **47808** (the BACnet Annex J standard port) by default. Like
the other protocol adapters (OPC UA, Modbus TCP, MQTT + Sparkplug B, DNP3,
EtherNet/IP + CIP, S7comm, Omron FINS, Mitsubishi SLMP) it follows ADR-010:
there is no companion process, no native plugin, and nothing runs until you
explicitly enable it on the **Outbound Protocols** screen.

Implemented from public BACnet/IP (Annex J) specification material. This is
the sixth and final workstream of the protocol-expansion program.

---

## v1 scope

| Layer | What is implemented | File |
| --- | --- | --- |
| BVLL/NPDU framing + primitive tag codec | The BACnet Virtual Link Layer header, the (unrouted) Network Layer PDU, and the ASN.1-style TAGGED primitive value codec (literal-byte pinned both directions) | `mobile/lib/protocols/bacnet/bacnet_bvll.dart`, `bacnet_tags.dart` |
| APDU service codecs | Who-Is/I-Am, ReadProperty, ReadPropertyMultiple, WriteProperty, and the Error/Reject/Abort reply PDUs | `mobile/lib/protocols/bacnet/bacnet_services.dart` |
| Request → response dispatch | Parses a raw UDP datagram down to a confirmed/unconfirmed service call and always answers what parses, shared by the host and the E2E fixture | `mobile/lib/protocols/bacnet/bacnet_dispatch.dart` |
| Tag-backed object image | The Device object plus one Analog Value/Binary Value object per mapped tag, served (and, for Present_Value, force-gate-written) off the live project tags | `mobile/lib/protocols/bacnet/bacnet_object_image.dart` |
| Exposure model | `BacnetMap` / `BacnetMapEntry`, auto-generation, per-entry access | `mobile/lib/models/bacnet_map.dart` |
| Socket host | `RawDatagramSocket` bind (UDP, no reassembly — one datagram is one complete frame); recent-peer tracking; a best-effort startup I-Am broadcast | `mobile/lib/services/bacnet_host.dart` |
| Config | `BacnetProtocolConfig` (enabled, port, deviceInstance, map), JSON key `bacnet` | `mobile/lib/models/protocol_settings.dart` |

Everything except the socket host is pure Dart with no `dart:io` and no
Flutter dependency, which is what lets the E2E fixture host (below) run under
a plain `dart run`.

---

## Wire layout: BVLL → NPDU → APDU, over UDP

A BACnet/IP datagram is three nested layers:

1. **BVLL** (BACnet Virtual Link Layer) — a 4-byte header (`0x81`, a function
   code, a 2-byte length covering the whole datagram) that distinguishes a
   unicast reply (`BVLC-Original-Unicast-NPDU`, `0x0A`) from a broadcast
   (`BVLC-Original-Broadcast-NPDU`, `0x0B`, used only for this device's
   startup I-Am). BBMD/Foreign-Device function codes are not implemented (see
   *Deferred*).
2. **NPDU** (Network Layer PDU) — a 2-byte header (protocol version `0x01`,
   a control byte). This device serves only **unrouted** NPDUs (no
   destination/source network present); an NPDU carrying a destination
   network (router traffic) is dropped politely.
3. **APDU** (Application Layer PDU) — the actual service request/response:
   PDU type in byte 0's high nibble, an invoke ID for confirmed services, a
   service choice byte, then service-specific tagged data.

One UDP datagram is one complete BVLL+NPDU+APDU frame — there is no
reassembly, unlike the length-prefixed TCP protocols (S7comm, SLMP,
EtherNet/IP) next door. BACnet/IP joins Omron FINS as the suite's second
datagram protocol.

---

## Object model: Device + Analog Value + Binary Value only

Following the plan's Ignition-scoped service set, v1 serves exactly three
object types:

| App tag type | BACnet object | Present_Value encoding |
| --- | --- | --- |
| `BOOL` | Binary Value (BV) | Enumerated 0/1 |
| `INT16` / `INT32` / `INT64` / `FLOAT64` | Analog Value (AV) | Real (IEEE-754 **single precision**, big-endian) |
| `STRING` | *not representable* — see *Deferred* | — |

One AV or BV object is created per mapped tag, each with its own instance
number (an AV 0 and a BV 0 are different objects — the two instance
sequences are independent). The Device object itself is always object
`(device, deviceInstance)`, always readable, and exposes `Object_List` as
both the whole array and by array index (index 0 = element count).

### Present_Value is always a NARROWING conversion

The app stores floating-point tags as 64-bit doubles and integers up to
64-bit width. A BACnet Real is 32-bit IEEE-754 single precision. Every
numeric tag's Present_Value is therefore the **float32 approximation** of
the stored value, not the value itself — an `INT32`/`INT64` beyond 2^24
and any `FLOAT64` not exactly representable in single precision lose
precision on the wire, exactly the same class of narrowing as SLMP's
`FLOAT64 → REAL` and S7comm's `FLOAT64 → FLOAT32` story next door. A value
written over BACnet lands in the tag as the double/int nearest that
float32. Read the same tag over OPC UA if you need full precision.

`Priority_Array` always reads as 16 all-NULL slots and `Relinquish_Default`
mirrors the current Present_Value — this device never actually commands a
priority slot, so a commandable-minded client (Ignition included) reads a
consistent, non-alarming picture rather than erroring on an unsupported
array.

---

## Service scope and the always-answer rule

Served: unconfirmed **Who-Is** → **I-Am** (instance-range filtered);
confirmed **ReadProperty** → ComplexAck or Error; confirmed
**ReadPropertyMultiple** → ComplexAck with **per-property embedded
values/errors** (one bad property never fails the whole batch — ALL/REQUIRED
expand to the object's full served property list, OPTIONAL expands to
nothing, and a reply that would exceed 1476 bytes gets `Abort
(buffer-overflow)` instead of a truncated or dropped answer); confirmed
**WriteProperty** → SimpleAck or Error, through the same force-gate chain
every other protocol's tag-backed image uses.

**Any confirmed request that parses far enough to yield an invoke ID always
gets an answer** — ComplexAck/SimpleAck, Error, Reject, or Abort — never
silence. A segmented request is answered `Abort
(segmentation-not-supported)`; an unrecognized confirmed service is answered
`Reject (unrecognized-service)`. Only genuinely **unparseable** input (bad
BVLL/NPDU framing, an unparseable APDU envelope, or malformed per-service
data) is dropped without a reply — the codecs return `null` rather than
throwing on hostile input, so one bad datagram can never wedge the bind.

Unconfirmed services this device does not serve are silently dropped (Reject
requires an invoke ID, which an Unconfirmed-Request never carries — there is
no PDU to answer with).

---

## The `BacnetMap` model and write-gate semantics

`BacnetMapEntry` binds one tag (by its dotted/indexed resolver leaf path) to
an object type (`AV`/`BV`) + instance number + `access` (`ReadOnly` /
`ReadWrite`). `BacnetMap.autoGenerate(project)` builds a default map from the
project's scalar leaves: `BOOL` leaves become Binary Value objects (instances
0, 1, 2…), every other numeric leaf becomes an Analog Value object (its own
independent instance sequence), and `STRING` leaves are skipped entirely.
Access is inherited from the root tag exactly as every other protocol's map
does (`SimulatedOutput`, an explicit `ReadOnly` tag access, or the reserved
`System` tag all yield `ReadOnly`; everything else `ReadWrite`).

A WriteProperty is refused, in order, if: the target isn't Present_Value on a
known AV/BV object; the underlying mapped tag doesn't resolve at all (an
unknown-object error — reads of an unresolvable tag serve 0.0/inactive
instead, but a write to nothing real behind the map entry is reported as
unknown, not as a refusal); the map entry's own `access` is `ReadOnly`; the
write-time hard backstop `isExternallyWritable` refuses it (the reserved
`System` tag, or the tag's own `access` is `ReadOnly`, independent of what a
mutable map entry claims); the tag's **root** is FORCED (forcing is
authoritative — an external write must never change the value behind a
force, and the root check has no bypass for a member path such as
`Tank.Level`). Only after all four gates pass is the incoming value decoded.

#### The write PRIORITY argument is accepted and IGNORED

Ignition's BACnet/IP driver always writes at a configured priority (default
8) — refusing a write that carries a priority argument would break it on day
one. So `WriteProperty`'s optional priority parameter is parsed off the wire
(so a malformed priority never corrupts the request) but then **never
consulted** by the write-gate chain: the write either lands (through the
gates above) or is refused, exactly the same regardless of what priority the
client asked for. This is a deliberate v1 simplification — see *Commandable
priority arrays* below.

---

## Web platform note

Hosting binds a real inbound UDP socket, which **web browsers do not allow**.
The BACnet/IP card's Start button is disabled on web with a note to that
effect; you can still design the object map in the browser. Run the desktop
(Windows/macOS/Linux) or mobile (Android/iOS) app to host. (Port 47808 is
above 1023, so there is **no privileged-port caveat** on any native
platform.)

---

## Deferred to v2 (deliberate, with reasons)

* **COV subscriptions** (SubscribeCOV / COVNotification). Ignition's driver
  falls back to polling when COV isn't offered, which is exactly the path
  this device supports — deferring COV doesn't break the target client.
* **Commandable priority arrays** (real relinquish-default logic, a
  per-priority-slot command stack). v1 accepts-and-ignores the priority
  argument instead (see above); a genuine command stack is a different
  object semantics, not a wire-format extension.
* **Segmentation** (both directions). Every response fits in one unsegmented
  APDU (max 1476 bytes) or is answered `Abort (buffer-overflow)`; a client
  that needs a bigger single answer retries with a smaller batch.
* **BBMD, Foreign-Device registration, routed networks, BACnet/SC.** No NPDU
  routing of any kind — see the Ignition recipe below for how discovery
  works instead across a NAT boundary.
* **Object types beyond Device/AV/BV** (no Analog Input/Output, Binary
  Input/Output, Multi-State Value, Integer Value, etc.). AV/BV cover every
  scalar tag type this app has; the others are additional object-type
  mappings on the same tag-to-object pattern, not a new mechanism.
* **CharacterString Value for `STRING` tags.** `BacnetMap.autoGenerate` skips
  `STRING` leaves and the object image refuses to encode/decode one, exactly
  like the FINS/SLMP/S7comm/EtherNet-IP maps defer `STRING`.
* **Alarming/eventing** (intrinsic reporting), schedules, trend logs, files,
  ReadRange, WritePropertyMultiple, DeviceCommunicationControl,
  ReinitializeDevice, TimeSynchronization — all answered `Reject
  (unrecognized-service)` today.

---

## Running the E2E

```bash
bash tool/bacnet_e2e.sh     # prints "BACNET PROBE PASS", exits 0
```

This is the only BACnet/IP test in the repo that is **not our codec talking
to itself**, so it — not the unit suite — is the authority on wire details.

It starts the pure-Dart fixture host (`mobile/tool/bacnet_host_probe.dart`) on
UDP port **47810** (not 47808, which may already be in use), waits for
`READY`, then runs `tool/py/bacnet_probe.py` — driving a real third-party
BACnet/IP client — against it and propagates the probe's exit code. The host
is killed unconditionally on the way out.

Because both the fixture host and the shipped host
(`services/bacnet_host.dart`) call the **same** pure `dispatchBacnetDatagram`
against the **same** `BacnetTagImage`, the bytes the client validates are —
by construction, not by diff — the bytes the app puts on the wire. The
fixture serves a Device object plus five mapped AV/BV objects backed by real
project tags (two seeded read-only values, a read/write pair, and a
ReadOnly-mapped refusal target) — the full tag-backed object model a shipped
project actually exposes, not a hand-rolled stand-in.

### The BAC0 → bacpypes3 substitution

The plan specified `BAC0==22.9.21` (which wraps `bacpypes==0.18.6`'s sync
API). That pin **fails to import** on this venv's Python (3.12):
`bacpypes/core.py` does `import asyncore`, a standard-library module Python
3.12 removed (deprecated since 3.6) — `pip install` succeeds, but every
`import bacpypes` then raises `ModuleNotFoundError`. This lane instead uses
**`bacpypes3`** (pinned in `tool/py/requirements.txt`) — an independent,
actively-maintained, **asyncio-native** reimplementation of the BACnet/IP
stack (its own APDU/tag codec, not a shim over the old `bacpypes`), so it is
still a genuine third-party conformance check; only the API shape (`async`
calls against a `bacpypes3.app.Application`, not BAC0's synchronous wrapper)
differs.

Two encoding/API disputes this client's own source settled at Task 5 (see
`tool/py/bacnet_probe.py`'s header for the full note): `read_property_multiple`'s
`parameter_list` argument is a **flat, alternating** sequence
(`objid, prop_list, objid, prop_list, …`), not a list of tuples, despite its
type hint; and a top-level Error/Reject/Abort answering a single
ReadProperty/WriteProperty is **raised** as a Python exception
(`bacpypes3.apdu.ErrorRejectAbortNack`, carrying `.errorClass`/`.errorCode`
directly) rather than returned, whereas a **per-property embedded** error
inside an otherwise-successful ReadPropertyMultiple ack is returned as a
plain `ErrorType` value in the result tuple, never raised.

### What the probe drives

1. `who_is()` — a directed Who-Is, asserting the fixture's device instance
   (3056) comes back in an I-Am.
2. Reads the Device object's `Object_Name`, seeded independently of the
   client.
3. `Object_List` — the **whole array** (6 objects: device + 5 mapped AV/BV),
   **index 0** (the count, 6), and **index 1** (one indexed entry, the
   Device object itself) — the array-index browse path Ignition's driver
   depends on.
4. Reads a seeded Analog Value's Present_Value (12.5) and a seeded Binary
   Value's Present_Value (active), both seeded independently of the client
   — the tag-encoding settler.
5. A **ReadPropertyMultiple batch** spanning the Device, the write-target
   AV, and a property (`description`) this device does not serve — asserts
   the unsupported property surfaces as an **embedded error inside the ack**
   while the other two items still return real values (the whole batch
   never fails for one bad property).
6. **WriteProperty → independent ReadProperty read-back** of a new AV value.
7. **WriteProperty carrying a priority argument** onto a Binary Value, then
   an independent read-back — proving the priority is accepted, not
   refused.
8. **WriteProperty to a ReadOnly-mapped AV** — refused
   (`errorClass=property`/`errorCode=write-access-denied`), with an
   independent read-back proving the value is unchanged.
9. **Reading an unsupported property** (`description`) on an object this
   device does serve — a BACnet error, not silence or a wrong value.

---

## Connecting Ignition's BACnet/IP driver

1. **Add the device by direct IP, not discovery.** Broadcast Who-Is does not
   cross Docker's NAT (same reality as FINS/SLMP/S7comm/EtherNet-IP — see
   those docs' recipes), and this device's I-Am replies unicast to whoever
   asked. In Ignition's BACnet/IP device configuration, add the device by
   its **direct IP address and port** (e.g. `host.docker.internal:47808` when
   Ignition runs in Docker and the app runs on the host) rather than relying
   on network discovery.
2. **Local-device settings**: any BACnet Local Device Object Instance /
   Network Number Ignition's driver needs for itself is independent of this
   device — this device's own identity (`deviceInstance`, default 3056, and
   `Object_Name`) is set from the app's Outbound Protocols → BACnet/IP card.
3. **Writes**: the driver's default write priority (commonly 8) is
   **accepted and ignored** by this device's write gate — a write lands or
   is refused by the same rule regardless of priority, so there is no
   "commandable" setup step required on the Ignition side; a plain
   ReadWrite-mapped tag just works.
4. **Polling**: the driver's ReadPropertyMultiple polling path is fully
   served (including `ALL`/`REQUIRED` expansion), so tag browsing/import via
   `Object_List` and steady-state polling both work without COV.
