---
id: knowledge:industry/protocols/modbus
title: Modbus
domain: industry/protocols
version: "2026-08"
topics: [modbus, modbus-tcp, modbus-rtu, mbap, crc16, big-endian, fieldbus]
summary: Modbus TCP and RTU-over-TCP wire format, function codes, big-endian register packing, and how an in-app pure-Dart server implements and E2E-proves both framings against a real tokio-modbus client.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/ethernet-ip-cip
learnings: [CL-6, CL-14]
---

# Modbus

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/modbus/modbus_pdu.dart`,
> `modbus_rtu.dart`, `mobile/lib/services/modbus_host.dart`, and the real-client
> E2E scripts `tool/modbus_e2e.sh` / `tool/modbus_rtu_e2e.sh`.
> **Read this before:** implementing or debugging a Modbus TCP/RTU master or
> slave, diagnosing a register-order or CRC mismatch, or comparing Modbus's
> wire model against another byte-oriented fieldbus (S7comm, FINS, SLMP).

---

## 1. The headline rule

**Modbus TCP is big-endian, framed by an explicit length field (MBAP); Modbus RTU has no header at all and derives frame length purely from the function code, with its CRC-16 stored little-endian.**

These are two different framings of the *same* PDU (protocol data unit) and function-code set. Getting the two mixed up (assuming RTU has a length field, or assuming the RTU CRC is big-endian because "everything else here is") is the single most common Modbus interop bug.

---

## 2. Wire format

### 2.1 MBAP framing (Modbus TCP)

A 7-byte header precedes every PDU:

| Field | Size | Notes |
|---|---|---|
| Transaction ID | u16 BE | echoed back, correlates request/response |
| Protocol ID | u16 BE | always `0` |
| Length | u16 BE | counts `unitId + PDU` bytes that follow |
| Unit ID | u8 | the addressed slave/unit |

The `Length` field is what makes MBAP framing self-describing over a TCP stream - a reassembler always knows exactly how many more bytes to buffer.

### 2.2 RTU framing (no header)

A frame is simply `unitId + PDU + CRC-16`, with the two CRC bytes stored **little-endian (low byte first)** on the wire. There is no length field anywhere. A stream transport carrying RTU framing (including "RTU over TCP", where RTU framing rides a TCP byte stream instead of a serial line) must derive the expected request length itself from the function code alone: the 8 classic function codes are either fixed at 8 total bytes, or (for the two write-multiple codes) `9 + byteCount`, where `byteCount` sits at a fixed offset. A function code outside those buckets cannot have its length derived and forces a resync.

CRC-16/MODBUS is the reflected variant: polynomial `0xA001`, initial value `0xFFFF`. The standard check value for `"123456789"` is `0x4B37`.

**Broadcast (unit id `0`)** addresses every outstation on the link at once in RTU: the request still executes, but no outstation replies (there is no single addressee for a multi-drop reply to go to). TCP has no such constraint (transaction id already disambiguates replies), so a TCP master using unit id `0` still gets a normal reply.

### 2.3 Function codes and the four data tables

| FC | Name | Table |
|---|---|---|
| `01` | Read Coils | Coils |
| `02` | Read Discrete Inputs | Discrete Inputs |
| `03` | Read Holding Registers | Holding Registers |
| `04` | Read Input Registers | Input Registers |
| `05` | Write Single Coil | Coils |
| `06` | Write Single Register | Holding Registers |
| `0F` | Write Multiple Coils | Coils |
| `10` | Write Multiple Registers | Holding Registers |

Modbus has **four independently-numbered data tables** (Coils, Discrete Inputs, Holding Registers, Input Registers), each its own 0-based 16-bit address space. Coils/Discrete Inputs are single bits; Holding/Input Registers are 16-bit words. An unimplemented function code answers exception `01` (Illegal Function); an out-of-range quantity or address answers exception `03` (Illegal Data Value).

### 2.4 Byte order and register packing

Every multi-byte value is **big-endian**:

- Each 16-bit register is transmitted big-endian (high byte first).
- A 32-bit value spans 2 registers, **high word first** ("ABCD" order) by spec default - register 0 holds the high 16 bits, register 1 the low 16 bits.
- A 64-bit float spans 4 registers, IEEE-754 double bytes in big-endian order, 2 bytes per register.
- Coil/discrete-input bit packing within a response byte is **LSB-first** (bit 0 of the first byte is the first requested coil).

The 32-bit word order ("ABCD" vs "CDAB" word-swapped, and independently "BADC"/"DCBA" byte-swapped within a register) is the classic Modbus interop mismatch - some third-party devices default to a word-swapped 32-bit layout. A production driver commonly exposes a "word swap" / "byte swap" toggle for exactly this reason.

---

## 3. Transport and port

Modbus TCP: TCP, IANA-registered port **502** (a privileged port on Linux/macOS - binding it requires elevated capability; unprivileged on Windows unless another process already owns it). RTU-over-TCP rides the same TCP socket type, just with RTU frame shape instead of MBAP.

Classic serial Modbus RTU (RS-485/RS-232) is a different transport entirely - a UART, not a TCP socket - and is out of scope for any pure-language (no native serial FFI) implementation; RTU *framing* is a separate concern from RTU *transport* and one can be supported without the other.

---

## 4. Addressing / map model

A Modbus master issues optimized block reads by table + starting address + quantity, not one request per point - the natural fit is a driver that materializes a table's contents from a tag database and serves arbitrary slices of it.

A general binding model: each mapped point occupies exactly one table, at an address assigned either by hand or by an auto-generation pass (BOOL points to Coils/Discrete Inputs by read/write access, numeric points to Holding/Input Registers). Register width per numeric type follows directly from its byte size (16-bit = 1 register, 32-bit = 2 registers, 64-bit float = 4 registers). A multi-register value can only be written atomically - a single-register write function refusing any address whose value spans more than one register, and a multi-register write function requiring the full span of every touched value to lie inside the request, is the correctness property that prevents a partial/torn write of a wide value.

Reads over an unmapped address commonly return `0`/`false` rather than an error, which is what lets a master block-read a whole table region without every address being individually mapped - only a genuinely out-of-range request (beyond the wire limits, 2000 bits / 125 registers) is refused.

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the Modbus standard itself.)*

`mobile/lib/protocols/modbus/modbus_pdu.dart` implements all 8 classic function codes (`01`/`02`/`03`/`04`/`05`/`06`/`0F`/`10`) against the project's `ModbusMap` and live tag database - `mobile/lib/services/modbus_host.dart` is the `dart:io` socket host. `modbus_rtu.dart` adds the RTU frame codec (`buildRtu`/`parseRtu`) and length-derivation (`rtuRequestLength`), reusing the same PDU handler for both framings; `RTU over TCP` is a per-project **framing switch**, not a second server. Word order defaults to hi-word-first ("ABCD") but is configurable (`ModbusProtocolConfig.wordSwap`/`byteSwap`), covering all four common 32-bit orderings.

Composite (struct/array) tags are never mapped as a single unit - auto-generation expands a composite into one map entry per scalar leaf, addressed by a dotted resolver path (e.g. `Motor.Speed`), resolved through the same tag-resolver every other protocol adapter in this app shares. `TIMER`/`COUNTER`/`STRING` leaves are skipped - no wire representation is defined for them here.

## 6. Write-gate interaction

A write to a **forced** tag is refused with exception `02` (Illegal Data Address) - the same code an unmapped or read-only address gets, since classic Modbus has no dedicated "access denied" exception. This is a deliberate visible-refusal choice (CL-14: the write path has two distinct predicates - `defaultsExternallyWritable` governs what auto-generation exposes, `isExternallyWritable` is the hard per-write backstop every handler must also consult, and a reserved/System tag refuses writes even under a mutated map). Before this behavior was hardened, a forced write was silently discarded while the server still answered a normal success echo - a deceptive-success bug class; masters now get a genuine error PDU they can decode.

For the two multi-element write codes (`0F`/`10`), a forced or refused element anywhere in the batch refuses the **whole** request atomically - no partial write ever lands.

## 7. Real-client E2E proof

Proven against a genuine Rust **`tokio-modbus`** crate client (v0.17), run from `tool/modbus_e2e.sh` (TCP/MBAP) and `tool/modbus_rtu_e2e.sh` (RTU over TCP). The TCP leg polls a register the fixture mutates independently on its own timer (proof of a live, not frozen, read), writes and independently reads back a register and a coil, reads a pre-forced coil and asserts the forced value, then writes to that same forced coil and asserts the client decodes `ExceptionCode::IllegalDataAddress` - not a silent success. The RTU leg attaches `tokio_modbus::client::rtu::attach_slave` directly to a plain `TcpStream` (no MBAP anywhere in the client stack) and exercises the same read/write/read-back sequence framed as RTU.

## 8. Gotchas

- **CL-6: Modbus RTU CRC-16 is little-endian on the wire while Modbus TCP MBAP fields are big-endian; RTU has no MBAP header at all.** Do not assume RTU is "big-endian because TCP is" - the CRC bytes specifically are stored low-byte-first.
- **The 32-bit word-order default ("ABCD", hi-word-first) is not universal.** Some third-party masters default to word-swapped ("CDAB"); a driver without a word-swap toggle will silently disagree with such a master on every 32-bit read.
- **RTU framing has no length field.** A stream reassembler for RTU-over-a-byte-stream transport must derive frame length from the function code; treating an unrecognized function code as "wait for more bytes" rather than an immediate exception risks hanging on a code whose length genuinely cannot be derived.
- **CL-14: two write-gate predicates, not one.** An auto-generation default-writable rule and a write-time hard backstop are different checks; conflating them lets a mutated/hand-edited map accidentally expose a reserved or read-only point as writable.

```
Wrong: assume CRC-16 bytes on an RTU frame are big-endian because the rest
       of the stack (TCP framing, register data) is big-endian.
Correct: CRC-16/MODBUS is stored low-byte-first on the wire, independent of
       how register/header data elsewhere is ordered.
```

---

## What this means practically

### "Why does my 32-bit read come back byte-swapped against one master but not another?"
Because there is no single universal 32-bit register order in Modbus - "ABCD" (hi-word-first, the spec default) and "CDAB" (word-swapped) are both common in the field, and some devices additionally swap bytes within a register ("BADC"/"DCBA"). Check (or expose) a word-swap/byte-swap setting rather than assuming one convention.

### "My RTU-over-TCP master gets no response to a function code my server doesn't implement - is that a bug?"
Not necessarily. A function code with a *derivable* length (fixed-size, or the four fixed-4-byte codes with no body) gets a proper exception `01` reply. A function code whose length genuinely can't be derived forces a resync (silence, buffered bytes discarded) instead - this mirrors how a real RTU outstation stays silent on an undecodable request rather than tearing down the link, and RTU masters commonly retry on silence.

---

## Related

- [ethernet-ip-cip.md](./ethernet-ip-cip.md) - the other little-endian-vs-big-endian contrast point in this suite.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
