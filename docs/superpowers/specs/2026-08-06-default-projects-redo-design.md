# Default Projects Redo — 14 demos → 7 curated, fully tested — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-08-06

## Goal

Replace the current **14** shipped default projects with a curated **7** that
together showcase *every* feature the engine, the editors, the simulation
layer, the HMI palette and the protocol gateway support — and prove each of
them with an integration test plus a headless-browser pass.

- **In scope:** the contents of `mobile/lib/data/default_projects.dart` (split
  into a package), the seeding/backfill consequences, a test-support fixture
  library for the demo logic that is retired from the shipped catalog, the
  re-pointing of ~35 dependent test files, a mechanical feature-coverage guard
  test, and docs.
- **Out of scope (hard guard):** **no engine changes.** This workstream is
  content + tests only. If building a showcase reveals an engine gap
  (a missing block, a pin that behaves oddly, a renderer that overflows), it
  is **recorded** in `docs/DEFERRED.md` and the showcase is reshaped around
  it — it is *not* fixed here. Protocol maps are limited to configuration the
  model already supports.

## North-star decisions (from brainstorming)

1. **Seven projects, verbatim lineup.** The approved lineup in §1 is the
   spec's core and is not to be re-litigated during implementation. Content
   details inside each project are the implementer's, the *story and the
   required feature list* are not.
2. **Curation over accumulation.** The 14 grew one feature at a time; each new
   engine capability got its own tiny demo. The 7 are organised by *what a
   user wants to see* (one project per language, one "everything at once", one
   flagship plant, one control-theory lab), and every retired demo's coverage
   is re-homed inside one of them — proven by the §5 coverage matrix and the
   §8 guard test.
3. **Retire from the catalog, not from the test suite.** Demo builders whose
   *exact* logic is not absorbed move verbatim into
   `mobile/test/support/legacy_demo_projects.dart`. Engine tests that assert
   scan-index-exact behaviour keep their original harness (import swap only);
   tests whose behaviour a new project genuinely reproduces are re-pointed at
   the new project. The per-test decision is fixed in §6 — implementers do not
   choose.
4. **Non-destructive migration by construction.** The six new/rebuilt projects
   get **fresh `proj_` ids**, so `backfillNewDefaults` adds them on next launch
   without touching anything the user already has. `proj_all_water` keeps its
   id (§3).
5. **One file per project.** `default_projects.dart` (1,597 lines) becomes a
   barrel over `mobile/lib/data/default_projects/`, keeping
   `DefaultProjects.all()` and its import path byte-stable so none of the ~35
   dependent files change their imports.

## Why this shape (grounded in the codebase)

- `mobile/lib/data/default_projects.dart` is a single `abstract class
  DefaultProjects` whose `all()` (lines 33–48) returns 14 builders, with
  private ladder shorthands `_xic/_xio/_ote/_otl/_otu/_ton` (lines 6–17) and a
  `_emptyProject` scratch used for `defaultValueFor(...)` composite/array
  defaults (lines 22–31). Composite defaults that *do* depend on a project's
  own `structDefs`/`fbDefinitions` use a per-project scratch project (the
  `_allWaterProject` and `_noisyLevelProject` pattern, lines 704–713 and
  1335–1345). Both patterns survive the split.
- **Dart privacy is library-scoped**, so `_xic` cannot be shared across the
  new per-project files. The shorthands become **public top-level functions**
  in `mobile/lib/data/default_projects/builders.dart` (§2).
- `ProjectRepository.backfillNewDefaults` (`mobile/lib/data/project_repository.dart`
  lines 284–315) only **adds** defaults whose id is absent from the catalog;
  it never overwrites, never deletes, and records what it has seeded in the
  `seeded_default_ids` ledger (line 76). `resetToDefaults` (lines 263–274)
  wipes the catalog *and* the ledger, then backfills — so Reset to Defaults is
  the only path that yields exactly the new 7. `seedDefaultsIfEmpty`
  (lines 253–259) is only the "you deleted your last project" recovery path.
- The boot shell calls `backfillNewDefaults()` then falls back to
  `catalog.first` for the active project (`mobile/lib/screens/workspace_shell.dart`
  lines 347, 355). Several tests depend on that boot project's shape, which is
  why the ordering decision in §3 is load-bearing.
- `FbDefinition` already carries **both** body kinds — `stSource` and
  `ladderRungs` (`mobile/lib/models/project_model.dart` lines 217–263), with
  dispatch in `mobile/lib/models/fb_exec.dart` lines 56–77. A ladder-bodied FB
  is therefore expressible **today, with zero engine work** — it has simply
  never been showcased in a default project.
- `ProtocolSettings` (`mobile/lib/models/protocol_settings.dart` lines
  688–753) hangs off `PlcProject.protocols`, and every protocol has a
  `<X>Map.autoGenerate(PlcProject)` helper (e.g. `ModbusMap.autoGenerate`,
  `modbus_map.dart:106`; `OpcuaMap.autoGenerate`, `opcua_map.dart:96`). No
  default project sets `protocols` today, so the Gateway screen opens empty on
  a fresh install.
- `PlcProject.trends` (`List<TrendPen>`) and `HmiComponent.trendPens`
  (`List<TrendPenRef>`) are the two halves of the trend chart: the component
  references project pens **by tag path**. No default defines a pen, which is
  why `TrendChartDisplay` has never appeared in a shipped dashboard.
- `ensureSystemTag` (`mobile/lib/models/system_tags.dart:62`) injects the
  reserved `System` tag at **load** time (`workspace_shell.dart:388`), not at
  build time — so `DefaultProjects.all()` output has no `System` tag today.

## Global constraints

- **No engine changes.** Content (`lib/data/**`) + tests + docs only. Any file
  under `mobile/lib/models/`, `mobile/lib/services/` or `mobile/lib/screens/`
  touched by this workstream is a spec violation unless it is
  `default_projects.dart`'s own move.
- Zero `flutter analyze` warnings (run `flutter` from `mobile/`; binary at
  `/c/flutter/bin/flutter`).
- **Never break:** the generic serialization round-trip
  (`serialization_roundtrip_test.dart` iterates `all()`), the LD no-persist
  invariant (`ld_no_persist_test.dart`), project transfer/encode-decode
  (`project_transfer_test.dart`), backfill semantics
  (`project_repository_test.dart`, `persistence_integration_test.dart`), and
  `System`-tag injection.
- Every shipped project must be **self-consistent and falsifiable**: it runs
  under the real scan pipeline and its proof test would fail if the logic were
  zeroed out. No decorative blocks that are wired but never affect an output.
- Every tag referenced by a rung, an FBD wire, an SFC action/condition, an ST
  statement, an HMI binding, a sim rule or a trend pen must exist in the
  project (the `System.*` members excepted — see §4.6).
- `DefaultProjects.all()` keeps its name, its signature and its import path
  `package:soft_plc_mobile/data/default_projects.dart`.

---

## §1 — The approved lineup (verbatim core)

1. **Ladder — Conveyor Line** (LD): rebuilt conveyor absorbing Basic Motor
   Start Stop's beginner seal-in rungs as its opening rungs; must collectively
   cover: contacts normal/negated/rising/falling, coils
   normal/negated/set/reset/pulse(rising/falling), TON, TOF, CTU, compare (at
   least GT/LT/EQ), math ADD/SUB + MOVE, OR branches, and a **LADDER-BODIED
   custom FB call** (currently showcased nowhere in defaults).
2. **FBD — HVAC Zone Controller**: refreshed; across its networks covers the
   full FBD palette meaningfully: NOT/AND/OR, ADD/SUB/MUL/DIV,
   GT/LT/GE/LE/EQ/NE (a representative spread), LIMIT, SEL, TON/TOF,
   CTU/CTD/CTUD (at least CTU+CTD or CTUD), R_TRIG/F_TRIG, TP,
   CONST/TAG_INPUT/TAG_OUTPUT, plus an **ST-bodied custom FB**; absorbs Tank
   Level Simulation's fill/drain deadband as a second network + dashboard.
3. **SFC — Batch Production**: merges Bottle Filling + Batch Mix: linear steps
   with STEP_T dwells, parallel fork/join, quality-gated alternative
   divergence.
4. **ST — Reactor Temperature Controller**: refreshed; IF/ELSIF/ELSE deadband
   control, gains an **INT16 array + DUT usage** and the **Hysteresis
   ST-bodied FB** (moved from Noisy Level).
5. **All Languages — Water Treatment Plant**: KEPT with id `proj_all_water`
   and refreshed lightly (it anchors the biggest smoke test — minimize churn;
   §4.5 documents exactly what changes).
