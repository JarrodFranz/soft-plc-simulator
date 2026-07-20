# EtherNet/IP + CIP Explicit Messaging (v1)

The app hosts an **EtherNet/IP + CIP explicit-messaging server** in-process, in
pure Dart, on TCP **44818** by default. Like the other four protocol adapters
(OPC UA, Modbus TCP, MQTT + Sparkplug B, DNP3) it follows ADR-010: there is no
companion process, no native plugin, and nothing runs until you explicitly
enable it on the **Outbound Protocols** screen.

Implemented from public EtherNet/IP and CIP specification material.

---

## v1 scope

| Layer | What is implemented | File |
| --- | --- | --- |
| Encapsulation | 24-byte header, CPF item lists, `NOP`, `RegisterSession` (0x65), `UnRegisterSession` (0x66), `SendRRData` (0x6F), `SendUnitData` (0x70) | `mobile/lib/protocols/enip/enip_encap.dart` |
| CIP messaging | Request/response envelope, EPATH parse/build (ANSI Extended Symbol + logical Class/Instance/Attribute), elementary type codec | `mobile/lib/protocols/enip/cip.dart` |
| Connection manager | Forward Open (0x54), Forward Close (0x4E) | `mobile/lib/protocols/enip/cip_connection.dart` |
| Tag services | Read Tag (0x4C), Write Tag (0x4D), Multiple Service Packet (0x0A) | `mobile/lib/protocols/enip/cip_tags.dart` |
| Exposure model | `CipMap` / `CipMapEntry`, auto-population, per-entry access | `mobile/lib/models/cip_map.dart` |
| Socket host | `ServerSocket`, frame reassembly, session + connection state | `mobile/lib/services/enip_host.dart` |

Everything except the socket host is pure Dart with no `dart:io` and no Flutter
dependency, which is what lets the E2E fixture host (below) run under a plain
`dart run`.

### Addressing: symbolic tag names

v1 addresses tags **symbolically**, by name, using the ANSI Extended Symbol
EPATH segment (`0x91`). A read of `Speed` carries the single segment
`91 05 'S' 'p' 'e' 'e' 'd' 00` (odd-length names take the mandatory pad byte so
every segment is a whole number of 16-bit words).

Composite and array tags are pre-expanded by `CipMap.autoPopulate` into one map
entry per scalar leaf, keyed by its dotted/indexed resolver path — `Tank.Level`,
`Arr[0]` — the same leaf keying the OPC UA map uses. A dotted name arrives as
consecutive symbol segments and is rejoined with `.` before resolution, so the
same `models/tag_resolver.dart` used by every other protocol layer resolves it.
No parallel resolution mechanism exists.

### Messaging modes

Both unconnected and connected explicit messaging are supported:

- **Unconnected (UCMM)** — `SendRRData` (0x6F) carrying a Null Address item and
  an Unconnected Data item. Read/Write Tag work here directly, with no Forward
  Open required.
- **Connected** — `Forward Open` (0x54) over UCMM establishes a connection; the
  client then sends `SendUnitData` (0x70) with a Connected Address item (the
  connection id) and a Connected Data item (a 2-byte sequence count followed by
  the CIP request). `Forward Close` (0x4E) tears it down.

**Which side allocates which connection id** is the detail most easily got
wrong, and the one the real-client E2E caught us on (see *Wire corrections*
below). The rule is that **the consumer of a direction's data allocates that
direction's id**:

- The target (this host) consumes O→T traffic, so **the target allocates the
  O→T connection id** and returns it as the first `u32` of the Forward Open
  reply. That is the id the originator addresses every subsequent
  `SendUnitData` to, and the id `CipConnectionManager.byConnectionId` resolves.
- The originator consumes T→O traffic, so the originator allocates the T→O id
  and sends it in the request; the target echoes it back unchanged.

Allocation is from a **monotonic counter**, never randomness or the clock, so
runs are byte-for-byte reproducible and tests assert exact ids. Session handles
come from a separate monotonic counter owned by the host and shared across
sockets; each socket gets its own `CipConnectionManager`, so connection ids
allocated on one socket never collide with another's.

The **Large Forward Open (0x5B)** is not implemented. A client that tries it
first (pycomm3 does, by default) receives `Service Not Supported` (0x08) and
falls back to the regular Forward Open — a path the E2E exercises deliberately.

### Supported services

