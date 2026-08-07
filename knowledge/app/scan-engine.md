---
id: knowledge:app/scan-engine
title: Scan Engine
domain: app
version: "2026-08"
topics: [scan-tick, task-scheduler, executor-runtime, edge-memory, watchdog, project-switch-reset]
summary: The exact per-tick execution order (simulation, signal generators, then due tasks' programs in priority order), how each language executor keys its cross-scan state, edge-memory semantics, watchdog fault behavior, and precisely what resets on a project switch.
related:
  - knowledge:app/index
  - knowledge:app/tag-model
  - knowledge:app/simulation
  - knowledge:industry/iec61131/task-scheduling
learnings: [CL-1, CL-2, CL-3, CL-4]
---

# Scan Engine

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/screens/scan_tick.dart`, `mobile/lib/models/task_scheduler.dart`,
> `mobile/lib/models/{ld_exec,fbd_exec,sfc_exec,st_exec}.dart`, `mobile/lib/screens/workspace_shell.dart`
> (`_executeScan`, `_beginProjectSession`, `_resyncHistorian`), and `docs/task-scheduling.md`.
> **Read this before:** debugging scan-order-dependent behavior, adding a new IEC language
> executor, changing task-scheduler priority/dedup logic, or reasoning about what state
> survives (or doesn't) across a scan tick or a project switch.

---

## 1. The headline rule

**One scan tick runs simulation and signal generators first, then each due task's programs
in strict `Startup > Event > Periodic > Continuous` priority order; protocol hosts are not
part of the scan tick at all.**

`runScanTick` (`mobile/lib/screens/scan_tick.dart:59-94`) is the entire per-tick orchestration:

```dart
ScanTickResult runScanTick(PlcProject p, int dtMs, ScanTickRuntime rt) {
  final firstScan = !rt.scheduler.startupFired;
  applySimRules(p, p.simRules, dtMs, rt.sim);
  applySignalGens(p, p.signalGens, dtMs, rt.signal);
  final readOnly = generatedPaths(p.signalGens);
  final due = scheduleTick(p.tasks, dtMs, rt.scheduler, (path) => readPath(p, path) == true);
  for (final task in due) {
    final only = task.programs.toSet();
    // executeLdPrograms -> executeFbdPrograms -> executeSfcPrograms -> executeStPrograms,
    // watchdog-timed with a Stopwatch; first watchdog trip returns immediately.
  }
  return ScanTickResult(...);
}
```

The caller, `WorkspaceShellState._executeScan` (`mobile/lib/screens/workspace_shell.dart:833-926`),
wraps this with: `runScanTick(...)` (line 845) then `System` status bookkeeping and
`updateSystemStatus(...)` (850-906, plain model mutations, **not** wrapped in `setState`) then
`_historian.sample(...)` (907-920) then `_repaintThrottle.request()` (926). **Protocol hosts
never appear in this path.** They are independent `dart:io` socket servers started only from
an explicit UI toggle (see [protocol-hosting.md](./protocol-hosting.md) §1) and read/write the
tag database asynchronously, decoupled from scan cadence - not the fourth stage of a
"sim -> tasks -> protocols -> historian" pipeline. A protocol write lands in the tag database
the instant it's processed; the *next* scan tick is simply the first one whose logic can react
to it.

---

## 2. Per-scan order in full

1. **`applySimRules`** - every enabled `SimRule`, unconditionally (see [simulation.md](./simulation.md)).
2. **`applySignalGens`** - every enabled `SignalGen`; `generatedPaths(p.signalGens)` collects
   their target paths into a `readOnly` set that logic execution below must not fight.
3. **`scheduleTick`** (`task_scheduler.dart:35-118`) - decides which tasks are due this tick, in
   priority order `Startup > Event > Periodic > Continuous`, and returns a deduped, ordered
   `List<DueTask>`.
4. **Per due task, in that priority order**: `executeLdPrograms` -> `executeFbdPrograms` ->
   `executeSfcPrograms` -> `executeStPrograms`, scoped to `only: task.programs.toSet()` and the
   signal-gen `readOnly` set, timed with a `Stopwatch`. `executeFbdPrograms` is passed the
   **same** `LdExecRuntime` the LD engine uses (`ldRt: rt.ld`) - a ladder-bodied custom function
   block called from an FBD network keeps its edge/pulse state across scans through that shared
   runtime (§4).
5. **Watchdog check** - if `task.watchdogMs > 0` and the measured elapsed time for that task's
   programs exceeds it, the tick returns immediately with `faulted: true`: no further tasks in
   this tick, and no further ticks at all, execute until the fault is cleared (see
   [industry/iec61131/task-scheduling.md](../industry/iec61131/task-scheduling.md) for the
   fault/`AlarmReset` recovery semantics).

## 3. Task-scheduler priority and dedup

`scheduleTick` (`task_scheduler.dart:35-118`) is pure and deterministic - all time enters via
`dtMs`, nothing reads a clock:

- **Priority order** is the fixed list `['Startup', 'Event', 'Periodic', 'Continuous']`
  (`task_scheduler.dart:28`).
- **A program name can only belong to one due task per tick.** A `claimed` set (line 90)
  ensures that if two due tasks in the same tick both list the same program, only the
  higher-priority task's copy runs; the lower-priority task's `DueTask` simply omits it.
- **Periodic** accumulates `dtMs` per tick against `periodMs`; fires at most once per tick even
  if the accumulator has built up more than one period's worth, and the carried remainder is
  clamped so a task that falls behind can never burst-fire (`task_scheduler.dart:43-59`).
- **Continuous** is due exactly when `!anyHigherDue` - no Startup/Event/Periodic task is due
  this tick (line 71-73, 83-84). This is the starvation-avoidance mechanism: Continuous never
  competes with time-critical work, but a Periodic task whose period is close to the scan
  period can still starve it entirely (CL-3; see task-scheduling.md's Continuous-starvation
  guidance).
- **Event** fires on a rising edge only (`now && !prev`, line 62-69). Edge memory
  (`rt.eventPrevTrigger[t.name]`) is advanced for **every** Event task each tick - including
  disabled ones and ones not currently due (`task_scheduler.dart:109-115`) - specifically so a
  re-enabled task detects a fresh edge rather than replaying a stale one.
- **Startup** fires exactly once per run session (`isFirstScan`, tracked by
  `rt.startupFired`, set `true` unconditionally at the end of every call, line 116).

## 4. Executor state keying

Each IEC language executor owns its own runtime-state map(s), all living on
`ScanTickRuntime` (`scan_tick.dart:14-40`) so they persist across ticks within one run session:

| Executor | Runtime class | Keying |
|---|---|---|
| LD | `LdExecRuntime.prevBool` (`Map<String,bool>`) | `"$progName\|$rungIndex\|$nodeId"` |
| FBD | `FbdRuntime` - 5 separate maps (`_elapsedMs`, `_pid`, `_counters`, `_prevClk`, `_pulse`) | block id (`FbdBlock.id`, unique within a project's FBD programs); an FBD-bodied custom FB's body instead keys `'fb:<instancePath>|<blockId>'`, disjoint from every program's own block ids |
| SFC | `SfcRuntime.active` (`Map<String,Set<String>>`), `.stepElapsedMs` (`Map<String,int>`) | program name; `"<prog>|<stepId>"` |
| ST | `StRuntime` | reserved/unused - FB instance data is stored directly on tags at `<instancePath>.<var>`, not in a runtime map |
| Task scheduler | `TaskSchedulerRuntime.periodicAccumMs`, `.eventPrevTrigger` | task name |
| Simulation | `SimRuntime.byRuleId` | `SimRule.id` (see [simulation.md](./simulation.md) §3) |

**Ladder-bodied custom function blocks share the LD engine's runtime** under a synthetic
program key `'fb:<instancePath>'` (`ld_exec.dart:534`), rather than a separate map. The
instance-prefixed key keeps an FB body's rung state disjoint from ordinary program-rung
state while letting one `LdExecRuntime` serve both a program's rungs and a ladder-bodied FB's
body - this is also why `executeFbdPrograms` is handed the LD runtime (`ldRt: rt.ld`) at
`scan_tick.dart:81-82`: an FBD network can call a ladder-bodied FB, and that FB's edge/pulse
state must be the same runtime the LD engine itself reads and writes.

**FBD-bodied custom function blocks share the FBD engine's `FbdRuntime`** the same way, under
the `'fb:<instancePath>|<blockId>'` prefix from the table above (`fbd_exec.dart`'s
`runScopedFbdBody`) rather than a separate map. Neither engine's call site knows ahead of time
whether the FB instance it's calling is ladder-bodied or FBD-bodied, so both an LD block call and
an FBD block call to a custom FB thread **both** `ldRt` and `fbdRt` down through
`executeFbInstance` uniformly - only the runtime matching the FB's actual body kind ends up used.

## 5. Edge memory

Rising/falling edge detection is per-key state inside the same executor runtime maps as §4:

- LD rising/falling contacts and pulse coils: `rt.prevBool[key]` where `key` is the same
  `"$progName|$rungIndex|$nodeId"` string.
- FBD `R_TRIG`/`F_TRIG`: `rt._prevClk[b.id]`.
- Task-scheduler Event edge: `rt.eventPrevTrigger[t.name]`, advanced every tick for every Event
  task (§3) - the one edge-memory location that updates unconditionally rather than only when
  its owning code path actually runs.

## 6. Timer/counter first-scan behavior (CL-1)

**CL-1: LD timer/counter blocks preload `PRE` on the first scan; FBD `CTD` does not.**

LD's `CTD` (`ld_exec.dart:337-348`) preloads `CV = PV` unconditionally on the first-ever scan
(tracked via `rt.prevBool[initKey] != true`), so `QD` cannot spuriously read `true` before any
counting has happened. FBD's `CTD` (`fbd_exec.dart:381-383`) has no such preload - its counter
state (`rt._counters[b.id]`) defaults to `[0, 0, 0]`, so `CV` starts at `0` regardless of `PV`.
An FBD `CTD` therefore needs an explicit `LD` (load) pulse before it produces a meaningful
count-down value - a UI or logic design that assumes FBD `CTD` behaves like LD `CTD` on power-up
will read a wrong initial value. FBD `CTD`'s `LD`/`CD` inputs are mutually exclusive per scan
via an `else if` (`fbd_exec.dart:385-389`): a simultaneous load-and-count-down never happens in
the same tick.

```
Wrong:  assume an FBD CTD's CV starts at PV, matching LD CTD's first-scan preload.
Correct: FBD CTD's CV starts at 0; drive an explicit LD pulse (e.g. from an R_TRIG on the
         first scan) if the design needs a preloaded count.
