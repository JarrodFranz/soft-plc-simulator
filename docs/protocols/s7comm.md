# S7comm (device side, v1)

The app hosts an **S7comm server** in-process, in pure Dart, on TCP **102** by
default. Like the other five protocol adapters (OPC UA, Modbus TCP, MQTT +
Sparkplug B, DNP3, EtherNet/IP + CIP) it follows ADR-010: there is no companion
process, no native plugin, and nothing runs until you explicitly enable it on
the **Outbound Protocols** screen.

Implemented from public S7comm specification material.

---

## v1 scope

| Layer | What is implemented | File |
| --- | --- | --- |
| TPKT (RFC 1006) | 4-byte header; the big-endian `length` counts the **whole** packet, header included | `mobile/lib/protocols/s7/tpkt_cotp.dart` |
| COTP (ISO 8073) | Connection Request (0xE0) → Connection Confirm (0xD0) with TSAP + TPDU-size parameters, Data (0xF0) | `mobile/lib/protocols/s7/tpkt_cotp.dart` |
| S7 PDU | 10-byte header (12 on `Ack_Data`), Setup Communication (0xF0), Read Var (0x04) / Write Var (0x05) item specs and data items | `mobile/lib/protocols/s7/s7_pdu.dart` |
| Area byte image | Materialize an area's byte image from tags; decode a written slice back onto them | `mobile/lib/protocols/s7/s7_area_image.dart` |
| Read/Write dispatch | Per-item Read Var / Write Var request → response | `mobile/lib/protocols/s7/s7_services.dart` |
| Exposure model | `S7Map` / `S7MapEntry`, auto-generation, per-entry access | `mobile/lib/models/s7_map.dart` |
| Socket host | `ServerSocket`, TPKT reassembly, per-socket COTP/S7 session state | `mobile/lib/services/s7_host.dart` |

Everything except the socket host is pure Dart with no `dart:io` and no Flutter
dependency, which is what lets the E2E fixture host (below) run under a plain
`dart run`.

**Everything on this protocol is BIG-ENDIAN** — the TPKT length, every
multi-byte S7 header and parameter field, and every encoded value. (The
EtherNet/IP codec next door is little-endian throughout; the two must not be
pattern-matched onto each other.)

---

## Addressing: memory area + byte offset

S7comm is unlike every other protocol this app hosts. OPC UA and CIP address
data by **name**, Modbus by **register**, DNP3 by **point**. S7comm addresses a
**byte range inside a memory area**: a real driver issues optimized block reads
("DB1 bytes 0..40" in one request) rather than one request per tag.

So the app materializes a packed **byte image** of an area from the project's
named tags, serves slices of it, and — in the write direction — decodes a
written slice back onto the tags it overlaps.

An item's wire address is a 24-bit field encoding `byteOffset * 8 + bitOffset`,
so the byte offset is `address >> 3` and the bit offset is `address & 0x07`.

### Supported areas

| Area | Name in the map | Wire code | Block number? |
| --- | --- | --- | --- |
| Data block | `DB` | `0x84` | yes |
| Merker / flags | `M` | `0x83` | no |
| Process inputs | `I` | `0x81` | no |
| Process outputs | `Q` | `0x82` | no |

`dbNumber` only discriminates within `DB`; the other three are flat address
spaces and store 0.

### Supported types

| App tag type | On the wire | Bytes |
| --- | --- | --- |
| `BOOL` | one bit inside a byte, at `bitOffset` | 1 (shared) |
| `INT16` | `INT` | 2 |
| `INT32` | `DINT` | 4 |
| `INT64` | `LINT` | 8 |
| `FLOAT64` | `REAL` | 4 |
| `STRING` | *not representable* — see below | — |

#### FLOAT64 → REAL is a NARROWING conversion

The app stores floating-point tags as 64-bit doubles. An S7 `REAL` is 32-bit
IEEE-754 single precision. A `FLOAT64` tag read over S7comm is therefore the
**float32 approximation** of the stored double, not the double itself, and a
value written over S7comm lands in the tag as the double nearest that float32.
Round-tripping a value through S7comm is lossy for any double that is not
exactly representable in single precision. Read the same tag over OPC UA if you
need the full precision.

