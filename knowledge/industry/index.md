---
id: knowledge:industry/index
title: Industry
domain: industry
version: "2026-08"
topics: [industry, protocols, plc-formats, iec61131, portable-knowledge, index]
summary: Domain hub for portable industrial-automation knowledge - protocol wire formats, vendor PLC project/exchange file formats, and IEC 61131-3 language semantics - true independent of this app's implementation.
related:
  - knowledge:index
  - knowledge:industry/protocols/index
  - knowledge:industry/plc-formats/index
  - knowledge:industry/iec61131/index
---

# Industry

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** a navigation hub over the three sub-domains authored under `industry/` -
> protocols, plc-formats, and iec61131 - each distilled from its own codec/parser/executor
> source and, where applicable, a real third-party client's end-to-end proof.
> **Read this before:** any question about an industrial protocol's wire format, a vendor PLC
> project-exchange file format, or IEC 61131-3 language semantics - anything that would still be
> true if this app were deleted and rewritten from scratch.

---

## What "industry" knowledge means here

`industry/` holds knowledge that is portable beyond this codebase. A fact belongs here, not in
[../app/index.md](../app/index.md), if it would still hold for a different implementation of the
same standard or protocol: Modbus's function codes and MBAP framing, OPC UA's secure-channel
handshake, L5X's document structure, or Structured Text's expression grammar are all true of the
standard or vendor format itself, independent of how this app happens to implement them. Contrast
this with [../app/index.md](../app/index.md), which documents this app's own engine mechanics
(scan order, the tag resolver, in-process protocol hosting) - those facts would not transfer to a
different soft-PLC implementation.

Every file in this domain still states its evidence in terms of *this* codebase (a codec source
file, an executor, a real-client E2E probe) because that is how the fact was verified here - but
the claim itself is about the external standard or protocol, not about an app-specific mechanism.

---

## The three sub-domains

| Sub-domain | Index | Covers |
|---|---|---|
| Protocols | [protocols/index.md](./protocols/index.md) | Nine industrial/SCADA protocols (Modbus, OPC UA, EtherNet/IP+CIP, S7comm, FINS, SLMP, DNP3, BACnet/IP, MQTT+Sparkplug B): wire format, framing, byte order, addressing model, and each one's real-client E2E proof |
| PLC project file formats | [plc-formats/index.md](./plc-formats/index.md) | Vendor PLC project-exchange XML dialects this app imports: PLCopen TC6 XML (multi-vendor standard) and Rockwell L5X (Studio 5000 native export) |
| IEC 61131-3 languages | [iec61131/index.md](./iec61131/index.md) | The four standard PLC programming languages (ST, LD, FBD, SFC) plus task scheduling and custom function blocks |

**Where to look first:** a wire-format or byte-order question starts at
[protocols/index.md](./protocols/index.md); a question about whether an imported project file
translates faithfully starts at [plc-formats/index.md](./plc-formats/index.md); a question about
what a program actually does when it runs starts at [iec61131/index.md](./iec61131/index.md).
The three sub-domains compose end to end: a vendor project file
([plc-formats/](./plc-formats/index.md)) imports its logic bodies into the native language
executors ([iec61131/](./iec61131/index.md)), whose tags then get exposed externally through a
hosted protocol ([protocols/](./protocols/index.md)).

---

## What this means practically

### "Is this fact app-specific or portable?"
Ask whether it would still be true of a different soft-PLC implementation of the same standard.
If yes, it belongs under `industry/`; if the fact is about how *this app's* scan loop, tag
resolver, or protocol host lifecycle works, it belongs under [../app/index.md](../app/index.md)
instead. See [../governance.md](../governance.md) section 1 (placement table) for the full rule.

### "Where do I look first for a protocol, format, or language question?"
Use the sub-domain table above, then that sub-domain's own lookup table for the specific file.

---

## Related

- [../index.md](../index.md) - top-level knowledge base index.
- [protocols/index.md](./protocols/index.md) - industrial protocol wire formats.
- [plc-formats/index.md](./plc-formats/index.md) - vendor PLC project file formats.
- [iec61131/index.md](./iec61131/index.md) - IEC 61131-3 language semantics.
- [../governance.md](../governance.md) - the placement table this domain boundary follows.
