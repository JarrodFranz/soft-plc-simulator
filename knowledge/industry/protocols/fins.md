---
id: knowledge:industry/protocols/fins
title: Omron FINS
domain: industry/protocols
version: "2026-08"
topics: [fins, omron, udp, big-endian, word-swap, memory-area]
summary: Omron FINS wire format over UDP, memory-area + word-offset addressing, the low-word-first 32-bit word-order gotcha settled by a real client, and how an in-app pure-Dart server implements and E2E-proves it against a real fins Python client.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/s7comm
learnings: [CL-7]
---

# Omron FINS

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/fins/fins_frame.dart`,
> `fins_memory.dart`, `fins_area_image.dart`, `fins_dispatch.dart`,
> `mobile/lib/services/fins_host.dart`, and the real-client E2E script
> `tool/fins_e2e.sh`.
> **Read this before:** implementing or debugging a FINS client/server,
> diagnosing a 32-bit word-order mismatch, or handling a datagram (UDP)
> industrial protocol with no reassembly or session state.

---

## 1. The headline rule

**FINS multi-byte fields are big-endian within each word, but a 32-bit (or wider) value's WORD order across words is LOW-WORD-FIRST - a genuinely separate axis from byte order that a build-parse round-trip cannot detect on its own.**

FINS is also this class of protocol's canonical **datagram** example: one UDP datagram is one complete frame, with no length-prefixing, no reassembly buffer, and no per-connection state - a request is correlated to its response purely by source address/port plus an echoed service-id field.

---

## 2. Wire format

### 2.1 Frame layout

A 10-byte header, big-endian throughout: `ICF`(0), `RSV`(1, `0x00`), `GCT`(2, gateway count `0x02`), `DNA`(3, dest network), `DA1`(4, dest node), `DA2`(5, dest unit), `SNA`(6, src network), `SA1`(7, src node), `SA2`(8, src unit), `SID`(9, service id) - then `commandCode` u16, then the command's `text` (a response instead carries `endCode` u16 + `data`).

`ICF` bit 6 (`0x40`) distinguishes a command (0) from a response (1); bit 0 (`0x01`) is a response-required flag the requester sets and the responder passes through unchanged.

**The response header is not the request header copied verbatim.** A responder swaps `DNA/DA1/DA2` (destination) with `SNA/SA1/SA2` (source) - the reply travels back to the node that sent the request, so what was the destination becomes the source of the reply. `SID` is echoed **unchanged** (a client correlates its reply by `SID`, not by node address); getting the address swap backwards sends every reply to the wrong node.

Node addressing fields are commonly accepted **permissively** in a simulator-class implementation - never validated against any notion of "this device's own address" - since a rejected node/unit mismatch is a confusing failure with no diagnostic value when the real correlation mechanism is the UDP 4-tuple, not the header fields.

### 2.2 Memory Area Read/Write

Command codes `0x0101` (Read) / `0x0102` (Write). An item spec names an area code, a word address, a bit (for bit-mode), and a count. Both **word-mode** and **bit-mode** addressing are commonly needed in practice: a word-area item is one 16-bit word; a bit-area item is one bit (transmitted as a full byte, `0x00`/`0x01`), with consecutive bits rolling into the next word after bit 15. Bit-mode is not a cosmetic addition - **Ignition's Omron FINS driver writes a Boolean as a bit-area Memory Area Write** (a 6-byte item spec plus one data byte), never a word-area write with a manually-set bit; a word-only v1 build dropped every such write as "not a served FINS command" until bit-mode was added.

Bit-unit data is served off the **same** underlying word image as word-mode data (bit-for-bit consistent) - the two addressing modes describe the same memory, not two separate stores.

### 2.3 Byte order and the 32-bit word-order gotcha

Every multi-byte field within one word is **big-endian**. A 32-bit or 64-bit value spans two or four **consecutive words**, and which word holds the high half is a documented Omron-family convention that a self-consistent encode/decode round-trip cannot verify - the same wrong assumption sits on both the encode and decode side, so it cancels out and passes every internal test.

**The settled order (proven, not assumed, against a real client): low word at the lower word address, big-endian within each word.** `DINT 0x1A2B3C4D` occupies word N = `0x3C4D` (low) and word N+1 = `0x1A2B` (high) - on the wire, bytes `3C 4D 1A 2B`. This can only be settled by seeding a known value into the underlying store **independently of the client under test** and having the client decode it through its own path - a write-then-read-back through the same implementation's own encode/decode is symmetric and therefore byte-transparent, and can never expose a word-order disagreement no matter how many times it's repeated.

---

## 3. Transport and port

**UDP**, port **9600** by default (a fully user-editable, non-privileged port on every platform - no privileged-port caveat, unlike a TCP protocol on a sub-1024 port). One datagram is one complete FINS frame; there is no reassembly buffer and no per-connection state - this is a structurally different transport model from every TCP-framed protocol in this family (S7comm, EtherNet/IP, SLMP), and pattern-matching a stream reassembler's design onto a datagram protocol is a category error.

A malformed, short, or non-FINS datagram from any source at any time should be dropped without disturbing the bind or the next datagram - a codec that returns null/error rather than throwing on hostile input, handled per-datagram inside its own error boundary, is what keeps one bad packet from wedging a UDP listener that has no per-client connection to tear down and reopen.

---

## 4. Addressing / map model

Like S7comm, FINS addresses a **memory area + offset** rather than a symbolic name - but the unit is a **word** (2 bytes), not a byte. A general binding model: materialize a packed word image of an area from named points, serve slices of it, decode a written slice back onto overlapping points. Auto-generation packs BOOL points bit-packed into a word (filling bits 0-15 before advancing) with the first non-BOOL point after a run of BOOLs closing the partially-used word and taking whole words from there. Gap/partial-coverage semantics mirror S7comm's area-image model exactly: unmapped words read as zero, writes to unmapped words are silently discarded, a point only partially covered by a write range is refused with an explicit error (not silently corrupted).

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the FINS protocol itself.)*

Areas served: Data Memory (`DM`, word code `0x82`/bit code `0x02`), Core I/O (`CIO`, `0xB0`/`0x30`), Work (`WR`, `0xB1`/`0x31`), Holding (`HR`, `0xB2`/`0x32`) - both word and bit units on each. Types: `BOOL`(1 bit), `INT16`(1 word), `INT32`(2), `INT64`(4), `FLOAT64`->`REAL`(2 words, narrowed to single precision, lossy round-trip by design). `STRING` and the Expansion (EM) memory banks are not representable/served (auto-generation skips `STRING` leaves entirely). A write to a bit inside a non-BOOL entry's word is refused rather than corrupting the encoded value; gap bits are discarded, mirroring word-write semantics.

## 6. Write-gate interaction

A write to a read-only map entry, or to a **FORCED** point, is refused with a not-writable end code, the point left unchanged - the shared write-gate backstop every adapter in this suite consults, resolved against the point's **root**, so a member path cannot bypass a force on its parent.

## 7. Real-client E2E proof

Proven against a genuine third-party **`fins`** Python client (v1.0.5 - pure Python, no native library). The probe drives a raw Memory Area Read (asserting the node-field swap, response ICF bit, echoed `SID`, command-code echo, end code, and big-endian word data with six distinct non-zero node addresses so the swap assertion is meaningful), the same read through the library's high-level decode, a two-word read proving adjacent-word order, **the 32-bit settler** (reads a DINT the fixture seeded independently of the client and asserts both the decoded value and the raw low-word-first byte layout), a seeded `REAL` on the same two-word order, a DINT write with independent read-back, a BOOL bit round trip in both word-view and bit-area-command forms - the second cross-checked byte-for-byte against the **Ignition Boolean write shape** (a bit-area write of one `0x01` item) through the WORD view, to prove both modes address the same memory - a second-area (`CIO`) round trip, and a read-only-entry write refusal.

## 8. Gotchas

- **CL-7 (applied to FINS): big-endian throughout at the word level - never pattern-match a little-endian read from a neighboring protocol (EtherNet/IP, SLMP) onto FINS.**
- **32-bit/64-bit word order across words is a separate axis from byte order within a word, and only a value seeded independently of the client under test - never a write-then-read-back through the same code path - can settle it.** A round trip through symmetric encode/decode logic is byte-transparent and structurally cannot expose a word-order bug.
- **A "word-only" implementation silently drops Ignition's Omron FINS driver, whose default Boolean-write behavior is bit-mode Memory Area Write, not a word-mode write with a manually-set bit.** The gap was diagnosed 2026-07-21 from an in-app log showing every write from that driver rejected as an unserved command - a word-mode-only build looks correct in every word-mode test and only fails against this specific driver's write path.
- **Bit reads/writes and word reads/writes must be served off the exact same underlying image**, or the two addressing modes silently disagree about the same memory location.

```
Wrong: prove a 32-bit word order correct via encode(value) -> wire bytes ->
       decode(wire bytes) == value, using the SAME implementation's encoder
       and decoder on both sides.