---

## The `S7Map` model

`S7MapEntry` binds one tag (by its dotted/indexed resolver leaf path) to
`area` + `dbNumber` + `byteOffset` + `bitOffset` + `access`
(`ReadOnly` / `ReadWrite`). Tags are resolved through the same shared
`models/tag_resolver.dart` every other adapter uses — there is no parallel
resolution mechanism.

`S7Map.autoGenerate(project)` builds a default map from the project's scalar
leaves (composite and array tags expand to one entry per leaf), packing them all
into **DB 1** in leaf order with natural alignment:

* consecutive `BOOL` leaves are **bit-packed**, filling bits 0..7 of a byte
  before advancing;
* the first non-`BOOL` leaf after a run of `BOOL`s closes the partially used
  byte, then aligns — 2-byte types to even offsets, 4- and 8-byte types to
  4-byte boundaries;
* `STRING` leaves (and anything with no S7 width) are **skipped entirely**.

Access is inherited from the **root** tag: an `ioType` of `SimulatedOutput`, or
an explicit tag `access` of `ReadOnly` (how the reserved `System` tag is
marked), yields `ReadOnly`; everything else yields `ReadWrite`.

You can edit every field by hand in the **S7 Area Map** editor on the Outbound
Protocols screen, including moving entries into `M`/`I`/`Q` or into another data
block.

---

## Gap semantics, partial coverage, and write refusal

These are deliberate product decisions, not accidents of implementation:

* **Unmapped bytes read as zero.** A real controller's data block is a
  fixed-size buffer whose unused bytes hold `0x00`, and matching that is what
  lets a driver block-read a whole block without every byte being mapped.
* **Writes to unmapped bytes are DISCARDED**, silently and without a per-item
  error — there is no tag there to write. A block write that spans mapped tags
  and gaps therefore succeeds, updating only the tags.
* **A tag only PARTIALLY covered by a write range is NOT written.** Writing half
  of a multi-byte value would corrupt it. Unlike a gap, this **is** reported, as
  a per-item `0x05` (address out of range), so a driver sees that its request
  did not do what it asked.
* **A write to a `ReadOnly` map entry, or to a FORCED tag, is REFUSED** with a
  per-item `0x03` (access denied), and the tag is left unchanged. The force
  check is made against the **root** tag, so a member path such as `Tank.Level`
  cannot bypass a force on `Tank`. Forcing is authoritative: an external write
  must never change the underlying value behind a force, because reads seed from
  the forced value and the corruption would only surface once the force was
  released.
* **One bad item never fails the others.** Read Var and Write Var responses
  carry one return code per item, in request order.
* **A single-bit write does not disturb its byte-neighbours.** Up to eight
  `BOOL` tags can share a byte; a BIT write is applied through a map narrowed to
  the addressed bit, so the other seven are untouched by construction.

---

## Two wire details settled by the real client

Both were things a Dart round-trip structurally could not decide, because the
same assumption sat on both sides of it. The E2E's real third-party client
decided them.

### 1. A BIT data item declares `bytes * 8`, not a bit count

A data item's `length` field is in **bits** for transport sizes `0x03` (BIT) and
`0x04` (BYTE/WORD), and in bytes for `0x09` (OCTET STRING). For a single-bit
item the question was whether to declare `1` (a true bit count) or `8` (one data
byte × 8).

An earlier version declared `1`. A Dart round-trip could never catch that,
because the write-side parser recovers the byte count as `(declared + 7) ~/ 8`,
which is 1 byte for **both** values. The real client settled it: `python-snap7`
slices a data item's payload as `declared ~/ 8`, so a declared `1` handed it
**zero** bytes and the bit value was lost outright. It requires `8`, which is
also what its own write path sends.

`8` is additionally the strictly safer choice for any *other* client: one that
reads the field as a true bit count still recovers `(8 + 7) ~/ 8 == 1` byte,
which is right, whereas a `~/ 8` client recovers nothing from a declared `1`.
See `buildDataItem` in `s7_pdu.dart`, whose doc comment carries this reasoning
so it is not "corrected" back on the strength of specification prose alone.

