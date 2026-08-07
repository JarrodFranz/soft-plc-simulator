---
id: knowledge:industry/protocols/dnp3
title: DNP3
domain: industry/protocols
version: "2026-08"
topics: [dnp3, ieee1815, outstation, crc16-dnp, unsolicited, select-operate, event-classes]
summary: DNP3 (IEEE 1815) link/transport/application-layer wire format, Class 0/1/2/3 polling and event reporting, SELECT/OPERATE control, and how an in-app pure-Dart outstation implements and E2E-proves it against a real Rust dnp3-crate master, including solicited and unsolicited event delivery.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/modbus
---

# DNP3

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/dnp3/dnp3_link.dart`,
> `dnp3_transport.dart`, `dnp3_app.dart`, `dnp3_outstation.dart`,
> `mobile/lib/services/dnp3_host.dart`, and the real-client E2E script
> `tool/dnp3_e2e.sh`.
> **Read this before:** implementing or debugging a DNP3 outstation/master,
> diagnosing a SELECT/OPERATE control rejection, or an event-class polling
> or unsolicited-reporting question.

---

## 1. The headline rule

**DNP3 is little-endian throughout (the link-layer CRC-16 and every application-layer multi-byte field), and it is a three-layer stack - data link (frame + per-16-byte-block CRC), transport (segment reassembly), application (object headers + services) - where a Class 0 poll and a Class 1/2/3 event poll are two genuinely different response mechanisms, not variations of one read.**

A point's **static** value (what Class 0 reports) and its **event history** (what Class 1/2/3 report) are tracked independently; a point can be static-only (never generates events) or assigned to an event class, and getting that distinction wrong either floods event buffers with points that should be static-only or silently drops changes a SCADA head-end expects to see as events.

---

## 2. Wire format

### 2.1 Data link layer (IEEE 1815)

A frame starts with two sync bytes `0x05 0x64`, then a 10-byte header **block**: `LENGTH`(1 byte - counts CONTROL + 2 address bytes + user-data length, i.e. `5 + userDataLen`, max 255), `CONTROL`(1 byte), `DESTINATION`(u16 LE), `SOURCE`(u16 LE), then a 2-byte CRC (LE) over the preceding 8 header bytes. User data follows in blocks of up to 16 bytes, **each individually followed by its own 2-byte CRC (LE)** over just that block's data - not one CRC over the whole payload.

**CRC-16/DNP** is the reflected variant: polynomial `0x3D65`, reflected shift constant `0xA6BC`, init `0`, final one's-complement (xorout `0xFFFF`). Cross-checking a from-scratch implementation against an independent library's predefined DNP3 CRC function (not just against your own bit-by-bit reference) is the standard way to gain confidence in a from-scratch CRC before trusting a real master's frames against it.

Every outbound response frame's CONTROL byte is commonly a fixed "unconfirmed user data" value - a v1-scope outstation need not implement the full data-link confirmation/FCB (frame-count-bit) state machine to be useful, but that is a documented scope reduction, not free of consequence: a master expecting link-layer confirmation behaves differently against such an outstation.

### 2.2 Transport and application layers

The transport layer reassembles application-layer fragments out of one or more link-layer frames (segment header + reassembly). The application layer carries object headers (group/variation + a qualifier describing the index range/count) followed by point data.

### 2.3 Byte order

**All DNP3 multi-byte integers are little-endian** - link-layer CRCs, addresses, and every application-layer multi-byte field alike.

### 2.4 Static objects, control objects, and event objects

| DNP3 point type | Static object | Control object | Event object |
|---|---|---|---|
| Binary Input | g1v2 (w/ flags) | - (read-only) | g2v2 (w/ absolute time) |
| Binary Output | g10v2 (status, w/ flags) | g12v1 (CROB) | g11v2 (w/ absolute time) |
| Analog Input | g30v1 (32-bit) / g30v5 (float) | - (read-only) | g32v3 (int) / g32v7 (float) |
| Analog Output | g40v1 (32-bit) / g40v3 (float) | g41v1 (32-bit block) / g41v3 (float block) | g42v3 (int) / g42v7 (float) |

Every static object's flags byte carries an ONLINE bit. Event objects carry the point's own index (qualifier `0x28`: a 2-byte count + a 2-byte index prefix per point) and a **48-bit absolute timestamp** (ms since the DNP3 epoch).

---

## 3. Transport and port

TCP, conventional port **20000** (not IANA-reserved, but the de facto default across DNP3 tooling). Link addressing is separate from IP addressing: an **outstation address** (this device's own DNP3 link address) and a **master address** (stamped as DESTINATION on outbound responses) are configured independently of the TCP endpoint. A frame addressed to any other destination than the outstation's own address is silently ignored - no response sent.

---

## 4. Addressing / map model

DNP3 addresses by **point type + a 0-based index**, four independently-numbered spaces (Binary Input, Binary Output, Analog Input, Analog Output - an Analog Input at index 0 and a Binary Output at index 0 are unrelated points), closer in spirit to Modbus's per-table addressing than to a byte/word-offset area image. A general binding model: BOOL points map to Binary Input (read-only) or Binary Output (read-write, control-capable); numeric points map to Analog Input (read-only) or Analog Output (read-write, control-capable), with the 32-bit-vs-float object variation chosen by the underlying value's type.

**Class 0 (static/integrity) polling.** A read naming no class objects, or explicitly `g60v1` (Class 0), returns a full grouped scan: one object header per (point type, variation) bucket present in the map, covering that bucket's index range with any gap zero/offline-filled. This is the conventional "integrity poll" every DNP3 master issues on connect/reconnect.

**Event classes (1/2/3) and reporting.** Every point - input **and** output - carries a per-point event class in `{0,1,2,3}`; class `0` (static-only, the conservative default) means the point never generates events and is reported only via Class 0. Change detection compares each participating point's current (force-aware) value against its last-reported value on a periodic tick; the **first** observation of a point records a baseline without emitting, so startup does not flood every point as a fabricated "change." Events accumulate in **per-class ring buffers** (bounded; oldest dropped on overflow, with an overflow IIN bit set until the buffer drains and a matching CONFIRM clears it).

**Solicited Class 1/2/3 polls** return buffered events for the requested classes, appended after a Class 0 scan if also requested; a response carrying events sets the application CON (confirm-requested) bit, and the events are **flushed only when a matching CONFIRM arrives** - an unconfirmed response's events stay buffered and are re-reported on the next poll rather than lost.

**Unsolicited reporting.** A master enables/disables it per class (`ENABLE_UNSOLICITED`/`DISABLE_UNSOLICITED`, naming classes via `g60v2/v3/v4`). On enable, the outstation queues a one-shot **null unsolicited** announcement (no objects) - the standard "I am now reporting" signal - then pushes an unsolicited response carrying new events whenever a change occurs in an enabled class, waiting for CONFIRM; an un-confirmed unsolicited response is **retried** the exact same fragment up to a bounded retry count before giving up (events stay buffered, retried on the next change/tick, not lost).

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the DNP3/IEEE 1815 standard itself.)*

Full data-link (CRC-16/DNP, `0x0564` framing) + transport (segment reassembly) + application layer (object headers, Class 0 grouped reads, Class 1/2/3 event polls, unsolicited event reporting, SELECT/OPERATE/DIRECT_OPERATE control) over plain TCP, all four point types with their conventional static/control object variations, per-point event classes on all four types, and force-aware reads/control rejection. `IIN1 DEVICE_RESTART` is set on every response from process start until the master issues the conventional restart-acknowledge WRITE clearing it.

**v1 simplifications, documented deliberately:** any-change events with no analog deadband; only absolute-time event variations (no relative/no-time); unsolicited is broadcast to every connected master rather than tracked per-master (a reasonable simplification when a deployment has exactly one master, a real behavioral gap otherwise); one solicited event batch awaits CONFIRM at a time; counters and double-bit-binary point types are out of scope; timed CROB pulses (`PULSE_ON`/`PULSE_OFF`) behave identically to `LATCH_ON`/`LATCH_OFF` (immediate and permanent, not a timed on-then-revert); time synchronization is not implemented.

## 6. Write-gate interaction (control)

**DIRECT_OPERATE** applies a control immediately. **SELECT then OPERATE** requires the OPERATE's control object(s) to be byte-identical to the preceding SELECT's (same group/variation/qualifier/range/indices/payload) and arrive within a bounded window (commonly ~5 seconds); anything else - no prior SELECT, a mismatched OPERATE, an expired SELECT - is rejected `NO_SELECT`. A control targeting an unmapped index, or a point type this outstation doesn't support control for, is rejected `NOT_SUPPORTED`.

A control targeting a **FORCED** point's root is **silently discarded** (never reaches the point) and reported `NOT_AUTHORIZED` - the forcing engineer's value always wins, made externally visible via DNP3's control-status response channel (a capability Modbus/MQTT lack, since they have no response channel to carry a refusal). This is the one adapter in this family whose control path has a dedicated response status specifically for "refused because forced," rather than reusing a generic access-denied code.

## 7. Real-client E2E proof

Proven against a genuine **Step Function I/O `dnp3`** Rust crate master (v1.6). The probe runs a Class 0 integrity poll (asserting a forced Binary Output reads its forced value even though its live value differs), DIRECT_OPERATEs a CROB onto that same forced point and asserts the master's own `operate()` call is rejected `BadStatus(NotAuthorized)` (the force-aware control-skip path proven against a real master's command, not a hand-rolled test double), DIRECT_OPERATEs and then SELECT-then-OPERATEs an Analog Output (two real, separate fragments) with independent re-poll confirmation each time, polls Class 1/2/3 events in a bounded loop against dedicated fixture-driven event points and asserts at least one event of each object group (g2/g32/g11/g42) is received, and finally brings up a second master association configured to ENABLE unsolicited reporting at startup and asserts it receives outstation-initiated unsolicited events (auto-CONFIRMed by the crate) - proving the enable-then-push-then-CONFIRM path end to end.

## 8. Gotchas

- **Static (Class 0) and event (Class 1/2/3) reporting are two structurally different mechanisms, not two views of the same data.** A point's per-point event class assignment governs whether it EVER produces an event at all - leaving every point at the static-only default is a valid, conservative choice, not an oversight, but a SCADA integration expecting event-driven updates on a point left at class 0 will see nothing until the next integrity poll.
- **The first observation of a point after (re)start must seed a baseline without emitting an event**, or every point's startup value gets reported as a fabricated "change" the instant polling begins.
- **An un-confirmed event batch (solicited or unsolicited) must stay buffered and be retried/re-reported, never dropped**, or a single missed CONFIRM (a transient network blip) permanently loses that batch's events.
- **A control targeting a forced point needs its own explicit rejection status distinguishable from "not supported" or "out of range."** Silently discarding the write while returning a generic success, or conflating it with an unrelated rejection code, both hide the real reason a master's command had no effect.
- **SELECT/OPERATE matching must be byte-identical on the control object, not merely "the same point and value."** A qualifier, range encoding, or index-list difference between the SELECT and the OPERATE is a legitimate mismatch to reject, not a detail to normalize away.

```
Wrong: report a control refused-because-forced with the same status code as
       "not supported" or "out of range."
Correct: DNP3 has a dedicated NOT_AUTHORIZED control status distinct from
       NOT_SUPPORTED - use it specifically for a forced-point refusal so a
       master's operator can tell "this point doesn't support control" from
       "this point is deliberately locked right now."
```

---

## What this means practically

### "My master's integrity poll works but it never receives an event even though I know the value changed"
Check the point's assigned event class. A point left at class `0` (the conservative default) is static-only by design and will never generate an event regardless of how often its value changes - only Class 0/integrity polling will ever see the new value for that point.

### "A SELECT-then-OPERATE control I know should succeed gets rejected NO_SELECT"
Confirm the OPERATE's control object is byte-identical to the preceding SELECT's - same group/variation/qualifier/range/indices/payload - and that it arrived inside the matching window. A master library that re-encodes the control object slightly differently between the two calls (a different qualifier choice, for instance) produces exactly this rejection even though "the same point and value" were intended both times.

---

## Related

- [modbus.md](./modbus.md) - the closer addressing-model analog (per-table/per-type independent index spaces) compared to an area-image protocol.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
