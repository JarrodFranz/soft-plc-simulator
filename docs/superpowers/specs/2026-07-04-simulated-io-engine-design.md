# Simulated I/O Engine (WS3) — Design Spec

**Date:** 2026-07-04
**Status:** Approved by delegation (user asked for the best-usability solution;
design decisions made by Claude and taken straight into implementation)
**Author:** Claude (pairing with Jarrod)

Workstream 3 of the editor-improvement effort. WS1 (ladder correctness) and WS2
(tag & type system) are merged.

## Problem

How simulated **inputs** change over time is hardcoded per project inside
`workspace_shell._evaluateActiveLogic` (e.g. `Photo_Eye` pulses `scanCount % 22 <
4`; `Temp_PV += 0.3` when heating; `Level_PV` ramps). It is invisible and
uneditable. The user wants a **"Simulated I/O" section** where they configure how
input tags behave — a bool that pulses, a value that ramps — each **gated by a
condition** over other tags (Photo_Eye pulses only while `Belt_Motor` is on; a
level switch trips only when `Water_Level > X`). This is also where a `TONTimer`
would begin to count.

## Design decisions (chosen for usability)

- **Data-driven rules.** A project holds a list of `SimRule`s. Each scan, a pure
  engine applies every enabled rule to drive its target tag. Multiple rules may
  target the same tag (they compose — e.g. `+heat`, `−cool`, `−ambient`).
- **Five behaviors** cover every real case with intuitive names:
  - `setWhileCondition` (BOOL): target = "condition holds". (Level switch true
    when `Water_Level > X`.)
  - `delayedSet` (BOOL): target → true after the condition holds continuously for
    `delayMs`; → false when it drops. (Sensor trips after a delay.)
  - `pulse` (BOOL): while the condition holds, target cycles true for `onMs`,
    false for `offMs`. (Photo eye blipping while the belt runs.)
  - `ramp` (numeric): while the condition holds, move target toward `targetValue`
    at `ratePerSec`, clamped to `[minValue, maxValue]`. (PV toward setpoint.)
  - `integrate` (numeric): while the condition holds, `target += ratePerSec · dt`
    (rate may be negative), clamped. (Tank fills, temperature rises, ambient
    loss.)
- **Condition = AND of simple clauses** (usable via dropdowns; OR deferred).
  Each clause is `leftPath comparator operand`, where `comparator ∈ {>, <, >=,
  <=, ==, !=}` and `operand` is a literal (number/bool) or another tag path.
  An empty clause list means **Always**.
- **Rates are per-second** (`ratePerSec`, `onMs`), not per-scan — so behavior is
  independent of the scan-speed slider (an improvement over the current
  scan-rate-dependent physics). Migrated defaults are converted using the
  default 500 ms scan so behavior is unchanged at the default speed.
- **Forcing wins.** A rule never overwrites a **forced** root tag (same rule as
  the scan setters), so manual forcing in the Tag Inspector still overrides the
  simulation.
- **Migration.** The existing hardcoded input-simulation lines are converted into
  default `SimRule`s on each project and **removed** from `_evaluateActiveLogic`
  (which keeps only the control logic that computes outputs). The behaviors thus
  become visible and editable, which is the whole point.

## Architecture

### Model (`project_model.dart`)

```dart
class SimClause {
  String leftPath;    // tag path read each scan
  String comparator;  // '>','<','>=','<=','==','!='
  String operandKind; // 'literal' | 'tag'
  String operand;     // literal text ('true','50') or a tag path
}

class SimRule {
  String id;
  String name;
  bool enabled;
  String targetPath;      // input tag driven by this rule
  String behavior;        // 'setWhileCondition'|'delayedSet'|'pulse'|'ramp'|'integrate'
  // behavior params (only the relevant ones are used per behavior)
  int delayMs;            // delayedSet
  int onMs;               // pulse
  int offMs;              // pulse
  double ratePerSec;      // ramp/integrate
  double targetValue;     // ramp
  double minValue;        // ramp/integrate clamp
  double maxValue;        // ramp/integrate clamp
  List<SimClause> condition; // AND-combined; empty = always
}
```

`PlcProject` gains `List<SimRule> simRules` as an **optional** field
(`this.simRules = ...` via `simRules ?? []`) plus `fromJson`/`toJson`, so existing
`PlcProject(...)` call sites don't all need editing — only projects that ship
default rules.

### Engine (`mobile/lib/models/sim_engine.dart` — new, pure Dart)

```dart
class RuleRuntime {          // per-rule state across scans
  int phaseMs;               // pulse: elapsed within current on/off phase
  bool pulseOn;              // pulse: current output phase
  int heldMs;                // delayedSet: how long condition has held
}

class SimRuntime { Map<String, RuleRuntime> byRuleId; }

bool evalCondition(PlcProject p, List<SimClause> clauses);   // AND, empty = true
void applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt);
```

