---
id: knowledge:industry/iec61131/sequential-function-chart
title: Sequential Function Chart
domain: industry/iec61131
version: "2026-08"
topics: [sequential-function-chart, sfc, iec-61131-3, step, transition, step-t, divergence, convergence]
summary: Documents IEC 61131-3 SFC's step/transition/token model alongside this engine's exact multi-token executor semantics - the active-step-set architecture, list-order-as-priority alternative divergence, true AND-semantics parallel fork/join, and STEP_T's scan-dtMs-not-task-period accumulation (CL-4).
related:
  - knowledge:industry/iec61131/index
  - knowledge:industry/iec61131/structured-text
  - knowledge:industry/iec61131/task-scheduling
learnings: [CL-4]
---

# Sequential Function Chart

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from IEC 61131-3's SFC language concept and the executor,
> `mobile/lib/models/sfc_exec.dart`.
> **Read this before:** writing or reviewing a chart with parallel branches, debugging why a
> step's elapsed-time condition fires later or earlier than expected, or reasoning about action
> qualifiers on import.

---

## 1. The headline rule

**This is a true multi-token engine (an active-step SET, not a single token), and `STEP_T`
accumulates by the scan tick's `dtMs`, not by the step's owning task's configured period
(CL-4).**

`SfcRuntime.active: Map<String, Set<String>>` maps program name to its currently-active step-id
set. `stepElapsedMs: Map<String,int>` is keyed `'<prog>|<stepId>'`. Every currently-active step
runs its action **every scan it is active** (unconditional N-qualifier semantics - see §4), and
every active step's elapsed time advances by that scan's own `dtMs`, sourced from
`executeSfcPrograms`'s own parameter, which is the scan tick's `dtMs` - completely independent of
`PlcTask.periodMs`.

```
Wrong assumption: "a step in a 1000ms Periodic task accumulates STEP_T in 1000ms increments,
so STEP_T tells me wall-clock dwell time directly."

Correct: STEP_T only increments on the scan ticks where that step's owning task actually fires,
and by that tick's own dtMs (e.g. a 50ms fixed-scan tick), NOT by the task's periodMs. A program
in a 1000ms task running on a 100ms scan dwells 10x longer in wall time than STEP_T alone
suggests, unless periodMs and the scan's dtMs happen to coincide.
```

See [task-scheduling.md](./task-scheduling.md) for the task-period mechanics this interacts with.

---

## 2. Per-scan algorithm

`executeSfcPrograms` runs, per program, per scan tick:

1. If the active set is empty, seed it with the chart's `isInitial`-flagged step (or the first
   step in list order if none is flagged initial).
2. **For every currently-active step** (not just one - the whole active set): advance its
   `stepElapsedMs` by this scan's `dtMs`, then run its `actionSt` with `STEP_T` exposed as an
   extra variable to the ST/expression engine.
3. Snapshot the active set **before** evaluating any transition this scan - a transition never
   sees a step that was only activated earlier in this same scan's transition pass.
4. Iterate `prog.sfcTransitions` in **list order**, per transition kind:
   - `single`: one source step, one target step.
   - `parallelFork`: one source, multiple targets - all activated at once if it fires.
   - `parallelJoin`: multiple sources (all must be active and unconsumed this scan), one target.
   - A transition is eligible only if every source is in the pre-scan snapshot **and** none of its
     sources have already been consumed by an earlier-evaluated transition this scan. This
     "consumed" gating is exactly what makes list order function as priority for alternative
     divergence: the first eligible-and-true transition sharing a source consumes it, and any
     later sibling transition sharing that source becomes ineligible for this scan.
   - The condition is evaluated with `STEP_T` bound to the *first* source's elapsed time - for a
     join with multiple sources, only `sources.first`'s `STEP_T` is exposed to the condition.
   - A transition whose target(s) don't resolve to real steps is skipped **without consuming its
     sources** - a dangling reference never strands the chart mid-fire.
5. Apply: the new active set = snapshot minus every consumed source plus every added target. Any
   step newly entering the active set this scan gets `stepElapsedMs` reset to `0` - its action
   does **not** run in the same scan it activates (action-running happens in step 2, against the
   pre-scan active set); the first STEP_T-timed action run is on the *following* scan tick.

---

## 3. Alternative vs parallel divergence/convergence - token semantics

| Construct | Engine transition kind | Semantics |
|---|---|---|
| Alternative divergence | multiple `single` transitions sharing a `fromStepId` | Exactly one branch taken - first eligible-and-true wins by list order (§2), no separate priority field |
| Parallel fork | `parallelFork` | True AND-divergence - every target in `toStepIds` activates simultaneously in one scan's apply step, no partial-fork state |
| Parallel join | `parallelJoin` | Waits for **every** source to be active and unconsumed - the slowest branch gates the join; branches that finish early sit "parked" in the active set, their action still re-running every scan they remain active |

---

## 4. Action qualifiers - only N is implemented

`SfcStep.actionSt` is a single ST-statement blob with no qualifier field in the executor - only
**N** (non-stored: runs every scan while the step is active) is natively supported. Any imported
qualifier besides N (S/R/P/L/D/…) degrades to a no-op action with a warning at import time; there
is no native authoring path for any other qualifier.

---

## 5. Initial steps - no uniqueness enforcement

`isInitial` is a plain boolean flag used only to seed the first active-step set
(`firstWhere(...isInitial, orElse: () => sfcSteps.first)`). There is no IEC-standard "exactly one
initial step" enforcement in the executor: zero flagged steps falls back to the first step in list
order; multiple flagged steps silently use whichever comes first in list order (the implicit
behavior of `firstWhere`).

---

## What this means practically

### "My transition condition checks `STEP_T > 5000` but the step visibly dwelled way longer than 5 seconds - why did it fire late/early?"
`STEP_T` tracks accumulated *scan-tick* `dtMs` on ticks the owning task actually fired, not
wall-clock time against the task's configured period (CL-4, §1). Check the task's `periodMs`
against the scan's actual `dtMs` if the two diverge.

### "Why didn't my newly-activated step's action run this same scan?"
By design - a step's `stepElapsedMs` resets to 0 the scan it activates, and action execution runs
against the *pre-scan* active set (§2 step 2 vs step 5), so a step's first action run is on the
following scan tick.

### "Two of my alternative-divergence transitions both had true conditions - which one fired?"
The one listed first in `sfcTransitions` - list order is priority, enforced by the
first-transition-consumes-the-source gating (§2, §3).

### "My parallel join never fires even though most branches are done."
A `parallelJoin` requires **every** listed source to be active simultaneously - a branch that
finished and looped back out of the active set no longer satisfies the join; check that all
branches converge on the join's exact source set, not just "eventually reach it."

### "I imported a chart with `S`/`R` qualified actions - why do they do nothing now?"
Only the N qualifier executes natively; S/R/P/L/D degrade to a no-op with an import warning (§4).

---

## Related

- [structured-text.md](./structured-text.md) - the expression/statement engine that evaluates every transition condition and step action.
- [task-scheduling.md](./task-scheduling.md) - how a task's period and the scan's dtMs relate, which STEP_T's accumulation depends on.
- [index.md](./index.md) - domain hub.
