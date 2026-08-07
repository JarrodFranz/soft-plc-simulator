---
id: knowledge:industry/protocols/endianness-and-framing
title: Endianness and Framing Across Protocols
domain: industry/protocols
version: "2026-08"
topics: [endianness, byte-order, framing, comparison, cross-protocol, big-endian, little-endian]
summary: A single cross-protocol comparison table (byte order, framing/delimiting, transport+port, session model, E2E client) for all nine industrial protocols in this domain, anchored by the rule that byte-order handling must never be pattern-matched from one protocol codec onto another.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/modbus
  - knowledge:industry/protocols/opc-ua
  - knowledge:industry/protocols/ethernet-ip-cip
  - knowledge:industry/protocols/s7comm
  - knowledge:industry/protocols/fins
  - knowledge:industry/protocols/slmp
  - knowledge:industry/protocols/dnp3
  - knowledge:industry/protocols/bacnet-ip
  - knowledge:industry/protocols/mqtt-sparkplug
learnings: [CL-5, CL-6, CL-7]
---

# Endianness and Framing Across Protocols

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** cross-checked against every codec header cited in this
> domain's per-protocol files (`mobile/lib/protocols/*/`) and each protocol's
> real-client E2E script (`tool/*_e2e.sh`).
> **Read this before:** touching any protocol codec in this suite, adding a
> tenth protocol, or debugging a byte-order/framing symptom (a value that
> reads as a huge or nonsensical number, a byte-swapped word, a
> reassembler that hangs or truncates).

---

## 1. The headline rule

**Never pattern-match byte-order or framing handling from one protocol's codec onto another's, even neighbors that look structurally similar - this suite spans little-endian, big-endian, and two genuinely mixed-convention protocols, and every framing-length field uses one of two mutually exclusive conventions (counts-the-whole-packet vs. counts-only-what-follows-a-fixed-prefix) with no visual cue in the bytes themselves to tell you which.**

