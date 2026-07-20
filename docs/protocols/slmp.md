# Mitsubishi SLMP / MELSEC Communication (device side, v1)

The app hosts a **Mitsubishi SLMP server** (MELSEC Communication, MC protocol,
**3E binary** frame) in-process, in pure Dart, over **TCP** on port **5007** by
default. Like the other protocol adapters (OPC UA, Modbus TCP, MQTT + Sparkplug
B, DNP3, EtherNet/IP + CIP, S7comm, Omron FINS) it follows ADR-010: there is no
companion process, no native plugin, and nothing runs until you explicitly
enable it on the **Outbound Protocols** screen.

Implemented from public SLMP / MC-protocol specification material.

SLMP is a **length-prefixed TCP** protocol (like S7comm and EtherNet/IP), and —
in deliberate contrast to its neighbours S7comm and FINS, which are **big-endian**
— SLMP's body is **LITTLE-ENDIAN** (see *Endianness* below).

---

## v1 scope

| Layer | What is implemented | File |
| --- | --- | --- |
| SLMP 3E frame | Subheader (`0x5000` req / `0xD000` resp), routing (network/pc/module), `requestDataLength`, monitoring timer, command, subcommand, data; response echoes the routing and carries an end code | `mobile/lib/protocols/slmp/slmp_frame.dart` |
| Command codec | Batch Read (`0x0401`) / Batch Write (`0x1401`) word-units device spec (device code, 3-byte device number, point count) and response data | `mobile/lib/protocols/slmp/slmp_commands.dart` |
| Device word image | Materialize a device's **word** image from tags; decode a written slice back onto them | `mobile/lib/protocols/slmp/slmp_device_image.dart` |
| Read/Write dispatch | Request → response, shared by the host and the E2E fixture | `mobile/lib/protocols/slmp/slmp_dispatch.dart` |
| Exposure model | `SlmpMap` / `SlmpMapEntry`, auto-generation, per-entry access | `mobile/lib/models/slmp_map.dart` |
| Socket host | `ServerSocket` bind + length-prefixed reassembly loop; client-count tracking | `mobile/lib/services/slmp_host.dart` |
| Config | `SlmpProtocolConfig` (enabled, port, map), JSON key `slmp` | `mobile/lib/models/protocol_settings.dart` |

Everything except the socket host is pure Dart with no `dart:io` and no Flutter
dependency, which is what lets the E2E fixture host (below) run under a plain
`dart run`.

---

## Endianness: body LITTLE-endian, subheader big-endian

**SLMP 3E binary is LITTLE-ENDIAN throughout its body** — the routing fields, the
`requestDataLength`, the 3-byte device number, the point count, and every encoded
word value. This is the **exact inverse** of the S7comm and FINS codecs that sit
right next door. Do **not** pattern-match a big-endian read from a neighbouring
protocol onto SLMP.

The **one** big-endian field is the 2-byte **subheader** (`0x5000` / `0xD000`),
handled in `slmp_frame.dart`; nothing else in the frame is big-endian.

---

## Transport: length-prefixed TCP

SLMP 3E rides a **TCP** stream. The host binds a single `ServerSocket` and
reassembles whole 3E frames out of arbitrary TCP chunking, exactly as the S7comm
and EtherNet/IP hosts do (and unlike the FINS UDP host, which has no reassembly).

