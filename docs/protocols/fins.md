# Omron FINS (device side, v1)

The app hosts an **Omron FINS server** in-process, in pure Dart, over **UDP** on
port **9600** by default. Like the other protocol adapters (OPC UA, Modbus TCP,
MQTT + Sparkplug B, DNP3, EtherNet/IP + CIP, S7comm) it follows ADR-010: there
is no companion process, no native plugin, and nothing runs until you explicitly
enable it on the **Outbound Protocols** screen.

Implemented from public FINS specification material.

FINS is this suite's **only datagram (UDP) protocol** — every other adapter is
TCP. One datagram is one complete FINS frame; there is no reassembly and no
per-connection state (see *Transport* below).

---

## v1 scope

| Layer | What is implemented | File |
| --- | --- | --- |
| FINS frame | 10-byte header (`ICF`/`RSV`/`GCT`/`DNA`/`DA1`/`DA2`/`SNA`/`SA1`/`SA2`/`SID`), command code, text; response swaps the node fields and echoes the `SID` | `mobile/lib/protocols/fins/fins_frame.dart` |
| Memory Area codec | Memory Area Read (`0x0101`) / Write (`0x0102`) item spec (area code, word address, bit, count) and response data | `mobile/lib/protocols/fins/fins_memory.dart` |
| Area word image | Materialize an area's **word** image from tags; decode a written slice back onto them | `mobile/lib/protocols/fins/fins_area_image.dart` |
| Read/Write dispatch | Request → response, shared by the host and the E2E fixture | `mobile/lib/protocols/fins/fins_dispatch.dart` |
| Exposure model | `FinsMap` / `FinsMapEntry`, auto-generation, per-entry access | `mobile/lib/models/fins_map.dart` |
| Socket host | `RawDatagramSocket` bind + receive loop; recent-source tracking | `mobile/lib/services/fins_host.dart` |
| Config | `FinsProtocolConfig` (enabled, port, map), JSON key `fins` | `mobile/lib/models/protocol_settings.dart` |

Everything except the socket host is pure Dart with no `dart:io` and no Flutter
dependency, which is what lets the E2E fixture host (below) run under a plain
`dart run`.

**Every multi-byte field on this protocol is BIG-ENDIAN** within a 16-bit word —
the command code, the word address, and every encoded value. The one subtlety is
how a value that spans **two** words is ordered; see *The 32-bit word order*.

---

## Transport: UDP, one datagram per frame

FINS runs over **UDP**. The host binds a single `RawDatagramSocket` and serves
every peer's datagrams on it. Because UDP preserves message boundaries, **one
datagram is one complete FINS frame** — there is no TPKT-style length prefix, no
reassembly buffer, and no `_Connection` class (the TCP hosts next door have all
three; do not pattern-match them onto this one).

A reply is correlated to its request purely by the requester's **source
address/port** and the **echoed `SID`** inside the frame; there is no session
handshake and no "connection closed" event. "Who is talking to us" is inferred
from recently-seen source addresses (shown as *Recent sources* on the card), not
from live sockets.

A malformed, short, or non-FINS datagram — from any source, at any time — is
dropped without disturbing the bind or the next datagram. The codecs return
`null` rather than throwing on hostile input, and every datagram is handled
inside its own try/catch, so one bad packet can never wedge the host.

Node addressing is accepted **permissively**: the header's `DNA/DA1/DA2` and
`SNA/SA1/SA2` fields are never validated against any notion of the host's own
address, and a response is built by swapping destination ↔ source and echoing
the `SID`. Validating them would give a confusing failure with no diagnostic
value (the reply is delivered by the UDP 4-tuple regardless).

---

## Addressing: memory area + word offset

A real FINS driver issues optimized block reads by **area code + word address**
("DM100, 20 words" in one request) rather than one request per tag. So the app
materializes a packed **word image** of an area from the project's named tags,
serves slices of it, and — in the write direction — decodes a written slice back
onto the tags it overlaps. FINS addresses a **word** (2 bytes), not a byte.

### Supported areas

| Area | Name in the map | Word wire code | Bit wire code |
| --- | --- | --- | --- |
| Data Memory | `DM` | `0x82` | `0x02` |
| Core I/O | `CIO` | `0xB0` | `0x30` |
| Work | `WR` | `0xB1` | `0x31` |
| Holding | `HR` | `0xB2` | `0x32` |

