# SFC v2 Minors + "Batch Mix & Dispatch" Showcase — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design)
**Workstream:** SFC v2 follow-up — fix the deferred Minors from the SFC v2 whole-branch review, and add a default project that demonstrates both parallel (AND) and alternative (conditional) SFC branches.

## Goal

Two things in one branch:
1. Fix the five deferred Minors logged during the SFC v2 whole-branch review (two are correctness guards against silent data loss; one is a cosmetic layout gap; two are DRY nits).
2. Add a new default project, **"SFC — Batch Mix & Dispatch"**, whose SFC program uses a parallel (AND) fork/join AND an alternative (conditional) divergence — so the shipped SFC v2 features are visible out of the box. The existing linear "SFC — Batch Bottle Filling" stays as the simple example.

Everything additive/backward-compatible: no existing project's behaviour changes; the new project is appended to the default roster.

## Current behaviour (as-found)

- Authoring helpers live in `mobile/lib/models/sfc_edit.dart`; the pure 2D layout in `mobile/lib/models/sfc_layout2.dart`; the multi-token engine in `mobile/lib/models/sfc_exec.dart`.
- Default projects are defined in `mobile/lib/data/default_projects.dart` as `DefaultProjects.all()` (currently 12 projects). The existing `_sfcFillingProject()` ("SFC — Batch Bottle Filling") is a **purely linear** state machine (s0→…→s5→loop) — no parallel or alternative branches.
- The ST condition evaluator (`mobile/lib/models/st_expr.dart`) supports `AND` / `OR` / `NOT` / `XOR`, comparisons (`>=` etc.), `TRUE`/`FALSE`, and the `STEP_T` variable. Bottle-filling already uses `Fill_Level >= 95.0` and `STEP_T >= 3000`.
- No test hardcodes the default-project count as a literal — the relevant tests use `DefaultProjects.all().length` (relative) and iterate `all()` generically for round-trip/scan checks. (The lone literal `12` in `mqtt_codec_test.dart:257` is MQTT packet bytes, unrelated.) So adding a 13th project needs **no golden re-baseline**; it is automatically covered by the generic round-trip.

## The five Minors (from the SFC v2 final review)

1. **`addParallelBranch` on an alternative-divergence head silently drops the other alt arms.** In `sfc_edit.dart`, `addParallelBranch` strips *all* `single` outgoings of the anchor to make the fork the sole exit; if the anchor already had ≥2 singles (an alternative divergence), the other arms' bodies become orphaned. Reachable via the UI (Add alternative, then Add parallel on the same step). Degrades gracefully (no crash/dangling) but silently loses user structure.
2. **`deleteSfcStep` of a fork *source* leaves an orphaned join + branches.** Deleting a step that owns an outgoing `parallelFork` removes the fork transition (it references the step as `fromStepId`) but leaves the paired `parallelJoin` and the branch steps dangling as unreachable leaves. Mildly contradicts the "no dangling references after every edit" contract.
3. **`_parFrag` uneven-branch join connector uses a uniform bottom-y.** In `sfc_layout2.dart`, join connectors for parallel branches of unequal height are drawn from a single `branchBottomY` rather than each column's real exit-y (which `_altFrag` already does), leaving a small visual gap for shorter branches. Cosmetic.
4. **DRY:** `sfc_exec.dart` reconstructs the `'<prog>|<stepId>'` key string inline in ~4 places.
5. **DRY:** `sfc_layout2.dart` `_guardFrag` duplicates `_transFrag`'s non-goto branch verbatim.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. `sfc_edit.dart`, `sfc_layout2.dart`, `sfc_exec.dart`.
- Additive/backward-compatible: no existing default project's serialized form or scan sequence changes; the fork/join model invariant holds after every authoring edit (a `parallelFork.toStepIds` = its branch heads; the paired `parallelJoin.fromStepIds` = its branch tails; every referenced id resolves).
- Deterministic engine (scan-tick clock only).
- No "OpenPLC" / "Beremiz" / "CODESYS" / "RSLogix" branding; no reverse-engineering wording.

## Component A — Minor fixes

### A1. Guard `addParallelBranch` against alt-head data loss (`sfc_edit.dart`)
When the anchor step already has ≥2 `single` outgoing transitions (an alternative-divergence head), `addParallelBranch` must **NOT** strip them. Make it a **safe no-op** (return without mutating) in that case — mirroring the existing safe-no-op guard used when the outer join is indeterminate. A single linear successor (≤1 single out) is still converted to a fork as today.

