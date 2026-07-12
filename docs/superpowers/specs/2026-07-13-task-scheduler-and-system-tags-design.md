# Task-Type Scheduler, Watchdog, Free-Run & System Tags — Design

**Date:** 2026-07-13
**Status:** Approved by user (chat, 2026-07-13).
**Builds on:** the scan loop in `mobile/lib/screens/workspace_shell.dart` (`_executeScan`, `_scanTimer`, `scanSpeedMs`, `isRunning`), the four language executors (`ld_exec.dart`, `fbd_exec.dart`, `sfc_exec.dart`, `st_exec.dart`), the sim engine (`sim_engine.dart`), the tag/composite model (`project_model.dart`, `tag_resolver.dart`), and the `PlcTask` model.

## Problem

The **Add New Program** dialog (`workspace_shell.dart:_showAddProgramDialog`) only lets a program be assigned to an *existing* task, and every project ships with a single Continuous task — so the Startup / Periodic / Event folders in the project tree can never receive a program. Worse, **task type is purely a label today**: `_executeScan` runs *every* program of *every* language on *every* scan, ignoring `task.type`, `periodMs`, and even task membership. A Periodic task does not run at its period; a Startup task does not run once at start.

This workstream makes the app honor task types with a real **priority scheduler + watchdog**, adds a **free-run** scan mode, lets the operator **create and manage tasks of all four IEC types**, and exposes a reserved **`System` UDT** carrying PLC status (fault, scan time, first-scan, wall clock, …) and control bits (alarm reset).

## Goal

1. Programs run according to the type of the task(s) they belong to: **Startup** (once at run-start), **Continuous** (every scan), **Periodic** (every `periodMs`), **Event** (on the rising edge of a bound BOOL tag).
2. **Priority preemption:** Startup/Event/Periodic tasks are higher priority than Continuous. On any scan tick where a higher-priority task is due, the **Continuous task is paused (skipped) for that tick** and resumes on the next tick where nothing higher-priority is pending.
3. **Watchdog:** each task has a time budget (`watchdogMs`, 0 = disabled). If a task's execution exceeds it, the PLC **faults and stops**; a fault banner names the offending task; a **Clear Fault** action (or a `System.AlarmReset` write) recovers.
4. **Free-run mode:** in addition to the fixed-`N`-ms scan, an operator can run the PLC "as fast as allowed" with no specified scan period; Periodic timing and the watchdog then use **measured wall-clock** elapsed time.
5. **Task management UI:** create / edit / delete tasks of any of the four types; the Add-Program dialog can target any task or create one inline.
6. **System UDT:** a reserved, built-in `System` tag exposing PLC status and control to logic, HMI, and every protocol server.

## Decisions (locked with the user)

- **Execution semantics honored** (not just organization).
- **Priority order:** Startup → Event → Periodic → Continuous. Continuous is **skipped** on any tick where a higher-priority task is due.
- **Event trigger:** false→true edge of a per-task bound **BOOL** tag.
- **Membership:** every program belongs to **≥1 task** (no orphans); a program may be in **multiple** tasks; on any scan a program runs **at most once** (deduped across due tasks, in priority order).
- **Watchdog action:** **fault + stop** on overrun.
- **Run-mode + fault state:** **session/shell state**, not persisted per project (like the existing scan-speed control).
- **System tag:** reserved root tag named **`System`**, type `SYSTEM`; includes a **wall clock**.

## Architecture

### Unit map