Each area is served in both addressing modes. A **word**-area item is one
16-bit word (2 bytes on the wire); a **bit**-area item is ONE bit (1 byte on
the wire, `0x00`/`0x01`), with the item spec's `bit` field (0..15) picking
the starting bit and consecutive bits rolling into the next word after bit
15. Bit-mode was deferred in v1 and pinned by a real client: **Ignition's
Omron FINS driver writes a Boolean as a bit-area Memory Area Write** (6-byte
item spec + one data byte) — the word-only build dropped it as "not a served
FINS command" (2026-07-21 in-app log). Bit reads are served off the same
word image as word reads (bit-for-bit consistent); bit writes land only on
`BOOL` map entries at exactly that (word, bit) — a bit inside a non-`BOOL`
entry's word is refused (`0x1103`) rather than corrupting the encoded value,
and gap bits are discarded, mirroring the word-write semantics. A request
naming any other area code gets a per-request error end code (`0x1101`, area
not found), never a dropped datagram.

### Supported types

| App tag type | On the wire | Words |
| --- | --- | --- |
| `BOOL` | one bit inside a word, at `bitOffset` (0..15) | 1 (shared) |
| `INT16` | `INT` | 1 |
| `INT32` | `DINT` | 2 |
| `INT64` | `LINT` | 4 |
| `FLOAT64` | `REAL` | 2 |
| `STRING` | *not representable* — see *Deferred* | — |

#### FLOAT64 → REAL is a NARROWING conversion

The app stores floating-point tags as 64-bit doubles. A FINS `REAL` is 32-bit
IEEE-754 single precision. A `FLOAT64` tag read over FINS is therefore the
**float32 approximation** of the stored double, not the double itself, and a
value written over FINS lands in the tag as the double nearest that float32.
Round-tripping through FINS is lossy for any double not exactly representable in
single precision. Read the same tag over OPC UA if you need full precision.

#### The 32-bit word order — LOW WORD FIRST (settled by the real client)

A 32-bit value (`DINT`/`REAL`) and a 64-bit value (`LINT`) span **two or four
consecutive words**, and which word holds the high half is a documented Omron
gotcha that a build→parse round-trip **cannot** detect (the same assumption sits
on both sides of it).

The implementation provisionally chose *high word first*. The Task-5 E2E
**overturned that**: the real third-party `fins` client serializes a multi-word
value **LOW-WORD-FIRST** — it word-reverses the big-endian byte string (see
`fins.fins_common.reverse_word_order`). The client is the authority, so the
settled order is:

> **Low word at the lower word address, big-endian within each word.**
> `DINT 0x1A2B3C4D` occupies word *N* = `0x3C4D` (low) and word *N+1* = `0x1A2B`
> (high) — on the wire, bytes `3C 4D 1A 2B`.

This was proven, not assumed: the E2E fixture **seeds** a known `DINT` into a tag
independently of the client, and the `fins` client reads it back through its own
two-word decode and asserts the exact value (probe step 5). A write→read-back
alone could never have settled it, because our encode and decode are symmetric
and therefore byte-transparent — only a value seeded outside the round trip
exposes a word-order disagreement. The order lives in exactly two helpers
(`_encodeInt`/`encodeFinsReal` and `_decodeInt`/`decodeFinsReal`, wrapped by
`_reverseWordOrder`) in `fins_area_image.dart`, with the literal-byte tests in
`test/fins_area_image_test.dart` pinning it. A single-word value (`INT16`,
`BOOL`) is unaffected — the word-reverse is a no-op for one word.

---

## The `FinsMap` model

`FinsMapEntry` binds one tag (by its dotted/indexed resolver leaf path) to
`area` + `wordAddress` + `bitOffset` + `access` (`ReadOnly` / `ReadWrite`).
`bitOffset` (0..15) is only meaningful for `BOOL`. Tags are resolved through the
same shared `models/tag_resolver.dart` every other adapter uses — there is no
parallel resolution mechanism.

`FinsMap.autoGenerate(project)` builds a default map from the project's scalar
leaves (composite and array tags expand to one entry per leaf), packing them all
into the **DM** area in leaf order:

* consecutive `BOOL` leaves are **bit-packed**, filling bits 0..15 of a word
  before advancing;
* the first non-`BOOL` leaf after a run of `BOOL`s closes the partially used
  word, then takes whole words;
* `STRING` leaves (and anything with no FINS width) are **skipped entirely**.

Access is inherited from the **root** tag: an `ioType` of `SimulatedOutput`, or
an explicit tag `access` of `ReadOnly` (how the reserved `System` tag is marked),
yields `ReadOnly`; everything else yields `ReadWrite`.

You can edit every field by hand in the **FINS Area Map** editor on the Outbound
Protocols screen, including moving entries into `CIO`/`WR`/`HR`.

The map is **persisted** in the project's `fins` config block and is what the
host serves — the host reads `project.protocols.fins.map` fresh on every
datagram, falling back to `autoGenerate` only for a project that has never
configured FINS.

---

## Gap semantics, partial coverage, and write refusal

These are deliberate product decisions, mirroring the S7comm area image:

* **Unmapped words read as zero.** The image is zero-filled and only covered
  words are written, so a driver can block-read a whole area without every word
  being mapped.