### 2. The trailing pad byte is accepted

Every data item is padded to an even byte count, **including the last one in a
response**. Real S7 pads *between* items rather than after the final one, so
this was a live interop risk. The E2E drives an odd-length (3-byte) read for
exactly this reason: the client accepted the trailing pad without complaint,
because it slices the payload by the declared length and ignores what follows.
The behaviour is retained, and the odd-length read stays in the probe so a
future client that *does* object surfaces immediately.

---

## A Read Var response never exceeds the negotiated PDU

Setup Communication agrees a maximum PDU length (480 here, clamped down from
any larger proposal and never below a 240-byte floor). A response that exceeds
it is dropped by a strict driver, so a read that overruns fails **silently** —
and it would fail on exactly the large-block read this protocol exists to
serve.

The budget is therefore charged each item's **full on-wire cost**, not the
bytes it carries: a data item is its payload *plus* a 4-byte header
(`returnCode`, `transportSize`, 2-byte length) *plus* a pad byte when the
payload length is odd. At 480 the data section may hold 466 bytes
(`480 − 12-byte Ack_Data header − 2-byte parameter`), so the largest servable
single read is **462** bytes, not 466.

An item that does not fit is answered with `0x05` (address out of range) and a
NULL transport — an explicit per-item error, never a truncated payload. The
bound also holds **in aggregate** across a multi-item request: each item's
admission reserves the 4-byte minimum every *later* item needs, so a large item
early in the list cannot starve its successors into pushing the finished
message past the PDU. `test/s7_services_test.dart` pins the boundary from both
sides at 480 and at the 240-byte floor.

This **charge-at-admission-plus-reserve-for-the-rest** shape is the shared
reference for the size budgets the other in-app hosts apply against their own
negotiated limits: EtherNet/IP applies the identical shape to the Multiple
Service Packet reply against the Forward Open connection size (see
`docs/protocols/ethernet-ip.md`, *Response-size budget on connected sends*).

---

## Port 102 is a privileged port

S7comm's standard port, **102**, is below 1024. On **Linux and macOS** binding a
port below 1024 requires elevated privileges, so **Start hosting will fail there
without them**. It does not fail silently: the host never reports `running` on a
bind it did not get, and the Outbound Protocols card renders the failure as its
own labelled red block ("Not hosting — the server did not start.") carrying the
operating system's error verbatim.

The port field is editable, and that is the workaround: any port above 1023
binds without elevation. Point the client at the same port — `python-snap7`'s
`connect()` takes a `tcp_port` argument, and most SCADA drivers expose the
equivalent. Windows and Android do not restrict low ports this way, so 102
generally binds there as-is.

The card shows a standing amber note whenever the configured port is below 1024,
so the caveat is visible before the first failed start rather than after it.

---

## Deferred to v2 (deliberate, with reasons)

* **`STRING`.** An S7 `STRING` is not a byte run — it is a struct carrying
  maximum-length and actual-length header bytes ahead of its characters, and a
  driver reading one expects that layout. Supporting it properly means modelling
  that struct on both sides rather than dumping characters at an offset, so
  `S7Map.autoGenerate` skips `STRING` leaves and the area image refuses to
  encode or decode one. A `STRING` can still be mapped by hand; it simply will
  not serve.
* **Timer (`0x1D`) and counter (`0x1C`) areas.** These use S5TIME and BCD
  encodings with no equivalent in this app's tag model, so mapping them would
  mean inventing a semantic rather than exposing one. A request naming either
  area gets a per-item `0x0A` (object does not exist).
* **Optimized-block access.** Newer controller families can hold blocks in an
  optimized layout with no stable byte offsets, addressed symbolically instead.
  v1's whole model is area + byte offset, which is what non-optimized access
  uses; symbolic access is a different addressing scheme, not a tweak to this
  one.

### NOT deferred: multi-item requests

**Multi-item Read Var and Write Var are fully implemented.** A request carrying
several item specifications is answered item-by-item in request order, each with
its own return code, so one bad or refused item never fails the others
(`s7_services.dart`). What is deferred is only the *third-party proof*: snap7's
response parser is single-item, so the E2E client cannot issue a multi-item
request. That behaviour is therefore covered by unit tests over real sockets
(`test/s7_host_test.dart`) and by the dispatch tests
(`test/s7_services_test.dart`) instead — including the PDU budget, which is
enforced across the whole item list in aggregate, not per item.

