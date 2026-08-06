# Built-in default projects

The simulator ships **seven** curated demo projects, replacing the previous
fourteen. Each one is a deliberate showcase: it has a story, a named feature
set it is *the* place to see, and a proof test that fails if the showcase is
gutted. `mobile/lib/data/default_projects.dart` is a thin **barrel** — it keeps
the `DefaultProjects.all()` signature and its import path
(`package:soft_plc_mobile/data/default_projects.dart`) stable, because ~35 test
files depend on both — while each project lives in its own file under
`mobile/lib/data/default_projects/`, with shared ladder-construction helpers in
`default_projects/builders.dart`.

**Order is load-bearing.** `all()[0]` is the boot-active project (the shell
activates `catalog.first`); it must be a `LadderLogic` project whose first tag
is `Start_PB`. `all().last` is used by the repository and persistence tests as
"a default the catalog is missing".

| # | Name | id | File |
|---|---|---|---|
| 1 | Ladder — Conveyor Line | `proj_ld_conveyor_line` | `ladder_conveyor_line.dart` |
| 2 | FBD — HVAC Zone Controller | `proj_fbd_hvac_zone` | `fbd_hvac_zone.dart` |
| 3 | SFC — Batch Production | `proj_sfc_batch_production` | `sfc_batch_production.dart` |
| 4 | ST — Reactor Temperature Controller | `proj_st_reactor_control` | `st_reactor_control.dart` |
| 5 | All Languages — Water Treatment Plant | `proj_all_water` | `all_water_treatment.dart` |
| 6 | Flagship — Production Line | `proj_flagship_line` | `flagship_production_line.dart` |
| 7 | Process Control Lab | `proj_process_lab` | `process_control_lab.dart` |

---

## 1. Ladder — Conveyor Line (`proj_ld_conveyor_line`)

**Story.** A two-zone conveyor line. The operator starts the line with a
beginner seal-in rung (absorbed from the retired "Basic Motor Start Stop"
demo), zone 1 runs under E-Stop/overload/jam interlocks, parts are counted off
the photo eye, a batch is tracked against a target, and zone 2 is driven by a
ladder-bodied custom function block.

**Showcase for** the full LD element set: contacts `normal`/`negated`/`rising`/
`falling`; coils `normal`/`negated`/`set`/`reset`/`rising`/`falling` (the two
one-scan pulse coils); OR branches (`BranchSpec`); `TON`, `TOF`, `CTU`;
comparisons `GT`/`LT`/`EQ`; arithmetic `ADD`/`SUB`/`MOVE`; a `TIMER` composite
tag; a DUT tag; and — the never-before-shipped headline — a **ladder-bodied
`FbDefinition`** (`MotorStarter`) whose seal-in state lives inside the instance
struct `Zone2Starter`, not in a global tag.

**Proof test.** `mobile/test/defaults/ld_conveyor_line_test.dart` (plus the
re-pointed `mobile/test/ld_exec_integration_test.dart`).

## 2. FBD — HVAC Zone Controller (`proj_fbd_hvac_zone`)

**Story.** A single HVAC zone plus the water tank it shares a plant room with.
Occupancy, an override switch and a window contact decide whether the zone is
enabled; a ±1 °C deadband calls for heat or cool; a reset schedule derives an
effective setpoint from the reservoir level; staging timers and edge detectors
sequence the second heat stage, the fan run-on and a purge one-shot; three
counters track heat starts, filter life and net occupancy; and the absorbed
tank network (from the retired "Tank Level Simulation") fills, drains and
alarms on level.

**Showcase for** the whole FBD palette across seven networks:
`NOT`/`AND`/`OR`; `ADD`/`SUB`/`MUL`/`DIV`;
`GT`/`LT`/`GE`/`LE`/`EQ`/`NE`; `LIMIT`; `SEL`; `TON`/`TOF`/`TP`;
`CTU`/`CTD`/`CTUD`; `R_TRIG`/`F_TRIG`; `CONST`/`TAG_INPUT`/`TAG_OUTPUT`; and an
**ST-bodied custom function block** (`SetpointShift`, instance `ZoneShift`).
Data crosses networks through tags, never wires, and networks execute in index
order within one scan. It is also one of the three **multi-screen** projects.

**Proof test.** `mobile/test/defaults/fbd_hvac_zone_test.dart` (plus the
re-pointed HVAC and tank cases in
`mobile/test/fbd_exec_integration_test.dart`).

## 3. SFC — Batch Production (`proj_sfc_batch_production`)