Correct: seed a known multi-word value into the underlying store by a path
       INDEPENDENT of the client under test, then have the real third-party
       client decode it through its own separate implementation and assert
       the exact expected value AND the raw byte layout.
```

---

## What this means practically

### "My round-trip tests for a multi-word value all pass, so why did a real client read back garbage?"
Because a round trip through one implementation's own encode and decode functions is symmetric by construction and cannot expose a word-order (or byte-order) disagreement - it will pass even if both halves agree on something the wire format actually disagrees with. Only an externally-seeded value, decoded by an independently-implemented client, tests the actual convention.

### "A client's polling stopped working the moment it started writing Booleans - what changed?"
Check whether the client's Boolean-write path uses a bit-area command rather than a word-area write with a bit set - a datagram/memory-area protocol commonly supports both addressing granularities, and an implementation that only serves one silently drops every request using the other with no obvious symptom besides "writes from this driver specifically don't work."

---

**Docker client gotcha (TL-1, tentative):** an Ignition FINS driver running in Docker must set
its Bind Address to `0.0.0.0`, not `localhost` - a loopback-bound UDP socket cannot reach
`host.docker.internal`, and the device sits at "BOUND" with zero datagrams arriving.

## Related

- [s7comm.md](./s7comm.md) - the other big-endian, memory-area-addressed protocol, but byte- rather than word-addressed.
- [slmp.md](./slmp.md) - the exact inverse convention (little-endian body) sitting right next to FINS in this suite; also settles a low-word-first 32-bit order, but from the opposite byte-order baseline.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
