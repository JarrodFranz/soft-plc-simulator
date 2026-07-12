# Task Scheduling, Watchdogs & the System UDT

This document covers the in-app task scheduler that decides, every scan
tick, which programs run — the four IEC 61131-3 task types, their priority
order, the per-task watchdog, free-run vs. fixed scan timing, and the
reserved `System` tag that exposes runtime status to logic and HMI screens.

Implementation: `mobile/lib/models/task_scheduler.dart` (pure scheduling
decision), `mobile/lib/screens/scan_tick.dart` (one scan tick: sim rules,
scheduling, per-task execution + watchdog), `mobile/lib/models/system_tags.dart`
(the `System` UDT), and `mobile/lib/screens/workspace_shell.dart` (the scan
loop, free-run/fixed timing, fault banner, Clear Fault).

## Task types and priority order

Each `PlcTask` (`PlcProject.tasks`) has a `type` of `Startup`, `Event`,
`Periodic`, or `Continuous`, a list of program names it owns, and an
`enabled` flag. A task's programs only execute on a scan tick where the
task itself is **due**.

Every scan tick, due tasks run in this fixed priority order:

```
Startup  >  Event  >  Periodic  >  Continuous
```

A program name can only belong to one task's due set per tick — if two due
tasks in the same tick both list the same program, the higher-priority task
claims it and the lower-priority task's copy is skipped for that tick (no
double execution).

- **Startup** — fires exactly once, on the very first scan tick of a run
  session (a run session begins when Run is pressed from Stopped, or on a
  project switch). Never fires again until the next run session.
- **Event** — fires on the **rising edge** of a bound `BOOL` trigger tag
  (`PlcTask.triggerTag`, a tag path): due when the tag reads `true` this
  tick and read `false` the previous tick. A tag that is already `true` when
  the run session starts does **not** fire on scan 1 — only a `false → true`
  transition fires it. Edge memory is tracked per task and updated every
  tick (even for disabled or not-currently-due Event tasks), so re-enabling
  a task detects a fresh edge rather than replaying a stale one.
- **Periodic** — accumulates elapsed time (the tick's `dtMs`) against the
  task's `periodMs`; due when the accumulator reaches or exceeds `periodMs`.
  Fires at most once per tick even if multiple periods have elapsed while
  the accumulator was behind — the remainder carries forward, but is
  clamped to `periodMs` so a task that falls behind (e.g. a slow scan)
  cannot build up unbounded backlog and burst-fire many times in a row.
  A `periodMs` of `0` means "as fast as possible" — due every tick.
- **Continuous** — the background/default task. Due on any tick where
  **no higher-priority task (Startup, Event, or Periodic) is due**. In
  other words, Continuous is skipped whenever the scheduler has
  higher-priority work to do that tick, and only gets scan time to itself
  otherwise. This guarantees time-critical Event/Periodic work is never
  starved by a busy Continuous program.

Disabled tasks (`enabled == false`) are never due, regardless of type.

## The per-task watchdog

Each task carries a `watchdogMs` limit (`0` = disabled). While its due
programs execute, the shell measures the wall-clock time actually spent
running them. If that measured time exceeds `watchdogMs` (and `watchdogMs
> 0`), the scan tick reports a **fault**: the faulting task's name and a
fault code are recorded, the scan loop stops advancing (`isRunning` is
cleared), and no further tasks in that tick — or subsequent ticks — execute
until the fault is cleared.

A fault is visible in two places:
- The **fault banner** at the top of the workspace shell, showing the
  faulting task and code.
- `System.Fault` / `System.FaultTask` / `System.FaultCode` (see below), so
  HMI screens and logic can react to it too.

### Clearing a fault

There are two equivalent ways to clear a fault and resume scanning:

1. **Clear Fault button** — on the fault banner, in-app. Clears the fault
   state immediately and resets the scan-time min/max stats for the next
   run.
2. **`System.AlarmReset`** — the reserved `System` tag's one writable
   control field. Any writer (HMI button, an external protocol write, or
   program logic) can set `System.AlarmReset` to `true`. A background
   supervisor poll (running independently of the scan loop, so it keeps
   working even while the scan loop itself is halted by a fault) checks
   this field roughly every 200 ms; if it is `true` while a fault is
   active, the fault clears and the flag self-resets to `false` — a level
   write behaves like a one-shot rising-edge reset, so each `true` write
   triggers exactly one recovery. Because the supervisor runs independently
   of the (potentially stopped) scan loop, `System.AlarmReset` can recover
   a faulted controller purely from the outside (SCADA/HMI) without the
   in-app Clear Fault button ever being touched.

Clearing a fault does **not** automatically resume Running — the operator
(or logic) still restarts the scan loop explicitly, same as a normal
Stopped → Run transition.

## Free-run vs. fixed scan mode

The scan loop can run in one of two timing modes, toggled from the
workspace shell:

- **Fixed scan** — a `Timer.periodic` fires every `scanSpeedMs`
  (configurable), so each tick's `dtMs` is that fixed configured period,
  regardless of how long the previous tick actually took to execute.
- **Free-run** — each tick re-arms a zero-delay timer immediately after the
  previous tick completes, so the controller scans "as fast as the platform
  allows" while still yielding to the UI event loop between ticks (so the
  app keeps painting/responding instead of the scan loop starving it).
  `dtMs` in free-run is the *measured* elapsed wall-clock time since the
  previous tick (clamped to a sane maximum), not a fixed constant — so
  Periodic accumulation and any time-based simulation/process behaviour see
  real elapsed time rather than an assumed one.