| Service | Code | Notes |
| --- | --- | --- |
| Read Tag | 0x4C | Reply is type code (`u16`) + packed value. Element count in the request is tolerated; v1 exposes only scalar leaves, so there is never more than one element. |
| Write Tag | 0x4D | Request is type code (`u16`) + element count (`u16`) + value. A type code that does not match the tag's actual CIP type is refused with 0x09. |
| Multiple Service Packet | 0x0A | Batches embedded Read/Write Tag requests. The request path must address the Message Router (class 0x02, instance 0x01). One embedded request failing only sets that embedded response's status — it never fails the batch. Over a connected send, the reply is bounded by the negotiated connection size (see *Response-size budget*). |
| Forward Open | 0x54 | Regular form only. The T→O and O→T Network Connection Parameters words are parsed and the connection sizes stored on the connection (see *Response-size budget*). |
| Forward Close | 0x4E | Matched by (connection serial, vendor id, originator serial), never by connection id — a Forward Close request does not carry one. |

Any other service code returns `Service Not Supported` (0x08).

### Response-size budget on connected sends

A `Forward Open` request carries, in its **Network Connection Parameters**
words, the size of the connection each direction negotiates. The low 9 bits of
each `u16` word are the connection size in bytes (the regular Forward Open,
`0x54`; the Large Forward Open with its wider `u32` fields is not implemented).
The connection manager decodes both words and stores them on the connection —
the **T→O size** (the size of the frames *this target sends*) is the one that
bounds a reply. A connected `SendUnitData` therefore carries that size into
`dispatchCipService` as a **response budget**.

The budget applies to the **Multiple Service Packet (0x0A)** reply, the one
service that can amplify a small request into a large reply. It mirrors the S7
Read Var budget (`s7_services.dart buildReadVarResponse`): each embedded
response's on-wire cost — its 2-byte reply-offset entry plus its
`buildCipResponse` body — is charged as it is admitted, and a fixed minimum
(`kCipMspItemHeaderLen`, a header-only error item) is reserved for every
still-to-come item, because the reply's item count must equal the request's, so
no item can be dropped. An embedded response that does not fit the remaining
room is replaced by a **header-only `0x11` (Reply Data Too Large)** item rather
than an oversized frame. The finished CIP response is therefore never larger
than the connection size the client agreed to.

Two behaviours are deliberately preserved:

- **Unconnected (UCMM / `SendRRData`) messaging is unbounded.** It negotiates no
  connection size, so no budget is applied — a UCMM batch behaves byte-for-byte
  as before this hardening pass.
- **A connected batch that fits its budget is byte-identical** to the same batch
  with no budget. Only a batch that *would* overrun changes; its over-budget
  items carry `0x11`.

A separate, always-on guard rejects a batch whose reply framing would exceed the
`u16` offset field: the emitted CIP response is `cursor + 6` bytes (the 2-byte
service count plus the 4-byte outer response header), so the bound is
`0xFFFF - 6`, not `0xFFFF`. A `cursor` in `(0xFFFF - 6, 0xFFFF]` builds a frame
whose own length runs past `0xFFFF` — a self-inconsistency the outer frame
length does not catch — and is refused with `0x0A` (Embedded List Error).

### Supported data types

| App tag type | CIP type | Code | Width |
| --- | --- | --- | --- |
| `BOOL` | `BOOL` | 0xC1 | 1 byte |
| `INT16` | `INT` | 0xC3 | 2 bytes |
| `INT32` | `DINT` | 0xC4 | 4 bytes |
| `INT64` | `LINT` | 0xC5 | 8 bytes |
| `FLOAT64` | `REAL` | 0xCA | 4 bytes |

> **`FLOAT64` → `REAL` is a NARROWING conversion.** CIP `REAL` is IEEE-754
> **single** precision (32-bit); the app's `FLOAT64` tag values are 64-bit Dart
> doubles. Encoding one for the wire loses any precision beyond what a float32
> can represent, and decoding widens it back. Round-tripping a `FLOAT64` through
> EtherNet/IP is therefore **lossy by design of the wire type**, not by defect.
> Compare read-back values with a tolerance, not exact equality, unless the
> value happens to be exactly representable as a float32 (`12.5`, `21.75`, and
> other small dyadic rationals are). CIP does define `LREAL` (0xCB, double
> precision), but exposing `FLOAT64` as `REAL` matches what a controller-style
> client expects to find behind a symbolic analog tag; an `LREAL` option is a
> candidate for v2.

`STRING` has **no** CIP type in v1 — see *Deferred to v2*.

### The `CipMap` exposure model

Nothing is reachable over EtherNet/IP unless it is in the project's `CipMap`.
Each `CipMapEntry` is a tag's resolver path plus an `access` mode
(`ReadOnly` / `ReadWrite`). `CipMap.autoPopulate` builds a default map from the
project's scalar leaves and inherits access from the **root** tag: a
`SimulatedOutput` tag, a tag whose own `access` is `ReadOnly`, or the reserved
`System` tag (checked by name, so it holds regardless of its `access` field)
all yield `ReadOnly`; `SimulatedInput` and `Internal` yield `ReadWrite`. The map
is editable in the app, and persists additively — a project JSON with no
`ethernet_ip` key loads with the protocol disabled on port 44818, unchanged
from before this feature existed.

