---
id: knowledge:app/index
title: App
domain: app
version: "2026-08"
topics: [scan-engine, tag-model, simulation, protocol-hosting, ui-performance, default-projects, architecture]
summary: Domain hub for this app's own architecture and engine semantics - scan tick ordering, the tag/write-gate model, the deterministic simulation engine, in-process protocol hosting, the decoupled UI repaint strategy, and the default-project catalog.
related:
  - knowledge:index
  - knowledge:industry/iec61131/index
  - knowledge:practices/index
---

# App

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/screens/scan_tick.dart`, `mobile/lib/models/`
> (`tag_resolver.dart`, `tag_write_gate.dart`, `system_tags.dart`, `sim_engine.dart`,
> `noise_model.dart`, `valve_curve.dart`, `signal_engine.dart`, `task_scheduler.dart`),
> `mobile/lib/services/` (the nine `*_host.dart` protocol hosts, `drop_log_gate.dart`,
> `app_logger.dart`, `notify_throttle.dart`, `tag_historian.dart`), `mobile/lib/widgets/live_tick.dart`,
> `mobile/lib/data/default_projects/`, `DECISIONS.md`, and the guard tests under
> `mobile/test/defaults/`.
> **Read this before:** debugging scan-order or timing-dependent behavior, working on the tag
> resolver or a protocol write path, adding or editing a `SimRule`/`SignalGen`, adding a new
> protocol host, touching any live-value widget, or editing the default-project catalog.

---

## What this domain covers

This app is a single-process, pure-Dart soft PLC simulator: one scan engine interprets four
IEC 61131-3 languages against one tag database, a deterministic simulation layer drives
simulated I/O, nine industrial protocol servers host that same tag database out to real
SCADA/OPC clients, and a Flutter canvas UI displays it all without letting per-scan repaint
cost dominate. This domain documents the mechanisms specific to *this* implementation -
not IEC 61131-3 itself (see [industry/iec61131/index.md](../industry/iec61131/index.md)) and
not a protocol's wire format (see [industry/protocols/index.md](../industry/protocols/index.md)).

## Where to look first

- Debugging why a value changed on the "wrong" scan, or why FBD/LD/SFC state survived (or
  didn't) across scans? [scan-engine.md](./scan-engine.md).
- Writing a tag path, adding a protocol write handler, or asking "why did this write get
  refused"? [tag-model.md](./tag-model.md) - the CL-14 write-gate section specifically.
- A `SimRule` or `SignalGen` producing an unexpected or non-reproducible value?
  [simulation.md](./simulation.md) - the CL-8 determinism section.
- Adding a protocol host, or debugging why a host "isn't running"?
  [protocol-hosting.md](./protocol-hosting.md).
- A live-value widget not updating, or updating too often? [ui-performance.md](./ui-performance.md).
- Editing `mobile/lib/data/default_projects/`, or asking why a shipped default didn't reach an
  existing install? [default-projects.md](./default-projects.md) - the CL-12 section.

## Lookup table

| Topic | File | What it covers |
|---|---|---|
| Scan tick order, executor state keying, edge memory, resets | [scan-engine.md](./scan-engine.md) | `runScanTick`, task-scheduler priority/dedup, per-language runtime state maps, project-switch reset scope |
| Tag paths, write gates, System tags | [tag-model.md](./tag-model.md) | `readPath`/`writePath` grammar, struct/array/FB-instance resolution, forcing, `defaultsExternallyWritable` vs `isExternallyWritable` (CL-14), `HmiComponent` layout (CL-13) |
| Simulation engine determinism | [simulation.md](./simulation.md) | All 8 `SimRule` behaviors, `RuleRuntime`, PRNG-seeded-from-id determinism (CL-8), valve curves, signal generators |
| In-process protocol hosting | [protocol-hosting.md](./protocol-hosting.md) | ADR-010, the 9 hosted protocols, no-autostart guarantee, hardening (fragment bounds/fail-loud/budgets), logging rule, `DropLogGate` |
| UI repaint architecture | [ui-performance.md](./ui-performance.md) | `LiveTick`/`NotifyThrottle`, why the scan loop does not `setState` the shell, `TagHistorian` ring buffer, `TrendChartDisplay` |
| Default-project catalog | [default-projects.md](./default-projects.md) | The 7-project catalog, seeding/backfill ledger, retired-id rule (CL-12), coverage/integrity/no-autostart guard tests |

## How the pieces fit together

One scan tick (`runScanTick`, `mobile/lib/screens/scan_tick.dart`) runs simulation rules and
signal generators, then the due tasks' programs, in that order, every tick - see
[scan-engine.md](./scan-engine.md) §1. All of it reads and writes through one resolver
(`readPath`/`writePath`, [tag-model.md](./tag-model.md) §2). Protocol hosts are **not** part of
that tick: they are independent `dart:io` socket servers, started only by an explicit UI
action, that call into the same resolver asynchronously per request - see
[protocol-hosting.md](./protocol-hosting.md) §1 and §2. The UI never rides the scan tick
directly either; a throttled pulse (`LiveTick`) decouples repaint from scan cadence - see
[ui-performance.md](./ui-performance.md) §1. All of this ships pre-populated: seven default
projects exercise the whole stack end to end - see [default-projects.md](./default-projects.md).

## What this means practically

### "Why doesn't a protocol write show up until the next scan, or show up instantly?"
It shows up instantly in the tag database (the protocol handler calls `writePath` directly,
off the scan tick), and the *next* scan tick is the first one whose logic can react to it -
there is no synchronization step between an async protocol write and the scan loop reading
that value. See [scan-engine.md](./scan-engine.md) §1 and [protocol-hosting.md](./protocol-hosting.md) §1.

### "Why did my `SimRule` produce a different noise sequence after I renamed it?"
Renaming a rule's *display name* does nothing; changing its `id` reseeds its PRNG stream
(CL-8). See [simulation.md](./simulation.md) §3.

### "Why did a protocol handler refuse my write to a tag whose map entry says ReadWrite?"
The map entry alone is never authoritative - every write handler also consults
`isExternallyWritable`, a hard backstop that a mutated map cannot override for the reserved
`System` tag or a tag declared `access: ReadOnly` (CL-14). See [tag-model.md](./tag-model.md) §4.

---

## Related

- [scan-engine.md](./scan-engine.md) - scan tick order and executor state.
- [tag-model.md](./tag-model.md) - tag paths, values, and write gates.
- [simulation.md](./simulation.md) - the deterministic simulation engine.
- [protocol-hosting.md](./protocol-hosting.md) - in-process protocol servers.
- [ui-performance.md](./ui-performance.md) - decoupled UI repaint.
- [default-projects.md](./default-projects.md) - the default-project catalog.
- [../index.md](../index.md) - top-level knowledge base index.
