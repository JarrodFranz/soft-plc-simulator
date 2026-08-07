---
id: knowledge:index
title: Knowledge Base Index
domain: root
version: "2026-08"
topics: [navigation, index, knowledge-base, domains]
summary: Top-level navigation hub for knowledge/, linking every canonical file across the industry, app, and practices domains, and defining how knowledge/ relates to docs/, docs/superpowers/, learning/, and DECISIONS.md.
related:
  - knowledge:governance
  - knowledge:gaps
---

# Knowledge Base Index

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** authored as the foundation index for `knowledge/`, cross-referencing the domain
> files written by the protocols, PLC-formats/IEC 61131, app, and practices authors.
> **Read this before:** any task that needs canonical knowledge - protocol wire formats, IEC
> 61131 language semantics, PLC vendor exchange file formats, this app's engine architecture,
> or verification/process practices proven on this project.

---

## 1. What's in `knowledge/`

`knowledge/` holds durable, verified reference material, organized into three domains:

- **`industry/`** - portable industrial-automation knowledge. True regardless of this codebase:
  protocol wire formats, vendor PLC project/exchange file formats, and IEC 61131-3 language
  semantics. If you deleted this app and rewrote it from scratch, this domain would still hold.
- **`app/`** - this app's own architecture and engine semantics: scan ordering, the tag model,
  simulation, in-process protocol hosting, UI repaint strategy, and the default-project catalog.
- **`practices/`** - development and verification practices proven on this project: how to
  browser-verify a Flutter-web canvas app, and the spec-to-PR development process.

Each domain has its own `index.md` with a lookup table; this file is one level up, indexing
every canonical file in the knowledge base.

---

## 2. `industry/`

Domain hub: [industry/index.md](industry/index.md) - what "industry" knowledge means here
(portable beyond this app) and how the three sub-domains below compose end to end.

### 2.1 `industry/protocols/`

One file per hosted protocol plus a cross-cutting comparison file.

| File | Covers |
|---|---|
| [industry/protocols/index.md](industry/protocols/index.md) | Domain hub: which protocols are hosted, where to start |
| [industry/protocols/modbus.md](industry/protocols/modbus.md) | Modbus TCP + RTU framing, the 8 function codes, register/word order, map model |
| [industry/protocols/opc-ua.md](industry/protocols/opc-ua.md) | Binary transport, secure channel (None + Basic256Sha256), sessions, address space, subscriptions, certificates |
| [industry/protocols/ethernet-ip-cip.md](industry/protocols/ethernet-ip-cip.md) | Encapsulation, CIP objects, Forward Open/Close, tag services, symbol browse, EPATH |
| [industry/protocols/s7comm.md](industry/protocols/s7comm.md) | TPKT/COTP, S7 PDU, Setup Communication, area read/write |
| [industry/protocols/fins.md](industry/protocols/fins.md) | UDP frame, memory areas, command/response |
| [industry/protocols/slmp.md](industry/protocols/slmp.md) | 3E binary frame, device codes, batch read/write |
| [industry/protocols/dnp3.md](industry/protocols/dnp3.md) | Link/transport/application layers, outstation, events/unsolicited, fragment bounds |
| [industry/protocols/bacnet-ip.md](industry/protocols/bacnet-ip.md) | BVLL/NPDU/APDU, objects, RPM/WP, tag codec |
| [industry/protocols/mqtt-sparkplug.md](industry/protocols/mqtt-sparkplug.md) | MQTT codec, Sparkplug B protobuf, NDEATH, publisher lifecycle |
| [industry/protocols/endianness-and-framing.md](industry/protocols/endianness-and-framing.md) | Cross-protocol comparison: byte order, framing, transport, port, the "never pattern-match across protocols" rule (CL-7) |

### 2.2 `industry/plc-formats/`

Vendor PLC project/exchange file formats.

