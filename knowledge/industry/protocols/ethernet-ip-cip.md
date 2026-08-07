---
id: knowledge:industry/protocols/ethernet-ip-cip
title: EtherNet/IP + CIP
domain: industry/protocols
version: "2026-08"
topics: [ethernet-ip, cip, enip, epath, forward-open, symbol-object, little-endian]
summary: EtherNet/IP encapsulation + CIP explicit-messaging wire format, EPATH symbolic addressing, the Forward Open connection-id allocation rule, and how an in-app pure-Dart server implements and E2E-proves both unconnected and connected messaging against a real pycomm3 LogixDriver.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/opc-ua
learnings: [CL-7]
---

# EtherNet/IP + CIP

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/enip/enip_encap.dart`,
> `cip.dart`, `cip_connection.dart`, `cip_tags.dart`, `cip_symbol.dart`,
> `mobile/lib/services/enip_host.dart`, and the real-client E2E script
> `tool/enip_e2e.sh`.
> **Read this before:** implementing or debugging a CIP explicit-messaging
> client/target, diagnosing a Forward Open connection-id mismatch, or
> comparing symbolic (name-based) addressing against a register/byte-offset
> protocol.

---

## 1. The headline rule

**EtherNet/IP encapsulation and CIP are little-endian throughout, and in a Forward Open, the consumer of a direction's traffic allocates that direction's connection id - not the originator for both, and not the target for both.**

Getting the allocation direction backwards is the single defect a self-consistent unit-test suite structurally cannot catch, because both sides of a Dart-only round-trip share the same wrong assumption; only a real third-party originator (which sends zeros in the field it expects the target to fill) exposes it.

---

## 2. Wire format

### 2.1 Encapsulation framing

A 24-byte header precedes the payload: `command` u16, `length` u16 (bytes of data **after** this header - excludes the header itself, the inverse of TPKT's length convention next door), `sessionHandle` u32, `status` u32, an 8-byte opaque `senderContext` echoed back verbatim, `options` u32 (reserved). Payloads (for `SendRRData`/`SendUnitData`) are encoded as **CPF** (Common Packet Format): a u16 item count followed by that many `typeId(u16) + length(u16) + data` items.

Key encapsulation commands: `RegisterSession` (`0x65`), `UnRegisterSession` (`0x66`), `SendRRData` (`0x6F`, unconnected), `SendUnitData` (`0x70`, connected), `ListIdentity` (`0x63`, pre-session discovery), `NOP` (`0x00`).

### 2.2 CIP request/response envelope

`service` u8, `pathWords` u8 (EPATH length in **16-bit words**, not bytes), then the EPATH, then service-specific data. A response is `service | 0x80`, a reserved byte, a `generalStatus` byte, an `additionalStatusWords` byte, then reply data.

### 2.3 EPATH addressing: symbolic vs. logical

| Segment | Byte | Shape |
|---|---|---|
| ANSI Extended Symbol | `0x91` | `nameLen(u8)` + ASCII bytes + one `0x00` pad if `nameLen` is odd |
| Logical (8-bit) | `0x20`/`0x24`/`0x30` | class/instance/attribute + one value byte |
| Logical (16-bit extended) | `0x21`/`0x25` | class/instance + reserved pad byte + u16 LE value |

The Extended Symbol segment is what carries a **tag name** - the symbolic addressing style a Logix-class controller driver uses (contrast S7comm/FINS/SLMP's numeric device/area+offset addressing; `pycomm3`'s `LogixDriver` and **Ignition's Allen-Bradley Logix driver** both browse this way). A dotted/indexed composite-tag leaf path (`Tank.Level`, `Arr[0]`) arrives as consecutive symbol segments joined by `.` before resolution.

### 2.4 Byte order

**Every multi-byte field in EtherNet/IP encapsulation and CIP is little-endian** (CL-7) - the opposite convention from S7comm/FINS next door (both big-endian throughout).

### 2.5 Connection establishment: Forward Open

Two messaging modes exist:

- **Unconnected (UCMM)** - `SendRRData` carrying a Null Address item + an Unconnected Data item. No prior handshake needed.
- **Connected** - `Forward Open` (`0x54`) over UCMM establishes a connection; the client then sends `SendUnitData` with a Connected Address item (the connection id) and a Connected Data item (a 2-byte sequence count + the CIP request). `Forward Close` (`0x4E`) tears it down.

**The consumer of a direction's data allocates that direction's connection id.** A target (server) consumes O→T (originator-to-target) traffic, so the target allocates the O→T id and returns it as the first `u32` of the Forward Open reply - that is the id the originator addresses subsequent `SendUnitData` frames to. The originator consumes T→O traffic and allocates that id itself, sending it in the request; the target echoes it back unchanged. Real originators send **zeros** in the request's O→T field precisely because they expect the target to fill it.

A `Forward Close` is matched by `(connection serial, vendor id, originator serial)` - never by connection id, because a Forward Close request does not carry one.

---

## 3. Transport and port

TCP, IANA-registered port **44818**, unprivileged on every platform.

---

## 4. Addressing / map model

Data is addressed **symbolically by tag name** via the Extended Symbol EPATH segment - closer to OPC UA's name-addressed model than to a register/offset protocol. A general binding model: each mapped point's resolver path becomes its symbol name; a composite (struct/array) point is pre-expanded into one entry per scalar leaf, keyed by its dotted/indexed path, the same leaf-keying convention a name-addressed protocol commonly shares with its OPC UA counterpart.

A controller-style client discovers the whole tag directory at connect time via a **Symbol Object** (class `0x6B`) browse (`Get Instance Attribute List`, `0x55`) - every browsable symbol is a scalar leaf in a flat, atomic exposure model with no structured-type description (that requires a Template Object, a materially larger object model describing memory layout, which a scalar-leaf-only exposure has no honest use for). Symbol instance ids are a dense 1-based sequence, so an entry with no representable wire type is skipped without burning an id, keeping numbering contiguous for a client walking the directory page by page.

A controller-identity handshake (Identity Object class `0x01`, a controller/program-name object) commonly precedes the tag-directory upload, wrapped in an `Unconnected Send` (`0x52`) - a Connection Manager service (class `0x06`) that transparently wraps another CIP request plus a route path and must be unwrapped and re-dispatched through the same service table as a direct request. Re-dispatch recursion (an `Unconnected Send` carrying a `Multiple Service Packet` carrying another `Unconnected Send`, and so on) needs a hard depth cap - otherwise a crafted nested frame becomes an unbounded-recursion resource-exhaustion vector, bounded only by the frame's own byte-size cap (potentially thousands of levels).

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the EtherNet/IP/CIP standard itself.)*

Encapsulation: 24-byte header, CPF item lists, `RegisterSession`/`UnRegisterSession`/`SendRRData`/`SendUnitData`/`ListIdentity`. CIP: Read Tag (`0x4C`), Write Tag (`0x4D`), Multiple Service Packet (`0x0A`, one embedded failure never fails the batch), Forward Open/Close (regular form only - Large Forward Open `0x5B` is not implemented and answers `Service Not Supported (0x08)`, which a real client falls back from), Get Instance Attribute List over the Symbol Object, Get Attributes All over the Identity/Program-Name objects, Get Attribute List (`0x03`) over the Identity object and over a proprietary Rockwell class (`0xAC`, undocumented publicly) that **Ignition's Allen-Bradley Logix driver** probes for symbol/template change detection at connect/browse time (attributes `{1,2,3,4,10}`: symbol count, template count, and two directory-fingerprint hashes) - answered with this host's own stable, deterministic fingerprint of its tag directory (no vendor impersonated; Vendor ID stays 0) so the driver's change-detection check passes and it proceeds to the Symbol Object browse. Any class other than Identity/`0xAC` gets a well-formed reply marking every requested attribute Not Supported (`0x14`), never a blanket service failure.

Data types: `BOOL`(0xC1, 1 byte), `INT`(0xC3, 2), `DINT`(0xC4, 4), `LINT`(0xC5, 8), `REAL`(0xCA, 4 - the app's 64-bit float tag type is narrowed to this single-precision wire type, a lossy round-trip by design). `STRING` has no CIP type here (a symbolic CIP string is a structured type needing the deferred Template Object). A response-size budget on connected sends (`Forward Open`'s negotiated T→O connection size) bounds the Multiple Service Packet reply the same charge-at-admission-plus-reserve-for-the-rest shape S7comm's Read Var budget uses (see [s7comm.md](./s7comm.md)) - an over-budget embedded item is replaced by a header-only `0x11` (Reply Data Too Large) rather than an oversized frame.

## 6. Write-gate interaction

| Situation | CIP general status |
|---|---|
| Tag not in the map, or not in the project at all | `0x05` Path Destination Unknown (deliberately indistinguishable, so an unexposed tag never leaks its existence) |
| Write to a read-only map entry | `0x0F` Privilege Violation, unchanged |
| Write to a FORCED tag | `0x0F` Privilege Violation, unchanged |
| Write type code mismatch | `0x09` Invalid Attribute Value |

A forced tag reads through its forced value (so a client sees what an operator forced) and refuses an external write with a visible status rather than a silent drop - the same policy every write-gated adapter in this suite shares, phrased in that protocol's own status-code vocabulary.

## 7. Real-client E2E proof

Proven against a genuine **`pycomm3`** Python client (v1.2.16). The lower-level `CIPDriver` exercises `RegisterSession`, Large-Forward-Open-rejected-then-fallback, Read/Write Tag over both connected and unconnected messaging (with an independent read-back after every write), a `ReadOnly`/forced-tag write refusal, an unmapped-name refusal, a Symbol Object browse, `Forward Close`, and `UnRegisterSession`. The decisive gate is a full `LogixDriver.open()` (its own session) - Identity + program-name reads via `Unconnected Send`, then `get_tag_list()` walking the Symbol Object with the full attribute set `{1,2,3,5,6,8}`, then `LogixDriver.read()` of a tag through the driver's own read path built from the *uploaded* tag definition (not bytes the probe hands it), including a dotted symbol (`Tank.Level`) confirmed intact in the uploaded directory.

## 8. Gotchas

- **CL-7: EtherNet/IP is little-endian; never copy byte-order handling between protocol codecs by pattern-matching against a neighboring big-endian protocol.**
- **Forward Open connection-id allocation direction is easy to get backwards, and a self-consistent unit test cannot catch it.** The consumer of a direction allocates that direction's id; a real client sending zeros in the O→T field (expecting the target to fill it) is the only thing that exposes an inverted implementation - an unroutable connection id of `0x00000000` is the symptom.
- **A single API's limitation is not the target's limitation.** A generic-messaging client API that only emits logical (Class/Instance/Attribute) EPATH segments cannot express symbolic Read/Write Tag *at all, for any target* - that is a property of the client library, not evidence the target mishandles symbolic addressing.
- **`FLOAT64` -> `REAL` (CIP single precision) is a narrowing conversion.** Compare read-back values with a tolerance unless the value happens to be exactly representable as a float32.
- **A Logix-class SCADA driver can probe a proprietary, publicly-undocumented Rockwell object before it ever reaches the Symbol Object browse.** Ignition's Allen-Bradley Logix driver issues a Get Attribute List against class `0xAC` for symbol/template change detection first. Answering it with a well-formed reply carrying a stable, honest fingerprint at the documented attribute ids `{1,2,3,4,10}` (per Rockwell's Logix Data Access manual, 1756-PM020) - rather than a blanket service failure for an unrecognized class - lets the driver's change-detection check pass and proceed to the Symbol Object browse normally.

```
Wrong: allocate the O->T connection id from the request's O->T field and
       echo it back, while allocating a separate id for T->O.
Correct: the target (consumer of O->T traffic) allocates the O->T id itself
       and returns it as the reply's first field; the originator allocates
       T->O and the target only echoes that one back.
```

---

## What this means practically

### "My unit tests all pass but a real Logix-class client's connected messages go nowhere - why?"
Check which side of the Forward Open exchange is allocating which connection id. A unit test where both the "client" and "server" code paths share the same author's assumption about allocation direction will pass even when that assumption is backwards - only a real originator's actual request/reply bytes expose the mismatch.

### "Why does my tag directory browse stop partway through with a client I know is fine?"
Pagination: an instance-attribute-list browse over the Symbol Object commonly bounds a single response by the negotiated connection size (connected) or a fixed cap (unconnected, which negotiates no size) and returns a partial-transfer status; the client is expected to re-request from the last-returned id + 1 until a page returns success with nothing left.

---

## Related

- [s7comm.md](./s7comm.md) - shares the same response-size-budget shape (charge-at-admission, reserve-for-the-rest) against a different negotiated PDU/connection limit.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
