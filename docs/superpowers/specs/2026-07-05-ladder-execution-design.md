# Ladder Execution Engine (WS4a) — Design Spec

**Date:** 2026-07-05
**Status:** Approved (user confirmed scope, coexistence model, and reference-runtime parity)
**Author:** Claude (pairing with Jarrod)

First execution workstream. WS1-WS3 are merged (graph LD editor, tag/type
system with real TIMER struct tags, simulated-I/O engine). SFC/FBD/ST
execution are later workstreams (WS4b-d).

## Problem

The LD editor builds a full rung graph, but nothing executes it — outputs are
computed by hardcoded per-project Dart in `workspace_shell._evaluateActiveLogic`.
Editing the ladder changes nothing at runtime, and `TIMER` tags never count.

## Reference-runtime parity (verified against the reference sources)

The reference IEC 61131-3 runtime in `Source/Examples` works as follows
(verified in `webserver/core/main.cpp` and `utils/matiec_src/lib/timer.txt`):

- **Graphical languages compile to ST, then C.** A rung becomes a boolean
  assignment (series → `AND`, parallel branch → `OR`), evaluated in network
  order. There is no graphical interpretation at runtime.
- **The runtime is a classic scan cycle:** read input image → execute program
  → write output image → advance the PLC clock → sleep to the fixed cycle
  (`updateBuffersIn(); config_run__(tick); updateBuffersOut(); updateTime();
  sleep_until(...)`).
- **Timers are stateful function blocks** whose time source is the PLC clock,
  which is advanced **once per scan by the tick time** (`updateTime()`), not by
  wall-clock reads mid-scan.

**Our design reproduces these observable semantics** — scan cycle ordering,
series=AND / parallel=OR evaluation in order, writes visible to later rungs,
and timers advancing by scan-dt — while using a **direct graph interpreter**
instead of ahead-of-time compilation. Interpretation is the right strategy
here: it runs in Flutter web (no C toolchain), gives an instant edit→run loop,
and keeps pause/step-scan deterministic (time freezes when paused, exactly as a
tick-based PLC clock does).

## Decisions (confirmed with user)

1. **Scope:** LD execution + TON/TOF timers only. SFC/FBD/ST executors are
   separate later workstreams.
2. **Coexistence:** executed ladder **replaces** the hardcoded control-logic
   writes for projects whose control logic is LD (motor, conveyor, and the LD
   portion of the water plant). Non-LD control (reactor ST-style logic, HVAC,
   SFC state machines, water-plant FBD/ST/SFC parts) stays hardcoded until its
   executor exists.
3. **Timer clock = scan dt** (`scanSpeedMs` per tick), matching the reference
   runtime's per-tick clock and the WS3 sim engine.

## Architecture

### Pure engine (`mobile/lib/models/ld_exec.dart` — new, pure Dart)

```dart
class LdExecRuntime {
  // prev-scan values keyed by "program|rung|node" (edge contacts, pulse coils)
  Map<String, bool> prevBool;
  void clear();
}

void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt,
    {void Function(String path, dynamic value)? write});
void executeRung(PlcProject p, PlcProgram prog, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String, dynamic) write);
```

**Power-flow evaluation.** For each rung, nodes are evaluated in **column
order** (`colAssignment` — a topological order of the graph):

- The **left rail** is powered. A node's **input power** = OR over the powers
  of all wires feeding its input. Series chains therefore AND; parallel
  convergences OR — identical to the boolean expressions the reference
  compiler generates.
- **Contact** output power = input power AND its condition:
  `normal` (NO) = tag true; `negated` (NC) = tag false; `rising`/`falling` =
  tag-value edge this scan (needs prev-scan value from `LdExecRuntime`).
  Tag reads go through `readPath` (so `JamTimer.DN` works).
- **Coil** output power = input power, and it **writes its tag**:
  `normal` (OTE) = follow power; `negated` = inverse; `set` (OTL) = write true
  only when powered; `reset` (OTU) = write false only when powered;
  `rising`/`falling` = one-scan pulse on the power edge.
- **TON/TOF block**: input power = IN. State lives in the block's real `TIMER`
  struct tag (WS2): the engine writes `.EN` (=IN), `.PRE` (= the block's
  `presetMs`, so editing the block updates the visible tag), `.ACC`
  (accumulates `dtMs`), `.TT`, `.DN`. TON: `.ACC` counts while IN, `.DN` when
  `.ACC >= .PRE`, resets when IN drops. TOF: `.DN` true while IN and holds for
  `.PRE` after IN drops (`.ACC` counts after the falling edge). The block's
  **output power = `.DN`** (Q), so a rung can end in a timer or continue
  through it. Timer countdown is live-observable in the Tag Inspector and
  Memory tree — the tag *is* the state.