6. **Flagship — Production Line** (NEW, "lots of moving parts"): multi-area
   plant — infeed conveyors (LD), blending/process with PID (FBD), batch
   sequencing with parallel branches (SFC), safety/supervision (ST); ≥3 HMI
   dashboards INCLUDING the never-showcased features: **trend chart widget
   with pens** (analog + BOOL step lane), **TextInputField**, a **System-tag
   diagnostics panel**; heavy sim layer (integrate, firstOrderLag, deadTime,
   noise, pulse; valve curve if natural); custom FBs of **BOTH** kinds (ST +
   ladder bodied); three tasks (Startup once, Continuous, Periodic);
   pre-configured protocol maps (at least Modbus + OPC UA enabled with
   auto-generated maps) so the gateway shows live content out of the box.
7. **Process Control Lab**: consolidates PID tank loop (autotune-compatible),
   MIMO two-zone + decoupler, cascade tanks with deadTime, noisy measurement +
   filtering — as multiple programs + multiple dashboards in ONE project.

---

## §2 — File organization

```
mobile/lib/data/default_projects.dart          # barrel — DefaultProjects.all()
mobile/lib/data/default_projects/
  builders.dart                                # shared shorthands + scratch helpers
  ladder_conveyor_line.dart                    # 1
  fbd_hvac_zone.dart                           # 2
  sfc_batch_production.dart                    # 3
  st_reactor_control.dart                      # 4
  all_water_treatment.dart                     # 5
  flagship_production_line.dart                # 6
  process_control_lab.dart                     # 7
```

**Barrel** (`default_projects.dart`) shrinks to imports + the class:

```dart
abstract class DefaultProjects {
  static List<PlcProject> all() => [
    ladderConveyorLineProject(),
    fbdHvacZoneProject(),
    sfcBatchProductionProject(),
    stReactorControlProject(),
    allWaterTreatmentProject(),
    flagshipProductionLineProject(),
    processControlLabProject(),
  ];
}
```

**`builders.dart`** hosts what was private on the class, promoted to public
top-level functions (Dart privacy is per-library, so `_xic` cannot cross
files). Names are `ld`-prefixed to avoid colliding with model identifiers:

| was | becomes | notes |
|---|---|---|
| `_xic(v,[c])` | `ldXic` | contact, `modifier: 'normal'` |
| `_xio(v,[c])` | `ldXio` | contact, `'negated'` |
| — | `ldXicRising` / `ldXicFalling` | contact, `'rising'` / `'falling'` |
| `_ote(v,[c])` | `ldOte` | coil, `'normal'` |
| — | `ldOteNeg` | coil, `'negated'` |
| `_otl` / `_otu` | `ldOtl` / `ldOtu` | coil, `'set'` / `'reset'` |
| — | `ldOsr` / `ldOsf` | coil, `'rising'` / `'falling'` (one-scan pulse) |
| `_ton(v,ms,[c])` | `ldTon` | block `TON`, `presetMs` |
| — | `ldTof`, `ldCtu` | block `TOF`, `CTU` |
| — | `ldCmp(type, a, b)` | block ∈ `GT LT GE LE EQ NE`, `operandA/operandB` |
| — | `ldMath(type, dest, a, b)` / `ldMove(dest, src)` | block ∈ `ADD SUB MUL DIV MOVE` |
| — | `ldFbCall(fbName, instance, pins)` | block whose `blockType` is an FB name, `variable` = instance path, `pinBindings` = pin→tag/literal |
| `_emptyProject` | `emptyScratchProject` | for `defaultValueFor(..., 'TIMER'/'INT16', n)` |
| (inline pattern) | `scratchProjectFor({structDefs, fbDefinitions})` | for DUT/FB-instance default values |

`buildRung` / `BranchSpec` continue to come from
`mobile/lib/models/ld_graph.dart` — unchanged.

**Doc-comment convention (existing, kept):** every project file opens with a
library-level doc comment stating (a) the story, (b) the exact feature list it
is the showcase for, (c) why the logic is falsifiable, and (d) the path of its
proof test — exactly as `_fbdPidTankLevelProject` (lines 972–989) and
`_noisyLevelProject` (lines 1293–1317) do today.

---

## §3 — Ids, names, ordering, and migration behavior

### Ids and names

| # | Name (unified "«Language» — «Story»" style) | id | replaces |
|---|---|---|---|
| 1 | `Ladder — Conveyor Line` | `proj_ld_conveyor_line` | `proj_motor`, `proj_ld_conveyor` |
| 2 | `FBD — HVAC Zone Controller` | `proj_fbd_hvac_zone` | `proj_fbd_hvac`, `proj_tank` |
| 3 | `SFC — Batch Production` | `proj_sfc_batch_production` | `proj_sfc_filling`, `proj_sfc_batchmix` |
| 4 | `ST — Reactor Temperature Controller` | `proj_st_reactor_control` | `proj_st_reactor` |
| 5 | `All Languages — Water Treatment Plant` | **`proj_all_water`** (retained) | — |
| 6 | `Flagship — Production Line` | `proj_flagship_line` | — (new) |
| 7 | `Process Control Lab` | `proj_process_lab` | `proj_tank_level_pid`, `proj_cascade_tanks`, `proj_noisy_level`, `proj_mimo_two_zone` |

Retired ids (no longer in `all()`): `proj_motor`, `proj_tank`,
`proj_st_reactor`, `proj_ld_conveyor`, `proj_fbd_hvac`, `proj_sfc_filling`,
`proj_sfc_batchmix`, `proj_tank_level_pid`, `proj_batch_counter`,
`proj_pulse_output`, `proj_cascade_tanks`, `proj_noisy_level`,
`proj_mimo_two_zone`.

**Why fresh ids rather than reusing the old ones:** `backfillNewDefaults`
never overwrites an id already in the catalog. Reusing `proj_ld_conveyor` for
the rebuilt conveyor would mean existing installs *silently keep the old
content forever*. A fresh id makes the rebuilt project arrive as a genuinely
new default, additively, on next launch.

### Ordering (load-bearing)

`all()[0]` is **`Ladder — Conveyor Line`**. The boot shell activates
`catalog.first`, so `all()[0]` is the project a first-run user lands in and
the project several shell tests scaffold against. Binding constraints on it:

- It is a `LadderLogic` project (several `.first`-based tests open the LD
  editor and the ST editor's quick-insert row against the boot project).
- Its **first tag is named `Start_PB`** — `persistence_integration_test.dart`
  (L96, L210) asserts the boot-active project's first tag is `Start_PB`. The
  conveyor absorbs the motor's beginner start/stop rungs, so this is natural,
  not a contrivance.

`all().last` is **`Process Control Lab`** — `project_repository_test.dart:150`
and `persistence_integration_test.dart:226` use `all().last` as "a genuinely
new default the catalog is missing"; any project works, this just fixes it.

### Migration behavior (must be documented, not changed)

| Install state | On next launch |
|---|---|
| **Fresh install / after Reset to Defaults** | Catalog + ledger empty → all **7** seeded. Exactly the new lineup. |
| **Existing install (has some/all of the 14)** | `backfillNewDefaults` adds the **6 new ids**. The 13 retired defaults **remain on device as ordinary user projects** (harmless; their ledger entries are inert). `proj_all_water` is already in the catalog, so the **refreshed** water content does **not** reach this install. |
| **Existing install, user runs Reset to Defaults** | Catalog + ledger cleared, then backfilled → exactly the new **7**, including the refreshed `proj_all_water`. |
| **Corrupt ledger** | `_decodeStringSet` degrades to `{}` → every default not currently in the catalog is re-added. Unchanged. |

Two consequences the spec accepts deliberately: (a) existing installs
temporarily show up to 20 projects until the user resets — the alternative
(deleting user-visible projects) is unacceptable; (b) **the `proj_all_water`
refresh is invisible to existing installs**, which is an independent reason to
keep its changes minimal (§4.5).

---

## §4 — The seven projects

Common to all seven: `layoutType: 'GridDashboard'`; `accentColor` drawn from
`{cyan, green, red, amber, teal}`; `gridSpanWidth` ∈ `{1,2,3,4}`; every
program is referenced by at least one enabled task.

### §4.1 — `proj_ld_conveyor_line` — "Ladder — Conveyor Line"

Controller `PLC_LINE`, `scanPeriodMs: 100`. One `LadderLogic` program
`ConveyorLine_LD`. Story: a two-zone conveyor line — the operator starts the
line (beginner seal-in, absorbed from Basic Motor Start Stop), zone 1 runs
under interlocks, zone 2 is driven by a **ladder-bodied `MotorStarter` FB**,
parts are counted and a jam is detected.

**Tags** (first tag `Start_PB`): `Start_PB`, `Stop_PB`, `EStop_OK`,
`Overload_OK`, `Photo_Eye`, `Manual_Jog` (SimulatedInput BOOL);
`Line_Latch`, `Part_Present`, `Part_Edge`, `Zone2_Request` (Internal BOOL);
`Zone1_Motor`, `Zone2_Motor`, `Belt_Jammed`, `Line_Fault` (SimulatedOutput
BOOL); `JamTimer`, `StopDelay` (`TIMER`, `defaultValueFor(emptyScratchProject,
'TIMER', 0)`); `Part_Count`, `Batch_Target`, `Parts_Remaining`,
`Shift_Total` (INT32); `Zone2Starter` (`dataType: 'MotorStarter'`, value from
`scratchProjectFor(fbDefinitions: [motorStarterFb])`); `Line_DUT`
(`Line_DUT` struct: `Running` BOOL, `Faulted` BOOL, `Speed` INT32).

**Rungs** (each rung's required element in bold):

| # | Rung | Covers |
|---|---|---|
| 0 | `Start_PB`/**branch** `Line_Latch` — `Stop_PB`(**XIO**) — `EStop_OK` — `Overload_OK` → **OTE** `Line_Latch` | contact normal + negated, coil normal, **OR branch** (`BranchSpec`) |
| 1 | `Line_Latch` — `EStop_OK` — **XIO** `Belt_Jammed` → OTE `Zone1_Motor` | permissive chain (absorbed motor rung 1) |
| 2 | **XIO** `EStop_OK` → **OTL** `Line_Fault`; **rising** `Start_PB` → **OTU** `Line_Fault` | coil **set** / **reset**, contact **rising** |
| 3 | **falling** `Photo_Eye` → **OSR pulse coil** `Part_Edge` | contact **falling**, coil **rising (pulse)** |
| 4 | `Part_Edge` → **ADD** `Part_Count := Part_Count + 1`; **ADD** `Shift_Total` | math **ADD** |
| 5 | `Line_Latch` → **SUB** `Parts_Remaining := Batch_Target - Part_Count` | math **SUB** |
| 6 | **GT** `Part_Count > 0` → **CTU** `PartCtu` (PV `Batch_Target`) | compare **GT**, **CTU** |
| 7 | **LT** `Parts_Remaining < 1` → **MOVE** `0 → Part_Count`; **OTE-negated** `Zone2_Request` | compare **LT**, **MOVE**, coil **negated** |
| 8 | **EQ** `Part_Count = Batch_Target` → OTE `Zone2_Request` | compare **EQ** |
| 9 | `Zone1_Motor` — **XIO** `Part_Present` → **TON** `JamTimer` (5000 ms); `JamTimer.DN` → OTL `Belt_Jammed`; `Photo_Eye` → OTU `Belt_Jammed` | **TON** |
| 10 | **XIO** `Line_Latch` → **TOF** `StopDelay` (3000 ms) → OTE `Zone2_Motor` hold-off | **TOF** |
| 11 | `Zone1_Motor` → **FB call** `MotorStarter` instance `Zone2Starter`, pins `Run←Zone2_Request`, `Permit←EStop_OK`, `Out→Zone2_Motor` | **ladder-bodied custom FB** |
| 12 | `Zone1_Motor` → MOVE into `Line_DUT.Running`; `Line_Fault` → MOVE into `Line_DUT.Faulted` | DUT member write |

**`MotorStarter` FB — ladder-bodied** (`FbDefinition(stSource: '',
ladderRungs: [...])`, vars: `Run` IN BOOL, `Permit` IN BOOL, `Seal` internal
BOOL, `Out` OUT BOOL). Body: one rung — `Run`/branch `Seal` — `Permit` →
OTE `Seal`; second rung — `Seal` — `Permit` → OTE `Out`. Its per-instance
latch state living inside `Zone2Starter` (not a global) is the headline the
proof test asserts.

**Sim:** `pulse` on `Photo_Eye` gated on `Zone1_Motor` (on 2000 / off 2500 ms)
— parts every ~4.5 s so the 5 s jam threshold only trips when parts stop.

**Tasks:** `LineTask` (Continuous, 100 ms).
**HMI** (`hmi_ld_conveyor_line`): START/STOP `PushbuttonSwitch`, `Manual JOG`
pushbutton, E-Stop/Overload `ToggleSwitch`, zone-1/zone-2 `LedIndicatorLight`,
`Part_Count`/`Parts_Remaining` `DigitalGaugeDisplay`, `Batch_Target`
`NumericSliderInput`, JAM + LINE FAULT `StatusPillDisplay`.

### §4.2 — `proj_fbd_hvac_zone` — "FBD — HVAC Zone Controller"

Controller `PLC_HVAC`, `scanPeriodMs: 100`. One `FunctionBlockDiagram` program
`HvacZone_FBD` with **seven networks** (`fbdNetworks`, `FbdBlock.network`).
Data crosses networks through tags, never wires (the existing
`WaterQuality_FBD` precedent).

| Net | Comment | Blocks |
|---|---|---|
| 0 | Occupancy & enable | `TAG_INPUT` ×2, `NOT`, `AND`, `OR`, `TAG_OUTPUT` |
| 1 | Effective setpoint math | `CONST`, `ADD`, `SUB`, `MUL`, `DIV`, `LIMIT`, `SEL` (`SEL(G=Occupied, IN0=Setback_SP, IN1=Comfort_SP)`) |
| 2 | Comparator bank | `GT`, `LT`, `GE`, `LE`, `EQ`, `NE` → six BOOL tags |
| 3 | Staging timers & edges | `TON` (heat stage delay), `TOF` (fan run-on), `TP` (purge one-shot), `R_TRIG`, `F_TRIG` |
| 4 | Cycle counters | `CTU` (heat starts), `CTD` (filter life countdown), `CTUD` (occupancy in/out) |
| 5 | Tank fill/drain deadband **(absorbed from Tank Level Simulation)** | `SUB`/`ADD` deadband, `LT`/`GT`, `AND` ×2, high-alarm `GT` → `Fill_Valve`, `Drain_Valve`, `High_Alarm` |
| 6 | Custom FB | `TAG_INPUT` → `SetpointShift` (ST-bodied FB instance `ZoneShift`) → `TAG_OUTPUT` |

**`SetpointShift` FB — ST-bodied**: vars `Occupied` IN BOOL, `Base` IN
FLOAT64 (init 22.0), `Setback` IN FLOAT64 (init 4.0), `Sp` OUT FLOAT64.
Body: `IF Occupied THEN Sp := Base; ELSE Sp := Base - Setback; END_IF;`

**Sim:** `integrate` heat/cool on `Room_Temp` gated on `Heat_Cmd`/`Cool_Cmd`,
`integrate` ambient drift when both false (carried over verbatim);
`integrate` fill/drain on `Level_PV` gated on `Fill_Valve`/`Drain_Valve`
(absorbed from Tank Level Simulation).

**Tasks:** `HvacControlTask` (Continuous, 100 ms).
**HMI:** two screens — `hmi_fbd_hvac_zone` (temperature/occupancy/staging) and
`hmi_fbd_hvac_tank` (absorbed tank dashboard: `TankGraphicDisplay`,
`NumericSliderInput` setpoint, fill/drain/high-alarm LEDs, level gauge).

### §4.3 — `proj_sfc_batch_production` — "SFC — Batch Production"

Controller `PLC_BATCH`, `scanPeriodMs: 200`. One `SequentialFunctionChart`
program `BatchProduction_SFC` merging Bottle Filling and Batch Mix into one
chart:

- **Linear segment with `STEP_T` dwells** (from Bottle Filling): `IDLE` →
  `WAIT_CONTAINER` → `FILLING` (exit on `Fill_Level >= 95.0`) → `CAPPING`
  (`STEP_T >= 3000`) → `EJECTING` (`STEP_T >= 2000`) → `COUNT`.
- **Parallel fork/join** (from Batch Mix): a `parallelFork` transition off
  `PREP` with `toStepIds: ['HEATING', 'CHARGING']`, each branch ending in a
  `*_DONE` step, rejoined by a `parallelJoin` with `fromStepIds:
  ['HEAT_DONE','CHARGE_DONE']` into `MIXING`.
- **Quality-gated alternative divergence**: two `'single'` transitions off
  `MIXING` — `STEP_T >= 3000 AND Quality_OK` → `DISPATCH`, and
  `STEP_T >= 3000 AND NOT Quality_OK` → `REJECT` — each ending in its own
  one-shot count step (`COUNT_OK` / `COUNT_REJ`) returning to `IDLE`.

**Tags:** `Start_Cmd`, `Quality_OK`, `Container_Present` (SimulatedInput);
`Temp_PV`, `Fill_Level` (SimulatedInput FLOAT64); `Temp_SP`, `Fill_Target`,
`Sfc_Step`, `Batch_Count`, `Reject_Count`, `Filled_Count` (Internal);
`Heater`, `Fill_Valve`, `Agitator`, `Cap_Solenoid`, `Eject_Cyl`,
`Dispatch_Pump`, `Drain_Valve` (SimulatedOutput BOOL).
**Sim:** `integrate` on `Temp_PV` gated on `Heater`; `integrate` on
`Fill_Level` gated on `Fill_Valve`.
**Tasks:** `BatchSequenceTask` (Periodic, 200 ms).
**HMI:** `hmi_sfc_batch_production` — start pushbutton, quality toggle, temp +
fill gauges, per-actuator LEDs, dispatched/rejected pills, `Sfc_Step` pill.

### §4.4 — `proj_st_reactor_control` — "ST — Reactor Temperature Controller"

Controller `PLC_ST`, `scanPeriodMs: 100`. Keeps the existing deadband
controller (`IF Auto_Mode … IF/ELSIF/ELSE … END_IF` + alarm assignments,
lines 265–289) verbatim as `ReactorTemp_ST`, and **gains**:

- an **INT16 array**: `Recipe_Setpoints`, `dataType: 'INT16'`,
  `arrayLength: 8`, `defaultValueFor(emptyScratchProject, 'INT16', 8)`; the ST
  body reads `Recipe_Setpoints[0]` into `Temp_SP` on the recipe-select branch
  (array indexing is inside the supported expression subset);
- a **DUT**: `Reactor_DUT` (`Heating` BOOL, `Cooling` BOOL, `Cycles` INT32),
  tag `Reactor_Status`, written by ST member assignments
  (`Reactor_Status.Heating := Heat_Cmd;` …);
- the **`Hysteresis` ST-bodied FB moved verbatim from Noisy Level** (name,
  five vars, `stSource` unchanged), instantiated as `TempAlarmHyst` and called
  from a small `ReactorAlarm_FBD` program (an FBD program is required — ST has
  no FB-call syntax in the supported subset) that wires `Temp_PV` +
  CONST High/Low into the instance and its `Out` to `Alarm_Latched`.

**Sim:** the three existing rules (heat `integrate`, cool `integrate`, ambient
`firstOrderLag`) unchanged.
**Tasks:** `TempControlTask` (Continuous, 100 ms, both programs).
**HMI:** the existing dashboard plus `Recipe_Setpoints[0]` gauge and the
`Alarm_Latched` pill.

### §4.5 — `proj_all_water` — "All Languages — Water Treatment Plant" (KEPT)

This project anchors `app_responsive_smoke_test`, `ld_exec_integration_test`,
`fbd_exec_integration_test` ×2, `st_exec_integration_test`,
`sfc_exec_integration_test` ×2 and `memory_responsive_test`. **Minimize
churn.** The complete, exhaustive change list:

1. `name` is already `All Languages — Water Treatment Plant` — **no change**.
2. `id` `proj_all_water` — **no change**.
3. **No** change to any tag name, tag path, `structDefs`, program name,
   rung, FBD block/wire/network, SFC step/transition, sim rule, task or HMI
   component id/binding.
4. The only edits: the four `PlcProgram.description` strings and the
   `HmiScreenDef.title` are left as-is; a **library-level doc comment** is
   added to `all_water_treatment.dart` naming its story, its four-language
   coverage and its proof tests (the doc-comment convention this project
   currently lacks).

In other words: **`proj_all_water` is moved to its own file and documented;
its data is byte-identical.** Its `toJson()` output must be unchanged — the
implementation task asserts this by comparing against a snapshot taken before
the split.

### §4.6 — `proj_flagship_line` — "Flagship — Production Line"

Controller `PLC_LINE01`, `scanPeriodMs: 100`. Four areas, four programs, one
language each:

| Program | Language | Role |
|---|---|---|
| `Infeed_LD` | LadderLogic | Two infeed conveyors, seal-in + jam TON + part `CTU`; calls the **ladder-bodied `ZoneStarter` FB** for conveyor 2 |
| `Blend_FBD` | FunctionBlockDiagram | Recipe blending: **`PID`** on `Blend_Level` → `Blend_Valve`, `LIMIT` clamp, `SEL` recipe pick, ratio `MUL`/`DIV`; calls the **ST-bodied `Scale` FB** (`Out := (In - InLo) * (OutHi - OutLo) / (InHi - InLo) + OutLo;`) |
| `Batch_SFC` | SequentialFunctionChart | Charge → **parallel fork** (heat ∥ agitate) → **join** → hold (`STEP_T`) → discharge → count |
| `Safety_ST` | StructuredText | Supervisory permissives, alarm aggregation, `System`-derived health flags, run-hours accumulation |

**Tasks (exactly three, per the approved lineup):**
`StartupTask` (`type: 'Startup'`, runs once: initialises recipe + counters),
`MainTask` (`type: 'Continuous'`, 100 ms: `Infeed_LD`, `Blend_FBD`,
`Safety_ST`), `BatchTask` (`type: 'Periodic'`, 250 ms: `Batch_SFC`).

**Custom FBs — both kinds:** `Scale` (ST-bodied) and `ZoneStarter`
(ladder-bodied — seal-in + a scoped `TON` start-delay whose `ACC` lives inside
the instance).

**Sim layer (heavy — 8/8 behaviors are reached with §4.7's help; this project
alone contributes 7):**

| Rule | behavior | notes |
|---|---|---|
| Blend inflow | `integrate` | `sourcePath: 'Blend_Valve'`, `refValue: 100`, **`valveCurve: 'equalPercentage'`** (the natural fit for a blend trim valve) |
| Blend outflow | `integrate` | constant draw the PID must hold against |
| Tank thermal | `firstOrderLag` | `sourcePath: 'Steam_Temp'`, `tauSec: 20` |
| Downstream transport | `deadTime` | `sourcePath: 'Blend_Level'`, `tauSec: 4.0` → `Line_Transfer` |
| Level transmitter | `noise` | `sourcePath: 'Blend_Level'`, `targetValue: 1.5`, `noiseDistribution: 'gaussian'`, `driftAmplitude`/`driftPeriodSec` set |
| Infeed photo eyes | `pulse` | gated on each conveyor motor |
| Air pressure OK | `setWhileCondition` | true while the compressor output is on **(behavior showcased nowhere today)** |
| Guard-door interlock | `delayedSet` | `delayMs: 2000` after the door closes **(behavior showcased nowhere today)** |

**`System` tag:** the builder calls `ensureSystemTag(project)` **before**
generating protocol maps, so the flagship ships with the reserved `System` tag
present. This makes the diagnostics dashboard bind in headless tests and puts
`System.*` leaves into the auto-generated maps as `ReadOnly`
(`ModbusMap.autoGenerate` / `OpcuaMap.autoGenerate` already special-case the
reserved tag). Members bound on the dashboard: `System.Running`,
`System.FirstScan`, `System.ScanCount`, `System.ScanTimeMs`,
`System.MaxScanTimeMs`, `System.UptimeMs`, `System.Fault`.

**Trend pens** (`PlcProject.trends`): `Blend_Level` (cyan, analog),
`Blend_Valve` (amber, analog), `Blend_Temp` (teal, analog),
`Batch_Running` (green, **BOOL → renders as a step lane**),
`Alarm_Active` (red, BOOL).

**Three HMI dashboards:**

| Screen | Components |
|---|---|
| `hmi_flagship_overview` | Line start/stop `PushbuttonSwitch`, E-Stop `ToggleSwitch`, per-area `LedIndicatorLight`, `Blend_Level` `TankGraphicDisplay`, `Blend_Valve` `DigitalGaugeDisplay`, `Blend_SP` `NumericSliderInput`, `StatusPillDisplay` alarm |
| `hmi_flagship_trends` | One `TrendChartDisplay` (span 4, `windowMs: 120000`, `trendPens`: the three analog pens) + one `TrendChartDisplay` (span 4, the two BOOL pens → step lanes) |
| `hmi_flagship_diagnostics` | **`TextInputField`** ×2 (`Recipe_Name` STRING, `Batch_Target` INT32) + the System-tag panel (`DigitalGaugeDisplay` ScanCount/ScanTimeMs/UptimeMs, `LedIndicatorLight` Running/FirstScan, `StatusPillDisplay` Fault) |

**Protocol maps:**

```dart
project.protocols = ProtocolSettings(
  gatewayUrl: kDefaultGatewayUrl,
  modbus: ModbusProtocolConfig(enabled: true, port: 502,
      map: ModbusMap.autoGenerate(project), wordSwap: false, byteSwap: false,
      unitId: 255, framing: 'tcp'),
  opcua: OpcUaProtocolConfig(enabled: true, port: 4840,
      namespaceUri: 'urn:softplc:${project.id}',
      map: OpcuaMap.autoGenerate(project), securityModes: ['None'],
      credentials: [], allowAnonymous: true),
);
```

Assigned **after** the project object is built (the `autoGenerate` helpers take
the project), following the two-phase local-variable pattern. `ProtocolSettings.defaults(p)`
is deliberately **not** used: it returns all nine protocols with
`enabled: false`, which would not "show live content out of the box".

> **Verification gate (must pass before `enabled: true` ships):** every host's
> `start()` checks `enabled` at start time and is invoked from the Gateway
> screen toggle — nothing in `workspace_shell.dart` auto-starts a host on
> project load. The implementation task **re-confirms this by test** (boot the
> shell on the flagship; assert no socket is bound). If auto-start is found,
> ship the maps with `enabled: false`, record the finding, and note it in
> `docs/DEFERRED.md` — do not change host code (no-engine-changes rule).

### §4.7 — `proj_process_lab` — "Process Control Lab"

Controller `PLC_LAB`, `scanPeriodMs: 500`. **Four programs, four dashboards,
one project.** Each area reproduces a retired demo's plant and control
**verbatim in tag names, sim-rule parameters and FBD topology** so the
re-pointed engine tests (§6) keep their meaning. The four tag namespaces are
verified disjoint — no renaming is needed:

| Area / program | HMI screen | Reproduces | Tags (verbatim) |
|---|---|---|---|
| `LevelPID_FBD` | `hmi_lab_pid` | `proj_tank_level_pid` — `PID` with Kp 1.0 / Ki 0.2 / Kd 0.05, inflow `integrate` scaled by `Valve_CV`, constant outflow | `Level_PV`, `Level_SP`, `Valve_CV` |
| `TwoZone_FBD` | `hmi_lab_mimo` | `proj_mimo_two_zone` — 2 `PID` + static decoupler (`MUL`/`SUB`/`LIMIT`), coupled `firstOrderLag` plant | `Heater_A/B`, `Temp_A/B`, `SP_A/B`, `Amb`, `u_A/u_B` |
| `CascadeMonitor_FBD` | `hmi_lab_cascade` | `proj_cascade_tanks` — `deadTime` transport line (`tauSec: 3.0`) between two integrating tanks | `Feed_Valve`, `Tank_A_Level`, `Transfer_Line`, `Tank_B_Level` |
| `NoisyLevelMonitor_FBD` | `hmi_lab_noise` | `proj_noisy_level` — `noise` measurement + `firstOrderLag` filter | `Fill_Valve`, `Tank_Level`, `Level_Meas`, `Level_Filtered` |

Sim-rule **ids** are re-namespaced per area (`pid_sim0`, `mimo_sa0`, …) since
ids must be unique within a project; every *behavioural* field
(`behavior`, `ratePerSec`, `tauSec`, `sourcePath`, `refValue`, `targetValue`,
`minValue`, `maxValue`) is copied verbatim.

**Autotune compatibility:** `resolvePidLoop` walks a *program's* blocks and
wires, so keeping each PID in its own program preserves autotune resolution.
`pid_autotune_screen_test` prefills PV `Level_PV` / CV `Valve_CV` — see the
§7 risk row on the screen's prefill heuristic.

**Tasks:** `LabTask` (Continuous, 500 ms) running all four programs.
The `Hysteresis` FB does **not** live here — it moves to §4.4.

---

## §5 — Feature → project coverage matrix

"Before" = showcased by at least one of today's 14 defaults. The rule this
matrix enforces: **no cell may go from ✓ to ✗.**

### FBD block types — all 27 (`kFbdBuiltinBlockTypes`, `fbd_pins.dart:118-126`)

| Block | Before | After (project) |
|---|---|---|
| `TAG_INPUT`, `TAG_OUTPUT`, `CONST` | ✓ | ✓ all FBD projects |
| `NOT`, `AND`, `OR` | `NOT`,`AND` ✓ / `OR` ✗ | ✓ HVAC net 0 |
| `ADD`, `SUB` | ✓ | ✓ HVAC net 1 |
| `MUL` | ✓ (MIMO) | ✓ HVAC net 1, Lab MIMO, Flagship |
| `DIV` | ✗ | ✓ HVAC net 1, Flagship `Scale` ratio |
| `GT`, `LT` | ✓ | ✓ HVAC net 2 |
| `GE`, `LE`, `EQ`, `NE` | ✗ | ✓ HVAC net 2 |
| `LIMIT` | ✓ (MIMO) | ✓ HVAC net 1, Lab MIMO, Flagship |
| `SEL` | ✗ | ✓ HVAC net 1, Flagship recipe pick |
| `TON`, `TOF` | ✗ (FBD-side) | ✓ HVAC net 3 |
| `TP` | ✓ (`proj_pulse_output`) | ✓ HVAC net 3 |
| `CTU` | ✓ (`proj_batch_counter`) | ✓ HVAC net 4 |
| `CTD`, `CTUD` | ✗ | ✓ HVAC net 4 |
| `R_TRIG` | ✓ (`proj_pulse_output`) | ✓ HVAC net 3 |
| `F_TRIG` | ✗ | ✓ HVAC net 3 |
| `PID` | ✓ | ✓ Lab ×3, Flagship `Blend_FBD` |
| custom FB block (name shadows built-ins) | ✓ (`Hysteresis`) | ✓ HVAC net 6, ST Reactor, Flagship |

### LD elements (`ld_exec.dart`)

| Element | Before | After |
|---|---|---|
| contact `normal` / `negated` | ✓ | ✓ Conveyor, Flagship, Water |
| contact `rising` / `falling` | ✗ | ✓ Conveyor rungs 2–3 |
| coil `normal` / `set` / `reset` | ✓ | ✓ Conveyor rungs 0, 2, 9 |
| coil `negated` | ✗ | ✓ Conveyor rung 7 |
| coil `rising` (pulse) / `falling` | ✗ | ✓ Conveyor rung 3 (+ falling variant) |
| OR branch (`BranchSpec`) | ✓ | ✓ Conveyor rung 0, Flagship, Water |
| `TON` | ✓ | ✓ Conveyor rung 9, Flagship, Water |
| `TOF` | ✗ | ✓ Conveyor rung 10 |
| `CTU` | ✗ (LD-side) | ✓ Conveyor rung 6, Flagship |
| `GT`, `LT`, `EQ` | ✗ | ✓ Conveyor rungs 6–8 |
| `ADD`, `SUB`, `MOVE` | ✗ | ✓ Conveyor rungs 4, 5, 7, 12 |
| custom FB call (`pinBindings`) | ✗ | ✓ Conveyor rung 11, Flagship `Infeed_LD` |
| `GE`, `LE`, `NE`, `MUL`, `DIV`, `TP`, `CTD`, `CTUD` (LD-side) | ✗ | ✗ — **unchanged**; covered by `ld_builtin_block_types_test` + the editor palette. Recorded as a deferred row, not a regression. |

### SFC / ST / FB / tasks / sim / HMI / protocols / system

| Feature | Before | After |
|---|---|---|
| SFC `'single'` transitions, `isInitial`, `STEP_T` dwell | ✓ | ✓ Batch Production, Flagship, Water |
| SFC `'parallelFork'` / `'parallelJoin'` | ✓ (batchmix) | ✓ Batch Production, Flagship |
| SFC alternative divergence (first-true-wins) | ✓ (batchmix) | ✓ Batch Production |
| ST `IF/ELSIF/ELSE/END_IF`, assignment, comparators, `AND/OR/NOT` | ✓ | ✓ ST Reactor, Water, Flagship |
| ST array index read (`a[0]`) | ✗ | ✓ ST Reactor `Recipe_Setpoints[0]` |
| ST struct-member write (`x.y := …`) | ✗ | ✓ ST Reactor `Reactor_Status.*` |
| `FbDefinition.stSource` (ST body) | ✓ (`Hysteresis`) | ✓ ST Reactor, HVAC, Flagship |
| **`FbDefinition.ladderRungs` (ladder body)** | ✗ | ✓ Conveyor `MotorStarter`, Flagship `ZoneStarter` |
| Array tag (`arrayLength`) | ✓ (Water `Recipe_Steps`) | ✓ Water, ST Reactor |
| DUT / `structDefs` | ✓ | ✓ Conveyor, Water, ST Reactor |
| `TIMER` composite tag | ✓ | ✓ Conveyor, Water, Flagship |
| Task `Startup` | ✓ (Water) | ✓ Water, Flagship |
| Task `Continuous` | ✓ | ✓ all |
| Task `Periodic` | ✓ | ✓ Batch Production, Water, Flagship |
| Task `Event` | ✗ | ✗ — **unchanged**; deferred row (the approved lineup fixes the flagship at three tasks) |
| Sim `integrate`, `ramp`, `pulse`, `firstOrderLag`, `deadTime`, `noise` | ✓ | ✓ Flagship + Lab + others |
| Sim `setWhileCondition`, `delayedSet` | ✗ | ✓ Flagship |
| `valveCurve` non-linear | ✗ | ✓ Flagship (`equalPercentage`) |
| `noiseDistribution: 'gaussian'` + drift | ✗ | ✓ Flagship |
| HMI `PushbuttonSwitch`, `ToggleSwitch`, `NumericSliderInput`, `LedIndicatorLight`, `DigitalGaugeDisplay`, `StatusPillDisplay`, `TankGraphicDisplay` | ✓ | ✓ |
| **HMI `TextInputField`** | ✗ | ✓ Flagship diagnostics |
| **HMI `TrendChartDisplay` + `PlcProject.trends` pens** | ✗ | ✓ Flagship trends (analog pens + BOOL step lanes) |
| Multi-screen project (>1 `HmiScreenDef`) | ✗ | ✓ HVAC (2), Flagship (3), Lab (4) |
| PID + autotune-resolvable loop | ✓ | ✓ Lab, Flagship |
| Reserved `System` tag bound on an HMI | ✗ | ✓ Flagship diagnostics |
| `ProtocolSettings` pre-configured (Modbus + OPC UA, auto-generated maps, enabled) | ✗ | ✓ Flagship |
| `SignalGen` (`signalGens`) bulk test tags | ✗ | ✗ — **unchanged**; deferred row |

---

## §6 — Legacy fixtures and the per-test re-point map

### The fixture library

`mobile/test/support/legacy_demo_projects.dart` — a **test-only** library
holding the retired builders **verbatim** (ids, names, tags, logic, sim rules
unchanged), so engine tests with scan-index-exact assertions keep their exact
harness:

```dart
/// Retired default-project builders, preserved verbatim as test fixtures.
/// These are NOT shipped (see mobile/lib/data/default_projects/ for the
/// seven curated defaults). They exist so engine tests whose assertions are
/// tied to a specific plant/timing keep their original harness.
PlcProject legacyBatchCounterProject();   // ex proj_batch_counter
PlcProject legacyPulseOutputProject();    // ex proj_pulse_output
PlcProject legacyMotorProject();          // ex proj_motor  (if needed, see below)
```

The library carries the retired builders' original doc comments (the
`proj_batch_counter` one-scan-delayed feedback note, lines 1052–1069, and the
`proj_pulse_output` TP-vs-hold note, lines 1129–1143) — those comments *are*
the explanation of what their tests assert.

### Decision rule applied per test

- **Fixture** when the test asserts scan-index-exact behaviour that depends on
  a specific pulse width / preset / topology (re-pointing would silently
  change what is proven).
- **Re-point** when a new project genuinely reproduces the same plant and the
  assertion is behavioural (reaches setpoint, lags, latches, counts).

### Re-point / update mapping (all 35 dependent files)

| Test file (`mobile/test/…`) | Today | Action |
|---|---|---|
| `counter_loop_integration_test.dart` | `proj_batch_counter` | **Fixture** `legacyBatchCounterProject()` — import swap only, assertions unchanged |
| `pulse_loop_integration_test.dart` | `proj_pulse_output` | **Fixture** `legacyPulseOutputProject()` — import swap only |
| `ld_exec_integration_test.dart` | `proj_motor`, `proj_ld_conveyor` ×2, `proj_all_water` | **Re-point** motor + conveyor cases → `proj_ld_conveyor_line` (its rungs 0–1 are the absorbed seal-in; rung 9 is the jam TON). Water case unchanged. |
| `fbd_exec_integration_test.dart` | `proj_fbd_hvac`, `proj_all_water` ×2, `proj_tank` | **Re-point** HVAC → `proj_fbd_hvac_zone`; tank fill/drain case → `proj_fbd_hvac_zone` net 5 (same tag names `Level_PV`/`Level_SP`/`Fill_Valve`/`Drain_Valve`/`High_Alarm`/`Auto_Mode`). Water cases unchanged. |
| `st_exec_integration_test.dart` | `proj_st_reactor` ×2, `proj_all_water` | **Re-point** → `proj_st_reactor_control` (ST source verbatim → assertions unchanged) |
| `sfc_exec_integration_test.dart` | `proj_sfc_filling`, `proj_all_water` ×2 | **Re-point** filler case → `proj_sfc_batch_production` (linear segment, same step names/dwells) |
| `sfc_batchmix_showcase_test.dart` | `proj_sfc_batchmix`, exact name string, region counts | **Re-point** → `proj_sfc_batch_production`; update the name literal to `'SFC — Batch Production'`; region counts become 1 parallel region (2 branches) + 1 alternative (2 arms) — same shape, re-asserted against the merged chart |
| `pid_loop_integration_test.dart` | `proj_tank_level_pid` | **Re-point** → `proj_process_lab`, program `LevelPID_FBD` (verbatim plant/gains) |
| `pid_autotune_test.dart` | `proj_tank_level_pid` (`resolvePidLoop`) | **Re-point** → `proj_process_lab` / `LevelPID_FBD` |
| `pid_autotune_screen_test.dart` | prefills `Level_PV` / `Valve_CV` | **Re-point** → `proj_process_lab`; see §7 risk row |
| `deadtime_cascade_integration_test.dart` | `proj_cascade_tanks` ×2 | **Re-point** → `proj_process_lab` / `CascadeMonitor_FBD` (verbatim rules) |
| `noise_measurement_integration_test.dart` | `proj_noisy_level` | **Re-point** → `proj_process_lab` / `NoisyLevelMonitor_FBD` (verbatim rules) |
| `hysteresis_fb_demo_test.dart` | `proj_noisy_level` `Hysteresis` FB | **Re-point** → `proj_st_reactor_control`; instance tag name changes `LevelAlarmHyst` → `TempAlarmHyst` (only literal change) |
| `mimo_project_test.dart` | `proj_mimo_two_zone` | **Re-point** → `proj_process_lab` / `TwoZone_FBD` (verbatim plant + decoupler) |
| `interaction_analysis_screen_test.dart` | `proj_mimo_two_zone` prefill | **Re-point** → `proj_process_lab`; see §7 risk row |
| `memory_responsive_test.dart` | `proj_all_water`, `proj_mimo_two_zone` ×2 | Water unchanged; MIMO → `proj_process_lab` (`edit_tag_Heater_A` still resolves) |
| `sfc_view_no_mutation_test.dart` | selects by program name `TankLevel_FBD` | **Re-point** selector → `proj_fbd_hvac_zone` / `HvacZone_FBD`; assert no SFC-language program and the task's `programNames` |
| `ld_branch_render_test.dart` | `p.name.contains('Motor')` | **Re-point** selector → `p.id == 'proj_ld_conveyor_line'` (rung 0 has the parallel branch) |
| `ld_symbol_alignment_test.dart` | `p.name.contains('Motor')` | Same re-point |
| `widget_test.dart` | `proj_ld_conveyor` | **Re-point** → `proj_ld_conveyor_line` |
| `ld_editor_responsive_test.dart` | `proj_ld_conveyor` ×2 | **Re-point** → `proj_ld_conveyor_line` |
| `editors_responsive_test.dart` | `proj_fbd_hvac` ×2, `proj_sfc_filling`, `proj_ld_conveyor` | **Re-point** → `proj_fbd_hvac_zone`, `proj_sfc_batch_production`, `proj_ld_conveyor_line` |
| `hmi_dashboard_builder_test.dart` | `proj_fbd_hvac` + `hmis.first` | **Re-point** → `proj_fbd_hvac_zone` |
| `simulated_io_screen_test.dart` | `proj_st_reactor` (15 call sites) | **Re-point** → `proj_st_reactor_control` (sim rules unchanged → field assertions unchanged) |
| `drawer_icon_distinction_test.dart` | `proj_st_reactor` + `PROGRAM:ReactorTemp_ST` | **Re-point** id; program name `ReactorTemp_ST` is kept, so the view id literal is unchanged |
| `forms_responsive_test.dart` | `all().first` | Unchanged code; now boots the conveyor. Verify no overflow. |
| `st_editor_quick_insert_scroll_test.dart` | `all().first` | Unchanged code; verify the QUICK INSERT row still renders (the boot project has no ST program → **if the screen requires one, re-point to `proj_st_reactor_control` explicitly**) |
| `project_transfer_test.dart` | `all()` loop, `all().first`, literal `proj_motor` | Loop unchanged; the `proj_motor` literal is a synthetic id string in a collision test — **rename to `proj_demo` to stop implying a real default** |
| `scan_count_continuity_test.dart` | `'Tags & Structs (8 Tags, 1 Structs)'` / `(9 …)` | **Update literals** to the conveyor's real counts |
| `workspace_undo_redo_test.dart` | `(8/9/10 Tags, 1 Structs)`, `(7/8 Tags, 0 Structs)`, `proj_st_reactor`, `proj_motor`, dropdown `'Tank Level Simulation'` | **Update literals** to the conveyor's and the second project's real counts; re-point ids; dropdown name → `'FBD — HVAC Zone Controller'` |
| `delete_confirmation_policy_test.dart` | `'Tags & Structs (8 Tags, 1 Structs)'` | **Update literal** |
| `project_repository_test.dart` | `all().length` ×6, `all().last`, `all().first.id` | Length assertions **self-adjust** (they reference `all().length`, not a literal) — verify only |
| `persistence_integration_test.dart` | `all().length` ×2, `all().last`, `catalog[1]`, first-tag `Start_PB` | Self-adjusting except: `catalog[1]` now switches to `proj_fbd_hvac_zone` (fine); `Start_PB` holds because of the §3 ordering constraint |
| `serialization_roundtrip_test.dart` | `all()` loop | Unchanged — group count goes 14→7 automatically |
| `ld_no_persist_test.dart` | `all()` loop | Unchanged |
| `app_responsive_smoke_test.dart` | `all()` loop + 5 ids by name | **Re-point** the 5 `firstWhere` ids and every project-name dropdown string; the loop now switches 7 projects instead of 14 (a runtime saving) |
| `import/import_xml_flow_test.dart`, `widgets/task_management_test.dart` | relative `debugAllProjects.length` deltas / `debugActiveProject` = `proj_motor` | Deltas are relative → verify only; `task_management_test` re-points its active-project expectation to the conveyor |

**`legacyMotorProject()` is only added if** re-pointing `ld_exec_integration_test`'s
motor case to the conveyor changes what it proves. The implementation task
makes that call after running it; if the fixture is not needed, it is not
written (no dead code).

---

## §7 — Error handling, invariants and risks

This workstream ships no runtime code paths, so "error handling" here means
the invariants a bad default project would violate and how each is caught.

| Situation | Handling / catch |
|---|---|
| A project references a tag that does not exist | Engine reads null/0/false silently — **no throw, and no test failure by default.** Caught by the §8 `default_projects_integrity_test` (every binding resolves) |
| Duplicate `SimRule.id` / `FbdBlock.id` / `HmiComponent.id` within a project | Not enforced by the model. Caught by the integrity test (per-project uniqueness) |
| Duplicate project id or duplicate project **name** across `all()` | Name collisions break the dropdown-by-name switching in `app_responsive_smoke_test`. Caught by the integrity test |
| Two tasks naming the same program | Legal (programs are deduped per tick, `task_scheduler.dart:99`) — allowed |
| An FB name shadowing a built-in block (`fbDefinitionFor` wins in both executors) | Forbidden in defaults: FB names must not be in `kFbdBuiltinBlockTypes` ∪ `kLdBuiltinBlockTypes`. Caught by the integrity test |
| A `TrendPenRef.penTagPath` with no matching `PlcProject.trends` pen | Renders an empty chart. Caught by the integrity test |
| Flagship's `enabled: true` protocols binding a socket at load | §4.6 verification gate; fall back to `enabled: false` + a deferred row |
| An HMI dashboard overflows at 390×844 | Caught by the browser pass (§9) and by `app_responsive_smoke_test`'s three sizes |
| A showcase reveals an engine gap (block behaves wrongly, renderer overflows) | **Record in `docs/DEFERRED.md`, reshape the showcase.** Do not fix engine code in this workstream |

**Open risks carried into the plan (each with a decided fallback):**

1. **`pid_autotune_screen_test` / `interaction_analysis_screen_test` prefill
   heuristics.** Both screens pre-fill MV/PV/CV from the active project. With
   four programs in `proj_process_lab` the heuristic may select a different
   loop than the test expects. *Fallback:* keep those two screen tests on
   fixtures (`legacyTankLevelPidProject()` / `legacyMimoTwoZoneProject()`) and
   record the prefill-with-multiple-loops behaviour as a deferred row. Decide
   by running, not by guessing.
2. **`st_editor_quick_insert_scroll_test` boots `all().first`,** which is now
   an LD-only project. *Fallback:* re-point it explicitly to
   `proj_st_reactor_control`.
3. **`app_responsive_smoke_test` runtime** drops (14→7 projects × 3 sizes) —
   a saving, but the flagship is the largest project ever shipped; if it
   dominates the runtime, its dashboards are asserted in its own test and the
   smoke loop keeps only the overview screen.

---

## §8 — Testing

### Per-project integration tests (7 new files)

One file per project, named `mobile/test/defaults/<slug>_test.dart`, each
driving the real scan pipeline over simulated time and asserting the
project's headline behaviours (falsifiable: zeroing the logic must fail them).

| File | Asserts |
|---|---|
| `defaults/ld_conveyor_line_test.dart` | Seal-in latches and drops on Stop/E-Stop; the fault latch requires a fresh Start (rising contact + OTU); the pulse coil fires for exactly one scan per falling photo-eye edge; `Part_Count` increments once per part (not once per scan); `Parts_Remaining` tracks `Batch_Target - Part_Count`; `MOVE` zeroes the count at the batch end; the jam `TON` trips after 5 s without parts and clears on the next part; `TOF` holds zone 2 for 3 s after the line stops; the **ladder-bodied FB** latches per-instance (its `Seal` lives in `Zone2Starter`, not as a global) |
| `defaults/fbd_hvac_zone_test.dart` | Occupancy/window enable truth table; `SEL` picks comfort vs setback setpoint; the six comparators agree with direct arithmetic on the same inputs; `TON` staging delay, `TOF` fan run-on, `TP` purge one-shot width, `R_TRIG`/`F_TRIG` fire one scan; `CTU` counts heat starts, `CTD` counts down, `CTUD` tracks occupancy net; the absorbed tank network fills below SP−db, drains above SP+db, alarms above the high limit; the **ST-bodied FB** shifts the setpoint on unoccupancy |
| `defaults/sfc_batch_production_test.dart` | Two full cycles increment `Filled_Count`; `STEP_T` dwells are honoured (cap ≥3 s, eject ≥2 s); the fork activates both branches, the join waits for **both** `*_DONE` steps; `Quality_OK` true routes to `DISPATCH`, false routes to `REJECT`; each count step fires once per batch |
| `defaults/st_reactor_control_test.dart` | Closed-loop reaches and holds `Temp_SP` ±2 °C; `Alarm_High`/`Alarm_Low` trip at 95/5 °C; `Recipe_Setpoints[0]` selects the setpoint; `Reactor_Status.Heating/Cooling` mirror the commands; the `Hysteresis` FB sets at High, resets at Low and **holds inside the deadband across scans** |
| `defaults/all_water_test.dart` | A thin guard: the project's `toJson()` equals a checked-in snapshot (proves §4.5's "byte-identical" claim). Behaviour stays covered by the four existing re-pointed engine tests |
| `defaults/flagship_line_test.dart` | Startup task runs exactly once (`System.FirstScan` / initialised counters); all four programs execute in one scan; the PID drives `Blend_Level` to `Blend_SP` and holds off the constant draw with a non-saturated valve; `deadTime` makes `Line_Transfer` lag `Blend_Level`; `setWhileCondition` and `delayedSet` rules behave (the latter only after 2 s); the SFC fork/join sequences; **both** FB kinds execute (ST `Scale` output = the linear map; ladder `ZoneStarter` holds per-instance state); the `System` tag is present and its members update; every trend pen's `tagPath` resolves; the Modbus and OPC UA maps are non-empty and mark `System.*` `ReadOnly` |
| `defaults/process_lab_test.dart` | All four areas run in one project: PID reaches setpoint; MIMO gain matrix has clearly non-zero off-diagonals and the decoupler reduces cross-loop disturbance; `Tank_B_Level` lags `Tank_A_Level` by ≈`tauSec`; `Level_Meas` jitters within the noise band while `Level_Filtered` has strictly lower variance |

### Guard tests (2 new files)

`mobile/test/defaults/default_projects_coverage_test.dart` — the mechanical
enforcement of §5. It walks `DefaultProjects.all()` and asserts, as explicit
sets:

- every string in `kFbdBuiltinBlockTypes` (27) appears as some
  `FbdBlock.type`;
- the LD sets `{normal, negated, rising, falling}` (contacts) and
  `{normal, negated, set, reset, rising, falling}` (coils) each appear as some
  `LdNode.modifier`; the LD blockType set
  `{TON, TOF, CTU, GT, LT, EQ, ADD, SUB, MOVE}` appears (the **exact** set
  §5 claims — the uncovered LD blockTypes are listed in a documented
  `_knownUncovered` constant so a future addition must consciously edit it);
- all 8 `SimRule.behavior` values appear;
- all 9 `HmiComponent.type` values appear, and at least one component has a
  non-empty `trendPens`;
- at least one `FbDefinition` has a non-empty `stSource` **and** at least one
  has a non-empty `ladderRungs`;
- SFC `'parallelFork'`, `'parallelJoin'` and ≥2 `'single'` transitions off one
  step all appear; some transition condition mentions `STEP_T`;
- task types `{Startup, Continuous, Periodic}` appear (`Event` is in the
  documented uncovered set);
- some project sets `protocols` with `modbus` and `opcua` non-null and
  non-empty maps;
- some HMI component binds a `System.*` path.

`mobile/test/defaults/default_projects_integrity_test.dart` — the §7
invariants: unique ids and unique names across `all()`; per-project unique
`SimRule`/`FbdBlock`/`HmiComponent`/`SfcStep`/`SfcTransition`/task/program
ids and names; every HMI `tagBinding`, trend `penTagPath`, sim
`targetPath`/`sourcePath`/clause `leftPath`, `LdNode.variable`, FBD
`TAG_INPUT`/`TAG_OUTPUT` binding, `pinBindings` value and ST/SFC assignment
target resolves to a real tag (or is a numeric/boolean literal, or a
`System.*` member); no `FbDefinition.name` collides with a built-in block
type; every program is referenced by ≥1 task.

### Whole-suite

`flutter test` from `mobile/` — green, including the untouched generic tests
(serialization round-trip, LD no-persist, project transfer, repository +
persistence backfill semantics) and `flutter analyze` with zero warnings.

---

## §9 — Browser verification (per `CLAUDE.md`)

One pass at the end of implementation, headless Playwright only:

1. `scripts/serve-web.sh --build` in the background (serves
   `mobile/build/web` on `http://localhost:8091`).
2. For **all 7** projects: visit **every HMI dashboard** (13 screens total:
   1+2+1+1+1+3+4) and **every program editor** (LD / FBD / SFC / ST), at
   **1440×900** and **390×844** (plus 768×1024 for the flagship's three
   dashboards, the widest content).
3. Screenshots into `.playwright-artifacts/screenshots/` named
   `<project-slug>-<screen>-<viewport>.png`; review each.
4. Console must be clean — **zero** `RenderFlex overflowed`, zero errors; zero
   failed network requests.
5. Specific things to eyeball because they are new: the flagship's
   `TrendChartDisplay` (analog pens auto-scaling + BOOL step lanes render as
   lanes, not as a 0/1 line), the `TextInputField` cards, the System
   diagnostics panel populating live, the HVAC 7-network canvas and the
   conveyor's 13-rung ladder at phone width.
6. Fix → rebuild → reload → re-screenshot. UI work is not done until this
   passes.

---

## §10 — Docs

- **`docs/default-projects.md` (new)** — the seven projects: story, what each
  showcases, its proof test, and the §5 coverage matrix (the single place a
  reader learns "where do I see feature X?").
- **`docs/DEFERRED.md`** — new section "Default projects redo (spec
  2026-08-06)" with the §11 rows; strike nothing (this workstream closes no
  prior deferral).
- **`CLAUDE.md`** — one line under the project-layout section pointing at
  `mobile/lib/data/default_projects/` (one file per project, barrel keeps
  `DefaultProjects.all()` stable).
- No protocol/IEC doc changes — no engine or protocol behaviour changes.

---

## §11 — Deferred (tracked in `docs/DEFERRED.md`)

- **Retired defaults linger on existing installs** — `backfillNewDefaults`
  cannot remove or replace a default the user already has; only Reset to
  Defaults yields exactly the 7. A "retire default ids" reconciliation pass
  (with user confirmation) is deferred.
- **`proj_all_water` refresh invisible to existing installs** — same root
  cause; a "refresh an existing default in place" migration is deferred.
- **LD-side `GE`/`LE`/`NE`/`MUL`/`DIV`/`TP`/`CTD`/`CTUD`** — supported by
  `ld_exec` and the editor palette, still not showcased in a default project
  (unchanged from today).
- **Task type `Event`** — no default project uses an event-triggered task; the
  approved flagship lineup fixes it at three tasks.
- **`SignalGen` / bulk simulated test tags** — no default project ships signal
  generators.
- **Protocols beyond Modbus + OPC UA** — MQTT, DNP3, EtherNet/IP, S7, FINS,
  SLMP and BACnet configs are not pre-populated in any default.
- **PID autotune / interaction-analysis prefill with multiple loops in one
  project** — if the §7 risk materialises, the screens' loop-selection
  heuristic gets a deferred row.
- Anything the implementation discovers that would need an engine change —
  recorded, not fixed (the §0 scope guard).

---

## Resolution / deviation notes (recorded honestly)

1. **`System.Uptime` does not exist.** The reserved `SYSTEM` UDT
   (`tag_resolver.dart:39-59`) has 19 members; the uptime member is
   **`UptimeMs`**. The flagship diagnostics panel binds the real names
   (`Running`, `FirstScan`, `ScanCount`, `ScanTimeMs`, `MaxScanTimeMs`,
   `UptimeMs`, `Fault`).
2. **"Update count-sensitive tests to 7" is not the real work.** Every
   count assertion in `project_repository_test.dart` and
   `persistence_integration_test.dart` is written against
   `DefaultProjects.all().length`, so it self-adjusts. The actual breakage is
   **order** sensitivity (`all().first`, `all().last`, `catalog[1]`, boot =
   `catalog.first`) and **hardcoded "N Tags, M Structs" label strings** in
   three shell tests. §3 and §6 target those instead.
3. **Old ids differ from the brief's shorthand.** The real retired ids are
   `proj_tank_level_pid`, `proj_batch_counter`, `proj_pulse_output`,
   `proj_cascade_tanks`, `proj_noisy_level`, `proj_mimo_two_zone` (not
   `proj_fbd_pid_tank` / `proj_fbd_batch_counter` / `proj_fbd_pulse` /
   `proj_cascade` / `proj_noisy` / `proj_mimo`).
4. **Blast radius is 35 files, not 34** — 32 import `DefaultProjects` or name
   a default id, plus 3 coupled only through the seeded catalog
   (`delete_confirmation_policy_test.dart`,
   `import/import_xml_flow_test.dart`, `widgets/task_management_test.dart`).
5. **Counter and pulse tests kept on fixtures, not re-pointed.** Their
   assertions are scan-index-exact against specific `onMs`/`offMs`/`PT`
   values; re-pointing them at the HVAC counter/edge networks would silently
   change what is proven. The HVAC project independently showcases
   `CTU`/`CTD`/`CTUD`/`R_TRIG`/`F_TRIG`/`TP` under its own new test.
6. **Dart privacy forced a rename.** `_xic`/`_ote`/… are library-private, so
   the one-file-per-project split requires public shared builders
   (`ldXic`, `ldOte`, …) in `default_projects/builders.dart`. Purely
   mechanical, but it touches every project file.
7. **`Event` task type stays uncovered.** Adding a fourth task to the flagship
   was considered and rejected — the approved lineup says three. Recorded as a
   deferred row; it is not a regression (no default uses `Event` today).
8. **`ProtocolSettings.defaults(p)` is not used for the flagship** — it
   returns all nine protocols `enabled: false`, which contradicts "the gateway
   shows live content out of the box". The flagship constructs Modbus + OPC UA
   configs explicitly, with a verification gate on host auto-start.
9. **Ladder-bodied FBs need no engine work.** `FbDefinition.ladderRungs` +
   `runScopedLdBody` dispatch already shipped (L5X sub-project 3), so the
   never-showcased feature in item 1 of the lineup is pure content.
10. **`proj_all_water` "refresh" is documentation only.** Because backfill
    cannot update an existing default, any data change would reach only fresh
    installs while every re-pointed test runs against the new data — pure
    churn for no user-visible gain. §4.5 therefore fixes the change list at
    "move to its own file + add the missing doc comment", with a `toJson()`
    snapshot test proving it.