**Story.** One packaging-and-batching line, merging the two retired SFC demos
into a single chart. A container is filled, capped and ejected on a linear
segment with `STEP_T` dwells (from "Batch Bottle Filling"); the product for the
next container is then prepared by a parallel fork that heats and charges the
mix tank at the same time and rejoins when both are done (from "Batch Mix &
Dispatch"); finally a quality gate splits the chart into two alternative arms —
dispatch or reject — each ending in its own one-shot count step before
returning to IDLE.

**Showcase for** SFC `'single'` transitions, `isInitial`, `STEP_T` dwell
conditions, `'parallelFork'`/`'parallelJoin'`, alternative divergence
(first-true-wins), one-shot counting steps, and a `Periodic` task.

**Proof test.** `mobile/test/defaults/sfc_batch_production_test.dart` (plus the
re-pointed `mobile/test/sfc_exec_integration_test.dart` and
`mobile/test/sfc_batch_production_showcase_test.dart`).

## 4. ST — Reactor Temperature Controller (`proj_st_reactor_control`)

**Story.** A jacketed reactor held at temperature by a ±2 °C on/off deadband
controller written in Structured Text, with high/low trip alarms, an eight-step
recipe table and a status struct. A small companion FBD program hosts a custom
`Hysteresis` function block that latches a hot-vessel alarm with a 40–60 °C
deadband (ST has no FB-call syntax in the supported subset, so the call has to
live in FBD).

**Showcase for** ST `IF/ELSIF/ELSE/END_IF`, assignment, comparators and
`AND`/`OR`/`NOT`; **ST array-index read** (`Recipe_Setpoints[0]`); **ST
struct-member write** (`Reactor_Status.Heating := …`); an `INT16` array tag; a
DUT tag; and the ST-bodied `Hysteresis` FB whose internal `Q` persists across
scans inside the instance struct `TempAlarmHyst`.

**Proof test.** `mobile/test/defaults/st_reactor_control_test.dart` (plus the
re-pointed `mobile/test/st_exec_integration_test.dart`,
`mobile/test/hysteresis_fb_demo_test.dart` and
`mobile/test/simulated_io_screen_test.dart`).

## 5. All Languages — Water Treatment Plant (`proj_all_water`)

**Story.** A municipal water treatment plant. The main pump is started with a
ladder seal-in; an FBD quality gate decides whether the water is in spec; an ST
supervisor raises alarms and the system-ready permissive; and an SFC sequences
a filter backwash whenever a 30 s ladder timer says turbidity has been out of
spec for too long.

**Showcase for** **all four IEC 61131-3 languages in one project**, a
multi-network FBD program whose networks hand data to each other through tags
(not wires), the three task types `Startup`/`Continuous`/`Periodic`, an array
tag (`Recipe_Steps`, INT16[8]), a DUT-typed tag (`Pump1_Status`) and a `TIMER`
composite (`BackwashTimer`).

**Proof test.** `mobile/test/defaults/all_water_test.dart` — a byte-identical
snapshot guard: this project's data is unchanged from before the redo (the
split added only its doc comment). Also exercised by
`mobile/test/ld_exec_integration_test.dart`,
`fbd_exec_integration_test.dart`, `st_exec_integration_test.dart` and
`sfc_exec_integration_test.dart`.

## 6. Flagship — Production Line (`proj_flagship_line`)

**Story.** A four-area plant with lots of moving parts. Two infeed conveyors
run under a seal-in with jam detection and part counting (LD); a blending
station holds tank level with a PID against a constant draw, picks a recipe
ratio and scales the level to a 4–20 mA transmitter signal (FBD); a batch
sequencer charges, then heats and agitates in parallel, holds, discharges and
counts (SFC); and a supervisor aggregates permissives, alarms, `System`-derived
health and run hours (ST).

**Showcase for** everything no other default covers at once: **all three task
types** (`Startup`/`Continuous`/`Periodic`); **both custom-FB body kinds**
(`Scale` ST-bodied, `ZoneStarter` ladder-bodied with a scoped `TIMER` var);
seven of the eight sim behaviours — `integrate` (with a non-linear
`equalPercentage` valve curve), `firstOrderLag`, `deadTime`, `noise` (gaussian
+ drift), `pulse`, **`setWhileCondition`** and **`delayedSet`** (the last two
showcased nowhere else); the reserved **`System` tag bound on an HMI**; the
**`TrendChartDisplay`** widget with project `TrendPen`s (six pens — four analog
on one chart plus two BOOL step lanes on another); the **`TextInputField`**
widget; and **pre-configured Modbus + OPC UA maps** so the Gateway screen shows
live content out of the box. Three HMI screens, 48 components in total.