The **length-field convention was verified against the real client at Task 3**
and is the trap this transport most easily gets wrong: the 3E `requestDataLength`
u16 (little-endian, at byte offset 7) counts the bytes that **follow** it
(monitoring timer + command + subcommand + command data) and does **not** include
the 9-byte fixed prefix before it. So the reassembly total is
`9 + requestDataLength`. (Contrast S7comm's TPKT length, which *includes* its own
4-byte header.) `pymcprotocol`'s `_make_senddata` emits exactly `timer + command +
subcommand + data` as the length, confirming this.

A malformed, short, or unsupported frame — from any client, at any time — is
dropped without disturbing the bind: an unparseable/unsupported frame yields a
`null` reply and is dropped with the connection left open; a frame whose declared
length is impossible closes only that one connection. The codecs return `null`
rather than throwing on hostile input, so one bad frame can never wedge the host.

Routing (network / PC / module I/O / module station) is accepted **permissively**:
the fields are never validated against any notion of the host's own address, and
a response simply echoes them back — the same permissive stance the S7comm host
takes on rack/slot.

---

## Addressing: device + device number

A real MC-protocol driver issues optimized block reads by **device code + device
number** ("D100, 20 words" in one request) rather than one request per tag. So the
app materializes a packed **word image** of a device from the project's named
tags, serves slices of it, and — in the write direction — decodes a written slice
back onto the tags it overlaps. SLMP word devices address a **word** (2 bytes).

### Supported devices

| Device | Name in the map | Word wire code |
| --- | --- | --- |
| Data register | `D` | `0xA8` |
| Internal relay | `M` | `0x90` |
| Link register | `W` | `0xB4` |
| File register | `R` | `0xAF` |

Only these four **word** devices are served. A request naming any other device
code gets a per-request error end code (`0xC059`, unsupported command / device),
never a dropped frame. Only the **word-units** subcommand (`0x0000`) is served; a
bit-units subcommand (`0x0001`) is dropped (BOOLs are addressed inside their
containing word — see below).

### Supported types

| App tag type | On the wire | Words |
| --- | --- | --- |
| `BOOL` | one bit inside a word, at `bitOffset` (0..15) | 1 (shared) |
| `INT16` | `INT` | 1 |
| `INT32` | `DINT` | 2 |
| `INT64` | 4-word integer | 4 |
| `FLOAT64` | `REAL` | 2 |
| `STRING` | *not representable* — see *Deferred* | — |

#### FLOAT64 → REAL is a NARROWING conversion

The app stores floating-point tags as 64-bit doubles. An SLMP `REAL` is 32-bit
IEEE-754 single precision. A `FLOAT64` tag read over SLMP is therefore the
**float32 approximation** of the stored double, not the double itself, and a value
written over SLMP lands in the tag as the double nearest that float32.
Round-tripping through SLMP is lossy for any double not exactly representable in
single precision. Read the same tag over OPC UA if you need full precision.

#### The 32-bit word order — LOW WORD FIRST (confirmed by the real client)

A 32-bit value (`DINT`/`REAL`) and a 64-bit value span **two or four consecutive
words**, and which word holds the high half is a documented Mitsubishi gotcha
that a build→parse round-trip **cannot** detect (the same assumption sits on both
sides of it).

The implementation provisionally chose *low word first*. The Task-5 E2E
**confirmed that choice**: the real third-party `pymcprotocol` client decodes a
multi-word value as a plain little-endian byte string (its `randomread` dword
decode is `int.from_bytes(bytes, "little")`), i.e. **low-word-first**. The client
is the authority, and it agreed with the provisional order:

> **Low word at the lower word address, little-endian within each word.**
> `DINT 0x1A2B3C4D` occupies word *N* = `0x3C4D` (low) and word *N+1* = `0x1A2B`
> (high) — on the wire, bytes `4D 3C 2B 1A`.

This was proven, not assumed: the E2E fixture **seeds** a known `DINT`
(`0x1A2B3C4D`, all four bytes distinct) into a tag independently of the client,
and the `pymcprotocol` client reads its two words back and asserts the literal
low-word-first order (probe step 5). A write→read-back alone could never have
settled it, because our encode and decode are symmetric and therefore
byte-transparent — only a value seeded outside the round trip exposes a word-order
disagreement. The order lives in exactly one helper (`_wordSlot`, used by
`_toWireWords`/`_fromWireWords`) in `slmp_device_image.dart`, with the
literal-byte tests in `test/slmp_device_image_test.dart` pinning it. A single-word
value (`INT16`, `BOOL`) is unaffected.

---

## The `SlmpMap` model

`SlmpMapEntry` binds one tag (by its dotted/indexed resolver leaf path) to
`device` + `address` (the device number) + `bitOffset` + `access` (`ReadOnly` /
`ReadWrite`). `bitOffset` (0..15) is only meaningful for `BOOL`. Tags are resolved
through the same shared `models/tag_resolver.dart` every other adapter uses —
there is no parallel resolution mechanism.

`SlmpMap.autoGenerate(project)` builds a default map from the project's scalar
leaves (composite and array tags expand to one entry per leaf), packing them all
into the **D** device in leaf order:

* consecutive `BOOL` leaves are **bit-packed**, filling bits 0..15 of a word
  before advancing;
* the first non-`BOOL` leaf after a run of `BOOL`s closes the partially used
  word, then takes whole words;
* `STRING` leaves (and anything with no SLMP width) are **skipped entirely**.

Access is inherited from the **root** tag: an `ioType` of `SimulatedOutput`, or an
explicit tag `access` of `ReadOnly` (how the reserved `System` tag is marked),
yields `ReadOnly`; everything else yields `ReadWrite`.

You can edit every field by hand in the **SLMP Device Map** editor on the Outbound
Protocols screen, including moving entries into `M`/`W`/`R`.

The map is **persisted** in the project's `slmp` config block and is what the host
serves — the host reads `project.protocols.slmp.map` fresh on every frame, falling
back to `autoGenerate` only for a project that has never configured SLMP.

---

## Gap semantics, partial coverage, and write refusal

These are deliberate product decisions, mirroring the S7comm / FINS area image:

* **Unmapped words read as zero.** The image is zero-filled and only covered words
  are written, so a driver can block-read a whole device without every word being
  mapped.
* **Writes to unmapped words are DISCARDED**, silently and without an error —
  there is no tag there to write. A block write spanning mapped tags and gaps
  succeeds, updating only the tags.
* **A tag only PARTIALLY covered by a write range is NOT written.** Writing half of
  a multi-word value would corrupt it. Unlike a gap this **is** reported (as an
  address-range end code, `0xC056`).
* **A write to a `ReadOnly` map entry, or to a FORCED tag, is REFUSED** with the
  write-protect end code (`0xC05B`), the tag left unchanged. This reuses the
  shared write-gate (`isExternallyWritable`, `models/tag_write_gate.dart`) — the
  same gate OPC UA / Modbus / DNP3 / EtherNet/IP / S7comm / FINS use — so the
  refusal is not duplicated or weakened here. The force check and the gate resolve
  the **root** tag, so a member path such as `Tank.Level` cannot bypass a force on
  `Tank` or a reserved-`System` refusal. A `SimulatedOutput` tag mapped `ReadWrite`
  by hand still accepts writes (the deliberate override survives). Forcing is
  authoritative: an external write must never change the value behind a force.

The `0xC05B` write-protect end code was confirmed against the real `pymcprotocol`
client at Task 5: a write to a `ReadOnly`-mapped tag raises the client's
`MCProtocolError` carrying exactly `0xC05B`, and the tag is unchanged afterward.

---

## Web platform note

Hosting binds a real inbound TCP port, which **web browsers do not allow** (a
browser cannot bind a listening TCP socket). The SLMP card's Start button is
disabled on web with a note to that effect; you can still design the device map in
the browser. Run the desktop (Windows/macOS/Linux) or mobile (Android/iOS) app to
host. (Port 5007 is above 1023, so unlike S7comm's port 102 there is **no
privileged-port caveat** on any native platform; the port is user-editable on the
card — MC protocol defines no universal default port.)

---

## Deferred to v2 (deliberate, with reasons)

* **4E frame.** SLMP also defines a 4E frame (a 3E frame with an added serial-number
  correlation header). v1 serves 3E binary only; adding 4E is a header extension on
  the same command set, not a new codec.
* **ASCII frames.** SLMP defines an ASCII variant alongside binary. v1 serves binary
  only (`pymcprotocol`'s `Type3E` defaults to binary); ASCII is a separate
  wire-format layer over the same commands.
* **X / Y and other bit devices, and exotic (EM-style) device banks.** v1 serves
  the four core **word** devices (`D`/`M`/`W`/`R`). Additional devices are further
  device-code mappings, not a new mechanism.
* **Timers and counters.** These carry a present value plus a coil/contact flag with
  no equivalent in this app's tag model, so mapping them would mean inventing a
  semantic rather than exposing one.
* **`STRING`.** An SLMP string is a byte run whose length conventions a driver
  expects; `SlmpMap.autoGenerate` skips `STRING` leaves and the device image
  refuses to encode or decode one. A `STRING` can still be mapped by hand; it
  simply will not serve.
* **Random read/write and monitor commands.** v1 serves the two Batch (word-units)
  commands. Random read/write (`0x0403`/`0x1402`) and register-monitor commands are
  additional command handlers on the same frame and device image.

---

## Running the E2E

```bash
bash tool/slmp_e2e.sh     # prints "SLMP PROBE PASS", exits 0
```

This is the only SLMP test in the repo that is **not our codec talking to
itself**, so it — not the unit suite — is the authority on wire details.

It starts the pure-Dart fixture host (`mobile/tool/slmp_host_probe.dart`) on TCP
port **15007** (not 5007, which may already be in use), waits for `READY`, then
runs `tool/py/slmp_probe.py` — driving the real third-party **`pymcprotocol`**
Python library — against it and propagates the probe's exit code. The host is
killed unconditionally on the way out.

Because both the fixture host and the shipped host (`services/slmp_host.dart`)
call the **same** pure `dispatchSlmpFrame` against the same `SlmpTagImage`, the
bytes the `pymcprotocol` client validates are — by construction, not by diff — the
bytes the app puts on the wire.

### What the probe drives

1. `connect()` — open the client TCP socket to the host.
2. A Batch Read of one `D` word, asserting the value (little-endian word data,
   `0x0000` end code, the D device code, the length reassembly).
3. A four-word block read, proving multi-word order and a longer-frame reassembly.
4. A `W`-device read, proving the device code is discriminated (not served from D).
5. **The 32-bit settler:** reads a `DINT` the fixture seeded independently
   (`0x1A2B3C4D`) and asserts the literal **low-word-first** two-word order.
6. A `DINT` **write → independent read-back** of the exact value.
7. A `BOOL` bit round trip (read the word, write the bit set, read it back).
8. A `ReadOnly`-entry write refused with the write-protect end code (`0xC05B`),
   value unchanged.