```

## 7. FBD network execution order (CL-2)

**CL-2: FBD networks execute in ascending index order within one scan; `TAG_OUTPUT` writes
immediately and `TAG_INPUT` reads live, so same-scan chaining across networks is real and
ordered.**

`fbd_exec.dart:521-537` states this as a doc comment and the code backs it exactly: network
indices are sorted (`netIndices = ... .toSet().toList()..sort()`) and iterated in that order.
`TAG_OUTPUT` performs a force-aware write the instant its network evaluates
(`fbd_exec.dart:479-489`); `TAG_INPUT` performs a synchronous `readPath` (line 211). Data
therefore flows from a lower-index network to a higher-index network **through tags, never
through wires** - wires never cross a network boundary. A design that assumes all networks
see the same tag snapshot for the whole scan (as if they evaluated against a frozen input set)
will be surprised: network 2 sees whatever network 0 or 1 already wrote this same tick.

## 8. SFC `STEP_T` and task period (CL-4)

**CL-4: SFC `STEP_T` advances by the scan's `dtMs`, not by the owning task's period - a
program in a 1000 ms task on a 100 ms scan dwells 10x longer in wall time than `STEP_T`
suggests.**

`executeSfcPrograms(PlcProject p, int dtMs, ...)` (`sfc_exec.dart:43`) accumulates
`elapsed = (rt.stepElapsedMs[key] ?? 0) + dtMs` (line 70-73) using the tick's own `dtMs` - not
the task's `periodMs`. The program only executes on ticks where its owning task is due
(scoped via `only: task.programs.toSet()` at the `scan_tick.dart:73-84` call site), gated by
`scheduleTick`'s periodic-accumulator logic (§3). Concretely: a `Periodic` task with
`periodMs: 1000` on a 100 ms scan fires roughly once every 10 scan ticks; each firing adds only
`dtMs = 100` ms to `STEP_T`. After 10 seconds of real wall-clock time (10 firings), `STEP_T`
reads only ~1000 ms - a 10x undercount relative to the step's actual wall-clock dwell. A
`STEP_T` dwell condition tuned by watching the wall clock, rather than by the task's period,
will fire 10x later than expected.

## 9. Project-switch resets

Two independent reset paths run on every project switch/create/duplicate/delete/reset/import
(all funnel through `WorkspaceShellState._beginProjectSession`,
`mobile/lib/screens/workspace_shell.dart:783-810`):

- **`ScanTickRuntime.resetSession()`** (`scan_tick.dart:29-39`) clears: `sim.byRuleId`,
  `ld.prevBool`, `ldMonitor`, `fbd`'s five maps, `fbdMonitor`, `sfc.active`/`.stepElapsedMs`,
  `st` (no-op - it's empty), `scheduler.reset()` (`startupFired = false`,
  `periodicAccumMs.clear()`, `eventPrevTrigger.clear()`), and `signal.reset()`
  (`elapsedMs = 0`). `_beginProjectSession` additionally resets the fault flags
  (`_faulted`/`_faultTaskName`/`_faultCode`) and, unless `preserveScanCount` is set, the
  scan-count/timing stats and uptime clock.
- **`_resyncHistorian()`** (`workspace_shell.dart:754-768`) calls `_historian.clear()` then
  `_historian.syncPens(_activeProject.trends)` - trend buffers "must never straddle two
  different projects" (comment, lines 159-161). See [ui-performance.md](./ui-performance.md) §3.

**What deliberately does NOT reset on a project switch:**

- **Protocol hosts** are not part of `resetSession` at all - they are explicitly `.stop()`'d (or
  `.disconnect()`'d) by the same call sites that switch the active project
  (`workspace_shell.dart:945-959`, `:1628-1640`), because hosting configuration is per-project
  and a running host cannot silently keep serving the old project's tag database.
- **`AppLogger`'s log buffer is deliberately NOT cleared** on project switch (unlike the
  historian) - see [ui-performance.md](./ui-performance.md) §4 for why.

---

## What this means practically

### "I renamed a task program but logic stopped running - why?"
Check `scheduleTick`'s claim/dedup logic (§3): if the renamed program is still listed under
two tasks (a stale reference plus the corrected one), only the higher-priority task's copy
executes each tick - the lower-priority task's copy is silently skipped, not run twice.

### "My FBD CTD's CV read 0 on the first scan even though PV was 10 - is that a bug?"
No - per CL-1 (§6), FBD `CTD` never preloads `CV` from `PV` on first scan (unlike LD `CTD`).
Drive an explicit `LD` pulse if a preloaded starting count is needed.

### "A tag written by network 3 in my FBD program doesn't show up in network 1 until next scan - why?"
Because networks execute in ascending index order (§7, CL-2) - a lower-index network runs
*before* a higher-index network in the same tick, so network 1 sees network 3's write only on
the *next* scan, not this one. Reorder the networks (or restructure the data flow) if same-scan
visibility in that direction is required.

### "Why does my SFC step's dwell condition fire later than the wall-clock time I expected?"
`STEP_T` counts scan `dtMs`, gated by how often the step's owning task actually runs (CL-4, §8)
- a step living in a slow `Periodic` task accumulates `STEP_T` far more slowly than a wall
clock would suggest.

---

## Related

- [tag-model.md](./tag-model.md) - the `readPath`/`writePath` resolver every executor and
  `applySimRules` reads and writes through.
- [simulation.md](./simulation.md) - `applySimRules`/`applySignalGens`, the two things that run
  before any task this tick.
- [protocol-hosting.md](./protocol-hosting.md) - why protocol hosts are not part of this tick.
- [ui-performance.md](./ui-performance.md) - how the UI observes scan results without riding
  the tick directly.
- [../industry/iec61131/task-scheduling.md](../industry/iec61131/task-scheduling.md) - the
  portable IEC task-type semantics this app's scheduler implements.
- [index.md](./index.md) - domain hub.