| Unit | File | Responsibility |
|---|---|---|
| Task model (additive) | `mobile/lib/models/project_model.dart` (`PlcTask`) | Add `triggerTag` (String, `''`) and `watchdogMs` (int, `0`). Serialize both (additive). `type`, `periodMs`, `enabled`, `programNames` already exist. |
| **Task scheduler (pure, new)** | `mobile/lib/models/task_scheduler.dart` | Given tasks + `dtMs` + a `TaskSchedulerRuntime` + a BOOL-tag lookup, decide which tasks are **due** this tick, in **priority order**, with per-task **deduped** program lists. No Flutter / `dart:io`. |
| Executor gating | `ld_exec.dart`, `fbd_exec.dart`, `sfc_exec.dart`, `st_exec.dart` | Add an optional `Set<String>? only` param to each `executeXxxPrograms`. `null` ⇒ run all (preserves current behavior + every existing test); non-null ⇒ run only programs whose `name` is in the set. |
| **System tags (pure, new)** | `mobile/lib/models/system_tags.dart` | The built-in `SYSTEM` composite definition; `ensureSystemTag(project)` (inject/back-fill the reserved `System` tag); `updateSystemStatus(project, SystemSnapshot)` (write status fields); `consumeAlarmReset(project)` (read+self-clear the control bit, returns whether a reset was requested). All pure. |
| Built-in composite registration | `mobile/lib/models/tag_resolver.dart` | Register `SYSTEM` in `_builtinComposites` so `System.*` paths resolve like `TIMER`/`COUNTER`. |
| Scan integration + run loop | `mobile/lib/screens/workspace_shell.dart` | Fixed vs free-run scheduling; per-tick scheduler call; per-task watchdog timing; fault state; `System` status write + `AlarmReset` consumption; scheduler `reset()` on Run/Stop/project-switch; supervisor poll while faulted. |
| Task-management + Add-Program UI | `mobile/lib/screens/workspace_shell.dart` (+ small dialog widgets) | Add Task / edit / delete (name, type, `periodMs`, `triggerTag`, `watchdogMs`, `enabled`); Add-Program dialog gains "＋ New task…"; run-mode toggle + scan-time readout + fault banner + Clear Fault. |
| Migration / defaults | `mobile/lib/data/default_projects.dart`, WS6 load path | Ensure every project has the `System` tag (back-fill missing fields); existing task assignments already cover every program. |

### The scan tick (revised `_executeScan`)

Each tick, in order:

1. **Sim rules** run once (`applySimRules`) — the plant/inputs, unchanged, always every tick.
2. **Scheduler:** `dueTasks = scheduleTick(tasks, dtMs, runtime, boolLookup)` returns an **ordered** `List<DueTask>` (priority order, Continuous omitted if any higher-priority task is due), each `DueTask` carrying `taskName`, `watchdogMs`, and its **ordered, deduped** `programs` (a task's list excludes programs already claimed by a higher-priority due task).
3. **Dispatch + watchdog:** for each `DueTask` in order, start a `Stopwatch`, run the four executors with `only: dueTask.programs`, stop the watch. If `watchdogMs > 0` and elapsed > `watchdogMs` → **fault**: set fault state (`taskName`, code 1), stop the scan loop, break.
4. **System status:** compute a `SystemSnapshot` (fault flags, `Running`, `FirstScan`, `ScanCount`, scan-time last/min/max, `FreeRun`, `UptimeMs`, wall clock from `DateTime.now()`) and `updateSystemStatus(project, snapshot)`.
5. **Alarm reset:** `consumeAlarmReset(project)` — a rising `AlarmReset` clears fault + resets scan min/max stats, then self-clears.

`dtMs` is the fixed `scanSpeedMs` in fixed mode, or the **measured** wall-clock delta since the previous tick (via a `Stopwatch`/`DateTime`) in free-run mode. The scheduler and system-tag units stay **pure** — the shell measures time and passes values in.

### Scheduler semantics (pure)

`TaskSchedulerRuntime` holds, across a run session:
- `startupFired` (bool) — becomes true after the first scan.
- `periodicAccumMs` (`Map<taskName,int>`) — accumulates `dtMs`; when ≥ `periodMs`, the task is due and the accumulator carries the remainder (`accum -= periodMs`).
- `eventPrevTrigger` (`Map<taskName,bool>`) — previous BOOL value of each Event task's `triggerTag`, for edge detection.
- `reset()` — clears all of the above; called at run-session boundaries.

Per tick, for each `enabled` task:
- **Startup** — due iff `!startupFired`.
- **Event** — due iff `triggerTag` resolves to a BOOL that is `true` now and was `false` on the previous tick (unknown/non-BOOL ⇒ treated as `false`, never due).
- **Periodic** — due iff accumulated time reached `periodMs`.
- **Continuous** — due iff **no** Startup/Event/Periodic task is due this tick.

Then `startupFired` is set true (so Startup fires exactly once), periodic accumulators updated, and `eventPrevTrigger` refreshed. `FirstScan` (a system field) is true on exactly the tick where Startup fires (the first scan of the session).

Determinism: same inputs ⇒ same output. All time comes in as `dtMs`; no `DateTime.now()`/`Stopwatch` inside the scheduler.

### Watchdog & fault lifecycle

- Fault is **shell state**: `_faulted` (bool), `_faultTask` (String), `_faultCode` (int).
- On overrun: `_faulted = true`, scan loop stopped (`isRunning = false`, timer cancelled), fault banner shown.
- **Recovery:** the Clear Fault button, or a rising edge on `System.AlarmReset` written by HMI/protocol. Because a faulted PLC's scan loop is halted, a lightweight **supervisor poll** (≈200 ms) runs *while faulted* to observe an external `AlarmReset` write and clear the fault. Clearing the fault leaves the PLC **stopped**; the operator presses Run to resume (which `reset()`s the scheduler → Startup + `FirstScan` fire again).
- Clear Fault pulses `System.AlarmReset` so the button and the tag share one path.

### Free-run vs fixed scan

Run-mode is a shell toggle (session state):
- **Fixed (N ms):** existing `Timer.periodic(scanSpeedMs)`. `dtMs = scanSpeedMs`.
- **Free-run:** scans re-armed back-to-back yielding to the event loop each tick (`Timer(Duration.zero, …)` re-arm, or `Future.microtask`), so the UI still paints; `dtMs` = measured wall-clock delta. `System.FreeRun = true`.

## System UDT (`SYSTEM` composite, reserved `System` tag)

Registered as a built-in composite (like `TIMER`/`COUNTER`). A reserved root tag `System` (dataType `SYSTEM`) is injected into every project and back-filled with any missing fields on load. It **cannot be deleted or renamed** in the Memory Manager; status fields render **read-only**; it is otherwise a normal tag — logic, HMI, and OPC UA / Modbus / DNP3 / MQTT can all read and map it.

**Status fields (engine-written each scan; read-only to logic):**

| Field | Type | Meaning |
|---|---|---|
| `Fault` | BOOL | A watchdog has tripped |
| `FaultTask` | STRING | Name of the faulted task (`''` when none) |
| `FaultCode` | INT32 | 0 = none, 1 = watchdog overrun |
| `Running` | BOOL | Scan loop active |
| `FirstScan` | BOOL | True only during the first scan of a run session |
| `ScanCount` | INT32 | Scans since session start |
| `ScanTimeMs` | FLOAT64 | Last measured scan time |
| `MaxScanTimeMs` | FLOAT64 | Peak scan time this session |
| `MinScanTimeMs` | FLOAT64 | Min scan time this session |
| `FreeRun` | BOOL | Free-run mode active |
| `UptimeMs` | INT32 | Elapsed ms since run-session start |
| `Year` `Month` `Day` `Hour` `Minute` `Second` | INT32 | Wall clock (`DateTime.now()`, local) |
| `DateTime` | STRING | Convenience formatted wall clock (e.g. `2026-07-13 14:05:32`) |

**Control fields (HMI/protocol/logic-written; engine-consumed):**

| Field | Type | Meaning |
|---|---|---|
| `AlarmReset` | BOOL | Rising edge clears the fault (`Fault`→false, `FaultTask`/`FaultCode` cleared) and resets scan min/max, then self-clears |

Scan min/max reset on run-session start and on `AlarmReset`. Wall-clock fields are written each scan (in free-run they refresh every tick).

## Task-management & Add-Program UI

- **Tree:** each task shows edit/delete affordances; an **Add Task** control creates a task with fields: name, type (Startup/Continuous/Periodic/Event), `periodMs` (Periodic only), `triggerTag` (Event only — BOOL tag picker reusing the type-ahead field), `watchdogMs`, `enabled`. Deleting a task is **blocked/warned** if it would leave any of its programs in no task (upholds the ≥1-task invariant).
- **Add-Program dialog:** the task selector lists all tasks **plus "＋ New task…"**, which expands inline to type + name (+ period/trigger) so a new program can be filed under any type on the spot. On add, the program is placed in the chosen (or newly created) task.
- **Toolbar:** run-mode toggle (Fixed *N* ms / Free-run), a scan-time readout (from `System.ScanTimeMs`), and a fault banner with **Clear Fault**.

## Testing

**Pure scheduler (`task_scheduler_test.dart`):** startup fires exactly once and only on the first tick; periodic accumulates and fires at `periodMs` boundaries carrying the remainder; event fires only on false→true edge (not on sustained true, not on unknown/non-BOOL tag); **Continuous is skipped on any tick where a higher-priority task is due** and resumes otherwise; `enabled == false` never fires; a program in two due tasks is deduped to one run in priority order; `reset()` re-arms startup; determinism (same inputs → same output).

**Watchdog:** a task whose execution exceeds `watchdogMs` trips the fault (task name + code 1); `watchdogMs == 0` never trips; under-budget never trips.

**Executor gating:** `only` restricts to the named programs across all four languages; `only == null` runs all (regression guard for existing behavior).

**System tags (`system_tags_test.dart`):** `ensureSystemTag` injects `System` when absent and back-fills missing fields without clobbering existing values; `updateSystemStatus` writes each status field (incl. wall clock + `DateTime` string format); `consumeAlarmReset` clears fault + resets min/max and self-clears only on a rising edge; `System` resolves via `readPath`/`writePath` (`System.Fault`, `System.AlarmReset`, `System.Hour`).

**Integration (`workspace_shell` / scan):** `_executeScan` honors the schedule end-to-end (a Periodic program runs at its period; a Startup program runs once; an Event program runs on a tag edge); a watchdog trip stops the loop and sets the fault banner; `FirstScan`/`ScanCount`/`Running`/`UptimeMs` reflect run state; free-run measured-dt path advances Periodic tasks.

**UI:** Add Task creates each type; Event task shows a BOOL trigger picker, Periodic shows a period field; Add-Program "＋ New task…" files a program under a new Startup/Periodic/Event task; deleting a task that would orphan a program is blocked/warned; run-mode toggle switches modes; Clear Fault clears the banner. No RenderFlex overflow at 320 / 360 / 1400.

**Persistence:** `triggerTag` + `watchdogMs` round-trip (WS6 lossless guard); the `System` tag round-trips; loading a pre-existing project injects/back-fills `System`.

**Regression:** full `flutter test`; `flutter analyze` **zero**; `flutter build web --release` compiles; all existing logic-execution behavior unchanged for the default single-Continuous-task projects (every program still runs each scan, because the sole Continuous task claims them all and no higher-priority task exists).

## Global constraints

- No vendor branding (no "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"; IEC 61131-3 terms are fine). Dark theme. Zero `flutter analyze` warnings (`withValues(alpha:)`, not `withOpacity`). Braces on all control flow; prefer `const`. No RenderFlex overflow at 320 / 360 / 1400.
- `mobile/lib/models/**` stays **pure Dart** (no `dart:io`, no Flutter): `task_scheduler.dart` and `system_tags.dart` take time/values as inputs; only `workspace_shell.dart` measures the clock and drives timers.
- **Force-aware:** all tag writes go through `writePath` / the existing force-aware write path; reads through `readPath` (forcing stays authoritative).
- **Additive persistence:** new `PlcTask` fields and the `System` tag are additive; the WS6 lossless round-trip stays green; a project with no task-type features behaves exactly as before.
- Avoid `INT64` for the new numeric fields (dart2js-safe) — `UptimeMs` and wall-clock components are `INT32`.
- The reserved `System` tag is protected from user delete/rename; status fields are read-only in the tag inspector; control bits remain writable.

## Phasing (one spec → phased plan)

- **Phase A — Model + pure scheduler + watchdog + executor gating.** `PlcTask.triggerTag`/`watchdogMs`; `task_scheduler.dart` + `TaskSchedulerRuntime`; `only` param on the four executors. Pure unit tests. (No UI yet; `_executeScan` not yet switched over.)
- **Phase B — Scan integration, free-run, fault lifecycle.** Switch `_executeScan` to the scheduler; per-task watchdog timing + fault stop; fixed/free-run run loop; fault banner + Clear Fault + supervisor poll. Integration tests.
- **Phase C — System UDT.** `system_tags.dart` + `SYSTEM` built-in composite; inject/back-fill; status write + wall clock; `AlarmReset` consumption; wire into the scan tick and Clear Fault. Unit + integration tests.
- **Phase D — Task-management + Add-Program UI.** Add/edit/delete tasks; "＋ New task…" in Add-Program; run-mode toggle + scan-time readout; no-orphan guard; reserved-tag protection in Memory Manager. Widget tests.
- **Phase E — Validation, docs, final review.** Full suite + analyze + web build; round-trip guards; update `docs/` (a task-scheduler/system-tags doc) and `ROADMAP.md`; whole-branch review; merge.