`applySimRules` iterates enabled rules; evaluates the condition via `readPath`
(WS2 resolver) + comparator; applies the behavior, writing the target via
`writePath` **unless** the target's root tag is forced; and advances the rule's
`RuleRuntime`. Pure (mutates the passed project + runtime), unit-testable.
`evalCondition` and each behavior are individually tested.

### UI (`mobile/lib/screens/simulated_io_screen.dart` — new)

Constructor `{ PlcProject currentProject, VoidCallback onProjectUpdated }` (the
established screen pattern). Contents:

- A list of rules: name, target path, a one-line behavior summary, a one-line
  condition summary, an enable toggle, edit and delete actions.
- **Add / Edit dialog:** name; **target-tag picker** (from `leafAndNodePaths`,
  WS2); **behavior dropdown** that reveals only the relevant param fields;
  **condition builder** — rows of `tag-path picker · comparator dropdown · value`
  added/removed with ＋/🗑, AND-combined, labelled "Always" when empty.

### Navigation (`workspace_shell.dart`)

- A **"Simulated I/O"** entry in the left dock under the TASKS section, keyed to
  `_activeViewId == 'SIMIO:rules'` (mirrors the `MEMORY` entry).
- `_buildCenterWorkspace` gains
  `else if (_activeViewId == 'SIMIO:rules') return SimulatedIoScreen(...)`.

### Scan integration (`workspace_shell.dart`)

- Add `final SimRuntime _simRuntime = SimRuntime();`, reset on project switch.
- In `_executeScan`, call
  `applySimRules(_activeProject, _activeProject.simRules, scanSpeedMs, _simRuntime)`
  **before** `_evaluateActiveLogic()` (inputs are driven, then control logic
  reads them).
- Remove the migrated **input-simulation** writes from `_evaluateActiveLogic`
  (listed below); keep the **control-logic** writes.

### Migration (default rules; remove hardcoded input sim)

Convert to default `SimRule`s and delete the corresponding lines:

| Project | Hardcoded input sim → default rule(s) |
|---|---|
| `proj_tank` | `Level_PV` integrate +ratePerSec while `Fill_Valve`, −rate while `Drain_Valve`, clamp 0–100 |
| `proj_st_reactor` | `Temp_PV` integrate +rate while `Heat_Cmd`, −rate while `Cool_Cmd`, −ambient always; clamp 0–105 |
| `proj_ld_conveyor` | `Photo_Eye` pulse (onMs/offMs) while `Belt_Motor`; `Part_Present` follows `Photo_Eye` (setWhileCondition on `Photo_Eye == true`) |
| `proj_fbd_hvac` | `Room_Temp` integrate ±rate while `Heat_Cmd`/`Cool_Cmd`, −ambient always |
| `proj_sfc_filling` | `Fill_Level` integrate +rate while `Fill_Valve` (clamp 0–100) |
| `proj_all_water` | `Turbidity_PV`, `Level_PV`, `Flow_PV` integrate/ramp rules gated by pump/backwash tags |

Rates are converted from the current per-scan deltas using the 500 ms default
(`ratePerSec = deltaPerScan · 2`) so default-speed behavior is unchanged. The
SFC/water control state-machine logic and all output computation stay in
`_evaluateActiveLogic`.

## Testing

- `mobile/test/sim_engine_test.dart` (pure): `evalCondition` (AND, empty=always,
  literal + tag operands, each comparator); `pulse` timing (toggles at onMs/offMs
  across `dt` steps, holds off when condition false); `delayedSet` (fires after
  `delayMs`, resets when condition drops); `ramp` (moves toward target, clamps,
  stops at target); `integrate` (accumulates rate·dt, clamps, negative rate);
  **forcing** (a forced target is not overwritten); condition-false leaves the
  target unchanged.
- `mobile/test/widget_test.dart`: the Simulated I/O screen pumps without overflow;
  existing app-smoke + LD/tag gates still pass.
- Chrome: open Simulated I/O, see the migrated conveyor `Photo_Eye` pulse rule;
  add a new rule and watch it drive a tag; force the target and confirm the rule
  yields.

## Global constraints (unchanged)

- No third-party / reference-editor branding.
- Dark theme preserved. `flutter analyze` **zero** issues. No RenderFlex overflow.

## Out of scope (deferred)

- OR / grouped conditions (AND-only for now).
- Executing LD/FBD/SFC graphs (control logic stays as per-project physics).
- Persisting `simRules`/`structDefs` to disk (JSON exists but no wired save/load;
  a future persistence workstream).
