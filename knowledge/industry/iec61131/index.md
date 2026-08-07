---
id: knowledge:industry/iec61131/index
title: IEC 61131-3 Languages
domain: industry/iec61131
version: "2026-08"
topics: [iec-61131-3, structured-text, ladder-diagram, function-block-diagram, sequential-function-chart, task-scheduling, function-blocks]
summary: Domain hub for IEC 61131-3's four programming languages, task scheduling, and custom function blocks, each documented as portable standard concepts plus this repo's engine-verified executable subset and gotchas.
related:
  - knowledge:index
  - knowledge:industry/plc-formats/index
  - knowledge:industry/protocols/index
learnings: [CL-1, CL-2, CL-3, CL-4, CL-18]
---

# IEC 61131-3 Languages

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** IEC 61131-3's language concepts, cross-checked against this repo's four executors
> (`mobile/lib/models/{ld,fbd,sfc,st}_exec.dart`), the shared expression engine
> (`st_expr.dart`), function-block execution (`fb_exec.dart`), and the task scheduler
> (`task_scheduler.dart`).
> **Read this before:** writing or reviewing PLC logic in any of the four languages, configuring
> tasks, authoring a custom function block, or reasoning about cross-language interop within one
> scan.

---

## What this domain covers

IEC 61131-3 defines the four standard PLC programming languages (Structured Text, Ladder Diagram,
Function Block Diagram, Sequential Function Chart) plus the task/resource execution model and
function-block reuse mechanism that ties them together. Every file here states the **standard's
general concept** first, then this app's **exact executable subset and behavioral gotchas**,
verified directly against the executor source, not inferred from the UI or the docs alone.

**Where to look first:** if you're debugging a specific behavioral surprise (a timer that starts
"already done," a task that never scans, a seal-in that drops a scan late), start with the
"What this means practically" section at the bottom of the relevant topic file - each one is
written as a direct answer to the symptom you'd actually search for.

**A cross-cutting fact worth knowing up front:** within one scan tick, the four engines always run
in the fixed order `LD -> FBD -> SFC -> ST`, regardless of program declaration order in the
project. This means an LD or FBD program's writes are visible to an ST program's reads in the
*same* scan, but an ST program's writes aren't visible to that task's other engines until the
*next* scan tick. See [structured-text.md](./structured-text.md) §7 for the full detail.

---

## Topics

| Topic | Canonical file | What it covers |
|---|---|---|
| Structured Text | [structured-text.md](./structured-text.md) | The two-statement-shape subset (assignment, `IF/ELSIF/ELSE`), the shared expression grammar, why FB-call syntax has no home in ST, silent-null error propagation |
| Ladder Diagram | [ladder-diagram.md](./ladder-diagram.md) | Node-and-wire rung model, contact/coil modifiers, power-flow vs data blocks, the seal-in ordering dependency, literal-only counter presets |
| Function Block Diagram | [function-block-diagram.md](./function-block-diagram.md) | Ascending-network same-scan chaining, per-block pin resolution, timer/counter preload gaps, the PID anti-windup algorithm, undocumented cycle handling |
| Sequential Function Chart | [sequential-function-chart.md](./sequential-function-chart.md) | Multi-token active-step-set model, list-order-as-priority divergence, true AND parallel fork/join, `STEP_T`'s scan-dtMs accumulation |
| Task Scheduling | [task-scheduling.md](./task-scheduling.md) | The four task types, the exact Continuous-starvation predicate, watchdog fault propagation, the reserved `System` UDT |
| Custom Function Blocks | [custom-function-blocks.md](./custom-function-blocks.md) | ST-bodied, ladder-bodied, and FBD-bodied instances, the shared scope-rewrite rule, the max-call-depth guard, Rockwell `EnableIn` re-assertion |

---

## Confirmed learnings

| CL | Rule |
|---|---|
| CL-1 | LD's `CTD` preloads `CV := PV` on its first scan; FBD's `CTD` does not (starts at `CV = 0`, needs an explicit `LD` pulse). See [ladder-diagram.md](./ladder-diagram.md) §4 and [function-block-diagram.md](./function-block-diagram.md) §3. |
| CL-2 | FBD networks execute in ascending index order within one scan; a `TAG_OUTPUT` write is visible to a later network's `TAG_INPUT` read in the same pass. See [function-block-diagram.md](./function-block-diagram.md) §1. |
| CL-3 | A `Continuous` task runs only when `!anyHigherDue` (no enabled Startup/Event/Periodic task due, project-wide) - a Periodic period close to the scan period starves Continuous indefinitely. See [task-scheduling.md](./task-scheduling.md) §1. |
| CL-4 | SFC `STEP_T` advances by the scan tick's own `dtMs`, not by the owning task's configured period. See [sequential-function-chart.md](./sequential-function-chart.md) §1. |
| CL-18 | Ladder `CTU`/`CTD` presets are integer literals baked into the rung's JSON, never tag references (FBD's equivalents are wired input pins and can be). See [ladder-diagram.md](./ladder-diagram.md) §7. |

---

## Related

- [../plc-formats/index.md](../plc-formats/index.md) - vendor project-file formats whose LD/FBD/SFC/ST bodies import into these exact executors.
- [../protocols/index.md](../protocols/index.md) - how tags this domain reads/writes get exposed externally.