* **Writes to unmapped words are DISCARDED**, silently and without an error —
  there is no tag there to write. A block write spanning mapped tags and gaps
  succeeds, updating only the tags.
* **A tag only PARTIALLY covered by a write range is NOT written.** Writing half
  of a multi-word value would corrupt it. Unlike a gap this **is** reported (as
  an address-range end code, `0x1103`).
* **A write to a `ReadOnly` map entry, or to a FORCED tag, is REFUSED** with a
  not-writable end code (`0x2101`), the tag left unchanged. This reuses the
  shared write-gate (`isExternallyWritable`, `models/tag_write_gate.dart`) — the
  same gate OPC UA / Modbus / DNP3 / EtherNet/IP / S7comm use — so the refusal is
  not duplicated or weakened here. The force check and the gate resolve the
  **root** tag, so a member path such as `Tank.Level` cannot bypass a force on
  `Tank` or a reserved-`System` refusal. A `SimulatedOutput` tag mapped
  `ReadWrite` by hand still accepts writes (the deliberate override survives).
  Forcing is authoritative: an external write must never change the value behind
  a force.

---

## Web platform note

Hosting binds a real inbound UDP port, which **web browsers do not allow** (a
browser cannot bind a listening UDP socket). The FINS card's Start button is
disabled on web with a note to that effect; you can still design the area map in
the browser. Run the desktop (Windows/macOS/Linux) or mobile (Android/iOS) app to
host. (Port 9600 is above 1023, so unlike S7comm's port 102 there is **no
privileged-port caveat** on any native platform.)

---

## Deferred to v2 (deliberate, with reasons)

* **FINS over TCP.** FINS also defines a TCP transport with a small
  connect/keep-alive framing layer on top of the same command set. v1 is UDP
  only — the command codec is transport-agnostic, so adding TCP later is a new
  host, not a codec change.
* **Expansion (EM) memory banks.** The `EM0`..`EM18` banks are additional word
  areas addressed by their own codes. v1 serves the four core word areas
  (`DM`/`CIO`/`WR`/`HR`); adding an EM bank is another area-code mapping, not a
  new mechanism.
* **Timers and counters.** The timer/counter areas carry a present value plus a
  completion flag with no equivalent in this app's tag model, so mapping them
  would mean inventing a semantic rather than exposing one.
* **`STRING`.** A FINS string is a byte run whose length conventions a driver
  expects; `FinsMap.autoGenerate` skips `STRING` leaves and the area image
  refuses to encode or decode one. A `STRING` can still be mapped by hand; it
  simply will not serve.

---

## Running the E2E

```bash
bash tool/fins_e2e.sh     # prints "FINS PROBE PASS", exits 0
```

This is the only FINS test in the repo that is **not our codec talking to
itself**, so it — not the unit suite — is the authority on wire details, and the
first client over UDP in this suite (every prior probe spoke TCP).

It starts the pure-Dart fixture host (`mobile/tool/fins_host_probe.dart`) on UDP
port **19600** (not 9600, which may already be in use), waits for `READY`, then
runs `tool/py/fins_probe.py` — driving the real third-party **`fins`** Python
library — against it and propagates the probe's exit code. The host is killed
unconditionally on the way out.

Because both the fixture host and the shipped host (`services/fins_host.dart`)
call the **same** pure `dispatchFinsDatagram` against the same `FinsTagImage`,
the bytes the `fins` client validates are — by construction, not by diff — the
bytes the app puts on the wire.

### What the probe drives

1. `connect()` — bind the client UDP socket and aim it at the host.
2. A raw Memory Area Read of one DM word, asserting the whole response frame: the
   node-field swap, the ICF response bit, the echoed `SID`, the command-code
   echo, a normal end code, and big-endian word data (six distinct, non-zero
   node addresses make the swap assertion meaningful).
3. The same word via the library's high-level `INT` decode.
4. A two-word read, proving the order of adjacent words.
5. **The 32-bit settler:** reads a `DINT` the fixture seeded independently, and
   asserts both the decoded value and the raw low-word-first byte layout.
6. A seeded `REAL` (`FLOAT64`→float32), riding the same two-word order.
7. A `DINT` **write → independent read-back** of the exact value.
8. A `BOOL` bit round trip (read the word, write the bit set, read it back).
   Then (8b) the **DM BIT area** (`0x02`): a bit-area read of the same flag
   (ONE byte per bit), a bit-area write clearing it, and the byte-for-byte
   **Ignition Boolean write shape** (bit-area write of one `0x01` item) —
   each cross-checked through the WORD view to prove both modes address the
   same memory.
9. A `CIO` second-area read / write / read-back.
10. A `ReadOnly`-entry write refused with a not-writable end code, value
    unchanged.
