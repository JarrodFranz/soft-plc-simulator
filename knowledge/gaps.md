---
id: knowledge:gaps
title: Knowledge Gaps Register
domain: root
version: "2026-08"
topics: [gaps, open-questions, coverage, backlog]
summary: The open-question and known-missing-coverage register for knowledge/, listing what is not yet documented or not yet implemented and, for each, the concrete next step that would close it.
related:
  - knowledge:index
  - knowledge:governance
---

# Knowledge Gaps Register

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** seeded at knowledge-base foundation time from the known-incomplete areas
> surfaced while planning the `knowledge/` domain files; carried forward as an append-only
> register.
> **Read this before:** starting a spec or investigation that might duplicate a gap already
> known, or before closing a gap (update its entry, don't just delete it - see
> [governance.md](./governance.md#10-anti-fragmentation---dont-drift)).

---

## How to use this file

Each entry is either a **knowledge gap** (something true that isn't written down anywhere yet)
or an **implementation gap** (something not built yet, tracked in more detail in
`docs/DEFERRED.md`). Both kinds are registered here because both limit what the knowledge base
can currently say. When a gap closes, do not delete the row - move it to a "Closed" section at
the bottom with the closing CL-N or PR reference, so the history of what was once unknown stays
visible.

---

## Open gaps

| # | Gap | What would close it |
|---|---|---|
| G-1 | L5X import supports RLL (ladder) and ST routines; FBD routine import was designed (`docs/superpowers/specs/2026-08-04-l5x-fbd-import-design.md`) but not shipped | Implement the FBD L5X import path per that spec, then document actual (not designed) behavior in [industry/plc-formats/rockwell-l5x.md](industry/plc-formats/rockwell-l5x.md) |
| G-2 | L5X SFC routines are not covered by the importer at all (no design doc, no implementation) | Scope an SFC-routine L5X import design, then document the wire format's SFC representation in [industry/plc-formats/rockwell-l5x.md](industry/plc-formats/rockwell-l5x.md) |
| G-3 | The default-project integrity guard test (`mobile/test/defaults/default_projects_integrity_test.dart`) only validates root-level project structure, not nested/child structure below it | Extend the integrity guard to walk nested structure, then update [app/default-projects.md](app/default-projects.md) with the widened guarantee |
| G-4 | Several IEC 61131 building blocks exist in the LD engine but are not exercised by any default/showcase project: comparisons `GE`/`LE`/`NE`, math blocks `MUL`/`DIV`, timer `TP`, and counters `CTD`/`CTUD` | Add or extend a default project (likely the conveyor-line default) to exercise these blocks, then cite it as the worked example in [industry/iec61131/ladder-diagram.md](industry/iec61131/ladder-diagram.md) |
| G-5 | The `Event` task type exists in the task scheduler UI (`newTaskType == 'Event'` branch in `mobile/lib/screens/workspace_shell.dart`) but no default project uses one | Add an Event-task example to a default project, then document its trigger semantics in [industry/iec61131/task-scheduling.md](industry/iec61131/task-scheduling.md) with a worked citation |
| G-6 | The signal-generator engine (`mobile/lib/models/signal_gen.dart`, `signal_engine.dart`) that backs Simulated Test Tags is not used by any default/showcase project | Add a SignalGen-backed folder to a default project, then cite it from [app/simulation.md](app/simulation.md) |
| G-7 | Of the 9+ hosted protocols, only Modbus and OPC UA are pre-configured (host enabled, tags mapped) in any default project; EtherNet/IP, S7comm, FINS, SLMP, DNP3, BACnet/IP, and MQTT Sparkplug have no default-project example | Add at least one default project per remaining protocol (or one multi-protocol default), then cross-link it from [industry/protocols/index.md](industry/protocols/index.md) and [app/default-projects.md](app/default-projects.md) |
| G-8 | The privileged-port classification in the no-autostart gate is proven for POSIX `EACCES` (errno 13); the Windows `WSAEACCES` (10013) path is not confirmed to classify the same way (CL-11 records the risk, not a fix) | Run the port-probe test on a Windows CI/dev box binding a privileged port, confirm or fix the classification, then promote CL-11 from risk-note to a confirmed-behavior citation in [practices/verification.md](practices/verification.md) |
| G-9 | The default-project backfill ledger never overwrites an existing project id (CL-12), which means a *retired* default project's id can never be reused - but there is no mechanism that removes a retired default from an existing install's project list | Design and implement a retirement/cleanup step for the backfill ledger, then document the resulting lifecycle (seed -> retire -> cleanup) in [app/default-projects.md](app/default-projects.md) |

---

## Closed gaps

_None yet. When a gap above is closed, move its row here with the closing reference._

| # | Gap | Closed by |
|---|---|---|
| - | - | - |

---

## Related

- [index.md](./index.md) - domain navigation hub; each gap above links to the canonical file it
  would extend once closed.
- [governance.md](./governance.md) - section 10 explains why closed gaps are moved, not deleted.
- [../learning/registry.md](../learning/registry.md) - several gaps here trace back to CL-N
  entries (CL-11, CL-12) that recorded the underlying risk or rule.
- `docs/DEFERRED.md` - the canonical deferred-*implementation*-work list; several gaps above
  (G-1, G-2, G-9) have a matching implementation-side entry there.