| File | Covers |
|---|---|
| [industry/plc-formats/index.md](industry/plc-formats/index.md) | Domain hub: which formats are supported for import, where to start |
| [industry/plc-formats/plcopen-tc6-xml.md](industry/plc-formats/plcopen-tc6-xml.md) | TC6 XML structure, POUs/DUTs/bodies, dialect variance, graphical-body segmentation |
| [industry/plc-formats/rockwell-l5x.md](industry/plc-formats/rockwell-l5x.md) | `RSLogix5000Content` structure, DataTypes/AOIs/tags/routines, RLL neutral text, ST routines, AB mnemonic/alias handling, what is and isn't importable |

### 2.3 `industry/iec61131/`

The four IEC 61131-3 languages plus tasks and custom function blocks.

| File | Covers |
|---|---|
| [industry/iec61131/index.md](industry/iec61131/index.md) | Domain hub: language coverage, where to start |
| [industry/iec61131/structured-text.md](industry/iec61131/structured-text.md) | ST semantics and the practically-relevant subset: statements, expressions, array/struct paths |
| [industry/iec61131/ladder-diagram.md](industry/iec61131/ladder-diagram.md) | Rung model, contacts/coils/edges, branch geometry, power-flow blocks (TON/TOF/TP/CTU/CTD/CTUD), compare/math data blocks, seal-in idiom, first-scan preload |
| [industry/iec61131/function-block-diagram.md](industry/iec61131/function-block-diagram.md) | Networks, dataflow evaluation, pin model, execution order, timer/counter/edge blocks, PID, SEL/LIMIT/Scale, custom-FB calls |
| [industry/iec61131/sequential-function-chart.md](industry/iec61131/sequential-function-chart.md) | Steps/transitions, STEP_T, alternative vs parallel divergence, fork/join token semantics, one-shot and initial steps |
| [industry/iec61131/task-scheduling.md](industry/iec61131/task-scheduling.md) | The 4 IEC task types, priority/dedup, watchdogs, free-run mode, System UDT, Continuous-starvation rule (CL-3) |
| [industry/iec61131/custom-function-blocks.md](industry/iec61131/custom-function-blocks.md) | FB definitions (ST-bodied and ladder-bodied), instance state, pin bindings, nesting guard, name validation |

## 3. `app/`

This app's engine architecture and runtime semantics.

| File | Covers |
|---|---|
| [app/index.md](app/index.md) | Domain hub: engine architecture overview, where to start |
| [app/scan-engine.md](app/scan-engine.md) | Scan tick order (sim -> tasks/programs -> protocols -> historian), executor state keying, edge memory, project-switch resets |
| [app/tag-model.md](app/tag-model.md) | Tag paths and resolver walking, structs/arrays/FB scopes, value model, defaults, write gates (`defaultsExternallyWritable` vs `isExternallyWritable`), System tags read-only |
| [app/simulation.md](app/simulation.md) | SimRule behaviors (integrate/firstOrderLag/deadTime/noise/setWhileCondition/delayedSet), RuleRuntime, determinism and PRNG-seeded-from-rule-id, valve curves, signal generators |
| [app/protocol-hosting.md](app/protocol-hosting.md) | ADR-010 in-process pure-Dart hosting, host lifecycle/no-autostart, port config, hardening program, logging rule, drop-log gate |
| [app/ui-performance.md](app/ui-performance.md) | LiveTick decoupled repaint, notify throttle, historian ring buffer, canvas rendering implications |
| [app/default-projects.md](app/default-projects.md) | The default-project catalog design, seeding/backfill ledger semantics, coverage/integrity/no-autostart guards, retired-id rule (CL-12) |

## 4. `practices/`

Development and verification practices proven on this project.

| File | Covers |
|---|---|
| [practices/index.md](practices/index.md) | Domain hub: which practices are documented, where to start |
| [practices/verification.md](practices/verification.md) | Headless Playwright against the Flutter-web canvas app (no DOM, coordinate clicks, screenshot+console+network method), desktop computer-use harness, E2E probe lanes per protocol, widget-test fake-async vs `dart:io`, privileged-port classification |
| [practices/development-process.md](practices/development-process.md) | Spec -> plan -> per-task implement/review -> whole-branch review -> fix wave -> browser verify -> PR; deferred registry convention; byte-identical snapshot technique |

---

## 5. Relationship to other folders