This is CL-7, generalized across the whole suite: "S7comm/TPKT/COTP and FINS are big-endian throughout; EtherNet/IP is little-endian - never copy byte-order handling between protocol codecs by pattern-matching." A build-parse round trip inside one implementation is structurally incapable of catching a byte-order or word-order bug on its own (see each protocol file's own gotchas section) - only a value seeded independently of the code under test, decoded by a genuinely separate implementation, proves the convention.

---

## 2. The comparison table

| Protocol | Byte order | Framing / delimiting | Transport + port | Session model | Real-client E2E proof |
|---|---|---|---|---|---|
| **Modbus TCP** | Big-endian (32-bit hi-word-first by default; word/byte swap configurable) | 7-byte MBAP header with an explicit length field (counts `unitId + PDU`, i.e. what follows the length field itself) | TCP, **502** | Stateless request/response; transaction-id correlated, no handshake | `tokio-modbus` (Rust) v0.17 |
| **Modbus RTU** (framing only, over TCP here) | Big-endian PDU; **CRC-16 stored little-endian** | No header at all; frame length **derived from the function code**, terminated by a 2-byte CRC | TCP-carried framing (real RS-485/RS-232 transport out of scope for a pure-language stack) | Stateless, no session or handshake | `tokio-modbus` RTU client, attached directly to a `TcpStream` |
| **OPC UA** | **Little-endian** throughout | ASCII Hello/Acknowledge handshake, then chunked messages with an 8-byte chunk header (message type + chunk indicator + explicit u32 size) | TCP, **4840** | Two-layer: SecureChannel (`OpenSecureChannel`) wraps a Session (`CreateSession`/`ActivateSession`) | `opcua` (Rust) crate v0.12.0 |
| **EtherNet/IP + CIP** | **Little-endian** throughout | 24-byte encapsulation header with an explicit length field (counts bytes **after** the header - excludes it) | TCP, **44818** | `RegisterSession` (session handle) + either `Forward Open` (connected, stateful connection ids) or UCMM (unconnected, stateless) | `pycomm3` (Python) v1.2.16 |
| **S7comm** | Big-endian throughout | TPKT 4-byte header with an explicit length field (counts the **whole packet including the header itself**) + COTP | TCP, **102** (privileged on Linux/macOS) | COTP connection + `Setup Communication` (negotiates max PDU length) | `python-snap7` (pure-Python at 3.x) v3.1.0 |
| **FINS** | Big-endian within a word; **32-bit+ values are low-word-first across words** | No length field at all; one UDP datagram is one complete frame | UDP, **9600** | Connectionless; correlated purely by source address/port + echoed `SID` | `fins` (pure-Python) v1.0.5 |
| **SLMP (MC protocol)** | **Little-endian body**, with the 2-byte subheader the **one documented big-endian exception** | 9-byte fixed prefix + an explicit length field that counts only what **follows** the prefix (excludes it) | TCP, no universal default port | Stateless per-frame, no session or handshake | `pymcprotocol` (pure-Python) v0.3.0 |
| **DNP3** | **Little-endian** throughout (link-layer CRC included) | `0x0564` sync + a 10-byte header block carrying a 1-byte LENGTH (max 255) + 16-byte user-data blocks, **each individually CRC-guarded** | TCP, **20000** (conventional, not IANA-reserved) | TCP connection, per-link-address; SELECT/OPERATE carries a bounded (~5s) matching-state window | `dnp3` (Rust, Step Function I/O) crate v1.6 |
| **BACnet/IP** | Big-endian throughout | BVLL 4-byte header with an explicit length field (counts the **whole datagram including the header**); one UDP datagram is one complete frame | UDP, **47808** | Connectionless, no session | `bacpypes3` (Python, asyncio-native) v0.0.106 |
| **MQTT + Sparkplug B** | Big-endian for MQTT's own u16 fields (keep-alive, packet id); Sparkplug payload is protobuf (its own wire rules, not a fixed-width integer endianness question) | Variable-length "Remaining Length": a 1-4 byte varint, 7 data bits per byte, high bit = more-follows | TCP, **1883** (plain) / **8883** (TLS) | CONNECT/CONNACK session + keep-alive `PINGREQ`; the app is the **client**, dialing **out** - the one adapter in this suite that doesn't accept inbound connections | `rumqttd` (embedded broker) v0.20 + `rumqttc` (Rust subscriber) v0.25 |

---

## 3. Reading the table: three groupings that matter

### 3.1 The little-endian club vs. the big-endian club

**Little-endian throughout:** OPC UA, EtherNet/IP + CIP, DNP3, and SLMP's *body*.
**Big-endian throughout:** Modbus TCP (MBAP + registers), S7comm/TPKT/COTP, FINS, BACnet/IP, and MQTT's own u16 fields.

These two lists sit right next to each other in a shared codebase's directory listing (`protocols/opcua/` next to `protocols/enip/` next to `protocols/s7/` next to `protocols/fins/`...), which is exactly the condition under which a byte-order bug gets introduced - copying a neighboring file's `Endian.big`/`Endian.little` call by habit rather than by checking that specific protocol's own spec.

### 3.2 The two genuinely mixed-convention protocols

- **Modbus RTU**: PDU data big-endian, but the **CRC-16 trailer is little-endian** (CL-6). This is easy to miss because the CRC sits at the very end of the frame, after every other field has already established a big-endian expectation.
- **SLMP 3E binary**: body little-endian, but the **2-byte subheader is big-endian** (CL-5) - the inverse asymmetry from Modbus RTU (header/prefix diverges from body, rather than trailer diverging from body). Confirmed against a real client library's own wire behavior, not treated as a bug to "fix" by making the subheader consistent with the rest.

### 3.3 The 32-bit-plus word-order axis (separate from byte order)

Byte order (within a 16-bit word) and **word order** (which word of a multi-word value is "first") are two independent questions, and a protocol can get one right while getting the other wrong without either mistake being visible in a same-implementation round trip:

- **FINS**: big-endian within each word, but 32-bit+ values are **low-word-first** across words.
- **SLMP**: little-endian within each word, but 32-bit+ values are **also low-word-first** across words.
- **Modbus**: big-endian within each register, and 32-bit values are **high-word-first** by spec default (though real-world masters commonly expect a configurable word-swap toggle for exactly this reason).

Both FINS's and SLMP's word-order conventions were settled by seeding a known multi-word value **independently of the client under test** and having a genuinely separate third-party implementation decode it - a write-then-read-back through one implementation's own symmetric encode/decode logic is structurally incapable of exposing a word-order disagreement, no matter how many times it's repeated (see each protocol's own gotchas section for the exact mechanism).

### 3.4 Two mutually exclusive length-field conventions

Every length-prefixed framing in this table (Modbus TCP's MBAP, S7comm's TPKT, SLMP's 9-byte prefix, EtherNet/IP's encapsulation header, BACnet/IP's BVLL, DNP3's link-layer LENGTH byte) picks one of exactly two conventions, and nothing in the bytes themselves signals which:

| Convention | Protocols |
|---|---|
| Length counts the **whole frame, including its own header** | TPKT (S7comm), BVLL (BACnet/IP) |
| Length counts only what **follows** a fixed prefix (excludes the length field's own preceding bytes) | Modbus MBAP, EtherNet/IP encapsulation, SLMP's 9-byte prefix, DNP3's link-layer LENGTH (counts CONTROL + addresses + user data, i.e. what follows LENGTH itself) |

Porting a reassembler's length-derivation logic from one protocol to another without re-checking which convention that *specific* protocol uses either under-counts (truncating every frame by the header size) or over-counts (buffering forever, waiting for bytes that will never arrive) by exactly the size of the header/prefix.

---

## 4. What this means practically

### "I'm adding a tenth protocol to this suite - what should I assume by default?"
Nothing. Read that protocol's own specification (or, in this codebase, its codec file's header comment) for both byte order *and* word order (they're independent questions) *and* which length-field convention it uses, even if - especially if - it looks structurally similar to a protocol already in the table. The two protocols in this table that sit at opposite ends of the alphabet from their nearest neighbor in a directory listing (S7comm/big-endian next to EtherNet-IP/little-endian; FINS/big-endian next to SLMP/little-endian-with-a-big-endian-subheader) are exactly the pairs where a copy-paste byte-order bug is most likely, because proximity in the codebase has zero correlation with agreement in the wire format.

### "My unit tests all pass and a real client still gets garbage - what's the fastest thing to check?"
Whether the test that "proved" the byte order or word order was a round trip through your own implementation's own encode and decode functions. If so, it proves nothing about the actual convention - it is symmetric by construction and will pass even when fully inverted from the real spec. Only a value seeded independently of the code under test (by a fixture, or hand-computed) and decoded by a genuinely separate third-party implementation can settle it.

### "A reassembler either hangs waiting for more bytes or truncates a valid frame - which length convention am I dealing with?"
Check whether the length field's documented value, for a frame you can compute by hand, matches `payload-only` or `whole-packet`. If your reassembler's target byte count comes out `header-size` bytes too high, you've applied the whole-packet convention to a payload-only protocol (under-buffering: you'll wait forever for bytes that were never coming); if it comes out `header-size` bytes too low, you've applied the payload-only convention to a whole-packet protocol (you'll truncate every frame).

---

## Related

- [modbus.md](./modbus.md), [opc-ua.md](./opc-ua.md), [ethernet-ip-cip.md](./ethernet-ip-cip.md), [s7comm.md](./s7comm.md), [fins.md](./fins.md), [slmp.md](./slmp.md), [dnp3.md](./dnp3.md), [bacnet-ip.md](./bacnet-ip.md), [mqtt-sparkplug.md](./mqtt-sparkplug.md) - each protocol's own wire-format detail, write-gate model, and E2E proof.
- [index.md](./index.md) - domain hub.