Refusal semantics, all verified by the real-client E2E:

| Situation | CIP general status |
| --- | --- |
| Tag not in the map, **or** not in the project at all | `0x05` Path Destination Unknown (deliberately indistinguishable — the map miss is checked first, so an unexposed tag does not leak its existence) |
| Write to a `ReadOnly` map entry | `0x0F` Privilege Violation; the tag is unchanged |
| **Write to a FORCED tag** | `0x0F` Privilege Violation; the tag is unchanged |
| Write whose wire type code does not match the tag's type | `0x09` Invalid Attribute Value |

**Force-aware writes are a visible refusal, not a silent drop.** A forced tag
reads through its `forcedValue` (so a client sees what the operator forced,
which is the whole point of a force), and an external write to it — or to any
member beneath a forced root, e.g. `Tank.Level` under a forced `Tank` — is
refused with 0x0F rather than being silently discarded. This mirrors the OPC UA
write path exactly (`protocols/opcua/opcua_services.dart`). The logic engines
skip forced tags silently; an external protocol must never appear to succeed
while having no effect.

### Robustness

Every codec in this stack has a **non-throwing contract**: fed arbitrary,
truncated, or hostile bytes off the wire, it returns `null` or a non-zero CIP
general status, never an exception. The socket host reassembles frames split
mid-header and mid-body, and answers coalesced frames in order. A malformed
frame drops only its own connection; an unregistered session handle or an
unknown connection id is refused at the encapsulation layer rather than
crashing. All of this is covered by `mobile/test/enip_*_test.dart` and
`mobile/test/cip_*_test.dart`.

---

## Deferred to v2 (and why)

These are **deliberate scope boundaries**, documented at the source, not
oversights.

- **Symbol Object / Template Object browse.** A client that uploads a
  controller tag list (which is what `pycomm3`'s `LogixDriver` does at connect
  time) reads the Symbol Object for names and instance ids, then the Template
  Object for the memory layout of every structured type. That is a substantial
  object model in its own right, and it is only needed for *discovery* —
  symbolic addressing works without it, provided the client knows the tag
  names, which for this app's use case it does (they are shown in the map
  editor). v1 therefore ships symbolic read/write and defers browse.
- **`STRING` as a struct.** A symbolic CIP string is not a scalar wire value:
  it is a structured type (a length field plus a character array) whose layout
  a client cannot decode without the Template Object describing it. Since the
  Template Object is deferred, `STRING` has no honest v1 representation, so
  `CipMap.autoPopulate` **skips `STRING` leaves** and `cipTypeForTagType`
  returns `null` for them. Exposing a string as raw bytes with no template
  would produce something no real client could read.
- **Identity Object / ListIdentity.** `ListIdentity` (0x63) is how a client
  discovers a device on the network and reads its vendor/product/serial
  identity. It is a discovery convenience, not a prerequisite for explicit
  messaging, and it invites inventing vendor and product-code values that do
  not describe a real device. Deferred pending a decision on what identity this
  simulator should honestly report.
- **Large Forward Open (0x5B)** and **implicit (Class 1 I/O) messaging.**
  Implicit messaging is a UDP cyclic-data plane, an entirely separate transport
  from the explicit-messaging TCP path this version implements.

---

## End-to-end proof (and how to run it)

Every EtherNet/IP unit test in this repo exercises our codec against frames
**our codec built**. That proves self-consistency, not conformance — it cannot
catch a misread specification, because both sides of the test share the same
misreading. The E2E closes that gap with a real third-party client.

```bash
bash tool/enip_e2e.sh
```

The script starts the Dart fixture host `mobile/tool/enip_host_probe.dart` on a
non-default port, waits for it to print `READY`, runs the **`pycomm3`** client
probe `tool/py/enip_probe.py` against it, kills the host unconditionally via a
`trap`, and propagates the probe's exit code. The probe prints
`ENIP PROBE PASS` and exits 0 only if all of these assert:

1. `RegisterSession` returns a session handle.
2. Large Forward Open (0x5B) is rejected with 0x08 and pycomm3 falls back to
   the regular Forward Open (0x54), which returns a **non-zero** connection id.
3. `Read Tag` over connected messaging returns the expected value, for every
   supported type (`BOOL` / `INT` / `DINT` / `LINT` / `REAL`).
4. `Write Tag` succeeds.
5. An **independent** `Read Tag` returns the exact written value. The write
   reply carries no value, so this separate read is the only thing that can
   prove the write actually landed.
6. The same value reads back over unconnected (UCMM / `SendRRData`) messaging.
7. A `ReadOnly`-mapped write and a forced-tag write are each refused with 0x0F
   and leave the value unchanged; a forced tag reads its forced value; an
   unmapped name returns 0x05.