`knowledge/` and `learning/` are not the only places knowledge-shaped content lives in this
repo. This table draws the boundary.

| Folder | What it is | Relationship to `knowledge/` |
|---|---|---|
| `docs/` | Per-feature living docs (e.g. `docs/task-scheduling.md`, `docs/protocols/*.md`, `docs/iec61131/*.md`) | Primary **source material** for `knowledge/` files. `docs/` files are feature-scoped and can drift from the implementation; `knowledge/` files are distilled, verified, and cross-referenced. When they disagree, the code wins (see [governance.md](./governance.md#7-source-verification-rule)). |
| `docs/superpowers/specs/` and `docs/superpowers/plans/` | Process artifacts: the spec and plan written before a feature was implemented | Cited from `knowledge/` only as **design rationale** pointers ("why this shape was chosen"), never as behavioral authority. A spec describes intent at write time; the implementation is the ground truth. |
| `learning/` | Repo root, separate from `knowledge/`. Append-only session log: `registry.md` (CL-N/TL-N entries), `HOW-TO-USE.md`, `sessions/` | The **learning loop** that feeds `knowledge/`. A session's findings get logged as a CL/TL in `learning/registry.md` first; once confirmed, the finding is folded into the relevant canonical file under `knowledge/`, cited inline by its CL-N id. `knowledge/` files should never contain the phrase "in this session" - that belongs in `learning/`. |
| `DECISIONS.md` | Repo-root architecture decision records (ADRs), e.g. ADR-010 (in-process pure-Dart protocol hosting) | Named and cited from `knowledge/` (see [app/protocol-hosting.md](app/protocol-hosting.md)) as the authority for *why* an architectural choice was made; `knowledge/` explains the resulting mechanism and how to work with it day to day. |
| `docs/DEFERRED.md` | Canonical deferred-work list | Referenced from [knowledge/gaps.md](./gaps.md) and [practices/development-process.md](practices/development-process.md) where a knowledge gap traces back to intentionally deferred work; `knowledge/gaps.md` covers *missing knowledge coverage*, `docs/DEFERRED.md` covers *missing implementation work* - related but distinct registers. |
| Code comments | Inline implementation notes | The most granular and most perishable layer. `knowledge/` files cite specific code paths as evidence (backticked, not linked) but never duplicate large code comments verbatim. |

---

## What this means practically

### "Where do I look first for a protocol wire-format question?"
[industry/protocols/index.md](industry/protocols/index.md), then the specific protocol file.
For any byte-order assumption, check
[industry/protocols/endianness-and-framing.md](industry/protocols/endianness-and-framing.md)
first (CL-7: byte order is not consistent across protocols).

### "Where do I look first for an IEC 61131 language semantics question?"
[industry/iec61131/index.md](industry/iec61131/index.md), then the specific language file.
Task-scheduling questions have their own file even though tasks are cross-language.

### "Where do I look first for 'why does the app behave this way' questions?"
[app/index.md](app/index.md). If the question is about determinism or a scan-timing edge
case, start with [app/scan-engine.md](app/scan-engine.md) or
[app/simulation.md](app/simulation.md).

### "Where do I look first before writing a spec or plan?"
[knowledge/gaps.md](./gaps.md) - check whether the gap is already known before re-investigating
it, and [learning/registry.md](../learning/registry.md) - check whether a CL/TL already covers
the mechanism.

### "I found something true that isn't written down anywhere. What do I do?"
See [governance.md](./governance.md), section 6 (learning-loop integration), and
[learning/HOW-TO-USE.md](../learning/HOW-TO-USE.md).

---

## Related

- [governance.md](./governance.md) - the authority on how `knowledge/` evolves; read before
  adding or editing any canonical file.
- [gaps.md](./gaps.md) - open questions and known-missing coverage.
- [industry/index.md](industry/index.md) - the industry domain hub (protocols,
  plc-formats, iec61131).
- [../learning/registry.md](../learning/registry.md) - the append-only CL/TL log that feeds
  updates into the files indexed above.
- [../learning/HOW-TO-USE.md](../learning/HOW-TO-USE.md) - how to read and write the learning
  registry.