**Protocol note.** Both protocol configs ship `enabled: true`. That is safe
only because nothing auto-starts a host on project load — `start()` is reached
exclusively from the Gateway screen's toggle. This is re-proved on every run by
`mobile/test/defaults/flagship_gateway_no_autostart_test.dart`, which boots the
shell and then re-binds ports 502 and 4840. Both maps also ship wide open
(anonymous OPC UA, `autoGenerate` publishing every scalar leaf) — that is
intentional for a simulator showcase, not a template for a real controller.

**Proof test.** `mobile/test/defaults/flagship_line_test.dart`.

## 7. Process Control Lab (`proj_process_lab`)

**Story.** A control-theory bench with four independent rigs in one project — a
single-loop PID level rig, a 2×2 cross-coupled thermal MIMO rig with a static
decoupler, a cascade-tank rig with a transport dead time, and a noisy
measurement rig with a first-order filter.

**Showcase for** `PID` and autotune-resolvable loops, multivariable interaction
analysis (`Heater_A/B` → `Temp_A/B` with strong off-diagonal gains), the
`deadTime` sim behaviour, the `noise` sim behaviour with a `firstOrderLag`
filter, and a **four-screen project**. Each rig's plant and control are
reproduced verbatim from the demo it consolidates, so the re-pointed engine
tests keep their exact meaning. Its program and tag **order is load-bearing** —
`LevelPID_FBD` must be `programs[0]` and `Heater_A`/`Heater_B`/`Temp_A`/`Temp_B`
must be the first four analog tags, because the PID-autotune and
interaction-analysis screens prefill from the first match.

**Proof test.** `mobile/test/defaults/process_lab_test.dart` (plus the
re-pointed `pid_loop_integration_test`, `pid_autotune_test`,
`pid_autotune_screen_test`, `deadtime_cascade_integration_test`,
`noise_measurement_integration_test`, `mimo_project_test` and
`interaction_analysis_screen_test`).

---

## Feature → project coverage

"Where do I see feature X?" Enforced mechanically by
`mobile/test/defaults/default_projects_coverage_test.dart` — a cell cannot go
from covered to uncovered without a conscious edit to that file.

### FBD block types (all 27, `kFbdBuiltinBlockTypes` in `fbd_pins.dart`)

| Block | Where |
|---|---|
| `TAG_INPUT`, `TAG_OUTPUT`, `CONST` | all FBD projects |
| `NOT`, `AND`, `OR` | HVAC net 0 |
| `ADD`, `SUB` | HVAC net 1 |
| `MUL` | HVAC net 1, Lab MIMO, Flagship |
| `DIV` | HVAC net 1, Flagship `Scale` ratio |
| `GT`, `LT` | HVAC net 2 |
| `GE`, `LE`, `EQ`, `NE` | HVAC net 2 |
| `LIMIT` | HVAC net 1, Lab MIMO, Flagship |
| `SEL` | HVAC net 1, Flagship recipe pick |
| `TON`, `TOF` | HVAC net 3 |
| `TP` | HVAC net 3 |
| `CTU` | HVAC net 4 |
| `CTD`, `CTUD` | HVAC net 4 |
| `R_TRIG` | HVAC net 3 |
| `F_TRIG` | HVAC net 3 |
| `PID` | Lab ×3, Flagship `Blend_FBD` |
| custom FB block | HVAC net 6, ST Reactor, Flagship |

### LD elements (`ld_exec.dart`)

| Element | Where |
|---|---|
| contact `normal` / `negated` | Conveyor, Flagship, Water |
| contact `rising` / `falling` | Conveyor |
| coil `normal` / `set` / `reset` | Conveyor |
| coil `negated` | Conveyor |
| coil `rising` (pulse) / `falling` | Conveyor |
| OR branch (`BranchSpec`) | Conveyor, Flagship, Water |
| `TON` | Conveyor, Flagship, Water |
| `TOF` | Conveyor |
| `CTU` | Conveyor, Flagship |
| `GT`, `LT`, `EQ` | Conveyor |
| `ADD`, `SUB`, `MOVE` | Conveyor |
| custom FB call (`pinBindings`) | Conveyor, Flagship `Infeed_LD` |
| `GE`, `LE`, `NE`, `MUL`, `DIV`, `TP`, `CTD`, `CTUD` | **not covered** — see below |

### SFC / ST / FB / tasks / sim / HMI / protocols / system