8. `Forward Close` is accepted, then `UnRegisterSession`.

The fixture host does **not** import `services/enip_host.dart`: `EnipHost`
extends `ChangeNotifier`, which pulls in `dart:ui`, unavailable under a plain
`dart run`. It imports the pure codec and re-implements only the small
reassembly loop — exactly as `modbus_host_probe.dart` and
`opcua_host_probe.dart` do. If the two ever diverge, `enip_host.dart` is
authoritative and the fixture must be updated to match.

### Wire corrections the real client forced

The E2E found one genuine defect that **every unit test had passed**, which is
precisely the failure mode it exists to catch.

**Forward Open returned the connection ids in the wrong direction.** The codec
read the O→T connection id out of the request and echoed it back in the reply,
while allocating its own id for the T→O field. That is backwards. Real
originators (pycomm3 among them) send **zeros** in the request's O→T field
because the target is expected to allocate it, and then read the **first** `u32`
of the reply as the id to address connected messages to. Our host handed
pycomm3 a connection id of `0x00000000`; every `SendUnitData` it then sent was
unroutable and refused. Fixed in `cip_connection.dart` by allocating the O→T id,
echoing the request's T→O id (offset 6, not 2), and keying the open-connection
table — `byTargetId`, renamed `byConnectionId` for clarity — on the allocated
O→T id. `enip_host.dart`, the fixture host, and the affected tests were updated
in step, and `cip_connection.dart`'s header now documents the consumer-allocates
rule prominently.

Everything else matched on the first run: the encapsulation header, CPF item
framing for both `SendRRData` and `SendUnitData`, the Forward Open and Forward
Close request field layouts and their path-size/pad-byte conventions, the
sequence-count handling in the Connected Data item, the CIP request/response
envelope, the ANSI Extended Symbol EPATH encoding, and the Read/Write Tag data
layouts.

### One honest limitation of the probe

`CIPDriver.generic_message()` builds its request path through
`pycomm3.packets.util.request_path()`, which emits only **logical** segments
(Class/Instance/Attribute). It has no parameter that emits an ANSI Extended
Symbol segment, so it cannot express a symbolic Read/Write Tag **at all, for
any target** — this is a property of that API, not of our host.

The probe does not work around this by hand-building bytes. It uses pycomm3's
own symbolic tag-path builder, `pycomm3.packets.util.tag_request_path()` — the
exact function `LogixDriver` itself calls to address a tag by name — inside a
two-line subclass of pycomm3's own request packet classes, submitted through
`CIPDriver.send()`. The encapsulation header, session handling, CPF framing,
connection sequence counts, response parsing, and CIP status decoding are all
still produced and consumed by pycomm3. `LogixDriver` itself is not usable here
because it uploads a tag list at connect time via the Symbol and Template
objects, which are deferred to v2.

---

## The Python probe lane

This is the **first user of a shared Python lane** that the protocol-expansion
program's remaining hosts (S7comm, FINS, SLMP, BACnet) reuse: those protocols
have mature Python client libraries and no vendored Rust crate, so their E2Es
follow this shape rather than the `gateway/` Rust-example shape used by OPC UA,
Modbus, MQTT, and DNP3.

```
tool/py/requirements.txt   pinned client-library versions (exact ==, never floating)
tool/py/enip_probe.py      the third-party client probe
tool/py/.venv/             created on first run; git-ignored, never committed
tool/enip_e2e.sh           venv create/reuse, quiet pip install, READY handshake,
                           unconditional teardown, exit-code propagation
```

Requirements:

- **Python 3.8+ on `PATH`.** `tool/enip_e2e.sh` creates `tool/py/.venv` on first
  run and reuses it afterwards; it handles both the Windows (`Scripts/`) and
  POSIX (`bin/`) venv layouts.
- **Network access on first run**, to `pip install` the pinned library. If that
  fails, the script says so and exits non-zero. It does **not** fall back to a
  hand-rolled client — a real third-party client is the entire point of the
  proof, and a fallback that passed would be worse than a failure, because it
  would be trusted.
- Currently pinned: **`pycomm3==1.2.16`**.

The venv, downloaded packages, and `__pycache__` are git-ignored. Only the
pinned `requirements.txt` is committed.

To add a protocol to this lane: write a pure-Dart fixture host at
`mobile/tool/<proto>_host_probe.dart` that prints `READY ...`, a probe at
`tool/py/<proto>_probe.py` that exits 0 with a `... PROBE PASS` line or
non-zero naming the failing step, pin its client library in
`tool/py/requirements.txt`, and copy `tool/enip_e2e.sh` with the port, paths,
and probe name changed.