Free-run only keeps re-arming while the controller is Running and not
faulted; a paused or faulted controller goes fully idle (no timer at all)
until Run is pressed again or the fault clears. Switching between fixed and
free-run — or changing the fixed scan speed — restarts the scan loop
cleanly without double-scheduling.

`System.FreeRun` reflects which mode is currently active.

## The `System` UDT

`System` is a reserved tag name and `SYSTEM` a reserved/built-in composite
type (an implicit DUT, alongside the built-in `TIMER`/`COUNTER` composites —
it does not need to be declared in a project's struct-def list). The shell
injects the `System` tag automatically the first time a project is opened
if it is missing, and back-fills any struct fields a project created before
a given field existed — so opening an older project never leaves it without
the newest status fields.

`System` is read-only from the tag/HMI/protocol-write perspective, except
for its one control field, `AlarmReset`.

### Status fields (written by the shell every scan tick)

| Field | Type | Description |
|---|---|---|
| `Fault` | `BOOL` | `true` while a watchdog fault is latched. |
| `FaultTask` | `STRING` | Name of the task whose watchdog tripped (empty when not faulted). |
| `FaultCode` | `INT32` | Numeric fault code (`0` = none; `1` = watchdog timeout). |
| `Running` | `BOOL` | `true` when the scan loop is actively advancing and not faulted. |
| `FirstScan` | `BOOL` | `true` only on the first scan tick of the current run session (mirrors Startup-task timing). |
| `ScanCount` | `INT32` | Number of scan ticks executed in the current run session. |
| `ScanTimeMs` | `FLOAT64` | Wall-clock duration of the most recently completed scan tick, in milliseconds. |
| `MaxScanTimeMs` | `FLOAT64` | Longest scan tick duration seen in the current run session. |
| `MinScanTimeMs` | `FLOAT64` | Shortest scan tick duration seen in the current run session. |
| `FreeRun` | `BOOL` | `true` when the scan loop is in free-run mode; `false` in fixed scan mode. |
| `UptimeMs` | `INT32` | Milliseconds since the current run session started. |
| `Year` / `Month` / `Day` / `Hour` / `Minute` / `Second` | `INT32` | Wall-clock date/time components, sampled each scan tick. |
| `DateTime` | `STRING` | Wall-clock date/time formatted as `YYYY-MM-DD HH:MM:SS`, sampled each scan tick. |

### Control field (writable)

| Field | Type | Description |
|---|---|---|
| `AlarmReset` | `BOOL` | Write `true` to request a fault-clear recovery. Consumed (self-clears to `false`) by the supervisor poll or the next scan tick that observes it, giving one-shot reset-on-write semantics. See "Clearing a fault" above. |

`MaxScanTimeMs`/`MinScanTimeMs` reset (along with the scan-count/uptime
clocks) at the start of every new run session, and also when a fault is
cleared via the Clear Fault button, so stale worst-case numbers from before
a fault don't linger into the next run.
