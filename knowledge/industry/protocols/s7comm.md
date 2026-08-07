---
id: knowledge:industry/protocols/s7comm
title: S7comm
domain: industry/protocols
version: "2026-08"
topics: [s7comm, tpkt, cotp, rfc1006, iso8073, big-endian, area-byte-offset]
summary: S7comm over TPKT/COTP wire format, memory-area + byte-offset addressing, PDU-size negotiation, and how an in-app pure-Dart server implements and E2E-proves it against a real python-snap7 client, including two wire details a build-parse round-trip structurally could not settle.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/fins
learnings: [CL-7]
---

# S7comm

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/s7/tpkt_cotp.dart`,
> `s7_pdu.dart`, `s7_area_image.dart`, `s7_services.dart`,
> `mobile/lib/services/s7_host.dart`, and the real-client E2E script
> `tool/s7_e2e.sh`.
> **Read this before:** implementing or debugging an S7comm client/server,
> diagnosing a BIT-item or PDU-size negotiation mismatch, or comparing
> byte-offset addressing against a name-addressed protocol.

---

## 1. The headline rule

**S7comm rides TPKT + COTP (both big-endian throughout), and TPKT's length field counts the WHOLE packet including its own 4-byte header - the exact inverse of EtherNet/IP's encapsulation length, which excludes its header.**

Every S7 memory access names a byte range inside an area (data block, merker, input, output) rather than a symbolic tag - a real driver issues one optimized block read per area/offset range rather than one request per point.

---

## 2. Wire format

### 2.1 TPKT (RFC 1006) framing

A 4-byte header: `version` u8 (`0x03`), `reserved` u8 (`0x00`), `length` u16 **big-endian** - the length of the **entire packet, header included** (`total = 4 + payload.length`). Getting this backwards (treating it as payload-only, EtherNet/IP-style) shifts every frame boundary a socket host derives from it.

### 2.2 COTP (ISO 8073, class 0) framing

Byte 0 is the length indicator (LI, header bytes that follow, excluding LI itself); byte 1 is the PDU type. Connection Request (`0xE0`) / Connection Confirm (`0xD0`) carry `dstRef`/`srcRef` (u16) + a class/option byte + a variable parameter list, each `code(u8) + len(u8) + value`, parsed **by code, never by position** (parameters may appear in any order on the wire). Known codes: `0xC1` source TSAP, `0xC2` destination TSAP, `0xC0` TPDU size. A Data TPDU (`0xF0`) is `LI 0x02` + a TPDU-number/EOT byte (`0x80` = last data unit) + carried user data.

### 2.3 The S7 PDU

A 10-byte header (12 on `Ack_Data`), then function-specific parameters/data: Setup Communication (`0xF0`, negotiates max PDU length), Read Var (`0x04`), Write Var (`0x05`) - each carrying one or more item specifications and, for a response, per-item data.

An item's wire address is a 24-bit field: `byteOffset * 8 + bitOffset`, so `byteOffset = address >> 3` and `bitOffset = address & 0x07`.

### 2.4 Memory areas

| Area | Wire code | Block number? |
|---|---|---|
| Data block (DB) | `0x84` | yes (`dbNumber`) |
| Merker/flags (M) | `0x83` | no |
| Process inputs (I) | `0x81` | no |
| Process outputs (Q) | `0x82` | no |

`dbNumber` only discriminates within DB; the other three are flat address spaces.

### 2.5 Byte order

**Everything on this protocol is big-endian** (CL-7) - TPKT length, every multi-byte S7 header/parameter field, and every encoded value.

---

## 3. Transport and port

TCP, port **102** - a privileged port on Linux/macOS (binding it without elevation fails there; Windows and Android do not restrict it this way). A driver's port field should be user-editable so a non-privileged port is a documented workaround, not a dead end.

---

## 4. Addressing / map model

Unlike a name-addressed protocol (OPC UA, CIP) or a register-table protocol (Modbus), S7comm addresses a **byte range inside a memory area**. A general binding model: materialize a packed byte image of an area from named points, serve slices of it on read, and decode a written slice back onto the points it overlaps on write. Auto-generation packs points into one data block in point order with natural alignment - consecutive BOOL points bit-packed into a byte before advancing, the first non-BOOL point after a run of BOOLs closing the partially-used byte and then aligning (2-byte types to even offsets, 4/8-byte types to 4-byte boundaries).

**Gap and partial-coverage semantics** are the load-bearing correctness properties of an area-image model, not implementation detail:

- **Unmapped bytes read as zero** - a real controller's block has a fixed size with unused bytes at `0x00`; matching that is what lets a driver block-read a whole block without every byte individually mapped.
- **Writes to unmapped bytes are silently discarded** - there is no point there to write, so a block write spanning mapped points and gaps still succeeds, updating only what's mapped.
- **A point only partially covered by a write range is NOT written**, and this *is* reported (an address-out-of-range per-item error) - writing half a multi-byte value would corrupt it.
- **A single-bit write must not disturb its byte-neighbours** - up to eight BOOL points can share a byte, so a bit write applies through a mask narrowed to exactly the addressed bit.

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the S7comm protocol itself.)*

TPKT/COTP framing, Setup Communication (PDU size negotiated down from any larger proposal, clamped to 480 here with a 240-byte floor), Read Var/Write Var (multi-item, one return code per item, so one bad item never fails the others). Types: `BOOL` (one bit), `INT`(2 bytes), `DINT`(4), `LINT`(8), `REAL`(4 - the app's 64-bit float type is narrowed to this single-precision wire type, lossy by design). `STRING`, and the timer/counter areas (`0x1D`/`0x1C`, S5TIME/BCD-encoded with no equivalent tag-model semantic), are not representable and are skipped by auto-generation. Optimized-block (symbolic) access, used by newer controller families with no stable byte offsets, is a different addressing scheme entirely and out of scope for a v1 area+offset model.

A Read Var response is bounded by the negotiated PDU length via a **charge-at-admission-plus-reserve-for-the-rest** budget: each item's full on-wire cost (payload + 4-byte header + odd-length pad byte) is charged as it's admitted, with a fixed minimum reserved for every still-to-come item so a large early item cannot starve its successors past the PDU boundary. At a 480-byte PDU, the data section holds 466 bytes (480 minus a 12-byte Ack_Data header minus a 2-byte parameter), so the largest servable single read is 462 bytes, not 466. This exact budget shape is reused by EtherNet/IP's Multiple Service Packet reply against its own negotiated connection size (see [ethernet-ip-cip.md](./ethernet-ip-cip.md)).

## 6. Write-gate interaction

A write to a read-only map entry, or to a **FORCED** point, is refused with a per-item `0x03` (access denied), the point left unchanged. The force check resolves the **root** point, so a member path (`Tank.Level`) cannot bypass a force on `Tank`. Forcing is authoritative: an external write must never silently corrupt the value behind a force, because reads seed from the forced value and any corruption would surface only once the force is released.

## 7. Real-client E2E proof

Proven against a genuine **`python-snap7`** client (v3.1.0 - at 3.x a pure-Python reimplementation, not a wrapper around the native `snap7` C library, so the bytes an implementation is judged against come from an independent second implementation of the wire format, with nothing to install at the system level). The probe connects (COTP CR/CC + Setup Communication/Ack_Data), confirms the client's own parsed PDU length, does a multi-byte read whose bytes all differ (so a byte-order fault cannot silently pass), an odd-length read, a BIT-transport read and write with an independent neighbour-byte-integrity check, a multi-byte write with independent read-back, an S7 `REAL` decode, a second-area (M) round trip, gap-bytes-read-as-zero, a `ReadOnly` write refusal, and a forced-tag write refusal.

## 8. Gotchas

- **CL-7: S7comm/TPKT/COTP are big-endian throughout; EtherNet/IP next door is little-endian. Never pattern-match byte-order handling between protocol codecs.**
- **TPKT length includes its own header; EtherNet/IP's encapsulation length excludes its own header.** These two length-field conventions are opposite, and copying one implementation's derivation onto the other silently misframes every message.
- **A BIT data item's declared length field is genuinely ambiguous between "a true bit count" and "one data byte expressed as 8 bits" - a Dart-only round-trip cannot distinguish them, because the write-side length-to-byte-count recovery (`(declared + 7) / 8`) produces `1` either way.** A real client settled it: a client library that slices a data item's payload as `declared / 8` (not `(declared+7)/8`) needs `8` declared, not `1` - a declared `1` hands such a client **zero** bytes and silently loses the value. `8` is additionally the strictly safer choice for *any* client, because a true-bit-count reader still recovers the correct `1` byte from `8` (`(8+7)/8 == 1`), whereas a `/8`-style reader recovers nothing from a declared `1`.
- **A trailing pad byte after the last item in a response is a live interop risk, not a theoretical one.** Real S7 pads between items rather than after the final one; a client that slices a payload by its declared length and ignores what follows tolerates the extra byte, but a client that doesn't would reject it - worth deliberately testing with an odd-length item at the end of a response.
- **Multi-item requests need a real second implementation to prove; a single-item-only reference client cannot exercise them.** When the available third-party client library only parses single-item responses, multi-item coverage has to fall back to unit tests over real sockets rather than the E2E leg - document that gap explicitly rather than silently under-claiming coverage.

```
Wrong: declare a BIT-transport data item's length field as 1 (the actual
       bit count).
Correct: declare it as 8 (one data byte's worth of bits) - required by at
       least one real client's payload-slicing convention, and strictly
       safer for any other client too.
```

---

## What this means practically

### "Why does my multi-byte read return the right bytes but in a suspiciously convenient order that I can't be sure is correct?"
Use a test value whose bytes are all different (not `0x01 0x02 0x02 0x01`-style palindromes) - only then does a byte-order fault actually change the result rather than accidentally canceling out.

### "A block write that spans several of my mapped points and some unmapped bytes partially succeeded - is that a bug?"
No, if every *fully-covered* point landed and no *partially-covered* point was touched. Silently discarding unmapped-gap bytes while writing every fully-covered point, and explicitly erroring any partially-covered point, is the standard area-image write contract - verify which category each affected point falls into before calling it a defect.

---

## Related

- [ethernet-ip-cip.md](./ethernet-ip-cip.md) - shares the charge-at-admission-plus-reserve-for-the-rest response-size-budget shape against a different negotiated limit.
- [fins.md](./fins.md) - the other big-endian, memory-area-addressed protocol in this suite, but word- rather than byte-addressed.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
