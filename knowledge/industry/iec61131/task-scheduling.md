---
id: knowledge:industry/iec61131/task-scheduling
title: Task Scheduling
domain: industry/iec61131
version: "2026-08"
topics: [task-scheduling, iec-61131-3, startup-task, event-task, periodic-task, continuous-task, watchdog, system-tag]
summary: Documents IEC 61131-3's four-task-type priority model alongside this engine's exact scheduling algorithm - fixed priority order, per-type due predicates, the watchdog fault-stops-the-tick behavior, and the Continuous-task starvation mechanism (CL-3) with its exact code path.
related:
  - knowledge:industry/iec61131/index
  - knowledge:industry/iec61131/sequential-function-chart
learnings: [CL-3, CL-4]
---

# Task Scheduling

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from IEC 61131-3's task-configuration concept and the scheduler,
> `mobile/lib/models/task_scheduler.dart` (pure decision logic), `mobile/lib/screens/scan_tick.dart`
> (per-tick orchestration), and `mobile/lib/models/system_tags.dart` (the reserved System UDT).
> **Read this before:** configuring task priorities/periods, debugging a Continuous program that
> never seems to run, setting a watchdog, or reasoning about the System tag's `AlarmReset` field.

---

## 1. The headline rule

**A `Continuous` task is due only when no `Startup`, `Event`, or `Periodic` task is due anywhere in
the project this tick (CL-3) - so a `Periodic` task whose period is close to the scan's own tick
period starves every `Continuous` program indefinitely, by design, not by bug.**

Fixed priority order: `['Startup', 'Event', 'Periodic', 'Continuous']`. `scheduleTick` iterates
this list outer, tasks inner, so due tasks are returned in strict priority order regardless of the
project's task list order. The exact Continuous predicate:

```dart
final anyHigherDue = tasks.any((t) =>
    t.enabled &&
    (dueStartup(t) || dueEvent(t) || (periodicDue[t.name] ?? false)));
...
case 'Continuous':
  return !anyHigherDue;
```

This is a **project-wide** check across *all* enabled Startup/Event/Periodic tasks, not a
per-Continuous-task check. If any Periodic task's `periodMs` is small relative to the actual scan
tick period (or the app is in free-run mode where `dtMs` is whatever the platform measures), that
Periodic task's `acc >= periodMs` condition becomes true on most or every tick, which makes
`anyHigherDue` true on most or every tick, which starves every Continuous task on the project -
not just programs sharing that task.

```
Wrong assumption: "Continuous tasks get some guaranteed minimum scan share regardless of what
Periodic tasks are configured."

Correct: Continuous is starved whenever ANY enabled higher-priority task is due, project-wide.
Keep Periodic periods well above the scan's own tick period (e.g. >= 10x) if Continuous programs
must actually run.
```

There is **no numeric "safe ratio" guidance and no validation UI** for this anywhere in the app -
a pathological configuration (Periodic period == scan period) is accepted silently and simply
starves Continuous forever.

---

## 2. The 4 task types and exact due predicates

| Type | Due predicate | Notes |
|---|---|---|
| `Startup` | `!rt.startupFired` | Fires exactly once per run session; `rt.startupFired = true` set unconditionally at the end of every `scheduleTick` call, only reset by `resetSession()`. |
| `Event` | `now && !prev` (rising edge on `triggerTag`) | Edge memory updates for **every** Event task, due or not, enabled or not, at the end of every `scheduleTick` - so re-enabling a disabled task never replays a stale edge as fresh. |
| `Periodic` | `acc >= periodMs` (or always due if `periodMs <= 0`) | Carry-forward: `next = due ? acc - periodMs : acc`, then clamped so `next` never exceeds one full `periodMs` - a task that falls behind carries at most one extra period's worth of backlog; it never bursts multiple fires in one tick. |
| `Continuous` | `!anyHigherDue` | See §1. |

---

## 3. Task-name dedup (no double execution)