- Test: from a chart where a step has 2 alternative arms, `addParallelBranch` on that step leaves the chart unchanged (both arms and their bodies intact) and `parseSfc` still succeeds with no dangling refs.

### A2. Remove the whole parallel construct when deleting a fork source (`sfc_edit.dart`)
`deleteSfcStepStructured` (the structured delete used by the editor) must detect when the target step owns an outgoing `parallelFork` and remove the **entire** parallel construct: the fork transition, every step reachable in its branch subgraph (reuse `_branchSubgraph`), and the paired `parallelJoin`. Nothing orphaned. If the fork's owning join is indeterminate, degrade safely (do not delete across an unknown boundary) rather than corrupting — consistent with the existing `deleteParallelBranch` guard.

- Test: deleting a fork-source step removes fork + branches + join with no orphaned steps/transitions; `parseSfc` succeeds with no dangling refs.

### A3. Per-column join connector in `_parFrag` (`sfc_layout2.dart`)
Change the parallel join connectors to originate from each branch column's actual exit-y (as `_altFrag` does at its convergence), instead of a uniform `branchBottomY`. Purely geometric; boxes unchanged.

- Test: for a parallel region with branches of unequal height, each join connector's start-y equals its own column's exit-y (not all equal); total bounds still contain all boxes; no step-box overlap.

### A4. `_stepKey` helper (`sfc_exec.dart`)
Extract `String _stepKey(String prog, String stepId) => '$prog|$stepId';` and use it at the ~4 sites that build `stepElapsedMs` keys. Pure refactor — no behaviour change (existing engine tests stay green as the byte guard).

### A5. `_guardFrag` delegates to `_transFrag` (`sfc_layout2.dart`)
`_guardFrag` calls into the shared non-goto trans-block construction of `_transFrag` (or a shared private helper) instead of duplicating it. Pure refactor — existing layout tests stay green.

## Component B — New default project `_sfcBatchMixProject()` (`default_projects.dart`)

Name **"SFC — Batch Mix & Dispatch"**, appended to `DefaultProjects.all()` as the 13th project. Periodic 200 ms task. One SFC program `BatchMix_SFC`.

### Chart (8 steps, 7 transitions)

Steps (ids stable):
- `s0` **IDLE** (initial) — reset: `Heater:=FALSE; Fill_Valve:=FALSE; Agitator:=FALSE; Dispatch_Pump:=FALSE; Drain_Valve:=FALSE; Temp_PV:=20.0; Fill_Level:=0.0;`
- `s1` **HEATING** (branch A head) — `Heater:=TRUE;`
- `s2` **HEAT_DONE** (branch A tail) — `Heater:=FALSE;`
- `s3` **FILLING** (branch B head) — `Fill_Valve:=TRUE;`
- `s4` **FILL_DONE** (branch B tail) — `Fill_Valve:=FALSE;`
- `s5` **MIXING** — `Agitator:=TRUE;`
- `s6` **DISPATCH** — `Agitator:=FALSE; Dispatch_Pump:=TRUE; Batch_Count:=Batch_Count + 1;`
- `s7` **REJECT** — `Agitator:=FALSE; Drain_Valve:=TRUE; Reject_Count:=Reject_Count + 1;`

Transitions (list order = alternative priority):
- `t0` `s0`→ **parallelFork** `toStepIds:[s1,s3]`, cond `Start_Cmd`
- `t1` `s1`→`s2` (single), cond `Temp_PV >= Temp_SP`
- `t2` `s3`→`s4` (single), cond `Fill_Level >= Fill_Target`
- `tj` **parallelJoin** `fromStepIds:[s2,s4]` → `toStepId:s5`, cond `TRUE`
- `t3` `s5`→`s6` (single), cond `STEP_T >= 3000 AND Quality_OK`
- `t4` `s5`→`s7` (single), cond `STEP_T >= 3000 AND NOT Quality_OK`
- `t5` `s6`→`s0` (single, GOTO/back-edge), cond `STEP_T >= 2000`
- `t6` `s7`→`s0` (single, GOTO/back-edge), cond `STEP_T >= 2000`

Parse shape: `IDLE → Par{[HEATING→HEAT_DONE],[FILLING→FILL_DONE]} join → MIXING → Alt{DISPATCH→(GOTO IDLE), REJECT→(GOTO IDLE)}`. The two alternative arms are first-true by list order and mutually exclusive via the `Quality_OK` / `NOT Quality_OK` terms.