---

## Running the E2E

```bash
bash tool/s7_e2e.sh     # prints "S7 PROBE PASS", exits 0
```

This is the only S7comm test in the repo that is **not our codec talking to
itself**, so it — not the unit suite — is the authority on wire details.

It starts the pure-Dart fixture host (`mobile/tool/s7_host_probe.dart`) on port
**10102** (not 102, which is privileged and may already be in use), waits for
`READY`, then runs `tool/py/s7_probe.py` against it and propagates the probe's
exit code. The host is killed unconditionally on the way out.

### What the probe drives

The numbering below is the probe's OWN step numbering — each item `N` is
`tool/py/s7_probe.py`'s `_stepN_...` function (steps 1–3 and 14 are inline in
`run()`). **Keep the two in step when either changes**: `s7_pdu.dart`'s
`buildDataItem` cites "`tool/py/s7_probe.py` step 6" as the evidence for the
BIT declared-length decision, and a reader who follows a drifted numbering
lands on the wrong step and loses that anchor.

1. `connect()` — COTP Connection Request → Connection Confirm, then S7 Setup
   Communication → its `Ack_Data` reply (snap7 does both inside `connect()`).
2. The client agrees the session is up (`get_connected()`).
3. The PDU length **the client** parsed out of **our** reply is exactly 480.
   Note what this does and does not prove: snap7's own default proposal is
   already 480, i.e. at this device's documented maximum, so the exact match
   proves our reply parameter's offset and byte order are what the client
   reads — but **not** that the server-side clamp fired, since the clamp is a
   no-op against a proposal that is already at the maximum. The probe prints
   snap7's pre-connect proposal so a future version proposing something else
   is visible rather than silently making this assertion vacuous. The clamp
   itself is proven separately, by a Dart unit test negotiating **down** from
   a 960-byte proposal.
4. A multi-byte read whose bytes all differ, so a byte-order fault cannot pass.
5. An **odd-length** read — wire question 2 above.
6. A **BIT-transport** read — wire question 1 above.
7. A **BIT-transport write**, then an independent read of the whole byte
   asserting both that the bit landed **and** that its neighbour survived.
8. A multi-byte write, then an **independent read-back of the exact value**.
9. An S7 `REAL` decode.
10. A **second area** (merker/M): read, write, independent read-back, plus a bit.
11. Gap bytes reading zero.
12. A `ReadOnly` write refused, value unchanged.
13. A write to a **forced** tag refused, forced value standing.
14. `disconnect()`.

Every write is followed by a **separate** request that reads the value back: a
read that agrees with a write proves nothing if both travel the same buggy path.

### Why the fixture host proves the shipped host

`S7Host` extends `ChangeNotifier`, which pulls in Flutter machinery unavailable
under a plain `dart run`, so the real client cannot be pointed at it directly.
Rather than keep two hand-written copies in step and verify them by diff, **all**
Read Var / Write Var response bytes are produced by one shared pure function,
`dispatchS7VarJob` in `mobile/lib/protocols/s7/s7_services.dart`, which both the
fixture and `S7Host` call. The bytes the third-party client validates are, by
construction, the bytes the app emits. (The COTP/Setup path is still a mirror,
and `s7_host.dart` remains authoritative for it.)

### Python lane setup

The probe reuses the shared Python lane established by the EtherNet/IP
workstream. `tool/s7_e2e.sh` creates or reuses a virtualenv at `tool/py/.venv`
and installs `tool/py/requirements.txt`, which pins **`python-snap7==3.1.0`**
exactly. Pins are exact on purpose: an E2E whose client library silently changes
version is no longer a reproducible proof, and a wire-level regression would be
indistinguishable from a client-side behaviour change. The virtualenv, its
packages, and any `__pycache__` are git-ignored — nothing downloaded here is
ever committed. Any Python 3.8+ interpreter on `PATH` is enough; the snap7
native library ships with the wheel.