A `claimed: Set<String>` accumulates program names across the outer priority loop; a program is
added to a due task's program list only if `claimed.add(programName)` succeeds. A program
referenced by two different tasks therefore runs at most once per tick, claimed by whichever due
task has the higher priority - the lower-priority task's claim on that program silently no-ops for
this tick.

---

## 4. Watchdogs - a fault stops the rest of that tick

Each task has a `watchdogMs` (`0` disables it). For each due task, in priority order, a stopwatch
wraps execution of all four language engines for that task's claimed programs
(`executeLdPrograms -> executeFbdPrograms -> executeSfcPrograms -> executeStPrograms`, scoped to
that task's program set). If elapsed time **strictly exceeds** `watchdogMs`, the scan-tick function
returns immediately with `faulted: true`.

**Consequence: any task listed after the faulting task in that tick's due list does not run at all
this tick** - a `Startup` task tripping its watchdog can prevent that tick's `Periodic`/`Continuous`
tasks from executing this cycle entirely (they simply get a chance again next tick, subject to
their own due predicates).

---

## 5. Free-run mode

Not implemented inside `task_scheduler.dart`/`scan_tick.dart` - both are `dtMs`-agnostic; `dtMs`
flows in as an opaque parameter regardless of source. Free-run vs fixed-scan timer mechanics
(`Timer.periodic` for fixed-interval scanning vs a self-rearming zero-delay timer with measured
elapsed `dtMs` for free-run) live in the scan-loop host, outside the scheduler itself.

---

## 6. The reserved `System` tag/UDT

`kSystemTagName = 'System'`, `kSystemTypeName = 'SYSTEM'`. `SYSTEM` is registered as a built-in
composite type in `tag_resolver.dart`'s composite lookup (alongside `TIMER` and `COUNTER`),
resolved by checking project struct defs first, then the built-in composites, then FB definitions
as a last resort - so a project struct or FB literally named `TIMER`/`COUNTER`/`SYSTEM` would
silently shadow the built-in (the same shadowing pattern FBD's built-in block types exhibit - see
[function-block-diagram.md](./function-block-diagram.md) §2). `ensureSystemTag` injects the `System`
tag if it's missing on project load and back-fills any struct fields absent from an older project's
`System.value` map, without clobbering fields that already have values - this is how the System
UDT stays forward-compatible as new fields are added over time.

`AlarmReset` is the tag's sole writable field, and it's a **one-shot level-to-edge translator**:
`consumeAlarmReset` reads the current value, writes `false` back immediately, and returns `true`
exactly once per external `true` write - the mechanism a supervisory poll (external to the four
engines) uses to detect an operator's alarm-reset action exactly once, even though the write itself
is a plain level write, not an edge.

---

## What this means practically

### "My Continuous program never seems to scan - why?"
Check every enabled Startup/Event/Periodic task's period against the scan's actual tick period.
Continuous is starved project-wide whenever any of them is due (CL-3, §1) - this is most commonly
caused by a Periodic task with too short a period, not a bug in the Continuous task itself.

### "One task's watchdog tripped, and now a lower-priority task didn't run at all this tick - is that a bug?"
No - a watchdog fault stops the rest of that tick's due-task list from executing, by priority
order (§4). The skipped task gets another chance next tick if it's still due then.

### "I referenced the same program in two tasks - did it run twice?"
No - dedup via `claimed` ensures a program runs at most once per tick, claimed by the
higher-priority task that lists it (§3).

### "Why does re-enabling my Event task fire immediately even though the trigger tag hasn't changed since I disabled it?"
It shouldn't - edge memory for Event tasks updates every tick regardless of enabled state, so a
stale `false->true` transition from while it was disabled is never replayed as a fresh edge (§2).
If you're seeing an immediate fire, check whether the trigger tag itself changed while the task was
disabled.

---

## Related

- [sequential-function-chart.md](./sequential-function-chart.md) - `STEP_T`'s dependence on a task's actual firing pattern (CL-4), the other half of this task-timing relationship.
- [index.md](./index.md) - domain hub.
