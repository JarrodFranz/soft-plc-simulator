---
id: knowledge:industry/plc-formats/index
title: PLC Project File Formats
domain: industry/plc-formats
version: "2026-08"
topics: [plc-formats, plcopen, tc6, xml, rockwell, l5x, project-exchange, import]
summary: Domain hub for vendor PLC project-exchange file formats this app imports - PLCopen TC6 XML and Rockwell L5X - each documented as a portable schema plus this app's exact import support matrix.
related:
  - knowledge:index
  - knowledge:industry/iec61131/index
  - knowledge:industry/protocols/index
learnings: [CL-17]
---

# PLC Project File Formats

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** the PLCopen TC6 and Rockwell L5X project-exchange schemas, cross-checked against
> this app's parsers, translators, and mapper under `mobile/lib/import/`.
> **Read this before:** importing a vendor PLC project export, extending a graphical translator,
> or answering "does this app support importing X" for either dialect.

---

## What this domain covers

Two vendor-neutral-ish project-exchange XML dialects this app imports as a brand-new project:
**PLCopen TC6 XML** (a multi-vendor standard exchange format used by CODESYS, Beckhoff, Schneider,
and others) and **Rockwell L5X** (Studio 5000 / RSLogix 5000's native export format, single-vendor).
Both files document the source schema's real structure first, then this app's exact support matrix
- what imports faithfully, what stubs with a named reason, and what's captured but genuinely not
translated yet - verified directly against the parser/translator source, not the shipped feature
docs alone (which have gone stale on at least one point, corrected in
[plcopen-tc6-xml.md](./plcopen-tc6-xml.md) §7).

**Where to look first:** if you need to know whether a specific language body (`LD`/`FBD`/`SFC`/`ST`,
or Rockwell `RLL`) actually executes after import, or only gets captured as a stub, go straight to
that dialect's support-matrix table (§6 in the PLCopen file, §5 in the L5X file).

**Both dialects import into the exact same native execution model** - see
[../iec61131/index.md](../iec61131/index.md) for what a translated program or function block
actually runs as once it lands.

---

## Topics

| Topic | Canonical file | What it covers |
|---|---|---|
| PLCopen TC6 XML | [plcopen-tc6-xml.md](./plcopen-tc6-xml.md) | TC6 document structure, descendant-based dialect-tolerant parsing, DUT/type-normalization tables, and the corrected finding that FBD/SFC bodies translate for real today (not an empty stub, contra the shipped feature doc) |
| Rockwell L5X | [rockwell-l5x.md](./rockwell-l5x.md) | L5X document structure, the RLL compile instruction set, real shipped AOI/RLL-Logic-AOI per-instance execution, and the confirmed still-fully-unshipped state of L5X FBD and SFC routine translation |

---

## Confirmed learnings

| CL | Rule |
|---|---|
| CL-17 | Dialect detection routes off the document root (`<project>` + a `plcopen`/`tc6` marker vs `<RSLogix5000Content>`), never off the filename. See both files' §2. |

---

## Related

- [../iec61131/index.md](../iec61131/index.md) - the native language executors these formats translate into.
- [../protocols/index.md](../protocols/index.md) - how imported tags get exposed externally once a project lands.