### Tags
- Inputs: `Start_Cmd` (BOOL, SimulatedInput), `Quality_OK` (BOOL, SimulatedInput, default true), `Temp_PV` (FLOAT64, SimulatedInput, °C, start 20), `Fill_Level` (FLOAT64, SimulatedInput, %, start 0).
- Internal: `Temp_SP` (FLOAT64, 70), `Fill_Target` (FLOAT64, 90), `Batch_Count` (INT32, 0), `Reject_Count` (INT32, 0).
- Outputs (SimulatedOutput, BOOL): `Heater`, `Fill_Valve`, `Agitator`, `Dispatch_Pump`, `Drain_Valve`.

### Sim rules (make it live; heating slower than filling so the join visibly waits)
- `sim0`: `integrate` `Temp_PV`, `ratePerSec: 12`, `min 20 max 95`, cond `Heater == true`. (~4.2 s to reach 70)
- `sim1`: `integrate` `Fill_Level`, `ratePerSec: 30`, `min 0 max 100`, cond `Fill_Valve == true`. (~3.0 s to reach 90 — finishes first; FILL_DONE parks and waits for HEAT_DONE)

The IDLE action resets `Temp_PV`/`Fill_Level` each cycle so the loop repeats deterministically.

### HMI (`GridDashboard`)
Start_Cmd (PushbuttonSwitch, green), Quality_OK (ToggleSwitch, cyan), Temp_PV (DigitalGaugeDisplay, °C), Fill_Level (DigitalGaugeDisplay, %), LEDs for Heater/Fill_Valve/Agitator/Dispatch_Pump/Drain_Valve, StatusPill for Batch_Count and Reject_Count. No overflow at 320/360/1400.

## Data flow

Scan tick → `executeSfcPrograms` runs `BatchMix_SFC`: IDLE waits for `Start_Cmd`, forks to HEATING+FILLING (both active), each branch advances to its DONE step at its own pace, the join fires when both DONE steps are active, MIXING dwells then routes to DISPATCH or REJECT by `Quality_OK`, and the chosen arm loops back to IDLE. `applySimRules` drives `Temp_PV`/`Fill_Level`. Go-Online highlights the active-step set (two lit during the parallel phase). Nothing new persisted beyond the project definition.

## Error handling / edge cases

- A1/A2 guards degrade to safe no-op / safe scoped delete rather than corrupting — never leave a dangling ref.
- The showcase chart is well-structured (parses to Seq/Par/Alt with GOTO leaves); the join condition `TRUE` fires as soon as both branch tails are active.
- Sim `integrate` is clamped to `[min,max]`; IDLE resets keep the loop bounded and deterministic.

## Testing

- **A1:** alt-head `addParallelBranch` no-op + parse-clean (new case in `sfc_edit_parallel_test.dart`).
- **A2:** fork-source `deleteSfcStepStructured` removes the whole construct, no orphans, parse-clean (new case in `sfc_edit_parallel_test.dart`).
- **A3:** uneven parallel branch join-connector start-y per column (new case in `sfc_layout2_test.dart`).
- **A4/A5:** pure refactors — existing `sfc_multitoken_test.dart` / `sfc_layout2_test.dart` stay green (byte/behaviour guards).
- **Showcase (`sfc_batchmix_showcase_test.dart`, new):** the project round-trips losslessly (`toJson`/`fromJson`), `parseSfc` yields exactly one `ParRegion` (2 branches) and one `AltRegion` (2 arms), and a multi-scan run drives the chart through fork → both branches → join → MIXING → **DISPATCH** (with `Quality_OK` true) in one run and → **REJECT** (with `Quality_OK` false) in another, asserting the expected active-step sets and output tags at each phase; deterministic.
- Full gate: `flutter analyze` (clean), `flutter test` (all pass — report count), `flutter build web --release`.
- Round-trip/scan of `DefaultProjects.all()` (existing generic tests) automatically covers the new project.

## Files

- **Modify:** `mobile/lib/models/sfc_edit.dart` (A1, A2), `mobile/lib/models/sfc_layout2.dart` (A3, A5), `mobile/lib/models/sfc_exec.dart` (A4), `mobile/lib/data/default_projects.dart` (Component B).
- **Create:** `mobile/test/sfc_batchmix_showcase_test.dart`; new cases in `mobile/test/sfc_edit_parallel_test.dart` and `mobile/test/sfc_layout2_test.dart`.
- **Docs:** update `docs/sfc-branching.md` (note the Batch Mix & Dispatch showcase), the SFC bullet in `README.md`, and a short `ROADMAP.md` note.

## Non-goals / YAGNI

- No new SFC engine or layout features; no change to the existing linear bottle-filling project.
- No UI for choosing fork/branch counts beyond what SFC v2 already ships.
- No re-baseline artifact (there is no golden snapshot to bump).