| Feature | Where |
|---|---|
| SFC `'single'` transitions, `isInitial`, `STEP_T` dwell | Batch Production, Flagship, Water |
| SFC `'parallelFork'` / `'parallelJoin'` | Batch Production, Flagship |
| SFC alternative divergence (first-true-wins) | Batch Production |
| ST `IF/ELSIF/ELSE/END_IF`, assignment, comparators, `AND/OR/NOT` | ST Reactor, Water, Flagship |
| ST array index read (`a[0]`) | ST Reactor `Recipe_Setpoints[0]` |
| ST struct-member write (`x.y := …`) | ST Reactor `Reactor_Status.*` |
| `FbDefinition.stSource` (ST body) | ST Reactor, HVAC, Flagship |
| `FbDefinition.ladderRungs` (ladder body) | Conveyor `MotorStarter`, Flagship `ZoneStarter` |
| Array tag (`arrayLength`) | Water, ST Reactor |
| DUT / `structDefs` | Conveyor, Water, ST Reactor |
| `TIMER` composite tag | Conveyor, Water, Flagship |
| Task `Startup` | Water, Flagship |
| Task `Continuous` | all |
| Task `Periodic` | Batch Production, Water, Flagship |
| Task `Event` | **not covered** — see below |
| Sim `integrate`, `ramp`, `pulse`, `firstOrderLag`, `deadTime`, `noise` | Flagship, Lab, others |
| Sim `setWhileCondition`, `delayedSet` | Flagship |
| `valveCurve` non-linear | Flagship (`equalPercentage`) |
| `noiseDistribution: 'gaussian'` + drift | Flagship |
| HMI `PushbuttonSwitch`, `ToggleSwitch`, `NumericSliderInput`, `LedIndicatorLight`, `DigitalGaugeDisplay`, `StatusPillDisplay`, `TankGraphicDisplay` | all HMI projects |
| HMI `TextInputField` | Flagship diagnostics |
| HMI `TrendChartDisplay` + `PlcProject.trends` pens | Flagship trends |
| Multi-screen project (>1 `HmiScreenDef`) | HVAC (2), Flagship (3), Lab (4) |
| PID + autotune-resolvable loop | Lab, Flagship |
| Reserved `System` tag bound on an HMI | Flagship diagnostics |
| `ProtocolSettings` pre-configured (Modbus + OPC UA) | Flagship |
| `SignalGen` bulk test tags | **not covered** — see below |

---

## Migration behaviour

Seeding is driven by `seedDefaultsIfEmpty` + `backfillNewDefaults` against the
`seeded_default_ids` ledger. `backfillNewDefaults` can only **add** a default
whose id has never been seeded — it never overwrites or removes one the user
already has.

| Install state | On next launch |
|---|---|
| Fresh install / after Reset to Defaults | Catalog + ledger empty → all **7** seeded. Exactly this lineup. |
| Existing install (has some/all of the old 14) | The **6 new ids** are added. The 13 retired defaults **remain on device as ordinary user projects** (harmless; their ledger entries are inert). `proj_all_water` is already in the catalog, so its refreshed content does **not** reach this install. |
| Existing install, user runs Reset to Defaults | Catalog + ledger cleared, then backfilled → exactly the new **7**. |
| Corrupt ledger | `_decodeStringSet` degrades to `{}` → every default not currently in the catalog is re-added. Unchanged behaviour. |

Only **Reset to Defaults** yields exactly the seven. An existing install
temporarily shows up to 20 projects until the user resets; deleting
user-visible projects on upgrade was rejected as unacceptable. Both
consequences are tracked in [`docs/DEFERRED.md`](DEFERRED.md).

---

## Not covered

Deliberately uncovered by the defaults, each with a row in
[`docs/DEFERRED.md`](DEFERRED.md) and each pinned as a set in the coverage
guard so it cannot drift silently:

- **LD-side `GE`, `LE`, `NE`, `MUL`, `DIV`, `TP`, `CTD`, `CTUD`** — supported by
  `ld_exec.dart` and available in the editor palette, but not showcased in any
  default project (unchanged from before the redo). Pinned as
  `knownUncoveredLdBlockTypes`.
- **Task type `Event`** — no default uses an event-triggered task; the approved
  flagship lineup fixes it at three tasks. Pinned as `knownUncoveredTaskTypes`.
- **`SignalGen` / bulk simulated test tags** — no default ships signal
  generators.
- **Protocols beyond Modbus + OPC UA** — MQTT, DNP3, EtherNet/IP, S7, FINS,
  SLMP and BACnet configs are not pre-populated in any default; the flagship
  configures Modbus + OPC UA only.
