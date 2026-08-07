---
id: knowledge:industry/protocols/index
title: Industrial Protocols
domain: industry/protocols
version: "2026-08"
topics: [protocols, index, modbus, opc-ua, ethernet-ip, s7comm, fins, slmp, dnp3, bacnet, mqtt, sparkplug]
summary: Domain hub for the nine industrial protocols covered in this knowledge base, each documented from its wire format through its real-client E2E proof, plus the cross-protocol endianness/framing comparison.
related:
  - knowledge:industry/index
  - knowledge:industry/protocols/endianness-and-framing
learnings: [CL-5, CL-6, CL-7, CL-14, CL-15]
---

# Industrial Protocols

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from each protocol's codec/host source files and its
> real-client end-to-end proof script; see each topic file's own provenance
> line for the exact files.
> **Read this before:** implementing, extending, or debugging any protocol
> client or server in this family; comparing two protocols' wire formats;
> or deciding whether a new protocol belongs in this suite.

---

## What this domain covers

Nine industrial/SCADA protocols, each documented to the same depth: wire-format
essentials (framing, byte order, key PDUs/services), transport and default
port, the addressing/tag-binding model, write-gate (force-aware refusal)
behavior, and the real third-party client library that machine-proves the
implementation end-to-end - not just a self-consistent unit-test round trip.

**Look here first** if you need to know a protocol's byte order, framing
shape, or default port; **look at
[endianness-and-framing.md](./endianness-and-framing.md) first** if you're
comparing two or more protocols, adding a new one to a codebase that already
hosts several, or debugging a symptom that smells like a byte-order/framing
mismatch (a huge or nonsensical decoded value, a byte-swapped word, a
reassembler that hangs or truncates).

Every empirical claim in this domain states how it was verified: a codec
source-file citation, a real-client E2E script, or both. A "this doesn't
work" claim carries the same bar - the exact tested shape, not a general
impression.

---

## Lookup table

| Topic | File | One-line scope |
|---|---|---|
| Cross-protocol comparison | [endianness-and-framing.md](./endianness-and-framing.md) | Byte order, framing/delimiting, transport+port, session model, and E2E client for all nine protocols in one table, plus the never-pattern-match rule |
| Modbus | [modbus.md](./modbus.md) | TCP (MBAP) + RTU framing, 8 function codes, 4 data tables, big-endian register packing |
| OPC UA | [opc-ua.md](./opc-ua.md) | Binary transport, SecureChannel/Session handshake, Basic256Sha256 security, name-addressed Browse/Read/Write/Subscribe |
| EtherNet/IP + CIP | [ethernet-ip-cip.md](./ethernet-ip-cip.md) | Encapsulation + CIP explicit messaging, symbolic EPATH addressing, Forward Open connection-id allocation |
| S7comm | [s7comm.md](./s7comm.md) | TPKT/COTP + S7 PDU, memory-area + byte-offset addressing, PDU-size negotiation |
| Omron FINS | [fins.md](./fins.md) | UDP datagram framing, memory-area + word-offset addressing, low-word-first 32-bit order |
| SLMP (MC protocol) | [slmp.md](./slmp.md) | 3E binary frame, mixed-endian (little body / big subheader), device + device-number addressing |
| DNP3 | [dnp3.md](./dnp3.md) | Link/transport/application layers, Class 0/1/2/3 polling, SELECT/OPERATE control, unsolicited reporting |
| BACnet/IP | [bacnet-ip.md](./bacnet-ip.md) | BVLL/NPDU/APDU, Device/AV/BV object model, ReadPropertyMultiple per-property errors |
| MQTT + Sparkplug B | [mqtt-sparkplug.md](./mqtt-sparkplug.md) | MQTT 3.1.1 control-packet codec, Sparkplug B protobuf payload, bdSeq birth/death pairing |

## What all nine share

Every protocol in this suite exposes points through the same shape of binding
model: a composite (struct/array) value is never addressed as one wire unit -
it is expanded into one entry per scalar leaf, keyed by a dotted or indexed
resolver path (`Motor.Speed`, `Recipe_Steps[0]`), through a single shared
tag-resolution mechanism rather than a parallel one per protocol. Every write
path is gated the same way in spirit, even though each protocol expresses the
refusal in its own status-code vocabulary: a write to a point that is
currently **forced** is refused (or, for a protocol with no response channel,
silently dropped) rather than silently discarded while reporting success -
forcing is authoritative and always wins over an external write, and the
force check always resolves the point's **root**, so a member path can never
bypass a force on its parent (see each protocol's own "Write-gate
interaction" section for the exact status code and any caveats).

## Confirmed learnings

| CL | Rule |
|---|---|
| CL-5 | SLMP 3E binary is little-endian EXCEPT the 2-byte subheader (big-endian) - a documented mixed convention, confirmed against a real client. |
| CL-6 | Modbus RTU CRC-16 is little-endian on the wire while Modbus TCP MBAP fields are big-endian; RTU has no MBAP header. |
| CL-7 | S7comm/TPKT/COTP and FINS are big-endian throughout; EtherNet/IP is little-endian - never copy byte-order handling between protocol codecs by pattern-matching. |
| CL-14 | The write path has two distinct predicates: a default-writable rule governs what map auto-generation exposes; a hard per-write backstop is the one every protocol write handler must additionally consult, so a mutated map can never make a reserved/read-only point writable. |
| CL-15 | An OPC UA certificate thumbprint is SHA-1 over the DER certificate; Basic256Sha256 OPN padding/sign-then-encrypt ordering must be byte-exact, validated against a strict client. |

---

## Related

- [endianness-and-framing.md](./endianness-and-framing.md) - the crown comparison piece; read this alongside any two protocol files.
- [../index.md](../index.md) - the industry-knowledge domain hub (protocols, plc-formats, iec61131).