**Ordering.** Programs execute in project order (all `language ==
'LadderLogic'`), rungs top-to-bottom, once per scan; every write is immediately
visible to later rungs (seal-in works). Writes go through a force-respecting
writer (a forced root tag is never overwritten — same rule as the sim engine
and scan setters).

### Scan integration (`workspace_shell.dart`)

Per scan: **sim inputs (WS3) → `executeLdPrograms` → remaining hardcoded
control logic**. Add `final LdExecRuntime _ldRuntime = LdExecRuntime();`,
cleared on project switch (alongside `_simRuntime`).

### Migration (replace hardcoded LD-control per project)

- **`proj_motor`** — the demo rungs currently live only in the LD editor's
  `_ensureDefaultRungs` (created when the editor opens), so execution would
  have nothing to run. **Pre-populate `MotorControl_LD` in
  `default_projects.dart`** with rungs that exactly reproduce the hardcoded
  behavior:
  - Rung 0: `(Start_PB OR Motor_Latch) AND NOT Stop_PB → OTE Motor_Latch`
    (Start_PB NO with Motor_Latch parallel branch, Stop_PB NC).
  - Rung 1: `Motor_Latch AND EStop_OK AND Overload_OK → OTE Motor_Run`
    (all NO contacts — EStop_OK/Overload_OK are true-when-healthy).
  Remove the `proj_motor` block from `_evaluateActiveLogic`.
- **`proj_ld_conveyor`** — the shipped rungs already implement the control
  logic (belt seal-in + interlocks, latch set/unlatch, part-present, jam TON,
  jam alarm). Remove the hardcoded conveyor control writes (`Belt_Motor`,
  `Belt_Latch`, `Belt_Jammed`), and **remove the WS3 sim rule "Part present
  follows photo eye"** — rung 2 (`Photo_Eye → OTE Part_Present`) now
  legitimately computes it (avoids double-drive). Keep the Photo_Eye pulse
  rule. Verify rung parity with the removed code; adjust rungs if the original
  behavior differed (e.g. jam-clear semantics).
- **`proj_all_water`** — `PumpControl_LD` covers the pump seal-in/latch,
  dosing, backwash TON, and backwash-active output. Remove exactly those
  hardcoded writes (`Pump_Latch`, `Pump_Motor`, `Treat_Dosing`,
  `Backwash_Active`); **keep** the non-LD control writes (`Quality_OK` — FBD;
  `Alarm_Active`, `System_Ready` — ST supervisor; backwash valve/pump
  sequencing — SFC) hardcoded until their executors exist. Verify parity.
- **Other projects** (tank, reactor, HVAC, SFC filling): control logic is not
  LD — untouched.

Timer tags: `JamTimer`/`BackwashTimer`/`TONTimer` are already real `TIMER`
structs (WS2); the engine keeps their `.PRE` synced from the block's
`presetMs` (5000 / 30000 / 5000).

## Testing

- `mobile/test/ld_exec_test.dart` (pure): series AND; parallel OR (seal-in
  latch holds after Start released and drops on Stop); NC contact; OTL/OTU
  latch pair; rising-edge contact fires one scan; TON accumulates by dt,
  DN at PRE, resets when IN drops; TOF holds Q for PRE after IN drops; block
  output powers a following coil; writes visible to a later rung; forced
  target not overwritten; unknown tag reads as false (no throw).
- Existing suite stays green; app smoke + LD overflow gates unchanged.
- Chrome (if capture works): press START in the motor HMI → ladder drives
  Motor_Run; conveyor jam timer counts in the Tag Inspector and trips
  Belt_Jammed; editing a rung changes runtime behavior.

## Global constraints (unchanged)

No third-party/reference-editor branding · dark theme preserved ·
`flutter analyze` zero issues · no RenderFlex overflow · behavior parity with
the removed hardcoded logic at the default scan speed.

## Out of scope (deferred)

- SFC, FBD, and ST execution (WS4b-d).
- Counters (CTU/CTD), math/compare blocks — the editor doesn't build them yet.
- Wall-clock timers (scan-dt is the reference-faithful choice; revisit only if
  a "real-time mode" is ever wanted).
- Compiling LD→ST (interpretation chosen deliberately; see parity section).
