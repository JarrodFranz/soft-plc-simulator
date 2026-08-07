# Default Projects Redo (14 → 7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 14 shipped default projects with 7 curated ones that
together showcase every engine/editor/sim/HMI/protocol feature, each proven by
its own integration test plus two mechanical guard tests.

**Architecture:** `mobile/lib/data/default_projects.dart` becomes a thin barrel
over `mobile/lib/data/default_projects/` (one file per project + a shared
`builders.dart` of public ladder shorthands). The 13 retired builders move to a
temporary `legacy_defaults.dart` (deleted in Task 8) and — for the two whose
tests are scan-index-exact — to a permanent test-only fixture library. New
projects are built and tested in isolation (Tasks 2–7) while `all()` still
returns the old 14; Task 8 flips the catalog and re-points the dependent tests
in one atomic switchover. Every task ends with the **full suite green**.

**Tech Stack:** Dart / Flutter (`mobile/`, package `soft_plc_mobile`),
`flutter_test`. The `flutter` binary is at `/c/flutter/bin/flutter` and is **not
on PATH**. Run all commands from `mobile/`.

## Global Constraints

- **No engine changes.** Content (`mobile/lib/data/**`) + tests + docs only. Any
  edit under `mobile/lib/models/`, `mobile/lib/services/` or
  `mobile/lib/screens/` is a spec violation. If a showcase reveals an engine gap,
  **record it in `docs/DEFERRED.md` and reshape the showcase** — do not fix it.
- Zero `flutter analyze` warnings: `/c/flutter/bin/flutter analyze` from `mobile/`.
- Full suite green after **every** task: `/c/flutter/bin/flutter test` from `mobile/`.
- **Never break:** `serialization_roundtrip_test.dart` (iterates `all()`),
  `ld_no_persist_test.dart`, `project_transfer_test.dart`,
  `project_repository_test.dart`, `persistence_integration_test.dart`, and
  `System`-tag injection.
- Every shipped project must be **self-consistent and falsifiable**: it runs
  under the real scan pipeline and its proof test fails if the logic is zeroed.
  No decorative blocks that are wired but never affect an output.
- Every tag referenced by a rung, an FBD wire, an SFC action/condition, an ST
  statement, an HMI binding, a sim rule or a trend pen **must exist** in the
  project (`System.*` members excepted).
- `DefaultProjects.all()` keeps its name, its signature and its import path
  `package:soft_plc_mobile/data/default_projects.dart`.
- Common to all seven projects: `layoutType: 'GridDashboard'`; `accentColor` ∈
  `{cyan, green, red, amber, teal}`; `gridSpanWidth` ∈ `{1,2,3,4}`; every program
  is referenced by at least one enabled task.
- Ids/names are fixed by the spec §3 table and are not to be re-litigated:
  `proj_ld_conveyor_line` / `Ladder — Conveyor Line`,
  `proj_fbd_hvac_zone` / `FBD — HVAC Zone Controller`,
  `proj_sfc_batch_production` / `SFC — Batch Production`,
  `proj_st_reactor_control` / `ST — Reactor Temperature Controller`,
  `proj_all_water` / `All Languages — Water Treatment Plant` (**id retained**),
  `proj_flagship_line` / `Flagship — Production Line`,
  `proj_process_lab` / `Process Control Lab`.
- `all()[0]` **must** be `proj_ld_conveyor_line` and its **first tag must be
  `Start_PB`** (`persistence_integration_test.dart` L96/L210 assert the boot
  project's first tag). `all().last` is `proj_process_lab`.
- Commit after every task. Do **not** merge or open a PR — that is the
  controller's call at the end.

---

## Recorded resolutions

Points where the spec was silent, self-conflicting, or contradicted by the live
engine code. Each was decided by reading the implementation, not by guessing;
the task that carries it is named. Referenced from the tasks as **R1**–**R14**.

| # | Resolution |
|---|---|
| **R1** | **LD `CTU` presets are literals.** `ld_exec.dart` reads the preset from `LdNode.presetMs` (an `int`) and never from a tag, so §4.1's "CTU `PartCtu` (PV `Batch_Target`)" is not expressible. Used a literal `10` kept in step with the `Batch_Target` tag, and added the `COUNTER`-typed `PartCtu` backing tag §4.1's tag list omits. (Task 2) |
| **R2** | **§4.1's rung table is under-specified.** It leaves `Part_Present` and `Zone2_Permit` with no driver. Added an explicit `Part_Present` drive rung and a `TOF`-driven `Zone2_Permit` rung. (Task 2) |
| **R3** | **§4.1 put two coils on one tag.** Its `OTE-negated` coil and its `EQ` rung both wrote `Zone2_Request`; last-writer-wins would have made the negated coil invisible. Re-homed the negated coil onto a new `Batch_Running` tag, and added the `falling` pulse coil (`Line_Stop_Edge` → `MOVE`) that §5's matrix claims but §4.1 omits. Net effect: 13 sketched rungs become 23. (Task 2) |
| **R4** | **HVAC keeps seven networks, but not the spec's split.** Putting the comparator bank in its own network would have forced `Heat_Cmd`/`Cool_Cmd` onto the new `Effective_SP` and broken the re-pointed truth table. Folded the bank into the deadband network so `Setpoint` ±1.0 stays verbatim; the count stays at seven. (Task 3) |
| **R5** | **`fbd_exec.dart`'s `CTD` has no first-scan preload** (unlike `ld_exec.dart`'s, which loads `CV := PV`). A bare CTD would sit at `CV 0` with `Q` true from scan 1 — a dead countdown. `Filter_Load` therefore ships `true` and drives the CTD's `LD` pin through an `R_TRIG`, which fires exactly once on the first scan. No engine change. (Task 3) |
| **R6** | **FBD networks execute in ascending index order within ONE scan.** A later network reads back what an earlier one just wrote — `WaterQuality_FBD` already relies on this. Tests must therefore assert edge/timer results on the SAME scan that produced the driving signal, not the next one. (Tasks 3, 6) |
| **R7** | **The merged SFC cycle is ~2x the bottle-filler's.** Set `Fill_Level` to 30 %/s, raised `sfc_exec_integration_test`'s bound 80 → 160 scans and `sfc_batchmix_showcase_test`'s two loops 120 → 200, and added `Container_Present` to the re-pointed batchmix test. The merged chart still parses to exactly one parallel region and one alternative region. (Tasks 4, 8) |
| **R8** | **`hysteresis_fb_demo_test`'s numeric sequence is tied to 60/40.** `ReactorAlarm_FBD` therefore uses `CONST` 60.0/40.0 as a hot-vessel latch rather than the reactor's 95/5 trip alarms, so only tag and program-name literals change in the re-point. (Tasks 5, 8) |
| **R9** | **§7 risk 1 resolved by ordering, not fixtures.** `PidAutoTuneScreen` prefills from the first `PID` block in the first FBD program, and `defaultInteractionAnalysisTags` from the first four analog tags in declaration order — so `LevelPID_FBD` is `programs[0]` and `Heater_A`/`Heater_B`/`Temp_A`/`Temp_B` lead the lab's tag list. (Task 7) |
| **R10** | **§7 risk 2 is a no-op.** The ST editor's QUICK INSERT row is built from `currentProject.tags` (`st_editor_screen.dart:360`) and renders unconditionally, so an LD-only boot project is fine and `st_editor_quick_insert_scroll_test` needs no re-point. (Task 8) |
| **R11** | **`SimRule.noise` seeds its PRNG from the rule id** (`_fnv1a`). The lab keeps the noise rig's original `sim0`–`sim3` ids verbatim so the sequence is unchanged, and namespaces the PID and cascade rigs instead. (Task 7) |
| **R12** | **§4.6's autostart gate passes.** `workspace_shell.dart` never calls `host.start()` — only `stop()` — so the flagship ships `enabled: true`. Proven two ways: no OPC UA/Modbus log entries after boot, AND both configured ports still bindable (the log check alone would miss a host logging below `AppLogger.kDefaultMinLevel`). (Task 8) |
| **R13** | **"Startup task initialises recipe + counters" vs "four programs."** `StartupTask` runs `Safety_ST` (the water plant's precedent) with a `System.FirstScan`-guarded init block, so no fifth program is needed. The block initialises only tags with **no other writer** — `Ratio_SP` is excluded because `Blend_FBD` rewrites it every scan, which would make the once-only assertion unfalsifiable. (Task 6) |
| **R14** | **Blast radius is 36 files, not 35.** `project_dropdown_polish_test.dart` hardcodes the tooltip `'Basic Motor Start Stop'` and is absent from §6's map. Separately, the three `'N Tags, M Structs'` literals become labels computed from `DefaultProjects.all()` (+1 for the injected `System` tag) rather than new hardcoded numbers. (Task 8) |

---

## File Structure

**Created (library):**

| File | Responsibility |
|---|---|
| `mobile/lib/data/default_projects/builders.dart` | Public ladder shorthands (`ldXic`…`ldFbCall`) + `emptyScratchProject` / `scratchProjectFor` |
| `mobile/lib/data/default_projects/all_water_treatment.dart` | Project 5 — verbatim move of `_allWaterProject`, plus its missing library doc comment |
| `mobile/lib/data/default_projects/legacy_defaults.dart` | **Temporary.** The other 13 current builders, verbatim. Deleted in Task 8. |
| `mobile/lib/data/default_projects/ladder_conveyor_line.dart` | Project 1 |
| `mobile/lib/data/default_projects/fbd_hvac_zone.dart` | Project 2 |
| `mobile/lib/data/default_projects/sfc_batch_production.dart` | Project 3 |
| `mobile/lib/data/default_projects/st_reactor_control.dart` | Project 4 |
| `mobile/lib/data/default_projects/flagship_production_line.dart` | Project 6 |
| `mobile/lib/data/default_projects/process_control_lab.dart` | Project 7 |

**Modified:** `mobile/lib/data/default_projects.dart` (shrinks to imports + the
`DefaultProjects` class).

**Created (tests):** `mobile/test/support/legacy_demo_projects.dart` and
`mobile/test/defaults/{ld_conveyor_line,fbd_hvac_zone,sfc_batch_production,st_reactor_control,all_water,flagship_line,process_lab}_test.dart`
plus `mobile/test/defaults/{default_projects_coverage,default_projects_integrity}_test.dart`.

**Sequencing rule (load-bearing):** Tasks 2–7 add project *files* and their
tests only. They do **not** touch `DefaultProjects.all()`. Every existing test
therefore keeps passing untouched through Task 7, because `all()` still returns
the same 14 projects in the same order. Task 8 is the single atomic switchover:
it rewrites `all()`, deletes `legacy_defaults.dart`, re-points the dependent
tests, and adds the two guard tests.

---

### Task 1: Split the file, promote the builders, extract `proj_all_water`

**Model:** sonnet · **Effort:** medium

**Files:**
- Create: `mobile/lib/data/default_projects/builders.dart`
- Create: `mobile/lib/data/default_projects/all_water_treatment.dart`
- Create: `mobile/lib/data/default_projects/legacy_defaults.dart`
- Create: `mobile/test/support/legacy_demo_projects.dart`
- Create: `mobile/test/defaults/all_water_test.dart`
- Modify: `mobile/lib/data/default_projects.dart` (whole file replaced)
- Modify: `mobile/test/counter_loop_integration_test.dart:18`
- Modify: `mobile/test/pulse_loop_integration_test.dart` (the `firstWhere` line)

**Interfaces:**
- Produces (from `builders.dart`, imported by every later project file):
  - `LdNode ldXic(String v, [String c = ''])` — contact, `modifier: 'normal'`
  - `LdNode ldXio(String v, [String c = ''])` — contact, `'negated'`
  - `LdNode ldXicRising(String v, [String c = ''])` — contact, `'rising'`
  - `LdNode ldXicFalling(String v, [String c = ''])` — contact, `'falling'`
  - `LdNode ldOte(String v, [String c = ''])` — coil, `'normal'`
  - `LdNode ldOteNeg(String v, [String c = ''])` — coil, `'negated'`
  - `LdNode ldOtl(String v, [String c = ''])` — coil, `'set'`
  - `LdNode ldOtu(String v, [String c = ''])` — coil, `'reset'`
  - `LdNode ldOsr(String v, [String c = ''])` — coil, `'rising'` (one-scan pulse)
  - `LdNode ldOsf(String v, [String c = ''])` — coil, `'falling'`
  - `LdNode ldTon(String v, int ms, [String c = ''])` — block `TON`, `presetMs: ms`
  - `LdNode ldTof(String v, int ms, [String c = ''])` — block `TOF`
  - `LdNode ldCtu(String v, int preset, [String c = ''])` — block `CTU`, `presetMs: preset` (**the CTU preset is a literal `int`; `ld_exec.dart` reads `n.presetMs`, never a tag**)
  - `LdNode ldCmp(String type, String a, String b, [String c = ''])` — block ∈ `GT LT GE LE EQ NE`, `operandA: a`, `operandB: b`
  - `LdNode ldMath(String type, String dest, String a, String b, [String c = ''])` — block ∈ `ADD SUB MUL DIV`, `variable: dest`
  - `LdNode ldMove(String dest, String src, [String c = ''])` — block `MOVE`
  - `LdNode ldFbCall(String fbName, String instance, Map<String, String> pins, [String c = ''])` — block whose `blockType` is an FB name, `variable: instance`, `pinBindings: pins`
  - `final PlcProject emptyScratchProject`
  - `PlcProject scratchProjectFor({List<PlcStructDef> structDefs, List<FbDefinition> fbDefinitions})`
- Produces (from `all_water_treatment.dart`): `PlcProject allWaterTreatmentProject()`
- Produces (from `legacy_defaults.dart`, **temporary**): `legacyMotorProject()`,
  `legacyTankProject()`, `legacyStReactorProject()`, `legacyLdConveyorProject()`,
  `legacyFbdHvacProject()`, `legacySfcFillingProject()`, `legacySfcBatchMixProject()`,
  `legacyFbdPidTankLevelProject()`, `legacyFbdBatchCounterProject()`,
  `legacyFbdPulseOutputProject()`, `legacyCascadeTanksProject()`,
  `legacyNoisyLevelProject()`, `legacyMimoTwoZoneProject()` — all `PlcProject Function()`
- Produces (from `mobile/test/support/legacy_demo_projects.dart`):
  `PlcProject legacyBatchCounterProject()`, `PlcProject legacyPulseOutputProject()`

- [ ] **Step 1: Capture the `proj_all_water` byte-identical snapshot (before touching anything)**

Run from `mobile/`:

```bash
/c/flutter/bin/flutter test --plain-name 'placeholder-that-matches-nothing' 2>/dev/null || true
```

Then write the snapshot generator as a throwaway test file
`mobile/test/defaults/_snapshot_gen_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';

void main() {
  test('write proj_all_water snapshot', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    File('test/defaults/all_water_snapshot.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(p.toJson()));
  });
}
```

Run: `/c/flutter/bin/flutter test test/defaults/_snapshot_gen_test.dart`
Expected: PASS, and `mobile/test/defaults/all_water_snapshot.json` exists.
Then delete the generator: `rm test/defaults/_snapshot_gen_test.dart`

- [ ] **Step 2: Write the failing snapshot guard test**

Create `mobile/test/defaults/all_water_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';

/// §4.5 guard: `proj_all_water` is MOVED to its own file and documented — its
/// data must stay byte-identical. Behaviour remains covered by the four
/// existing engine tests that already drive this project
/// (ld/fbd/st/sfc `_exec_integration_test.dart`).
void main() {
  test('proj_all_water toJson() equals the pre-split snapshot', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final actual = const JsonEncoder.withIndent('  ').convert(p.toJson());
    final expected =
        File('test/defaults/all_water_snapshot.json').readAsStringSync();
    expect(actual, expected,
        reason: 'the water plant must be moved verbatim — no data changes');
  });
}
```

- [ ] **Step 3: Run it to confirm it passes against the un-split file**

Run: `/c/flutter/bin/flutter test test/defaults/all_water_test.dart`
Expected: PASS (it is a regression guard, not a red-first test — it must be
green *before* the split so that a break during the split is unambiguous).

- [ ] **Step 4: Write `builders.dart`**

Create `mobile/lib/data/default_projects/builders.dart`:

```dart
// Shared construction helpers for the seven built-in default projects.
//
// Dart privacy is LIBRARY-scoped, so the ladder shorthands that used to be
// private statics on `DefaultProjects` (`_xic`, `_ote`, …) cannot be shared
// across the one-file-per-project split. They are promoted to public
// top-level functions here, `ld`-prefixed so they never collide with model
// identifiers. `buildRung`/`BranchSpec` still come from `models/ld_graph.dart`.
library;

import '../../models/project_model.dart';

// ── Contacts ─────────────────────────────────────────────────────────────
LdNode ldXic(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'normal', comment: c);
LdNode ldXio(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'negated', comment: c);
LdNode ldXicRising(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'rising', comment: c);
LdNode ldXicFalling(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'falling', comment: c);

// ── Coils ────────────────────────────────────────────────────────────────
LdNode ldOte(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'normal', comment: c);
LdNode ldOteNeg(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'negated', comment: c);
LdNode ldOtl(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'set', comment: c);
LdNode ldOtu(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'reset', comment: c);
/// One-scan pulse on the RISING edge of this coil's power flow.
LdNode ldOsr(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'rising', comment: c);
/// One-scan pulse on the FALLING edge of this coil's power flow.
LdNode ldOsf(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'falling', comment: c);

// ── Blocks ───────────────────────────────────────────────────────────────
LdNode ldTon(String v, int ms, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'TON', variable: v, presetMs: ms, comment: c);
LdNode ldTof(String v, int ms, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'TOF', variable: v, presetMs: ms, comment: c);

/// Count-up counter. NOTE: `ld_exec.dart` reads the preset from
/// `LdNode.presetMs` — an `int` literal — so a CTU preset can never be a tag
/// reference on the ladder side. Callers that also want the preset visible as
/// a tag must keep the two in sync themselves.
LdNode ldCtu(String v, int preset, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'CTU', variable: v, presetMs: preset, comment: c);

/// Comparison block; [type] ∈ `GT LT GE LE EQ NE`. Operands are numeric
/// literals or tag paths (resolved by `_operandValue` in `ld_exec.dart`).
LdNode ldCmp(String type, String a, String b, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: type, operandA: a, operandB: b, comment: c);

/// Arithmetic block; [type] ∈ `ADD SUB MUL DIV`. Writes `a <op> b` into [dest].
LdNode ldMath(String type, String dest, String a, String b, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: type, variable: dest,
    operandA: a, operandB: b, comment: c);

/// MOVE block: writes [src] (literal or tag path) into [dest].
LdNode ldMove(String dest, String src, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'MOVE', variable: dest,
    operandA: src, operandB: '0', comment: c);

/// Custom function-block call: [fbName] is an `FbDefinition.name`, [instance]
/// is the instance tag path, [pins] maps pin name -> tag path (input pins are
/// read from those tags, output pins are written back to them).
LdNode ldFbCall(String fbName, String instance, Map<String, String> pins,
        [String c = '']) =>
    LdNode(
        id: '', kind: LdKind.block, blockType: fbName, variable: instance,
        pinBindings: Map<String, String>.from(pins), comment: c);

// ── Scratch projects for `defaultValueFor(...)` ───────────────────────────

/// Throwaway project used only to resolve built-in composite (TIMER/COUNTER)
/// and scalar-array default values, which do not depend on a project's own
/// structDefs or fbDefinitions.
final PlcProject emptyScratchProject = PlcProject(
  id: '_scratch',
  name: '_scratch',
  controllerName: '_scratch',
  tags: [],
  structDefs: [],
  programs: [],
  tasks: [],
  hmis: [],
);

/// Throwaway project carrying [structDefs] / [fbDefinitions] so
/// `defaultValueFor(...)` can expand a DUT-typed or FB-instance-typed tag's
/// structural default before the real project object exists.
PlcProject scratchProjectFor({
  List<PlcStructDef> structDefs = const [],
  List<FbDefinition> fbDefinitions = const [],
}) =>
    PlcProject(
      id: '_scratch_for',
      name: '_scratch_for',
      controllerName: '_scratch',
      tags: [],
      structDefs: List<PlcStructDef>.from(structDefs),
      programs: [],
      tasks: [],
      hmis: [],
      fbDefinitions: List<FbDefinition>.from(fbDefinitions),
    );
```

- [ ] **Step 5: Extract `proj_all_water` into its own file**

Create `mobile/lib/data/default_projects/all_water_treatment.dart` by moving
`_allWaterProject()` out of `default_projects.dart` **verbatim** (lines 696–970
of the current file), renaming it to `allWaterTreatmentProject()`, converting
`_xic/_xio/_ote/_otl/_ton` to `ldXic/ldXio/ldOte/ldOtl/ldTon` and
`_emptyProject` to `emptyScratchProject`, and prefixing the library doc comment
below. **Change nothing else** — no tag, path, structDef, program name, rung,
block, wire, network, step, transition, sim rule, task or HMI id/binding.

The file header (the doc comment this project currently lacks):

```dart
/// **All Languages — Water Treatment Plant** (`proj_all_water`).
///
/// (a) Story: a municipal water treatment plant. The main pump is started with
/// a ladder seal-in; an FBD quality gate decides whether the water is in spec;
/// an ST supervisor raises alarms and the system-ready permissive; and an SFC
/// sequences a filter backwash whenever a 30 s ladder timer says turbidity has
/// been out of spec for too long.
///
/// (b) Showcase for: **all four IEC 61131-3 languages in one project**, a
/// multi-network FBD program whose networks hand data to each other through
/// tags (not wires), the three task types `Startup`/`Continuous`/`Periodic`,
/// an array tag (`Recipe_Steps`, INT16[8]), a DUT-typed tag (`Pump1_Status`)
/// and a `TIMER` composite (`BackwashTimer`).
///
/// (c) Falsifiable: zeroing `WaterQuality_FBD` pins `Quality_OK` false, which
/// makes `PumpControl_LD` dose forever and the backwash SFC cycle forever;
/// zeroing `Safety_ST` leaves `System_Ready` false with the pump running.
///
/// (d) Proof tests: `test/ld_exec_integration_test.dart`,
/// `test/fbd_exec_integration_test.dart`, `test/st_exec_integration_test.dart`,
/// `test/sfc_exec_integration_test.dart`, and the byte-identical data guard in
/// `test/defaults/all_water_test.dart`.
///
/// This project's DATA is byte-identical to the pre-split version (see the
/// snapshot guard above) — the split added only this comment.
library;

import '../../models/ld_graph.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject allWaterTreatmentProject() {
  // ... verbatim body of the former DefaultProjects._allWaterProject() ...
}
```

- [ ] **Step 6: Move the other 13 builders into `legacy_defaults.dart`**

Create `mobile/lib/data/default_projects/legacy_defaults.dart` holding the
remaining 13 builders, **verbatim**.

Mechanical recipe (the bodies are pure data literals — do not retype them):

1. `git show HEAD:mobile/lib/data/default_projects.dart` gives you the original.
2. Cut each `static PlcProject _xxxProject() …` declaration (including its
   preceding doc comment) out of the old file and paste it in, in the same
   order.
3. Drop the `static ` keyword and rename `_xxxProject` → `legacyXxxProject`
   using the table below.
4. Inside every pasted body, replace `_xic(`→`ldXic(`, `_xio(`→`ldXio(`,
   `_ote(`→`ldOte(`, `_otl(`→`ldOtl(`, `_otu(`→`ldOtu(`, `_ton(`→`ldTon(`, and
   `_emptyProject`→`emptyScratchProject`. There are no other private
   references.
5. Nothing else changes — no tag, path, structDef, program, rung, block, wire,
   step, transition, sim rule, task or HMI id/binding/value.

Header and the exact renames:

```dart
// TEMPORARY transit file for the 13 default projects being retired by the
// default-projects redo (spec docs/superpowers/specs/2026-08-06-default-
// projects-redo-design.md). It keeps `DefaultProjects.all()` returning exactly
// the same 14 projects, in the same order, while the seven curated
// replacements are built and tested alongside it. DELETED by Task 8 of
// docs/superpowers/plans/2026-08-06-default-projects-redo.md.
library;

import '../../models/ld_graph.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject legacyMotorProject() { /* was _motorProject */ }
PlcProject legacyTankProject() => /* was _tankProject */;
PlcProject legacyStReactorProject() => /* was _stReactorProject */;
PlcProject legacyLdConveyorProject() => /* was _ldConveyorProject */;
PlcProject legacyFbdHvacProject() => /* was _fbdHvacProject */;
PlcProject legacySfcFillingProject() => /* was _sfcFillingProject */;
PlcProject legacySfcBatchMixProject() => /* was _sfcBatchMixProject */;
PlcProject legacyFbdPidTankLevelProject() => /* was _fbdPidTankLevelProject */;
PlcProject legacyFbdBatchCounterProject() => /* was _fbdBatchCounterProject */;
PlcProject legacyFbdPulseOutputProject() => /* was _fbdPulseOutputProject */;
PlcProject legacyCascadeTanksProject() => /* was _cascadeTanksProject */;
PlcProject legacyNoisyLevelProject() { /* was _noisyLevelProject */ }
PlcProject legacyMimoTwoZoneProject() => /* was _mimoTwoZoneProject */;
```

Keep each builder's existing doc comment attached to it (the PID gains note, the
batch-counter one-scan-delayed-feedback note, the pulse-output TP note, the
cascade dead-time note, the noisy-level note, the MIMO note) — those comments
*are* the explanation their tests rely on.

- [ ] **Step 7: Shrink `default_projects.dart` to the barrel**

Replace the whole of `mobile/lib/data/default_projects.dart` with:

```dart
// Barrel over `default_projects/` — one file per built-in project. This file's
// PATH and the `DefaultProjects.all()` signature are load-bearing: ~35 test
// files import `package:soft_plc_mobile/data/default_projects.dart`.
library;

import '../models/project_model.dart';
import 'default_projects/all_water_treatment.dart';
import 'default_projects/legacy_defaults.dart';

abstract class DefaultProjects {
  static List<PlcProject> all() => [
    legacyMotorProject(),
    legacyTankProject(),
    legacyStReactorProject(),
    legacyLdConveyorProject(),
    legacyFbdHvacProject(),
    legacySfcFillingProject(),
    legacySfcBatchMixProject(),
    allWaterTreatmentProject(),
    legacyFbdPidTankLevelProject(),
    legacyFbdBatchCounterProject(),
    legacyFbdPulseOutputProject(),
    legacyCascadeTanksProject(),
    legacyNoisyLevelProject(),
    legacyMimoTwoZoneProject(),
  ];
}
```

- [ ] **Step 8: Run analyze + the full suite**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`
Run: `/c/flutter/bin/flutter test`
Expected: all tests pass, including `test/defaults/all_water_test.dart` (proves
the water plant survived the move byte-identically).

- [ ] **Step 9: Create the test-only fixture library**

Create `mobile/test/support/legacy_demo_projects.dart`:

```dart
/// Retired default-project builders, preserved verbatim as test fixtures.
///
/// These are NOT shipped (see `mobile/lib/data/default_projects/` for the seven
/// curated defaults). They exist so engine tests whose assertions are tied to a
/// specific plant/timing keep their original harness: re-pointing them at a new
/// project would silently change what they prove.
library;

import 'package:soft_plc_mobile/models/project_model.dart';

// ── Batch Counter (CTU) ──────────────────────────────────────────────────
//
// Showcase for the CTU (count-up) function block: Part_Sensor pulses
// (simulated part arrivals passing a photo eye) drive CTU.CU. Each rising
// edge increments CV by exactly one — holding the sensor true does not
// over-count, because CTU is edge-triggered, not level-triggered. CV feeds
// Count (SimulatedOutput) and Q feeds Batch_Done once CV reaches Batch_Size.
//
// Self-reset is wired through tag feedback, not a same-scan topological
// cycle: a SECOND TAG_INPUT block reads Batch_Done and drives CTU.R. When
// Q fires, Batch_Done goes true THIS scan; the second TAG_INPUT block reads
// that new value only on the NEXT scan, so R resets CV to 0 one scan later —
// a clean, cycle-free, one-scan-delayed feedback reset. See
// test/counter_loop_integration_test.dart for the exact scan-by-scan
// behavior this produces.
PlcProject legacyBatchCounterProject() => /* verbatim copy of the former
    DefaultProjects._fbdBatchCounterProject() body, id 'proj_batch_counter' */;

// ── Pulse Output (R_TRIG + TP) ───────────────────────────────────────────
//
// Showcase for the R_TRIG edge detector gating a TP (pulse timer): each
// rising edge of Start_Btn fires exactly one Q pulse on R_TRIG, which starts
// TP. TP then holds Pulse_Out true for Pulse_Time ms REGARDLESS of how long
// Start_Btn stays held — TP is non-retriggerable. The sim rule drives
// Start_Btn with an on-phase (5000ms) deliberately LONGER than Pulse_Time
// (3000ms) so the demo visibly proves the output pulse width is set by TP,
// not by the button hold. See test/pulse_loop_integration_test.dart.
PlcProject legacyPulseOutputProject() => /* verbatim copy of the former
    DefaultProjects._fbdPulseOutputProject() body, id 'proj_pulse_output' */;
```

Copy the two builder bodies verbatim from
`mobile/lib/data/default_projects/legacy_defaults.dart`. Neither uses a ladder
shorthand or a scratch project, so no imports beyond `project_model.dart` are
needed.

- [ ] **Step 10: Re-point the two scan-index-exact tests at the fixtures**

In `mobile/test/counter_loop_integration_test.dart`, replace the
`default_projects.dart` import with `support/legacy_demo_projects.dart` and
change line 18:

```dart
    final p = legacyBatchCounterProject();
```

In `mobile/test/pulse_loop_integration_test.dart`, do the same:

```dart
    final p = legacyPulseOutputProject();
```

Leave every assertion in both files untouched.

- [ ] **Step 11: Run the two re-pointed tests, then the full suite**

Run: `/c/flutter/bin/flutter test test/counter_loop_integration_test.dart test/pulse_loop_integration_test.dart`
Expected: PASS with unchanged assertions.
Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 12: Commit**

```bash
git add mobile/lib/data/default_projects.dart mobile/lib/data/default_projects/ mobile/test/support/legacy_demo_projects.dart mobile/test/defaults/
git commit -m "refactor(defaults): split default_projects into a package + fixture library

- default_projects.dart becomes a barrel; all() output unchanged (14 projects, same order)
- shared ladder shorthands promoted to public builders.dart (Dart privacy is library-scoped)
- proj_all_water moved verbatim to its own documented file, guarded by a toJson() snapshot
- counter/pulse tests re-pointed at verbatim test-only fixtures"
```

---

### Task 2: Ladder — Conveyor Line (`proj_ld_conveyor_line`)

**Model:** sonnet · **Effort:** medium

**Deviation from the spec's §4.1 rung table (deliberate, see Resolutions R2/R3):**
the 13 sketched rungs become **23**. The spec's table left `Part_Present` and
`Zone2_Permit` with no driver, and put an `OTE-negated` coil on `Zone2_Request`,
which its own `EQ` rung also writes (two coils fighting over one tag). This task
therefore adds a `Part_Present` drive rung, a `TOF`-driven `Zone2_Permit` rung,
the `Zone2_Motor`-clearing behaviour that the FB's own `Permit` provides, and
the `falling` pulse coil (`Line_Stop_Edge` → `MOVE`) that §5's matrix claims but
§4.1 omits — with the negated coil re-homed onto a new `Batch_Running` tag.
New tags beyond §4.1's list: `PartCtu` (COUNTER — the LD `CTU` needs a backing
composite), `Zone2_Permit`, `Batch_Running`, `Line_Stop_Edge`.

**Files:**
- Create: `mobile/lib/data/default_projects/ladder_conveyor_line.dart`
- Create: `mobile/test/defaults/ld_conveyor_line_test.dart`

**Interfaces:**
- Consumes: `builders.dart` (`ldXic`, `ldXio`, `ldXicRising`, `ldXicFalling`,
  `ldOte`, `ldOteNeg`, `ldOtl`, `ldOtu`, `ldOsr`, `ldOsf`, `ldTon`, `ldTof`,
  `ldCtu`, `ldCmp`, `ldMath`, `ldMove`, `ldFbCall`, `emptyScratchProject`,
  `scratchProjectFor`) and `models/ld_graph.dart` (`buildRung`, `BranchSpec`).
- Produces: `PlcProject ladderConveyorLineProject()` — id `proj_ld_conveyor_line`,
  name `Ladder — Conveyor Line`, first tag `Start_PB`, one `LadderLogic` program
  `ConveyorLine_LD` (23 rungs), one ladder-bodied `FbDefinition` named
  `MotorStarter`, one HMI screen `hmi_ld_conveyor_line`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/defaults/ld_conveyor_line_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/ladder_conveyor_line.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
int _i(PlcProject p, String path) => (readPath(p, path) as num?)?.toInt() ?? 0;

/// One scan tick exactly as the workspace shell runs it for an LD-only
/// project: simulated inputs first, then ladder execution.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
}

void main() {
  test('seal-in latches on Start and drops on Stop and on E-Stop', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isFalse);
    expect(_b(p, 'Zone1_Motor'), isFalse);

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isTrue);
    expect(_b(p, 'Zone1_Motor'), isTrue);

    writePath(p, 'Start_PB', false); // seal-in holds
    _scan(p, sim, ld);
    expect(_b(p, 'Zone1_Motor'), isTrue);

    writePath(p, 'Stop_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isFalse);
    expect(_b(p, 'Zone1_Motor'), isFalse);
  });

  test('E-Stop latches Line_Fault; only a FRESH Start press unlatches it', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isFalse);

    writePath(p, 'EStop_OK', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isTrue);

    writePath(p, 'EStop_OK', true); // healthy again, but the fault LATCHES
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isTrue);

    writePath(p, 'Start_PB', true); // rising edge unlatches
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isFalse);

    // Holding Start is NOT a fresh press: re-fault, hold Start, no unlatch.
    writePath(p, 'EStop_OK', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Fault'), isTrue,
        reason: 'a held Start_PB gives no rising edge, so OTU never fires');
  });

  test('the pulse coil fires for exactly one scan per falling photo-eye edge, '
      'and Part_Count increments once per part (not once per scan)', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    // Part arrives (photo eye blocked) and stays blocked for 3 scans.
    writePath(p, 'Photo_Eye', true);
    for (var i = 0; i < 3; i++) {
      _scan(p, sim, ld);
      expect(_b(p, 'Part_Edge'), isFalse, reason: 'no falling edge yet');
    }
    expect(_i(p, 'Part_Count'), 0);

    // Part clears: exactly one falling edge -> one pulse -> one count.
    writePath(p, 'Photo_Eye', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Part_Edge'), isTrue);
    expect(_i(p, 'Part_Count'), 1);
    expect(_i(p, 'Shift_Total'), 1);

    _scan(p, sim, ld);
    expect(_b(p, 'Part_Edge'), isFalse, reason: 'the pulse coil is one scan wide');
    expect(_i(p, 'Part_Count'), 1, reason: 'no double count while the eye stays clear');
  });

  test('the FALLING pulse coil fires for one scan when the line stops and '
      'abandons the partial batch', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Stop_Edge'), isFalse);

    // Feed two parts so the batch is genuinely partial.
    for (var part = 0; part < 2; part++) {
      writePath(p, 'Photo_Eye', true);
      _scan(p, sim, ld);
      writePath(p, 'Photo_Eye', false);
      _scan(p, sim, ld);
    }
    expect(_i(p, 'Part_Count'), 2);

    writePath(p, 'Stop_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Stop_Edge'), isTrue, reason: 'falling power edge on Line_Latch');
    expect(_i(p, 'Part_Count'), 0, reason: 'the partial batch was abandoned');
    expect(_i(p, 'Shift_Total'), 2, reason: 'the shift total is never reset by a stop');

    _scan(p, sim, ld);
    expect(_b(p, 'Line_Stop_Edge'), isFalse, reason: 'the pulse coil is one scan wide');
  });

  test('SUB tracks Parts_Remaining, EQ requests zone 2, MOVE zeroes the batch, '
      'the negated coil clears Batch_Running, and CTU counts the parts', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);
    final target = _i(p, 'Batch_Target');
    expect(target, 10);

    var sawRequest = false;
    for (var part = 0; part < target; part++) {
      writePath(p, 'Photo_Eye', true);
      _scan(p, sim, ld);
      writePath(p, 'Photo_Eye', false);
      _scan(p, sim, ld);
      if (_b(p, 'Zone2_Request')) {
        sawRequest = true;
      }
    }

    expect(sawRequest, isTrue,
        reason: 'EQ Part_Count == Batch_Target must request zone 2 for at least one scan');
    expect(_i(p, 'PartCtu.CV'), target, reason: 'CTU counted one per part edge');
    expect(_i(p, 'Part_Count'), 0, reason: 'MOVE zeroed the count at the batch end');
    // Parts_Remaining is recomputed from the freshly-zeroed count.
    _scan(p, sim, ld);
    expect(_i(p, 'Parts_Remaining'), target);
    expect(_b(p, 'Batch_Running'), isTrue,
        reason: 'the negated coil re-asserts Batch_Running once the batch restarts');
  });

  test('the jam TON trips after 5 s without parts and a part clears it', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    for (var i = 0; i < 8; i++) {
      _scan(p, sim, ld);
      expect(_b(p, 'Zone1_Motor'), isTrue, reason: 'runs until the jam trips (scan $i)');
    }
    expect(_i(p, 'JamTimer.ACC'), 4500);

    _scan(p, sim, ld);
    expect(_b(p, 'JamTimer.DN'), isTrue);
    expect(_b(p, 'Belt_Jammed'), isTrue);

    _scan(p, sim, ld);
    expect(_b(p, 'Zone1_Motor'), isFalse, reason: 'the jam interlock opens rung 1');

    writePath(p, 'Photo_Eye', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Belt_Jammed'), isFalse, reason: 'a part unlatches the jam');
  });

  test('TOF holds the zone-2 permit for 3 s after the line stops', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);
    expect(_b(p, 'Zone2_Permit'), isTrue);

    writePath(p, 'Stop_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_Latch'), isFalse);
    expect(_b(p, 'Zone2_Permit'), isTrue, reason: 'TOF run-on has not expired');

    // 3000 ms preset at 500 ms/scan: still held at 2500, dropped at 3000.
    for (var i = 0; i < 4; i++) {
      _scan(p, sim, ld);
    }
    expect(_b(p, 'Zone2_Permit'), isTrue);
    _scan(p, sim, ld);
    expect(_b(p, 'Zone2_Permit'), isFalse);
  });

  test('the LADDER-BODIED MotorStarter FB keeps its seal-in state INSIDE the '
      'instance, not in a global tag', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    final fb = p.fbDefinitions.firstWhere((f) => f.name == 'MotorStarter');
    expect(fb.ladderRungs, isNotEmpty,
        reason: 'this FB is the ladder-bodied showcase — stSource must stay empty');
    expect(fb.stSource, isEmpty);
    expect(p.tags.any((t) => t.name == 'Seal'), isFalse,
        reason: 'Seal exists only as an FB-internal var, never as a global tag');

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    // Drive one part edge for every part in the batch so the EQ rung raises
    // Zone2_Request for a single scan; the FB must LATCH on that one scan.
    for (var part = 0; part < 10; part++) {
      writePath(p, 'Photo_Eye', true);
      _scan(p, sim, ld);
      writePath(p, 'Photo_Eye', false);
      _scan(p, sim, ld);
    }

    // The loop exits ON the scan where rung 10's EQ set Zone2_Request true;
    // rung 11's MOVE only zeroes Part_Count for the NEXT scan's comparison, so
    // step one scan further to see the request drop while the FB keeps holding.
    _scan(p, sim, ld);

    expect(_b(p, 'Zone2Starter.Seal'), isTrue,
        reason: 'the one-scan request sealed in inside the instance struct');
    expect(_b(p, 'Zone2_Motor'), isTrue);
    expect(_b(p, 'Zone2_Request'), isFalse,
        reason: 'the request itself is long gone — only the FB seal holds zone 2');

    // Dropping the permit (line stops, TOF expires) drops the FB seal and Out.
    writePath(p, 'Stop_PB', true);
    for (var i = 0; i < 10; i++) {
      _scan(p, sim, ld);
    }
    expect(_b(p, 'Zone2_Permit'), isFalse);
    expect(_b(p, 'Zone2Starter.Seal'), isFalse);
    expect(_b(p, 'Zone2_Motor'), isFalse);
  });

  test('the DUT members mirror the line state', () {
    final p = ladderConveyorLineProject();
    for (final r in p.simRules) {
      r.enabled = false;
    }
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_DUT.Running'), isTrue);
    expect(_i(p, 'Line_DUT.Speed'), 1450);
    expect(_b(p, 'Line_DUT.Faulted'), isFalse);

    writePath(p, 'EStop_OK', false);
    _scan(p, sim, ld);
    expect(_b(p, 'Line_DUT.Faulted'), isTrue);
  });

  test('with sim rules ON the line survives normal part passage', () {
    final p = ladderConveyorLineProject();
    final sim = SimRuntime();
    final ld = LdExecRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld);
    writePath(p, 'Start_PB', false);

    var sawPart = false;
    for (var i = 0; i < 30; i++) {
      _scan(p, sim, ld);
      if (_b(p, 'Photo_Eye')) {
        sawPart = true;
      }
      expect(_b(p, 'Zone1_Motor'), isTrue, reason: 'no jam while parts arrive (scan $i)');
      expect(_b(p, 'Belt_Jammed'), isFalse, reason: 'no jam while parts arrive (scan $i)');
    }
    expect(sawPart, isTrue, reason: 'the photo eye genuinely pulsed during the run');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/defaults/ld_conveyor_line_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package ... ladder_conveyor_line.dart`
(the target library does not exist yet).

- [ ] **Step 3: Write the project builder**

Create `mobile/lib/data/default_projects/ladder_conveyor_line.dart`:

```dart
/// **Ladder — Conveyor Line** (`proj_ld_conveyor_line`).
///
/// (a) Story: a two-zone conveyor line. The operator starts the line with a
/// beginner seal-in rung (absorbed from the retired "Basic Motor Start Stop"
/// demo), zone 1 runs under E-Stop/overload/jam interlocks, parts are counted
/// off the photo eye, a batch is tracked against a target, and zone 2 is
/// driven by a LADDER-BODIED custom function block.
///
/// (b) Showcase for the full LD element set: contacts `normal`/`negated`/
/// `rising`/`falling`; coils `normal`/`negated`/`set`/`reset`/`rising` and
/// `falling` (the two one-scan pulse coils); OR branches (`BranchSpec`);
/// `TON`, `TOF`, `CTU`; comparisons
/// `GT`/`LT`/`EQ`; arithmetic `ADD`/`SUB`/`MOVE`; a `TIMER` composite tag; a DUT
/// tag; and — the never-before-shipped headline — a **ladder-bodied
/// `FbDefinition`** (`MotorStarter`) whose seal-in state lives inside the
/// instance struct `Zone2Starter`, not in a global tag.
///
/// (c) Falsifiable: zeroing the seal-in branch makes Start a jog; removing the
/// rising contact on rung 3 lets a HELD Start clear the E-Stop fault latch;
/// removing the falling contact on rung 5 counts once per scan instead of once
/// per part; deleting the `MotorStarter` body leaves `Zone2_Motor` dead even
/// though the request pulses.
///
/// (d) Proof test: `test/defaults/ld_conveyor_line_test.dart` (plus the
/// re-pointed `test/ld_exec_integration_test.dart`).
library;

import '../../models/ld_graph.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject ladderConveyorLineProject() {
  final structDefs = [
    PlcStructDef(name: 'Line_DUT', fields: [
      StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Faulted', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
    ]),
  ];

  // Ladder-bodied custom FB. `stSource` stays EMPTY: a non-empty `ladderRungs`
  // is what selects the ladder dispatch in `fb_exec.dart`. `Seal` is an
  // INTERNAL var, so each instance keeps its own latch inside its struct tag.
  final motorStarterFb = FbDefinition(
    name: 'MotorStarter',
    vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Permit', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Seal', dataType: 'BOOL', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ],
    ladderRungs: [
      buildRung(
        index: 0,
        comment: 'FB rung 0: seal in the run request while the permit holds',
        main: [ldXic('Run', 'Run request'), ldXic('Permit', 'Permit'), ldOte('Seal', 'Instance seal')],
        branches: [
          BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Seal', 'Seal-in aux')]),
        ],
      ),
      buildRung(
        index: 1,
        comment: 'FB rung 1: drive the output from the sealed state',
        main: [ldXic('Seal', 'Sealed'), ldXic('Permit', 'Permit'), ldOte('Out', 'Starter output')],
      ),
    ],
  );

  final fbScratch = scratchProjectFor(fbDefinitions: [motorStarterFb]);
  final dutScratch = scratchProjectFor(structDefs: structDefs);

  return PlcProject(
    id: 'proj_ld_conveyor_line',
    name: 'Ladder — Conveyor Line',
    controllerName: 'PLC_LINE',
    scanPeriodMs: 100,
    fbDefinitions: [motorStarterFb],
    tags: [
      // Start_PB MUST stay first: persistence_integration_test asserts the
      // boot-active project's first tag is Start_PB.
      PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Line start pushbutton NO'),
      PlcTag(name: 'Stop_PB', path: 'Inputs/Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Line stop pushbutton NC'),
      PlcTag(name: 'EStop_OK', path: 'Inputs/EStop_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Emergency stop healthy (TRUE = healthy)'),
      PlcTag(name: 'Overload_OK', path: 'Inputs/Overload_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Thermal overload healthy'),
      PlcTag(name: 'Photo_Eye', path: 'Inputs/Photo_Eye', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Part detection photo eye'),
      PlcTag(name: 'Manual_Jog', path: 'Inputs/Manual_Jog', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Manual jog pushbutton (runs zone 1 without latching)'),
      PlcTag(name: 'Line_Latch', path: 'Internal/Line_Latch', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Line seal-in latch'),
      PlcTag(name: 'Part_Present', path: 'Internal/Part_Present', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Part present flag (follows the photo eye)'),
      PlcTag(name: 'Part_Edge', path: 'Internal/Part_Edge', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'One-scan pulse per part leaving the photo eye (rising pulse coil)'),
      PlcTag(name: 'Line_Stop_Edge', path: 'Internal/Line_Stop_Edge', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'One-scan pulse when the line stops (falling pulse coil) — abandons the partial batch'),
      PlcTag(name: 'Zone2_Request', path: 'Internal/Zone2_Request', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'One-scan zone-2 start request at batch completion'),
      PlcTag(name: 'Zone2_Permit', path: 'Internal/Zone2_Permit', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Zone-2 permit — TOF run-on 3s after the line stops'),
      PlcTag(name: 'Batch_Running', path: 'Internal/Batch_Running', dataType: 'BOOL', value: true, ioType: 'Internal', description: 'Batch in progress (negated coil: cleared when no parts remain)'),
      PlcTag(name: 'Zone1_Motor', path: 'Outputs/Zone1_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Zone 1 belt drive contactor'),
      PlcTag(name: 'Zone2_Motor', path: 'Outputs/Zone2_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Zone 2 belt drive contactor (driven by the MotorStarter FB)'),
      PlcTag(name: 'Belt_Jammed', path: 'Outputs/Belt_Jammed', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Belt jam alarm (latched)'),
      PlcTag(name: 'Line_Fault', path: 'Outputs/Line_Fault', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'E-Stop fault latch — requires a fresh Start press to clear'),
      PlcTag(name: 'JamTimer', path: 'Timers/JamTimer', dataType: 'TIMER', value: defaultValueFor(emptyScratchProject, 'TIMER', 0), ioType: 'Internal', description: 'On-delay timer: zone 1 running with no part for 5s trips the jam alarm'),
      PlcTag(name: 'StopDelay', path: 'Timers/StopDelay', dataType: 'TIMER', value: defaultValueFor(emptyScratchProject, 'TIMER', 0), ioType: 'Internal', description: 'Off-delay timer: holds the zone-2 permit 3s after the line stops'),
      PlcTag(name: 'PartCtu', path: 'Counters/PartCtu', dataType: 'COUNTER', value: defaultValueFor(emptyScratchProject, 'COUNTER', 0), ioType: 'Internal', description: 'Count-up counter: parts seen this batch (preset 10)'),
      PlcTag(name: 'Part_Count', path: 'Internal/Part_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Parts counted in the current batch'),
      PlcTag(name: 'Batch_Target', path: 'Internal/Batch_Target', dataType: 'INT32', value: 10, ioType: 'Internal', description: 'Parts per batch (kept in step with the CTU preset)'),
      PlcTag(name: 'Parts_Remaining', path: 'Internal/Parts_Remaining', dataType: 'INT32', value: 10, ioType: 'Internal', description: 'Batch_Target - Part_Count (SUB block)'),
      PlcTag(name: 'Shift_Total', path: 'Internal/Shift_Total', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Parts counted this shift (never reset by the batch)'),
      PlcTag(name: 'Zone2Starter', path: 'Internal/Zone2Starter', dataType: 'MotorStarter', value: defaultValueFor(fbScratch, 'MotorStarter', 0), ioType: 'Internal', description: 'Ladder-bodied MotorStarter FB instance driving zone 2'),
      PlcTag(name: 'Line_DUT', path: 'Status/Line_DUT', dataType: 'Line_DUT', value: defaultValueFor(dutScratch, 'Line_DUT', 0), ioType: 'Internal', description: 'Line status/telemetry struct instance'),
    ],
    structDefs: structDefs,
    simRules: [
      // Parts every ~4.5s while zone 1 runs, so the 5s no-part jam threshold
      // only trips once parts genuinely stop arriving.
      SimRule(id: 'sim0', name: 'Photo eye blips while zone 1 runs', targetPath: 'Photo_Eye',
          behavior: 'pulse', onMs: 2000, offMs: 2500,
          condition: [SimClause(leftPath: 'Zone1_Motor', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'ConveyorLine_LD',
        language: 'LadderLogic',
        description: 'Two-zone conveyor: seal-in, interlocks, part counting, batching, '
            'jam detection and a ladder-bodied MotorStarter FB for zone 2',
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Line Start/Stop Seal-In',
            main: [
              ldXic('Start_PB', 'Start NO'),
              ldXio('Stop_PB', 'Stop NC'),
              ldXic('EStop_OK', 'E-Stop healthy'),
              ldXic('Overload_OK', 'Overload healthy'),
              ldOte('Line_Latch', 'Seal-in latch'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Line_Latch', 'Seal-in aux')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Zone 1 Motor Permissives (jam interlock)',
            main: [
              ldXic('Line_Latch', 'Latched'),
              ldXic('EStop_OK', 'E-Stop healthy'),
              ldXio('Belt_Jammed', 'Jam interlock NC'),
              ldOte('Zone1_Motor', 'Zone 1 contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Manual_Jog', 'Manual jog')]),
            ],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: E-Stop Latches the Line Fault (SET coil)',
            main: [ldXio('EStop_OK', 'E-Stop opened'), ldOtl('Line_Fault', 'Latch fault')],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: A FRESH Start Press Unlatches the Fault (rising contact + RESET coil)',
            main: [ldXicRising('Start_PB', 'Start rising edge'), ldOtu('Line_Fault', 'Unlatch fault')],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Part Present Flag',
            main: [ldXic('Photo_Eye', 'Eye blocked'), ldOte('Part_Present', 'Part present')],
          ),
          buildRung(
            index: 5,
            comment: 'Rung 5: Part Leaves the Eye — falling contact drives a one-scan pulse coil',
            main: [ldXicFalling('Photo_Eye', 'Eye clears'), ldOsr('Part_Edge', 'One-scan pulse')],
          ),
          buildRung(
            index: 6,
            comment: 'Rung 6: Count the Part into the Batch (ADD)',
            main: [ldXic('Part_Edge', 'One part'), ldMath('ADD', 'Part_Count', 'Part_Count', '1', 'Part_Count + 1')],
          ),
          buildRung(
            index: 7,
            comment: 'Rung 7: Count the Part into the Shift Total (ADD)',
            main: [ldXic('Part_Edge', 'One part'), ldMath('ADD', 'Shift_Total', 'Shift_Total', '1', 'Shift_Total + 1')],
          ),
          buildRung(
            index: 8,
            comment: 'Rung 8: Parts Remaining in the Batch (SUB)',
            main: [ldXic('Line_Latch', 'Line running'), ldMath('SUB', 'Parts_Remaining', 'Batch_Target', 'Part_Count', 'Target - Count')],
          ),
          buildRung(
            index: 9,
            comment: 'Rung 9: Batch Part Counter (GT gate + CTU)',
            main: [
              ldCmp('GT', 'Part_Count', '0', 'Batch started'),
              ldXic('Part_Edge', 'One part'),
              ldCtu('PartCtu', 10, 'Parts per batch'),
            ],
          ),
          buildRung(
            index: 10,
            comment: 'Rung 10: Batch Complete Requests Zone 2 (EQ)',
            main: [ldCmp('EQ', 'Part_Count', 'Batch_Target', 'Count = Target'), ldOte('Zone2_Request', 'Zone 2 request')],
          ),
          buildRung(
            index: 11,
            comment: 'Rung 11: Batch Complete Zeroes the Count (LT + MOVE)',
            main: [ldCmp('LT', 'Parts_Remaining', '1', 'Nothing left'), ldMove('Part_Count', '0', '0 -> Part_Count')],
          ),
          buildRung(
            index: 12,
            comment: 'Rung 12: Batch Running Flag (NEGATED coil)',
            main: [ldCmp('LT', 'Parts_Remaining', '1', 'Nothing left'), ldOteNeg('Batch_Running', 'Inverted: batch idle')],
          ),
          buildRung(
            index: 13,
            comment: 'Rung 13: Jam Detection — zone 1 running with no part for 5s (TON)',
            main: [
              ldXic('Zone1_Motor', 'Zone 1 running'),
              ldXio('Part_Present', 'No part NC'),
              ldTon('JamTimer', 5000, '5s jam timer'),
            ],
          ),
          buildRung(
            index: 14,
            comment: 'Rung 14: Latch the Jam Alarm',
            main: [ldXic('JamTimer.DN', 'Timer done'), ldOtl('Belt_Jammed', 'Latch jam')],
          ),
          buildRung(
            index: 15,
            comment: 'Rung 15: A Part Clears the Jam Alarm',
            main: [ldXic('Photo_Eye', 'Part seen'), ldOtu('Belt_Jammed', 'Unlatch jam')],
          ),
          buildRung(
            index: 16,
            comment: 'Rung 16: Zone 2 Permit — 3s off-delay run-on after the line stops (TOF)',
            main: [
              ldXic('Line_Latch', 'Line running'),
              ldTof('StopDelay', 3000, '3s run-on'),
              ldOte('Zone2_Permit', 'Zone 2 permit'),
            ],
          ),
          buildRung(
            index: 17,
            comment: 'Rung 17: Zone 2 Starter — LADDER-BODIED custom FB call. '
                'Unconditional (wired straight off the left rail) so the FB keeps '
                'evaluating its own Permit and can drop its seal when the permit goes away.',
            main: [
              ldFbCall('MotorStarter', 'Zone2Starter', {
                'Run': 'Zone2_Request',
                'Permit': 'Zone2_Permit',
                'Out': 'Zone2_Motor',
              }, 'Zone 2 starter instance'),
            ],
          ),
          buildRung(
            index: 18,
            comment: 'Rung 18: DUT — Running member',
            main: [ldXic('Zone1_Motor', 'Zone 1 running'), ldOte('Line_DUT.Running', 'DUT.Running')],
          ),
          buildRung(
            index: 19,
            comment: 'Rung 19: DUT — Faulted member',
            main: [ldXic('Line_Fault', 'Line faulted'), ldOte('Line_DUT.Faulted', 'DUT.Faulted')],
          ),
          buildRung(
            index: 20,
            comment: 'Rung 20: DUT — Speed member (MOVE)',
            main: [ldXic('Zone1_Motor', 'Zone 1 running'), ldMove('Line_DUT.Speed', '1450', 'Nameplate rpm')],
          ),
          buildRung(
            index: 21,
            comment: 'Rung 21: Line Stopped — one-scan pulse on the FALLING power edge',
            main: [ldXic('Line_Latch', 'Line running'), ldOsf('Line_Stop_Edge', 'One-scan stop pulse')],
          ),
          buildRung(
            index: 22,
            comment: 'Rung 22: Stopping the Line Abandons the Partial Batch (MOVE)',
            main: [ldXic('Line_Stop_Edge', 'Line just stopped'), ldMove('Part_Count', '0', '0 -> Part_Count')],
          ),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'LineTask', type: 'Continuous', periodMs: 100, programNames: ['ConveyorLine_LD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_ld_conveyor_line',
        title: 'Conveyor Line HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'cl1', title: 'START Line (NO)', type: 'PushbuttonSwitch', tagBinding: 'Start_PB', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'cl2', title: 'STOP Line (NC)', type: 'PushbuttonSwitch', tagBinding: 'Stop_PB', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'cl3', title: 'Manual JOG', type: 'PushbuttonSwitch', tagBinding: 'Manual_Jog', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'cl4', title: 'E-Stop Healthy', type: 'ToggleSwitch', tagBinding: 'EStop_OK', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'cl5', title: 'Overload Healthy', type: 'ToggleSwitch', tagBinding: 'Overload_OK', gridSpanWidth: 1, accentColor: 'teal'),
          HmiComponent(id: 'cl6', title: 'Zone 1 Running', type: 'LedIndicatorLight', tagBinding: 'Zone1_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'cl7', title: 'Zone 2 Running', type: 'LedIndicatorLight', tagBinding: 'Zone2_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'cl8', title: 'Part Detected', type: 'LedIndicatorLight', tagBinding: 'Photo_Eye', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'cl9', title: 'Parts Counted', type: 'DigitalGaugeDisplay', tagBinding: 'Part_Count', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'cl10', title: 'Parts Remaining', type: 'DigitalGaugeDisplay', tagBinding: 'Parts_Remaining', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'cl11', title: 'Batch Target', type: 'NumericSliderInput', tagBinding: 'Batch_Target', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'cl12', title: 'JAM ALARM', type: 'StatusPillDisplay', tagBinding: 'Belt_Jammed', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'cl13', title: 'LINE FAULT', type: 'StatusPillDisplay', tagBinding: 'Line_Fault', gridSpanWidth: 2, accentColor: 'red'),
        ],
      ),
    ],
  );
}
```

- [ ] **Step 4: Run the new test**

Run: `/c/flutter/bin/flutter test test/defaults/ld_conveyor_line_test.dart`
Expected: PASS (all nine tests).
If the "batch complete" test fails on `Zone2_Request`, check rung ordering: the
EQ rung (10) **must** precede the MOVE rung (11), otherwise the count is zeroed
before the comparison ever sees it.

- [ ] **Step 5: Run analyze + full suite**

Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass (the new project is not in
`all()` yet, so nothing else can regress).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/data/default_projects/ladder_conveyor_line.dart mobile/test/defaults/ld_conveyor_line_test.dart
git commit -m "feat(defaults): add Ladder — Conveyor Line showcase project

Full LD element coverage (edge contacts, pulse/negated/set/reset coils, TON/TOF/CTU,
GT/LT/EQ, ADD/SUB/MOVE, OR branches, TIMER/COUNTER/DUT tags) plus the first shipped
LADDER-BODIED custom function block (MotorStarter -> Zone2Starter)."
```

---

### Task 3: FBD — HVAC Zone Controller (`proj_fbd_hvac_zone`)

**Model:** opus · **Effort:** high

Densest hand-written artefact in the plan: seven networks, ~90 blocks and ~70
wires, with three block families (`CTD` preload, `TP`/`R_TRIG` interaction,
same-scan cross-network tag reads) whose exact engine semantics decide whether
the diagram works at all.

**Files:**
- Create: `mobile/lib/data/default_projects/fbd_hvac_zone.dart`
- Create: `mobile/test/defaults/fbd_hvac_zone_test.dart`

**Interfaces:**
- Consumes: `builders.dart` (`scratchProjectFor`).
- Produces: `PlcProject fbdHvacZoneProject()` — id `proj_fbd_hvac_zone`, name
  `FBD — HVAC Zone Controller`, one `FunctionBlockDiagram` program
  `HvacZone_FBD` with **seven networks**, one ST-bodied `FbDefinition` named
  `SetpointShift` (instance tag `ZoneShift`), two HMI screens
  `hmi_fbd_hvac_zone` and `hmi_fbd_hvac_tank`.
- Binding constraint for Task 8: this project keeps the tag names
  `Room_Temp`, `Setpoint`, `Occupied`, `Window_Open`, `Fan_Cmd`, `Heat_Cmd`,
  `Cool_Cmd`, `Hvac_Active` (re-pointed HVAC truth table) **and**
  `Level_PV`, `Level_SP`, `Auto_Mode`, `Fill_Valve`, `Drain_Valve`,
  `High_Alarm` (re-pointed tank fill/drain case) with identical semantics
  (±1.0 °C deadband around `Setpoint`; ±5.0 % deadband around `Level_SP`;
  high alarm above 85.0 %).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/defaults/fbd_hvac_zone_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/fbd_hvac_zone.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();
int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

void main() {
  late PlcProject p;
  late FbdRuntime rt;

  setUp(() {
    p = fbdHvacZoneProject();
    for (final r in p.simRules) {
      r.enabled = false; // hand-drive the inputs; no plant drift
    }
    rt = FbdRuntime();
  });

  void scan([int dtMs = 500]) {
    applySimRules(p, p.simRules, dtMs, SimRuntime());
    executeFbdPrograms(p, dtMs, rt);
  }

  test('the program has seven networks', () {
    final prog = p.programs.firstWhere((x) => x.name == 'HvacZone_FBD');
    expect(prog.fbdNetworks.length, 7);
  });

  test('occupancy / override / window enable truth table (NOT, AND, OR)', () {
    void set(bool occ, bool ovr, bool win) {
      writePath(p, 'Occupied', occ);
      writePath(p, 'Override_On', ovr);
      writePath(p, 'Window_Open', win);
    }

    set(true, false, false);
    scan();
    expect(_b(p, 'Hvac_Active'), isTrue);
    expect(_b(p, 'Fan_Cmd'), isTrue);

    set(false, false, false);
    scan();
    expect(_b(p, 'Hvac_Active'), isFalse);

    set(false, true, false); // override alone enables (the OR)
    scan();
    expect(_b(p, 'Hvac_Active'), isTrue);

    set(true, true, true); // an open window vetoes everything (the NOT + AND)
    scan();
    expect(_b(p, 'Hvac_Active'), isFalse);
    expect(_b(p, 'Fan_Cmd'), isFalse);
  });

  test('heat/cool deadband around Setpoint (SUB/ADD/LT/GT/AND)', () {
    void set(double temp, double sp) {
      writePath(p, 'Occupied', true);
      writePath(p, 'Window_Open', false);
      writePath(p, 'Room_Temp', temp);
      writePath(p, 'Setpoint', sp);
    }

    set(18.0, 21.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isTrue);
    expect(_b(p, 'Cool_Cmd'), isFalse);

    set(24.0, 21.0);
    scan();
    expect(_b(p, 'Cool_Cmd'), isTrue);
    expect(_b(p, 'Heat_Cmd'), isFalse);

    set(21.0, 21.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
  });

  test('SEL picks comfort vs setback, and the DIV/ADD/SUB/LIMIT chain clamps '
      'the effective setpoint; MUL computes the span', () {
    writePath(p, 'Level_PV', 50.0); // Level_PV/50 == 1.0 reset trim
    writePath(p, 'Occupied', true);
    scan();
    // SEL -> Comfort_SP (22.0); + (50/50 = 1.0) - 1.0 = 22.0; LIMIT 16..28.
    expect(_d(p, 'Effective_SP'), closeTo(22.0, 1e-9));

    writePath(p, 'Occupied', false);
    scan();
    // SEL -> Setback_SP (18.0); + 1.0 - 1.0 = 18.0.
    expect(_d(p, 'Effective_SP'), closeTo(18.0, 1e-9));

    // A higher level pushes the reset schedule up: 22 + (100/50) - 1 = 23.
    writePath(p, 'Occupied', true);
    writePath(p, 'Level_PV', 100.0);
    scan();
    expect(_d(p, 'Effective_SP'), closeTo(23.0, 1e-9));

    // (Comfort_SP - Setback_SP) * 2.0 = (22 - 18) * 2 = 8.
    expect(_d(p, 'Sp_Span'), closeTo(8.0, 1e-9));
  });

  test('the six comparators agree with direct arithmetic on the same inputs', () {
    writePath(p, 'Occupied', true);
    writePath(p, 'Level_PV', 50.0); // Effective_SP == Comfort_SP == 22.0
    writePath(p, 'Setpoint', 22.0);

    for (final t in <double>[18.0, 22.0, 26.0]) {
      writePath(p, 'Room_Temp', t);
      scan();
      final esp = _d(p, 'Effective_SP');
      expect(_b(p, 'Temp_GE'), t >= esp, reason: 'GE at $t vs $esp');
      expect(_b(p, 'Temp_LE'), t <= esp, reason: 'LE at $t vs $esp');
      expect(_b(p, 'Temp_EQ'), t == esp, reason: 'EQ at $t vs $esp');
      expect(_b(p, 'Temp_NE'), t != esp, reason: 'NE at $t vs $esp');
    }
  });

  test('TON staging delay, TOF fan run-on, TP purge one-shot, R_TRIG/F_TRIG '
      'each fire for exactly one scan', () {
    writePath(p, 'Occupied', true);
    writePath(p, 'Window_Open', false);
    writePath(p, 'Setpoint', 21.0);
    writePath(p, 'Room_Temp', 10.0); // hard call for heat

    // Networks execute in ASCENDING INDEX ORDER within a single scan, so net 2
    // writes Heat_Cmd and net 3's R_TRIG/TON/TP read it back on that same scan.
    scan();
    expect(_b(p, 'Heat_Cmd'), isTrue);
    expect(_b(p, 'Heat_Start_Edge'), isTrue, reason: 'R_TRIG on the heat call');
    expect(_b(p, 'Purge_Pulse'), isTrue, reason: 'TP started by the R_TRIG pulse (ET 500 < 2000)');
    expect(_b(p, 'Heat_Stage2'), isFalse, reason: 'TON is at 500 ms of its 5000 ms preset');

    scan();
    expect(_b(p, 'Heat_Start_Edge'), isFalse, reason: 'R_TRIG is one scan wide');

    // 5000 ms TON at 500 ms/scan.
    for (var i = 0; i < 10; i++) {
      scan();
    }
    expect(_b(p, 'Heat_Stage2'), isTrue);
    expect(_b(p, 'Purge_Pulse'), isFalse, reason: 'the 2000 ms TP has expired');

    // Drop the heat call: F_TRIG fires once (same scan, net 3 after net 2),
    // and the fan TOF holds for 10 s.
    writePath(p, 'Room_Temp', 21.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Heat_Stop_Edge'), isTrue, reason: 'F_TRIG on the heat drop');
    scan();
    expect(_b(p, 'Heat_Stop_Edge'), isFalse);

    writePath(p, 'Occupied', false); // Fan_Cmd drops; TOF keeps Fan_RunOn true
    scan();
    expect(_b(p, 'Fan_Cmd'), isFalse);
    expect(_b(p, 'Fan_RunOn'), isTrue);
    for (var i = 0; i < 22; i++) {
      scan();
    }
    expect(_b(p, 'Fan_RunOn'), isFalse, reason: 'the 10 s run-on expired');
  });

  test('CTU counts heat starts, CTD counts filter life down, CTUD tracks the '
      'occupancy net', () {
    writePath(p, 'Occupied', true);
    writePath(p, 'Window_Open', false);
    writePath(p, 'Setpoint', 21.0);

    // Lead-in scan with the room ABOVE setpoint: no heat call, so the CTD's
    // one-shot LD preload lands on a scan with no CD edge. `fbd_exec`'s CTD
    // takes the LD branch OR the CD branch, never both in one scan — without
    // this the first heat start would be swallowed by the preload.
    writePath(p, 'Room_Temp', 30.0);
    scan();

    for (var cycle = 0; cycle < 3; cycle++) {
      writePath(p, 'Room_Temp', 10.0);
      scan();
      scan();
      writePath(p, 'Room_Temp', 30.0);
      scan();
      scan();
    }
    expect(_i(p, 'Heat_Starts'), 3, reason: 'one CTU count per heat start');
    expect(_i(p, 'Filter_Life'), 97,
        reason: 'the first-scan R_TRIG preloaded CV to the 100 preset, then the '
            'same three heat-start edges counted it down');
    expect(_b(p, 'Filter_Due'), isFalse,
        reason: 'without the preload the CTD would sit at CV 0 and Q would be '
            'true from scan 1 — this is what makes the countdown falsifiable');

    // CTUD: occupancy falls then rises — one down-count and one up-count cancel.
    final before = _i(p, 'Occupancy_Net');
    writePath(p, 'Occupied', false);
    scan();
    scan();
    writePath(p, 'Occupied', true);
    scan();
    scan();
    expect(_i(p, 'Occupancy_Net'), before);

    writePath(p, 'Ctu_Reset', true);
    scan();
    expect(_i(p, 'Heat_Starts'), 0, reason: 'the CTU reset pin works');
  });

  test('the absorbed tank network fills below SP-5, drains above SP+5 and '
      'alarms above the high limit', () {
    void set(bool auto, double pv, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Level_PV', pv);
      writePath(p, 'Level_SP', sp);
    }

    set(true, 40.0, 50.0);
    scan();
    expect(_b(p, 'Fill_Valve'), isTrue);
    expect(_b(p, 'Drain_Valve'), isFalse);
    expect(_b(p, 'High_Alarm'), isFalse);

    set(true, 60.0, 50.0);
    scan();
    expect(_b(p, 'Drain_Valve'), isTrue);
    expect(_b(p, 'Fill_Valve'), isFalse);

    set(true, 50.0, 50.0);
    scan();
    expect(_b(p, 'Fill_Valve'), isFalse);
    expect(_b(p, 'Drain_Valve'), isFalse);

    set(false, 40.0, 50.0);
    scan();
    expect(_b(p, 'Fill_Valve'), isFalse);

    set(false, 90.0, 50.0);
    scan();
    expect(_b(p, 'High_Alarm'), isTrue);
  });

  test('the ST-bodied SetpointShift FB drops the setpoint when unoccupied', () {
    final fb = p.fbDefinitions.firstWhere((f) => f.name == 'SetpointShift');
    expect(fb.stSource, isNotEmpty);
    expect(fb.ladderRungs, isEmpty, reason: 'this one is the ST-bodied showcase');

    writePath(p, 'Occupied', true);
    scan();
    expect(_d(p, 'Shifted_SP'), closeTo(22.0, 1e-9));

    writePath(p, 'Occupied', false);
    scan();
    expect(_d(p, 'Shifted_SP'), closeTo(18.0, 1e-9),
        reason: 'Base 22.0 - Setback 4.0');
  });

  test('with sim rules ON the room converges toward the setpoint', () {
    final live = fbdHvacZoneProject();
    final liveRt = FbdRuntime();
    final sim = SimRuntime();
    writePath(live, 'Occupied', true);
    writePath(live, 'Window_Open', false);
    writePath(live, 'Setpoint', 22.0);
    writePath(live, 'Room_Temp', 15.0);
    for (var i = 0; i < 400; i++) {
      applySimRules(live, live.simRules, 500, sim);
      executeFbdPrograms(live, 500, liveRt);
    }
    expect((readPath(live, 'Room_Temp') as num).toDouble(), closeTo(22.0, 2.0),
        reason: 'the on/off deadband controller must reach the comfort band');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/defaults/fbd_hvac_zone_test.dart`
Expected: FAIL — the library `fbd_hvac_zone.dart` does not exist.

- [ ] **Step 3: Write the project builder**

Create `mobile/lib/data/default_projects/fbd_hvac_zone.dart`:

```dart
/// **FBD — HVAC Zone Controller** (`proj_fbd_hvac_zone`).
///
/// (a) Story: a single HVAC zone plus the water tank it shares a plant room
/// with. Occupancy, an override switch and a window contact decide whether the
/// zone is enabled; a ±1 °C deadband calls for heat or cool; a reset schedule
/// derives an effective setpoint from the reservoir level; staging timers and
/// edge detectors sequence the second heat stage, the fan run-on and a purge
/// one-shot; three counters track heat starts, filter life and net occupancy;
/// and the absorbed tank network (from the retired "Tank Level Simulation")
/// fills, drains and alarms on level.
///
/// (b) Showcase for the whole FBD palette across seven networks:
/// `NOT`/`AND`/`OR`; `ADD`/`SUB`/`MUL`/`DIV`; `GT`/`LT`/`GE`/`LE`/`EQ`/`NE`;
/// `LIMIT`; `SEL`; `TON`/`TOF`/`TP`; `CTU`/`CTD`/`CTUD`; `R_TRIG`/`F_TRIG`;
/// `CONST`/`TAG_INPUT`/`TAG_OUTPUT`; and an **ST-bodied custom function block**
/// (`SetpointShift`, instance `ZoneShift`). Data crosses networks through tags,
/// never wires — the same pattern `WaterQuality_FBD` established, and networks
/// execute in index order within one scan so a later network reads what an
/// earlier one just wrote.
///
/// (c) Falsifiable: deleting the `NOT` lets an open window keep the zone
/// running; collapsing the `SEL` makes comfort and setback the same setpoint;
/// removing the `R_TRIG` makes the `CTU` count every scan the heater is on
/// instead of once per start; deleting the tank comparators leaves both valves
/// dead.
///
/// (d) Proof test: `test/defaults/fbd_hvac_zone_test.dart` (plus the
/// re-pointed HVAC and tank cases in `test/fbd_exec_integration_test.dart`).
library;

import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject fbdHvacZoneProject() {
  final setpointShiftFb = FbDefinition(
    name: 'SetpointShift',
    stSource: 'IF Occupied THEN\n'
        '    Sp := Base;\n'
        'ELSE\n'
        '    Sp := Base - Setback;\n'
        'END_IF;',
    vars: [
      FbVar(name: 'Occupied', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Base', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 22.0),
      FbVar(name: 'Setback', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 4.0),
      FbVar(name: 'Sp', dataType: 'FLOAT64', direction: FbVarDir.output, initialValue: 22.0),
    ],
  );
  final fbScratch = scratchProjectFor(fbDefinitions: [setpointShiftFb]);

  return PlcProject(
    id: 'proj_fbd_hvac_zone',
    name: 'FBD — HVAC Zone Controller',
    controllerName: 'PLC_HVAC',
    scanPeriodMs: 100,
    fbDefinitions: [setpointShiftFb],
    tags: [
      // ── Zone temperature control ──────────────────────────────────────
      PlcTag(name: 'Room_Temp', path: 'Inputs/Room_Temp', dataType: 'FLOAT64', value: 18.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Zone temperature sensor'),
      PlcTag(name: 'Setpoint', path: 'Internal/Setpoint', dataType: 'FLOAT64', value: 22.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Active comfort setpoint (±1 °C deadband)'),
      PlcTag(name: 'Occupied', path: 'Inputs/Occupied', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Zone occupancy sensor'),
      PlcTag(name: 'Window_Open', path: 'Inputs/Window_Open', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Window contact switch (vetoes HVAC)'),
      PlcTag(name: 'Override_On', path: 'Inputs/Override_On', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Manual occupancy override'),
      PlcTag(name: 'Fan_Cmd', path: 'Outputs/Fan_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Zone fan motor command'),
      PlcTag(name: 'Heat_Cmd', path: 'Outputs/Heat_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Heating coil valve'),
      PlcTag(name: 'Cool_Cmd', path: 'Outputs/Cool_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Cooling coil valve'),
      PlcTag(name: 'Hvac_Active', path: 'Internal/Hvac_Active', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'HVAC enabled (network 0 result, read back by network 2)'),
      // ── Effective-setpoint schedule ───────────────────────────────────
      PlcTag(name: 'Comfort_SP', path: 'Internal/Comfort_SP', dataType: 'FLOAT64', value: 22.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Occupied comfort setpoint'),
      PlcTag(name: 'Setback_SP', path: 'Internal/Setback_SP', dataType: 'FLOAT64', value: 18.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Unoccupied setback setpoint'),
      PlcTag(name: 'Effective_SP', path: 'Internal/Effective_SP', dataType: 'FLOAT64', value: 22.0, ioType: 'Internal', engineeringUnits: '°C', description: 'SEL(occupancy) + level reset, clamped 16–28 °C'),
      PlcTag(name: 'Sp_Span', path: 'Internal/Sp_Span', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: '°C', description: '(Comfort_SP - Setback_SP) * 2 — displayed schedule span'),
      // ── Comparator bank ───────────────────────────────────────────────
      PlcTag(name: 'Temp_GE', path: 'Internal/Temp_GE', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Room_Temp >= Effective_SP'),
      PlcTag(name: 'Temp_LE', path: 'Internal/Temp_LE', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Room_Temp <= Effective_SP'),
      PlcTag(name: 'Temp_EQ', path: 'Internal/Temp_EQ', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Room_Temp == Effective_SP'),
      PlcTag(name: 'Temp_NE', path: 'Internal/Temp_NE', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Room_Temp != Effective_SP'),
      // ── Staging timers and edges ──────────────────────────────────────
      PlcTag(name: 'Heat_Stage2', path: 'Outputs/Heat_Stage2', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Second heat stage — TON 5 s after the first call'),
      PlcTag(name: 'Fan_RunOn', path: 'Outputs/Fan_RunOn', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fan run-on — TOF 10 s after the fan command drops'),
      PlcTag(name: 'Purge_Pulse', path: 'Outputs/Purge_Pulse', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Purge damper one-shot — TP 2 s per heat start'),
      PlcTag(name: 'Heat_Start_Edge', path: 'Internal/Heat_Start_Edge', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'R_TRIG on Heat_Cmd (one scan)'),
      PlcTag(name: 'Heat_Stop_Edge', path: 'Internal/Heat_Stop_Edge', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'F_TRIG on Heat_Cmd (one scan)'),
      PlcTag(name: 'Occ_Rise', path: 'Internal/Occ_Rise', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'R_TRIG on Occupied (CTUD up input)'),
      PlcTag(name: 'Occ_Fall', path: 'Internal/Occ_Fall', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'F_TRIG on Occupied (CTUD down input)'),
      // ── Counters ──────────────────────────────────────────────────────
      PlcTag(name: 'Ctu_Reset', path: 'Inputs/Ctu_Reset', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Reset the heat-start counter'),
      // Ships TRUE so the network-4 R_TRIG fires on the FIRST scan and preloads
      // the CTD's CV to its 100 preset — `fbd_exec.dart`'s CTD has no
      // first-scan preload of its own. Toggling it off and on again reloads the
      // countdown, which is exactly what a filter change should do.
      PlcTag(name: 'Filter_Load', path: 'Inputs/Filter_Load', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Reload the filter-life countdown to its preset (edge-triggered; ships true to preload on the first scan)'),
      PlcTag(name: 'Occ_Reset', path: 'Inputs/Occ_Reset', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Reset the occupancy up/down counter'),
      PlcTag(name: 'Occ_Load', path: 'Inputs/Occ_Load', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Preload the occupancy up/down counter'),
      PlcTag(name: 'Heat_Starts', path: 'Internal/Heat_Starts', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'CTU.CV — heat starts since reset'),
      PlcTag(name: 'Heat_Starts_Done', path: 'Internal/Heat_Starts_Done', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'CTU.Q — 20 heat starts reached'),
      PlcTag(name: 'Filter_Life', path: 'Internal/Filter_Life', dataType: 'INT32', value: 100, ioType: 'Internal', description: 'CTD.CV — filter life remaining'),
      PlcTag(name: 'Filter_Due', path: 'Outputs/Filter_Due', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'CTD.Q — filter change due'),
      PlcTag(name: 'Occupancy_Net', path: 'Internal/Occupancy_Net', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'CTUD.CV — occupancy in minus out'),
      PlcTag(name: 'Occ_Full', path: 'Internal/Occ_Full', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'CTUD.QU — zone at capacity'),
      PlcTag(name: 'Occ_Empty', path: 'Internal/Occ_Empty', dataType: 'BOOL', value: true, ioType: 'Internal', description: 'CTUD.QD — zone empty'),
      // ── Absorbed tank network ─────────────────────────────────────────
      PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 42.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Plant-room reservoir level sensor'),
      PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal', engineeringUnits: '%', description: 'Level setpoint (±5 % deadband)'),
      PlcTag(name: 'Auto_Mode', path: 'Inputs/Auto_Mode', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Tank auto/manual switch'),
      PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fill valve solenoid'),
      PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Drain valve solenoid'),
      PlcTag(name: 'High_Alarm', path: 'Outputs/High_Alarm', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'High level alarm (> 85 %)'),
      // ── Custom FB ─────────────────────────────────────────────────────
      PlcTag(name: 'Shifted_SP', path: 'Internal/Shifted_SP', dataType: 'FLOAT64', value: 22.0, ioType: 'Internal', engineeringUnits: '°C', description: 'SetpointShift FB output'),
      PlcTag(name: 'ZoneShift', path: 'Internal/ZoneShift', dataType: 'SetpointShift', value: defaultValueFor(fbScratch, 'SetpointShift', 0), ioType: 'Internal', description: 'ST-bodied SetpointShift FB instance'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Heating warms room', targetPath: 'Room_Temp',
          behavior: 'integrate', ratePerSec: 0.16, minValue: 0, maxValue: 40,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Cooling cools room', targetPath: 'Room_Temp',
          behavior: 'integrate', ratePerSec: -0.16, minValue: 0, maxValue: 40,
          condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim2', name: 'Ambient drift', targetPath: 'Room_Temp',
          behavior: 'integrate', ratePerSec: -0.02, minValue: 15, maxValue: 40,
          condition: [
            SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'false'),
            SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'false'),
          ]),
      SimRule(id: 'sim3', name: 'Tank fills while filling', targetPath: 'Level_PV',
          behavior: 'integrate', ratePerSec: 1.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim4', name: 'Tank drains while draining', targetPath: 'Level_PV',
          behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Drain_Valve', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'HvacZone_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Seven-network HVAC zone controller: enable logic, effective-setpoint '
            'schedule, comparator bank + heat/cool deadband, staging timers and edges, '
            'cycle counters, the absorbed tank fill/drain network, and a custom FB',
        fbdNetworks: [
          FbdNetwork(comment: 'Occupancy, override and window — HVAC enable'),
          FbdNetwork(comment: 'Effective setpoint — SEL schedule + level reset, clamped'),
          FbdNetwork(comment: 'Comparator bank and the ±1 °C heat/cool deadband'),
          FbdNetwork(comment: 'Staging timers and edge detectors'),
          FbdNetwork(comment: 'Cycle counters — heat starts, filter life, occupancy net'),
          FbdNetwork(comment: 'Reservoir fill/drain deadband and high alarm'),
          FbdNetwork(comment: 'Custom function block — SetpointShift'),
        ],
        fbdBlocks: [
          // ── Network 0 ─────────────────────────────────────────────────
          FbdBlock(id: 'n0_occ', type: 'TAG_INPUT', title: 'Occupied', tagBinding: 'Occupied', x: 50, y: 80, network: 0),
          FbdBlock(id: 'n0_ovr', type: 'TAG_INPUT', title: 'Override On', tagBinding: 'Override_On', x: 50, y: 190, network: 0),
          FbdBlock(id: 'n0_or', type: 'OR', title: 'Occupied OR Override', x: 260, y: 120, network: 0),
          FbdBlock(id: 'n0_win', type: 'TAG_INPUT', title: 'Window Open', tagBinding: 'Window_Open', x: 50, y: 300, network: 0),
          FbdBlock(id: 'n0_not', type: 'NOT', title: 'Window Closed', x: 260, y: 300, network: 0),
          FbdBlock(id: 'n0_and', type: 'AND', title: 'HVAC Enable', x: 460, y: 200, network: 0),
          FbdBlock(id: 'n0_fan', type: 'TAG_OUTPUT', title: 'Fan Cmd', tagBinding: 'Fan_Cmd', x: 660, y: 140, network: 0),
          FbdBlock(id: 'n0_act', type: 'TAG_OUTPUT', title: 'HVAC Active', tagBinding: 'Hvac_Active', x: 660, y: 260, network: 0),
          // ── Network 1 ─────────────────────────────────────────────────
          FbdBlock(id: 'n1_occ', type: 'TAG_INPUT', title: 'Occupied', tagBinding: 'Occupied', x: 50, y: 80, network: 1),
          FbdBlock(id: 'n1_setb', type: 'TAG_INPUT', title: 'Setback SP', tagBinding: 'Setback_SP', x: 50, y: 190, network: 1),
          FbdBlock(id: 'n1_comf', type: 'TAG_INPUT', title: 'Comfort SP', tagBinding: 'Comfort_SP', x: 50, y: 300, network: 1),
          FbdBlock(id: 'n1_sel', type: 'SEL', title: 'Occupied ? Comfort : Setback', x: 280, y: 190, network: 1),
          FbdBlock(id: 'n1_lvl', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 410, network: 1),
          FbdBlock(id: 'n1_c50', type: 'CONST', title: 'Level Ref', tagBinding: '50.0', x: 50, y: 520, network: 1),
          FbdBlock(id: 'n1_div', type: 'DIV', title: 'Level / 50', x: 280, y: 460, network: 1),
          FbdBlock(id: 'n1_add', type: 'ADD', title: 'SP + reset', x: 500, y: 300, network: 1),
          FbdBlock(id: 'n1_c1', type: 'CONST', title: 'Reset Bias', tagBinding: '1.0', x: 280, y: 620, network: 1),
          FbdBlock(id: 'n1_sub', type: 'SUB', title: 'less bias', x: 720, y: 360, network: 1),
          FbdBlock(id: 'n1_c16', type: 'CONST', title: 'Min SP', tagBinding: '16.0', x: 500, y: 620, network: 1),
          FbdBlock(id: 'n1_c28', type: 'CONST', title: 'Max SP', tagBinding: '28.0', x: 500, y: 700, network: 1),
          FbdBlock(id: 'n1_lim', type: 'LIMIT', title: 'Clamp 16..28', x: 940, y: 400, network: 1),
          FbdBlock(id: 'n1_esp', type: 'TAG_OUTPUT', title: 'Effective SP', tagBinding: 'Effective_SP', x: 1160, y: 400, network: 1),
          FbdBlock(id: 'n1_sub2', type: 'SUB', title: 'Comfort - Setback', x: 280, y: 780, network: 1),
          FbdBlock(id: 'n1_c2', type: 'CONST', title: 'Span Factor', tagBinding: '2.0', x: 280, y: 880, network: 1),
          FbdBlock(id: 'n1_mul', type: 'MUL', title: 'Span * 2', x: 500, y: 820, network: 1),
          FbdBlock(id: 'n1_span', type: 'TAG_OUTPUT', title: 'SP Span', tagBinding: 'Sp_Span', x: 720, y: 820, network: 1),
          // ── Network 2 ─────────────────────────────────────────────────
          FbdBlock(id: 'n2_rt', type: 'TAG_INPUT', title: 'Room Temp', tagBinding: 'Room_Temp', x: 50, y: 80, network: 2),
          FbdBlock(id: 'n2_sp', type: 'TAG_INPUT', title: 'Setpoint', tagBinding: 'Setpoint', x: 50, y: 190, network: 2),
          FbdBlock(id: 'n2_db', type: 'CONST', title: 'Deadband', tagBinding: '1.0', x: 50, y: 300, network: 2),
          FbdBlock(id: 'n2_sub', type: 'SUB', title: 'SP - 1', x: 280, y: 240, network: 2),
          FbdBlock(id: 'n2_lt', type: 'LT', title: 'Temp < SP-1', x: 500, y: 140, network: 2),
          FbdBlock(id: 'n2_en', type: 'TAG_INPUT', title: 'HVAC Active', tagBinding: 'Hvac_Active', x: 50, y: 410, network: 2),
          FbdBlock(id: 'n2_ah', type: 'AND', title: 'Heat Enable', x: 720, y: 120, network: 2),
          FbdBlock(id: 'n2_heat', type: 'TAG_OUTPUT', title: 'Heat Cmd', tagBinding: 'Heat_Cmd', x: 940, y: 120, network: 2),
          FbdBlock(id: 'n2_add', type: 'ADD', title: 'SP + 1', x: 280, y: 520, network: 2),
          FbdBlock(id: 'n2_gt', type: 'GT', title: 'Temp > SP+1', x: 500, y: 460, network: 2),
          FbdBlock(id: 'n2_ac', type: 'AND', title: 'Cool Enable', x: 720, y: 440, network: 2),
          FbdBlock(id: 'n2_cool', type: 'TAG_OUTPUT', title: 'Cool Cmd', tagBinding: 'Cool_Cmd', x: 940, y: 440, network: 2),
          FbdBlock(id: 'n2_esp', type: 'TAG_INPUT', title: 'Effective SP', tagBinding: 'Effective_SP', x: 50, y: 640, network: 2),
          FbdBlock(id: 'n2_ge', type: 'GE', title: 'Temp >= Eff SP', x: 280, y: 640, network: 2),
          FbdBlock(id: 'n2_oge', type: 'TAG_OUTPUT', title: 'Temp GE', tagBinding: 'Temp_GE', x: 500, y: 640, network: 2),
          FbdBlock(id: 'n2_le', type: 'LE', title: 'Temp <= Eff SP', x: 280, y: 730, network: 2),
          FbdBlock(id: 'n2_ole', type: 'TAG_OUTPUT', title: 'Temp LE', tagBinding: 'Temp_LE', x: 500, y: 730, network: 2),
          FbdBlock(id: 'n2_eq', type: 'EQ', title: 'Temp = Eff SP', x: 280, y: 820, network: 2),
          FbdBlock(id: 'n2_oeq', type: 'TAG_OUTPUT', title: 'Temp EQ', tagBinding: 'Temp_EQ', x: 500, y: 820, network: 2),
          FbdBlock(id: 'n2_ne', type: 'NE', title: 'Temp <> Eff SP', x: 280, y: 910, network: 2),
          FbdBlock(id: 'n2_one', type: 'TAG_OUTPUT', title: 'Temp NE', tagBinding: 'Temp_NE', x: 500, y: 910, network: 2),
          // ── Network 3 ─────────────────────────────────────────────────
          FbdBlock(id: 'n3_hc', type: 'TAG_INPUT', title: 'Heat Cmd', tagBinding: 'Heat_Cmd', x: 50, y: 80, network: 3),
          FbdBlock(id: 'n3_pt1', type: 'CONST', title: 'Stage Delay', tagBinding: '5000', x: 50, y: 190, network: 3),
          FbdBlock(id: 'n3_ton', type: 'TON', title: 'Stage 2 Delay', x: 280, y: 120, network: 3),
          FbdBlock(id: 'n3_stage', type: 'TAG_OUTPUT', title: 'Heat Stage 2', tagBinding: 'Heat_Stage2', x: 500, y: 120, network: 3),
          FbdBlock(id: 'n3_fc', type: 'TAG_INPUT', title: 'Fan Cmd', tagBinding: 'Fan_Cmd', x: 50, y: 300, network: 3),
          FbdBlock(id: 'n3_pt2', type: 'CONST', title: 'Run-On', tagBinding: '10000', x: 50, y: 410, network: 3),
          FbdBlock(id: 'n3_tof', type: 'TOF', title: 'Fan Run-On', x: 280, y: 340, network: 3),
          FbdBlock(id: 'n3_runon', type: 'TAG_OUTPUT', title: 'Fan Run-On', tagBinding: 'Fan_RunOn', x: 500, y: 340, network: 3),
          FbdBlock(id: 'n3_rtrig', type: 'R_TRIG', title: 'Heat Start Edge', x: 280, y: 520, network: 3),
          FbdBlock(id: 'n3_hse', type: 'TAG_OUTPUT', title: 'Heat Start Edge', tagBinding: 'Heat_Start_Edge', x: 500, y: 520, network: 3),
          FbdBlock(id: 'n3_ftrig', type: 'F_TRIG', title: 'Heat Stop Edge', x: 280, y: 610, network: 3),
          FbdBlock(id: 'n3_hstop', type: 'TAG_OUTPUT', title: 'Heat Stop Edge', tagBinding: 'Heat_Stop_Edge', x: 500, y: 610, network: 3),
          FbdBlock(id: 'n3_pt3', type: 'CONST', title: 'Purge Width', tagBinding: '2000', x: 500, y: 720, network: 3),
          FbdBlock(id: 'n3_tp', type: 'TP', title: 'Purge One-Shot', x: 720, y: 660, network: 3),
          FbdBlock(id: 'n3_purge', type: 'TAG_OUTPUT', title: 'Purge Pulse', tagBinding: 'Purge_Pulse', x: 940, y: 660, network: 3),
          FbdBlock(id: 'n3_occ', type: 'TAG_INPUT', title: 'Occupied', tagBinding: 'Occupied', x: 50, y: 810, network: 3),
          FbdBlock(id: 'n3_rtrig2', type: 'R_TRIG', title: 'Occupancy In', x: 280, y: 780, network: 3),
          FbdBlock(id: 'n3_orise', type: 'TAG_OUTPUT', title: 'Occ Rise', tagBinding: 'Occ_Rise', x: 500, y: 780, network: 3),
          FbdBlock(id: 'n3_ftrig2', type: 'F_TRIG', title: 'Occupancy Out', x: 280, y: 870, network: 3),
          FbdBlock(id: 'n3_ofall', type: 'TAG_OUTPUT', title: 'Occ Fall', tagBinding: 'Occ_Fall', x: 500, y: 870, network: 3),
          // ── Network 4 ─────────────────────────────────────────────────
          FbdBlock(id: 'n4_hse', type: 'TAG_INPUT', title: 'Heat Start Edge', tagBinding: 'Heat_Start_Edge', x: 50, y: 80, network: 4),
          FbdBlock(id: 'n4_rst', type: 'TAG_INPUT', title: 'CTU Reset', tagBinding: 'Ctu_Reset', x: 50, y: 190, network: 4),
          FbdBlock(id: 'n4_pv1', type: 'CONST', title: 'Start Limit', tagBinding: '20', x: 50, y: 300, network: 4),
          FbdBlock(id: 'n4_ctu', type: 'CTU', title: 'Heat Starts', x: 280, y: 180, network: 4),
          FbdBlock(id: 'n4_done', type: 'TAG_OUTPUT', title: 'Start Limit Hit', tagBinding: 'Heat_Starts_Done', x: 500, y: 140, network: 4),
          FbdBlock(id: 'n4_cnt', type: 'TAG_OUTPUT', title: 'Heat Starts', tagBinding: 'Heat_Starts', x: 500, y: 240, network: 4),
          FbdBlock(id: 'n4_ld', type: 'TAG_INPUT', title: 'Filter Load', tagBinding: 'Filter_Load', x: 50, y: 410, network: 4),
          // `fbd_exec.dart`'s CTD seeds its CV at 0 and has NO first-scan
          // preload (unlike `ld_exec.dart`'s CTD, which loads CV := PV on the
          // first scan). Without this R_TRIG the countdown would start already
          // expired — CV 0, Q true from scan 1. Filter_Load ships TRUE, so this
          // edge detector fires exactly once, on the first scan, loading
          // CV := 100; it is false on every scan after that, which is what lets
          // the CD edges actually count down.
          FbdBlock(id: 'n4_ldedge', type: 'R_TRIG', title: 'Filter Preload (first scan)', x: 170, y: 410, network: 4),
          FbdBlock(id: 'n4_pv2', type: 'CONST', title: 'Filter Life', tagBinding: '100', x: 50, y: 520, network: 4),
          FbdBlock(id: 'n4_ctd', type: 'CTD', title: 'Filter Countdown', x: 280, y: 420, network: 4),
          FbdBlock(id: 'n4_due', type: 'TAG_OUTPUT', title: 'Filter Due', tagBinding: 'Filter_Due', x: 500, y: 380, network: 4),
          FbdBlock(id: 'n4_life', type: 'TAG_OUTPUT', title: 'Filter Life', tagBinding: 'Filter_Life', x: 500, y: 480, network: 4),
          FbdBlock(id: 'n4_orise', type: 'TAG_INPUT', title: 'Occ Rise', tagBinding: 'Occ_Rise', x: 50, y: 630, network: 4),
          FbdBlock(id: 'n4_ofall', type: 'TAG_INPUT', title: 'Occ Fall', tagBinding: 'Occ_Fall', x: 50, y: 720, network: 4),
          FbdBlock(id: 'n4_orst', type: 'TAG_INPUT', title: 'Occ Reset', tagBinding: 'Occ_Reset', x: 50, y: 810, network: 4),
          FbdBlock(id: 'n4_oload', type: 'TAG_INPUT', title: 'Occ Load', tagBinding: 'Occ_Load', x: 50, y: 900, network: 4),
          FbdBlock(id: 'n4_pv3', type: 'CONST', title: 'Capacity', tagBinding: '10', x: 50, y: 990, network: 4),
          FbdBlock(id: 'n4_ctud', type: 'CTUD', title: 'Occupancy Net', x: 280, y: 780, network: 4),
          FbdBlock(id: 'n4_full', type: 'TAG_OUTPUT', title: 'Zone Full', tagBinding: 'Occ_Full', x: 500, y: 690, network: 4),
          FbdBlock(id: 'n4_empty', type: 'TAG_OUTPUT', title: 'Zone Empty', tagBinding: 'Occ_Empty', x: 500, y: 780, network: 4),
          FbdBlock(id: 'n4_net', type: 'TAG_OUTPUT', title: 'Occupancy Net', tagBinding: 'Occupancy_Net', x: 500, y: 870, network: 4),
          // ── Network 5 (absorbed tank) ─────────────────────────────────
          FbdBlock(id: 't_auto', type: 'TAG_INPUT', title: 'Auto Mode', tagBinding: 'Auto_Mode', x: 50, y: 80, network: 5),
          FbdBlock(id: 't_pv', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 200, network: 5),
          FbdBlock(id: 't_sp', type: 'TAG_INPUT', title: 'Level SP', tagBinding: 'Level_SP', x: 50, y: 320, network: 5),
          FbdBlock(id: 't_db', type: 'CONST', title: 'Deadband', tagBinding: '5.0', x: 50, y: 440, network: 5),
          FbdBlock(id: 't_sub', type: 'SUB', title: 'SP - 5', x: 240, y: 360, network: 5),
          FbdBlock(id: 't_lt', type: 'LT', title: 'PV < SP-5', x: 420, y: 220, network: 5),
          FbdBlock(id: 't_af', type: 'AND', title: 'Fill Enable', x: 600, y: 160, network: 5),
          FbdBlock(id: 't_of', type: 'TAG_OUTPUT', title: 'Fill Valve', tagBinding: 'Fill_Valve', x: 790, y: 160, network: 5),
          FbdBlock(id: 't_add', type: 'ADD', title: 'SP + 5', x: 240, y: 500, network: 5),
          FbdBlock(id: 't_gt', type: 'GT', title: 'PV > SP+5', x: 420, y: 380, network: 5),
          FbdBlock(id: 't_ad', type: 'AND', title: 'Drain Enable', x: 600, y: 340, network: 5),
          FbdBlock(id: 't_od', type: 'TAG_OUTPUT', title: 'Drain Valve', tagBinding: 'Drain_Valve', x: 790, y: 340, network: 5),
          FbdBlock(id: 't_hi', type: 'CONST', title: 'High Limit', tagBinding: '85.0', x: 420, y: 540, network: 5),
          FbdBlock(id: 't_ga', type: 'GT', title: 'PV > 85', x: 600, y: 520, network: 5),
          FbdBlock(id: 't_oa', type: 'TAG_OUTPUT', title: 'High Alarm', tagBinding: 'High_Alarm', x: 790, y: 520, network: 5),
          // ── Network 6 (custom FB) ─────────────────────────────────────
          FbdBlock(id: 'n6_occ', type: 'TAG_INPUT', title: 'Occupied', tagBinding: 'Occupied', x: 50, y: 80, network: 6),
          FbdBlock(id: 'n6_base', type: 'CONST', title: 'Base SP', tagBinding: '22.0', x: 50, y: 190, network: 6),
          FbdBlock(id: 'n6_sb', type: 'CONST', title: 'Setback', tagBinding: '4.0', x: 50, y: 300, network: 6),
          FbdBlock(id: 'n6_shift', type: 'SetpointShift', title: 'Zone Setpoint Shift', tagBinding: 'ZoneShift', x: 300, y: 190, network: 6),
          FbdBlock(id: 'n6_out', type: 'TAG_OUTPUT', title: 'Shifted SP', tagBinding: 'Shifted_SP', x: 560, y: 190, network: 6),
        ],
        fbdWires: [
          // Network 0.
          FbdWire(fromBlockId: 'n0_occ', fromPin: 'OUT', toBlockId: 'n0_or', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n0_ovr', fromPin: 'OUT', toBlockId: 'n0_or', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n0_win', fromPin: 'OUT', toBlockId: 'n0_not', toPin: 'IN'),
          FbdWire(fromBlockId: 'n0_or', fromPin: 'OUT', toBlockId: 'n0_and', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n0_not', fromPin: 'OUT', toBlockId: 'n0_and', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n0_and', fromPin: 'OUT', toBlockId: 'n0_fan', toPin: 'IN'),
          FbdWire(fromBlockId: 'n0_and', fromPin: 'OUT', toBlockId: 'n0_act', toPin: 'IN'),
          // Network 1.
          FbdWire(fromBlockId: 'n1_occ', fromPin: 'OUT', toBlockId: 'n1_sel', toPin: 'G'),
          FbdWire(fromBlockId: 'n1_setb', fromPin: 'OUT', toBlockId: 'n1_sel', toPin: 'IN0'),
          FbdWire(fromBlockId: 'n1_comf', fromPin: 'OUT', toBlockId: 'n1_sel', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n1_lvl', fromPin: 'OUT', toBlockId: 'n1_div', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n1_c50', fromPin: 'OUT', toBlockId: 'n1_div', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n1_sel', fromPin: 'OUT', toBlockId: 'n1_add', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n1_div', fromPin: 'OUT', toBlockId: 'n1_add', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n1_add', fromPin: 'OUT', toBlockId: 'n1_sub', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n1_c1', fromPin: 'OUT', toBlockId: 'n1_sub', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n1_c16', fromPin: 'OUT', toBlockId: 'n1_lim', toPin: 'MN'),
          FbdWire(fromBlockId: 'n1_sub', fromPin: 'OUT', toBlockId: 'n1_lim', toPin: 'IN'),
          FbdWire(fromBlockId: 'n1_c28', fromPin: 'OUT', toBlockId: 'n1_lim', toPin: 'MX'),
          FbdWire(fromBlockId: 'n1_lim', fromPin: 'OUT', toBlockId: 'n1_esp', toPin: 'IN'),
          FbdWire(fromBlockId: 'n1_comf', fromPin: 'OUT', toBlockId: 'n1_sub2', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n1_setb', fromPin: 'OUT', toBlockId: 'n1_sub2', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n1_sub2', fromPin: 'OUT', toBlockId: 'n1_mul', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n1_c2', fromPin: 'OUT', toBlockId: 'n1_mul', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n1_mul', fromPin: 'OUT', toBlockId: 'n1_span', toPin: 'IN'),
          // Network 2.
          FbdWire(fromBlockId: 'n2_sp', fromPin: 'OUT', toBlockId: 'n2_sub', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_db', fromPin: 'OUT', toBlockId: 'n2_sub', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_rt', fromPin: 'OUT', toBlockId: 'n2_lt', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_sub', fromPin: 'OUT', toBlockId: 'n2_lt', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_en', fromPin: 'OUT', toBlockId: 'n2_ah', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_lt', fromPin: 'OUT', toBlockId: 'n2_ah', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_ah', fromPin: 'OUT', toBlockId: 'n2_heat', toPin: 'IN'),
          FbdWire(fromBlockId: 'n2_sp', fromPin: 'OUT', toBlockId: 'n2_add', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_db', fromPin: 'OUT', toBlockId: 'n2_add', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_rt', fromPin: 'OUT', toBlockId: 'n2_gt', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_add', fromPin: 'OUT', toBlockId: 'n2_gt', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_en', fromPin: 'OUT', toBlockId: 'n2_ac', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_gt', fromPin: 'OUT', toBlockId: 'n2_ac', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_ac', fromPin: 'OUT', toBlockId: 'n2_cool', toPin: 'IN'),
          FbdWire(fromBlockId: 'n2_rt', fromPin: 'OUT', toBlockId: 'n2_ge', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_esp', fromPin: 'OUT', toBlockId: 'n2_ge', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_ge', fromPin: 'OUT', toBlockId: 'n2_oge', toPin: 'IN'),
          FbdWire(fromBlockId: 'n2_rt', fromPin: 'OUT', toBlockId: 'n2_le', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_esp', fromPin: 'OUT', toBlockId: 'n2_le', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_le', fromPin: 'OUT', toBlockId: 'n2_ole', toPin: 'IN'),
          FbdWire(fromBlockId: 'n2_rt', fromPin: 'OUT', toBlockId: 'n2_eq', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_esp', fromPin: 'OUT', toBlockId: 'n2_eq', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_eq', fromPin: 'OUT', toBlockId: 'n2_oeq', toPin: 'IN'),
          FbdWire(fromBlockId: 'n2_rt', fromPin: 'OUT', toBlockId: 'n2_ne', toPin: 'IN1'),
          FbdWire(fromBlockId: 'n2_esp', fromPin: 'OUT', toBlockId: 'n2_ne', toPin: 'IN2'),
          FbdWire(fromBlockId: 'n2_ne', fromPin: 'OUT', toBlockId: 'n2_one', toPin: 'IN'),
          // Network 3.
          FbdWire(fromBlockId: 'n3_hc', fromPin: 'OUT', toBlockId: 'n3_ton', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_pt1', fromPin: 'OUT', toBlockId: 'n3_ton', toPin: 'PT'),
          FbdWire(fromBlockId: 'n3_ton', fromPin: 'Q', toBlockId: 'n3_stage', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_fc', fromPin: 'OUT', toBlockId: 'n3_tof', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_pt2', fromPin: 'OUT', toBlockId: 'n3_tof', toPin: 'PT'),
          FbdWire(fromBlockId: 'n3_tof', fromPin: 'Q', toBlockId: 'n3_runon', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_hc', fromPin: 'OUT', toBlockId: 'n3_rtrig', toPin: 'CLK'),
          FbdWire(fromBlockId: 'n3_rtrig', fromPin: 'Q', toBlockId: 'n3_hse', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_hc', fromPin: 'OUT', toBlockId: 'n3_ftrig', toPin: 'CLK'),
          FbdWire(fromBlockId: 'n3_ftrig', fromPin: 'Q', toBlockId: 'n3_hstop', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_rtrig', fromPin: 'Q', toBlockId: 'n3_tp', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_pt3', fromPin: 'OUT', toBlockId: 'n3_tp', toPin: 'PT'),
          FbdWire(fromBlockId: 'n3_tp', fromPin: 'Q', toBlockId: 'n3_purge', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_occ', fromPin: 'OUT', toBlockId: 'n3_rtrig2', toPin: 'CLK'),
          FbdWire(fromBlockId: 'n3_rtrig2', fromPin: 'Q', toBlockId: 'n3_orise', toPin: 'IN'),
          FbdWire(fromBlockId: 'n3_occ', fromPin: 'OUT', toBlockId: 'n3_ftrig2', toPin: 'CLK'),
          FbdWire(fromBlockId: 'n3_ftrig2', fromPin: 'Q', toBlockId: 'n3_ofall', toPin: 'IN'),
          // Network 4.
          FbdWire(fromBlockId: 'n4_hse', fromPin: 'OUT', toBlockId: 'n4_ctu', toPin: 'CU'),
          FbdWire(fromBlockId: 'n4_rst', fromPin: 'OUT', toBlockId: 'n4_ctu', toPin: 'R'),
          FbdWire(fromBlockId: 'n4_pv1', fromPin: 'OUT', toBlockId: 'n4_ctu', toPin: 'PV'),
          FbdWire(fromBlockId: 'n4_ctu', fromPin: 'Q', toBlockId: 'n4_done', toPin: 'IN'),
          FbdWire(fromBlockId: 'n4_ctu', fromPin: 'CV', toBlockId: 'n4_cnt', toPin: 'IN'),
          FbdWire(fromBlockId: 'n4_hse', fromPin: 'OUT', toBlockId: 'n4_ctd', toPin: 'CD'),
          FbdWire(fromBlockId: 'n4_ld', fromPin: 'OUT', toBlockId: 'n4_ldedge', toPin: 'CLK'),
          FbdWire(fromBlockId: 'n4_ldedge', fromPin: 'Q', toBlockId: 'n4_ctd', toPin: 'LD'),
          FbdWire(fromBlockId: 'n4_pv2', fromPin: 'OUT', toBlockId: 'n4_ctd', toPin: 'PV'),
          FbdWire(fromBlockId: 'n4_ctd', fromPin: 'Q', toBlockId: 'n4_due', toPin: 'IN'),
          FbdWire(fromBlockId: 'n4_ctd', fromPin: 'CV', toBlockId: 'n4_life', toPin: 'IN'),
          FbdWire(fromBlockId: 'n4_orise', fromPin: 'OUT', toBlockId: 'n4_ctud', toPin: 'CU'),
          FbdWire(fromBlockId: 'n4_ofall', fromPin: 'OUT', toBlockId: 'n4_ctud', toPin: 'CD'),
          FbdWire(fromBlockId: 'n4_orst', fromPin: 'OUT', toBlockId: 'n4_ctud', toPin: 'R'),
          FbdWire(fromBlockId: 'n4_oload', fromPin: 'OUT', toBlockId: 'n4_ctud', toPin: 'LD'),
          FbdWire(fromBlockId: 'n4_pv3', fromPin: 'OUT', toBlockId: 'n4_ctud', toPin: 'PV'),
          FbdWire(fromBlockId: 'n4_ctud', fromPin: 'QU', toBlockId: 'n4_full', toPin: 'IN'),
          FbdWire(fromBlockId: 'n4_ctud', fromPin: 'QD', toBlockId: 'n4_empty', toPin: 'IN'),
          FbdWire(fromBlockId: 'n4_ctud', fromPin: 'CV', toBlockId: 'n4_net', toPin: 'IN'),
          // Network 5 (absorbed tank, wiring verbatim).
          FbdWire(fromBlockId: 't_sp', fromPin: 'OUT', toBlockId: 't_sub', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_db', fromPin: 'OUT', toBlockId: 't_sub', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_pv', fromPin: 'OUT', toBlockId: 't_lt', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_sub', fromPin: 'OUT', toBlockId: 't_lt', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_auto', fromPin: 'OUT', toBlockId: 't_af', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_lt', fromPin: 'OUT', toBlockId: 't_af', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_af', fromPin: 'OUT', toBlockId: 't_of', toPin: 'IN'),
          FbdWire(fromBlockId: 't_sp', fromPin: 'OUT', toBlockId: 't_add', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_db', fromPin: 'OUT', toBlockId: 't_add', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_pv', fromPin: 'OUT', toBlockId: 't_gt', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_add', fromPin: 'OUT', toBlockId: 't_gt', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_auto', fromPin: 'OUT', toBlockId: 't_ad', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_gt', fromPin: 'OUT', toBlockId: 't_ad', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_ad', fromPin: 'OUT', toBlockId: 't_od', toPin: 'IN'),
          FbdWire(fromBlockId: 't_pv', fromPin: 'OUT', toBlockId: 't_ga', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_hi', fromPin: 'OUT', toBlockId: 't_ga', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_ga', fromPin: 'OUT', toBlockId: 't_oa', toPin: 'IN'),
          // Network 6.
          FbdWire(fromBlockId: 'n6_occ', fromPin: 'OUT', toBlockId: 'n6_shift', toPin: 'Occupied'),
          FbdWire(fromBlockId: 'n6_base', fromPin: 'OUT', toBlockId: 'n6_shift', toPin: 'Base'),
          FbdWire(fromBlockId: 'n6_sb', fromPin: 'OUT', toBlockId: 'n6_shift', toPin: 'Setback'),
          FbdWire(fromBlockId: 'n6_shift', fromPin: 'Sp', toBlockId: 'n6_out', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'HvacControlTask', type: 'Continuous', periodMs: 100, programNames: ['HvacZone_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_fbd_hvac_zone',
        title: 'HVAC Zone Controller HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'hz1', title: 'Zone Temperature (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Room_Temp', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'hz2', title: 'Comfort Setpoint', type: 'NumericSliderInput', tagBinding: 'Setpoint', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'hz3', title: 'Effective Setpoint (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Effective_SP', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'hz4', title: 'Zone Occupied', type: 'ToggleSwitch', tagBinding: 'Occupied', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'hz5', title: 'Manual Override', type: 'ToggleSwitch', tagBinding: 'Override_On', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'hz6', title: 'Window Open', type: 'ToggleSwitch', tagBinding: 'Window_Open', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'hz7', title: 'Fan Running', type: 'LedIndicatorLight', tagBinding: 'Fan_Cmd', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'hz8', title: 'Heating ON', type: 'LedIndicatorLight', tagBinding: 'Heat_Cmd', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'hz9', title: 'Heat Stage 2', type: 'LedIndicatorLight', tagBinding: 'Heat_Stage2', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'hz10', title: 'Cooling ON', type: 'LedIndicatorLight', tagBinding: 'Cool_Cmd', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'hz11', title: 'Fan Run-On', type: 'LedIndicatorLight', tagBinding: 'Fan_RunOn', gridSpanWidth: 1, accentColor: 'teal'),
          HmiComponent(id: 'hz12', title: 'Heat Starts', type: 'DigitalGaugeDisplay', tagBinding: 'Heat_Starts', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'hz13', title: 'Filter Life', type: 'DigitalGaugeDisplay', tagBinding: 'Filter_Life', gridSpanWidth: 2, accentColor: 'green'),
          HmiComponent(id: 'hz14', title: 'Occupancy Net', type: 'DigitalGaugeDisplay', tagBinding: 'Occupancy_Net', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'hz15', title: 'Shifted Setpoint (FB)', type: 'DigitalGaugeDisplay', tagBinding: 'Shifted_SP', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'hz16', title: 'HVAC ACTIVE', type: 'StatusPillDisplay', tagBinding: 'Hvac_Active', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'hz17', title: 'FILTER DUE', type: 'StatusPillDisplay', tagBinding: 'Filter_Due', gridSpanWidth: 2, accentColor: 'amber'),
        ],
      ),
      HmiScreenDef(
        id: 'hmi_fbd_hvac_tank',
        title: 'Plant Room Tank Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'ht1', title: 'Reservoir Level', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'ht2', title: 'Level Setpoint', type: 'NumericSliderInput', tagBinding: 'Level_SP', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'ht3', title: 'Auto Mode', type: 'ToggleSwitch', tagBinding: 'Auto_Mode', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'ht4', title: 'Fill Valve', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'ht5', title: 'Drain Valve', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'ht6', title: 'High Alarm', type: 'LedIndicatorLight', tagBinding: 'High_Alarm', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'ht7', title: 'Level Gauge (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Level_PV', gridSpanWidth: 4, accentColor: 'cyan'),
        ],
      ),
    ],
  );
}
```

- [ ] **Step 4: Run the new test**

Run: `/c/flutter/bin/flutter test test/defaults/fbd_hvac_zone_test.dart`
Expected: PASS.
If the comparator test fails, remember networks execute **in index order within
one scan**: `Effective_SP` (net 1) is written before net 2 reads it back, so a
single scan is enough.

- [ ] **Step 5: Run analyze + full suite**

Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/data/default_projects/fbd_hvac_zone.dart mobile/test/defaults/fbd_hvac_zone_test.dart
git commit -m "feat(defaults): add FBD — HVAC Zone Controller showcase project

Seven networks covering the full FBD palette (OR/DIV/GE/LE/EQ/NE/SEL/TON/TOF/TP/
CTD/CTUD/F_TRIG were previously unshipped), the absorbed tank fill/drain network,
and an ST-bodied SetpointShift custom function block."
```

---

### Task 4: SFC — Batch Production (`proj_sfc_batch_production`)

**Model:** sonnet · **Effort:** medium

**Files:**
- Create: `mobile/lib/data/default_projects/sfc_batch_production.dart`
- Create: `mobile/test/defaults/sfc_batch_production_test.dart`

**Interfaces:**
- Consumes: nothing from `builders.dart` (no ladder, no composite defaults).
- Produces: `PlcProject sfcBatchProductionProject()` — id
  `proj_sfc_batch_production`, name `SFC — Batch Production`, one
  `SequentialFunctionChart` program `BatchProduction_SFC`, one HMI screen
  `hmi_sfc_batch_production`.
- Binding constraints for Task 8: the chart must parse to **exactly one**
  `ParRegion` (2 branches) and **exactly one** `AltRegion` (2 arms)
  (`sfc_batchmix_showcase_test`), must set `Sfc_Step := 5` at the `COUNT` step
  and increment `Filled_Count` there (`sfc_exec_integration_test`), and must
  keep the tag names `Start_Cmd`, `Quality_OK`, `Batch_Count`, `Reject_Count`,
  `Fill_Level`, `Temp_PV`, `Temp_SP`, `Fill_Target`, `Filled_Count`,
  `Sfc_Step`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/defaults/sfc_batch_production_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/sfc_batch_production.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

void main() {
  test('the merged chart parses to one parallel region (2 branches) and one '
      'alternative region (2 arms)', () {
    final p = sfcBatchProductionProject();
    final prog = p.programs.firstWhere((x) => x.language == 'SequentialFunctionChart');
    final region = parseSfc(prog.sfcSteps, prog.sfcTransitions);
    final pars = <ParRegion>[];
    final alts = <AltRegion>[];
    void walk(SfcRegion r) {
      if (r is ParRegion) {
        pars.add(r);
        for (final b in r.branches) {
          for (final x in b) {
            walk(x);
          }
        }
      } else if (r is AltRegion) {
        alts.add(r);
        for (final b in r.branches) {
          for (final x in b) {
            walk(x);
          }
        }
      } else if (r is SeqRegion) {
        for (final x in r.items) {
          walk(x);
        }
      }
    }

    walk(region);
    expect(pars.length, 1);
    expect(pars.first.branches.length, 2);
    expect(alts.length, 1);
    expect(alts.first.branches.length, 2);
  });

  test('two full cycles: Filled_Count increments once per container and the '
      'STEP_T dwells are honoured', () {
    final p = sfcBatchProductionProject();
    final sim = SimRuntime();
    final rt = SfcRuntime();
    void tick([int ms = 500]) {
      applySimRules(p, p.simRules, ms, sim);
      executeSfcPrograms(p, ms, rt);
    }

    writePath(p, 'Quality_OK', true);
    writePath(p, 'Container_Present', true);
    tick();
    expect(_i(p, 'Sfc_Step'), 0);

    writePath(p, 'Start_Cmd', true);

    var capScans = 0;
    var ejectScans = 0;
    for (var i = 0; i < 300 && _i(p, 'Filled_Count') < 2; i++) {
      tick();
      if (_i(p, 'Sfc_Step') == 3) {
        capScans++;
      }
      if (_i(p, 'Sfc_Step') == 4) {
        ejectScans++;
      }
    }

    expect(_i(p, 'Filled_Count'), 2, reason: 'two containers completed');
    expect(capScans, greaterThanOrEqualTo(2 * 6),
        reason: 'the 3000 ms cap dwell is at least 6 scans of 500 ms, twice');
    expect(ejectScans, greaterThanOrEqualTo(2 * 4),
        reason: 'the 2000 ms eject dwell is at least 4 scans of 500 ms, twice');
    expect(_i(p, 'Batch_Count'), greaterThanOrEqualTo(1),
        reason: 'Quality_OK routes each batch to DISPATCH');
    expect(_i(p, 'Reject_Count'), 0);
  });

  test('the fork activates BOTH branches and the join waits for both', () {
    final p = sfcBatchProductionProject();
    final prog = p.programs.firstWhere((x) => x.language == 'SequentialFunctionChart');
    final sim = SimRuntime();
    final rt = SfcRuntime();
    writePath(p, 'Quality_OK', true);
    writePath(p, 'Container_Present', true);
    writePath(p, 'Start_Cmd', true);

    var maxActive = 0;
    var sawJoinWait = false;
    for (var i = 0; i < 300; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeSfcPrograms(p, 500, rt);
      final active = rt.active[prog.name] ?? <String>{};
      if (active.length > maxActive) {
        maxActive = active.length;
      }
      // One branch parked on its *_DONE step while the other is still working:
      // the join is genuinely holding for both.
      if (active.contains('b_charge_done') && active.contains('b_heating')) {
        sawJoinWait = true;
      }
    }
    expect(maxActive, greaterThanOrEqualTo(2),
        reason: 'the parallel fork must run two steps simultaneously');
    expect(sawJoinWait, isTrue,
        reason: 'the join must hold the finished branch until the other completes');
  });

  test('Quality_OK false routes the batch down the REJECT arm instead', () {
    final p = sfcBatchProductionProject();
    final sim = SimRuntime();
    final rt = SfcRuntime();
    writePath(p, 'Quality_OK', false);
    writePath(p, 'Container_Present', true);
    writePath(p, 'Start_Cmd', true);
    for (var i = 0; i < 300; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeSfcPrograms(p, 500, rt);
    }
    expect(_i(p, 'Reject_Count'), greaterThanOrEqualTo(1));
    expect(_i(p, 'Batch_Count'), 0);
  });

  test('the count steps are true one-shots', () {
    final p = sfcBatchProductionProject();
    final sim = SimRuntime();
    final rt = SfcRuntime();
    void tick() {
      applySimRules(p, p.simRules, 500, sim);
      executeSfcPrograms(p, 500, rt);
    }

    writePath(p, 'Quality_OK', true);
    writePath(p, 'Container_Present', true);
    writePath(p, 'Start_Cmd', true);
    var guard = 0;
    while (_i(p, 'Batch_Count') < 1 && guard < 500) {
      tick();
      guard++;
    }
    expect(_i(p, 'Batch_Count'), 1);

    writePath(p, 'Start_Cmd', false); // no new cycle may start
    for (var i = 0; i < 60; i++) {
      tick();
    }
    expect(_i(p, 'Batch_Count'), 1,
        reason: 'the count step fires once per batch, not once per scan');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/defaults/sfc_batch_production_test.dart`
Expected: FAIL — the library does not exist.

- [ ] **Step 3: Write the project builder**

Create `mobile/lib/data/default_projects/sfc_batch_production.dart`:

```dart
/// **SFC — Batch Production** (`proj_sfc_batch_production`).
///
/// (a) Story: one packaging-and-batching line, merging the two retired SFC
/// demos into a single chart. A container is filled, capped and ejected on a
/// LINEAR segment with `STEP_T` dwells (from "Batch Bottle Filling"); the
/// product for the next container is then prepared by a PARALLEL fork that
/// heats and charges the mix tank at the same time and rejoins when both are
/// done (from "Batch Mix & Dispatch"); finally a quality gate splits the chart
/// into two ALTERNATIVE arms — dispatch or reject — each ending in its own
/// one-shot count step before returning to IDLE.
///
/// (b) Showcase for: SFC `'single'` transitions, `isInitial`, `STEP_T` dwell
/// conditions, `'parallelFork'` / `'parallelJoin'`, alternative divergence
/// (first-true-wins), one-shot counting steps, and a `Periodic` task.
///
/// (c) Falsifiable: removing the join lets MIXING start before both branches
/// finish; making both alternative conditions identical routes every batch the
/// same way regardless of `Quality_OK`; turning a count step's action into a
/// level assignment makes `Batch_Count` climb every scan instead of once per
/// batch.
///
/// (d) Proof test: `test/defaults/sfc_batch_production_test.dart` (plus the
/// re-pointed `test/sfc_exec_integration_test.dart` and
/// `test/sfc_batchmix_showcase_test.dart`).
library;

import '../../models/project_model.dart';

PlcProject sfcBatchProductionProject() => PlcProject(
      id: 'proj_sfc_batch_production',
      name: 'SFC — Batch Production',
      controllerName: 'PLC_BATCH',
      scanPeriodMs: 200,
      tags: [
        PlcTag(name: 'Start_Cmd', path: 'Inputs/Start_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Operator start command'),
        PlcTag(name: 'Quality_OK', path: 'Inputs/Quality_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Batch quality accept (true = dispatch, false = reject)'),
        PlcTag(name: 'Container_Present', path: 'Inputs/Container_Present', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Container presence sensor'),
        PlcTag(name: 'Temp_PV', path: 'Inputs/Temp_PV', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Mix tank temperature'),
        PlcTag(name: 'Fill_Level', path: 'Inputs/Fill_Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Container / mix tank fill level'),
        PlcTag(name: 'Temp_SP', path: 'Internal/Temp_SP', dataType: 'FLOAT64', value: 70.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Target mix temperature'),
        PlcTag(name: 'Fill_Target', path: 'Internal/Fill_Target', dataType: 'FLOAT64', value: 90.0, ioType: 'Internal', engineeringUnits: '%', description: 'Target charge level'),
        PlcTag(name: 'Sfc_Step', path: 'Internal/Sfc_Step', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Current SFC step index (0–15)'),
        PlcTag(name: 'Batch_Count', path: 'Internal/Batch_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Dispatched batches'),
        PlcTag(name: 'Reject_Count', path: 'Internal/Reject_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Rejected batches'),
        PlcTag(name: 'Filled_Count', path: 'Internal/Filled_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Containers filled, capped and ejected'),
        PlcTag(name: 'Sequence_Running', path: 'Internal/Sequence_Running', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Sequence active flag'),
        PlcTag(name: 'Heater', path: 'Outputs/Heater', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Mix tank heater'),
        PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Filler / charge valve'),
        PlcTag(name: 'Agitator', path: 'Outputs/Agitator', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Mixer agitator'),
        PlcTag(name: 'Cap_Solenoid', path: 'Outputs/Cap_Solenoid', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Capping solenoid'),
        PlcTag(name: 'Eject_Cyl', path: 'Outputs/Eject_Cyl', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Ejection cylinder'),
        PlcTag(name: 'Dispatch_Pump', path: 'Outputs/Dispatch_Pump', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Dispatch transfer pump'),
        PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reject drain valve'),
      ],
      structDefs: [],
      simRules: [
        // 30 %/s keeps a whole merged cycle inside ~19 s of simulated time, so
        // the re-pointed linear-segment test still completes two containers
        // well inside its scan budget.
        SimRule(id: 'sim0', name: 'Filling raises level', targetPath: 'Fill_Level',
            behavior: 'integrate', ratePerSec: 30.0, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Heating raises temp', targetPath: 'Temp_PV',
            behavior: 'integrate', ratePerSec: 12.0, minValue: 20, maxValue: 95,
            condition: [SimClause(leftPath: 'Heater', comparator: '==', operand: 'true')]),
      ],
      programs: [
        PlcProgram(
          name: 'BatchProduction_SFC',
          language: 'SequentialFunctionChart',
          description: 'Linear fill/cap/eject segment with STEP_T dwells, then a parallel '
              'heat/charge fork-join, then a quality-gated dispatch/reject divergence',
          sfcSteps: [
            SfcStep(id: 'b_idle', name: 'IDLE', isInitial: true,
                actionSt: 'Sfc_Step := 0;\nSequence_Running := FALSE;\nFill_Valve := FALSE;\n'
                    'Cap_Solenoid := FALSE;\nEject_Cyl := FALSE;\nHeater := FALSE;\n'
                    'Agitator := FALSE;\nDispatch_Pump := FALSE;\nDrain_Valve := FALSE;\n'
                    'Fill_Level := 0.0;\nTemp_PV := 20.0;'),
            SfcStep(id: 'b_wait', name: 'WAIT_CONTAINER',
                actionSt: 'Sfc_Step := 1;\nSequence_Running := TRUE;\nFill_Valve := FALSE;\n'
                    'Eject_Cyl := FALSE;\nFill_Level := 0.0;'),
            SfcStep(id: 'b_filling', name: 'FILLING',
                actionSt: 'Sfc_Step := 2;\nFill_Valve := TRUE;\n// Fill_Level rises until >= 95%'),
            SfcStep(id: 'b_capping', name: 'CAPPING',
                actionSt: 'Sfc_Step := 3;\nFill_Valve := FALSE;\nCap_Solenoid := TRUE;\n// 3s cap press dwell'),
            SfcStep(id: 'b_ejecting', name: 'EJECTING',
                actionSt: 'Sfc_Step := 4;\nCap_Solenoid := FALSE;\nEject_Cyl := TRUE;\n// 2s eject stroke'),
            SfcStep(id: 'b_count', name: 'COUNT',
                actionSt: 'Sfc_Step := 5;\nEject_Cyl := FALSE;\nFilled_Count := Filled_Count + 1;'),
            SfcStep(id: 'b_prep', name: 'PREP',
                actionSt: 'Sfc_Step := 6;\nFill_Level := 0.0;\nTemp_PV := 20.0;'),
            SfcStep(id: 'b_heating', name: 'HEATING', actionSt: 'Sfc_Step := 7;\nHeater := TRUE;'),
            SfcStep(id: 'b_heat_done', name: 'HEAT_DONE', actionSt: 'Sfc_Step := 8;\nHeater := FALSE;'),
            SfcStep(id: 'b_charging', name: 'CHARGING', actionSt: 'Sfc_Step := 9;\nFill_Valve := TRUE;'),
            SfcStep(id: 'b_charge_done', name: 'CHARGE_DONE', actionSt: 'Sfc_Step := 10;\nFill_Valve := FALSE;'),
            SfcStep(id: 'b_mixing', name: 'MIXING',
                actionSt: 'Sfc_Step := 11;\nAgitator := TRUE;\n// 3s mix dwell, then the quality gate'),
            SfcStep(id: 'b_dispatch', name: 'DISPATCH', actionSt: 'Sfc_Step := 12;\nAgitator := FALSE;\nDispatch_Pump := TRUE;'),
            SfcStep(id: 'b_reject', name: 'REJECT', actionSt: 'Sfc_Step := 13;\nAgitator := FALSE;\nDrain_Valve := TRUE;'),
            SfcStep(id: 'b_count_ok', name: 'COUNT_OK', actionSt: 'Sfc_Step := 14;\nDispatch_Pump := FALSE;\nBatch_Count := Batch_Count + 1;'),
            SfcStep(id: 'b_count_rej', name: 'COUNT_REJ', actionSt: 'Sfc_Step := 15;\nDrain_Valve := FALSE;\nReject_Count := Reject_Count + 1;'),
          ],
          sfcTransitions: [
            SfcTransition(id: 'bt0', fromStepId: 'b_idle', toStepId: 'b_wait', conditionSt: 'Start_Cmd'),
            SfcTransition(id: 'bt1', fromStepId: 'b_wait', toStepId: 'b_filling', conditionSt: 'Container_Present'),
            SfcTransition(id: 'bt2', fromStepId: 'b_filling', toStepId: 'b_capping', conditionSt: 'Fill_Level >= 95.0'),
            SfcTransition(id: 'bt3', fromStepId: 'b_capping', toStepId: 'b_ejecting', conditionSt: 'STEP_T >= 3000  (* cap press dwell *)'),
            SfcTransition(id: 'bt4', fromStepId: 'b_ejecting', toStepId: 'b_count', conditionSt: 'STEP_T >= 2000  (* eject stroke *)'),
            SfcTransition(id: 'bt5', fromStepId: 'b_count', toStepId: 'b_prep', conditionSt: 'TRUE'),
            // Parallel fork: heat and charge the next batch at the same time.
            SfcTransition(id: 'bt6', fromStepId: 'b_prep', toStepId: '', conditionSt: 'TRUE',
                kind: 'parallelFork', toStepIds: ['b_heating', 'b_charging']),
            SfcTransition(id: 'bt7', fromStepId: 'b_heating', toStepId: 'b_heat_done', conditionSt: 'Temp_PV >= Temp_SP'),
            SfcTransition(id: 'bt8', fromStepId: 'b_charging', toStepId: 'b_charge_done', conditionSt: 'Fill_Level >= Fill_Target'),
            SfcTransition(id: 'btj', fromStepId: '', toStepId: 'b_mixing', conditionSt: 'TRUE',
                kind: 'parallelJoin', fromStepIds: ['b_heat_done', 'b_charge_done']),
            // Alternative divergence: first-true-wins on the quality gate.
            SfcTransition(id: 'bt9', fromStepId: 'b_mixing', toStepId: 'b_dispatch', conditionSt: 'STEP_T >= 3000 AND Quality_OK'),
            SfcTransition(id: 'bt10', fromStepId: 'b_mixing', toStepId: 'b_reject', conditionSt: 'STEP_T >= 3000 AND NOT Quality_OK'),
            SfcTransition(id: 'bt11', fromStepId: 'b_dispatch', toStepId: 'b_count_ok', conditionSt: 'STEP_T >= 2000'),
            SfcTransition(id: 'bt12', fromStepId: 'b_reject', toStepId: 'b_count_rej', conditionSt: 'STEP_T >= 2000'),
            SfcTransition(id: 'bt13', fromStepId: 'b_count_ok', toStepId: 'b_idle', conditionSt: 'TRUE'),
            SfcTransition(id: 'bt14', fromStepId: 'b_count_rej', toStepId: 'b_idle', conditionSt: 'TRUE'),
          ],
        ),
      ],
      tasks: [
        PlcTask(name: 'BatchSequenceTask', type: 'Periodic', periodMs: 200, programNames: ['BatchProduction_SFC']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_sfc_batch_production',
          title: 'Batch Production Sequence HMI',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'bp1', title: 'START Sequence', type: 'PushbuttonSwitch', tagBinding: 'Start_Cmd', gridSpanWidth: 2, accentColor: 'green'),
            HmiComponent(id: 'bp2', title: 'Quality OK', type: 'ToggleSwitch', tagBinding: 'Quality_OK', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'bp3', title: 'Container Present', type: 'ToggleSwitch', tagBinding: 'Container_Present', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'bp4', title: 'Mix Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_PV', gridSpanWidth: 2, accentColor: 'amber'),
            HmiComponent(id: 'bp5', title: 'Fill Level (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Fill_Level', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'bp6', title: 'Heater', type: 'LedIndicatorLight', tagBinding: 'Heater', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 'bp7', title: 'Fill Valve', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'bp8', title: 'Agitator', type: 'LedIndicatorLight', tagBinding: 'Agitator', gridSpanWidth: 1, accentColor: 'teal'),
            HmiComponent(id: 'bp9', title: 'Cap Solenoid', type: 'LedIndicatorLight', tagBinding: 'Cap_Solenoid', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 'bp10', title: 'Eject Cylinder', type: 'LedIndicatorLight', tagBinding: 'Eject_Cyl', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'bp11', title: 'Dispatch Pump', type: 'LedIndicatorLight', tagBinding: 'Dispatch_Pump', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'bp12', title: 'Drain Valve', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'bp13', title: 'Sequence Running', type: 'LedIndicatorLight', tagBinding: 'Sequence_Running', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'bp14', title: 'Containers Filled', type: 'StatusPillDisplay', tagBinding: 'Filled_Count', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'bp15', title: 'Dispatched', type: 'StatusPillDisplay', tagBinding: 'Batch_Count', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'bp16', title: 'Rejected', type: 'StatusPillDisplay', tagBinding: 'Reject_Count', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'bp17', title: 'CURRENT STEP', type: 'StatusPillDisplay', tagBinding: 'Sfc_Step', gridSpanWidth: 4, accentColor: 'teal'),
          ],
        ),
      ],
    );
```

- [ ] **Step 4: Run the new test**

Run: `/c/flutter/bin/flutter test test/defaults/sfc_batch_production_test.dart`
Expected: PASS.
If the region test reports more than one alternative region, check that
`b_count`, `b_count_ok` and `b_count_rej` each have exactly ONE outgoing
transition — only `b_mixing` may have two.

- [ ] **Step 5: Run analyze + full suite**

Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/data/default_projects/sfc_batch_production.dart mobile/test/defaults/sfc_batch_production_test.dart
git commit -m "feat(defaults): add SFC — Batch Production showcase project

Merges the retired bottle-filling and batch-mix charts into one: linear STEP_T
segment, parallel heat/charge fork-join, quality-gated alternative divergence."
```

---

### Task 5: ST — Reactor Temperature Controller (`proj_st_reactor_control`)

**Model:** sonnet · **Effort:** medium

**Files:**
- Create: `mobile/lib/data/default_projects/st_reactor_control.dart`
- Create: `mobile/test/defaults/st_reactor_control_test.dart`

**Interfaces:**
- Consumes: `builders.dart` (`emptyScratchProject`, `scratchProjectFor`).
- Produces: `PlcProject stReactorControlProject()` — id
  `proj_st_reactor_control`, name `ST — Reactor Temperature Controller`, two
  programs `ReactorTemp_ST` (StructuredText) and `ReactorAlarm_FBD`
  (FunctionBlockDiagram), the `Hysteresis` `FbDefinition` moved verbatim from
  the retired Noisy Level demo (instance tag `TempAlarmHyst`), one HMI screen
  `hmi_st_reactor`.
- Binding constraints for Task 8: the deadband/alarm ST block, the three sim
  rules (`sim0`/`sim1`/`sim2` with their exact fields) and the tag names
  `Temp_PV`, `Temp_SP`, `Temp_Ambient`, `Auto_Mode`, `Heat_Cmd`, `Cool_Cmd`,
  `Alarm_High`, `Alarm_Low`, `Reactor_Ready`, plus the program name
  `ReactorTemp_ST`, all stay **verbatim** (re-pointed
  `st_exec_integration_test`, `simulated_io_screen_test`,
  `drawer_icon_distinction_test`). The `Hysteresis` FB keeps its name, its five
  vars and its `stSource` **including the 60.0 / 40.0 initial values**, and the
  FBD `CONST` thresholds are **60.0 / 40.0** so the re-pointed
  `hysteresis_fb_demo_test` keeps its numeric assertions verbatim.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/defaults/st_reactor_control_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/st_reactor_control.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();
int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

void main() {
  test('the deadband controller heats, cools, reports ready and alarms', () {
    final p = stReactorControlProject();
    final st = StRuntime();
    void set(bool auto, double temp, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Temp_PV', temp);
      writePath(p, 'Temp_SP', sp);
    }

    set(true, 40.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Heat_Cmd'), isTrue);
    expect(_b(p, 'Reactor_Ready'), isFalse);

    set(true, 60.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Cool_Cmd'), isTrue);

    set(true, 50.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
    expect(_b(p, 'Reactor_Ready'), isTrue);

    set(false, 40.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Heat_Cmd'), isFalse);

    set(true, 96.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Alarm_High'), isTrue);

    set(true, 4.0, 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Alarm_Low'), isTrue);
  });

  test('the INT16 array supplies the setpoint on recipe select', () {
    final p = stReactorControlProject();
    final st = StRuntime();
    final recipe = p.tags.firstWhere((t) => t.name == 'Recipe_Setpoints');
    expect(recipe.dataType, 'INT16');
    expect(recipe.arrayLength, 8);

    writePath(p, 'Recipe_Setpoints[0]', 65);
    writePath(p, 'Recipe_Select', false);
    writePath(p, 'Temp_SP', 75.0);
    executeStPrograms(p, 500, st);
    expect(_d(p, 'Temp_SP'), 75.0, reason: 'recipe select is off');

    writePath(p, 'Recipe_Select', true);
    executeStPrograms(p, 500, st);
    expect(_d(p, 'Temp_SP'), 65.0, reason: 'Recipe_Setpoints[0] drives the setpoint');
  });

  test('the DUT members mirror the commands and count heat cycles', () {
    final p = stReactorControlProject();
    final st = StRuntime();
    writePath(p, 'Auto_Mode', true);

    writePath(p, 'Temp_PV', 40.0);
    writePath(p, 'Temp_SP', 50.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Reactor_Status.Heating'), isTrue);
    expect(_b(p, 'Reactor_Status.Cooling'), isFalse);
    expect(_i(p, 'Reactor_Status.Cycles'), 1);

    executeStPrograms(p, 500, st); // still heating, no new rising edge
    expect(_i(p, 'Reactor_Status.Cycles'), 1);

    writePath(p, 'Temp_PV', 60.0);
    executeStPrograms(p, 500, st);
    expect(_b(p, 'Reactor_Status.Heating'), isFalse);
    expect(_b(p, 'Reactor_Status.Cooling'), isTrue);

    writePath(p, 'Temp_PV', 40.0);
    executeStPrograms(p, 500, st);
    expect(_i(p, 'Reactor_Status.Cycles'), 2, reason: 'a second heat start counted');
  });

  test('the Hysteresis FB sets above High, HOLDS through the deadband and '
      'resets below Low', () {
    final p = stReactorControlProject();
    final rt = FbdRuntime();
    void runWith(double temp) {
      writePath(p, 'Temp_PV', temp);
      executeFbdPrograms(p, 500, rt, only: {'ReactorAlarm_FBD'});
    }

    runWith(20.0);
    expect(_b(p, 'Alarm_Latched'), isFalse);
    runWith(65.0);
    expect(_b(p, 'Alarm_Latched'), isTrue);
    runWith(50.0);
    expect(_b(p, 'Alarm_Latched'), isTrue, reason: 'Q holds inside the 40–60 deadband');
    runWith(35.0);
    expect(_b(p, 'Alarm_Latched'), isFalse);
    runWith(50.0);
    expect(_b(p, 'Alarm_Latched'), isFalse, reason: 'the deadband is symmetric');
  });

  test('closed loop: the thermal plant reaches and holds the setpoint under '
      'Auto, and decays toward ambient with control off', () {
    final p = stReactorControlProject();
    final sim = SimRuntime();
    final st = StRuntime();
    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeStPrograms(p, 500, st);
    }

    final ambient = _d(p, 'Temp_Ambient');
    final sp = _d(p, 'Temp_SP');
    expect(sp, greaterThan(ambient));
    writePath(p, 'Auto_Mode', true);

    for (var i = 0; i < 400; i++) {
      scan();
    }
    expect((_d(p, 'Temp_PV') - sp).abs(), lessThanOrEqualTo(5.0));
    expect(_b(p, 'Reactor_Ready'), isTrue);

    writePath(p, 'Auto_Mode', false);
    scan();
    final handoff = _d(p, 'Temp_PV');
    for (var i = 0; i < 200; i++) {
      scan();
    }
    expect(_d(p, 'Temp_PV'), lessThan(handoff),
        reason: 'ambient pull alone must carry the reactor back down');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/defaults/st_reactor_control_test.dart`
Expected: FAIL — the library does not exist.

- [ ] **Step 3: Write the project builder**

Create `mobile/lib/data/default_projects/st_reactor_control.dart`:

```dart
/// **ST — Reactor Temperature Controller** (`proj_st_reactor_control`).
///
/// (a) Story: a jacketed reactor held at temperature by a ±2 °C on/off deadband
/// controller written in Structured Text, with high/low trip alarms, an
/// eight-step recipe table and a status struct. A small companion FBD program
/// hosts a custom `Hysteresis` function block that latches a hot-vessel alarm
/// with a 40–60 °C deadband (ST has no FB-call syntax in the supported subset,
/// so the call has to live in FBD).
///
/// (b) Showcase for: ST `IF/ELSIF/ELSE/END_IF`, assignment, comparators and
/// `AND`/`OR`/`NOT`; **ST array-index read** (`Recipe_Setpoints[0]`); **ST
/// struct-member write** (`Reactor_Status.Heating := …`); an `INT16` array tag;
/// a DUT tag; and the ST-bodied `Hysteresis` FB whose internal `Q` persists
/// across scans inside the instance struct `TempAlarmHyst`.
///
/// (c) Falsifiable: zeroing the deadband block leaves `Heat_Cmd`/`Cool_Cmd`
/// false and the reactor drifts to ambient forever; removing the `Heat_Prev`
/// edge guard makes `Reactor_Status.Cycles` climb every scan; deleting the FB's
/// internal `Q` makes the hot-vessel alarm chatter inside the deadband.
///
/// (d) Proof test: `test/defaults/st_reactor_control_test.dart` (plus the
/// re-pointed `test/st_exec_integration_test.dart`,
/// `test/hysteresis_fb_demo_test.dart` and `test/simulated_io_screen_test.dart`).
library;

import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject stReactorControlProject() {
  // Moved VERBATIM from the retired "Noisy Level Measurement" demo: same name,
  // same five vars, same initial values, same stSource. Only its host project
  // and its instance name changed.
  final hysteresisFb = FbDefinition(
    name: 'Hysteresis',
    stSource: 'IF PV > High THEN\n'
        '    Q := TRUE;\n'
        'ELSIF PV < Low THEN\n'
        '    Q := FALSE;\n'
        'END_IF;\n'
        'Out := Q;',
    vars: [
      FbVar(name: 'PV', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'High', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 60.0),
      FbVar(name: 'Low', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 40.0),
      FbVar(name: 'Q', dataType: 'BOOL', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ],
  );

  final structDefs = [
    PlcStructDef(name: 'Reactor_DUT', fields: [
      StructFieldDef(name: 'Heating', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Cooling', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Cycles', dataType: 'INT32', defaultValue: 0),
    ]),
  ];
  final fbScratch = scratchProjectFor(fbDefinitions: [hysteresisFb]);
  final dutScratch = scratchProjectFor(structDefs: structDefs);

  return PlcProject(
    id: 'proj_st_reactor_control',
    name: 'ST — Reactor Temperature Controller',
    controllerName: 'PLC_ST',
    scanPeriodMs: 100,
    fbDefinitions: [hysteresisFb],
    tags: [
      PlcTag(name: 'Temp_PV', path: 'Inputs/Temp_PV', dataType: 'FLOAT64', value: 22.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Reactor temperature process value'),
      PlcTag(name: 'Temp_SP', path: 'Internal/Temp_SP', dataType: 'FLOAT64', value: 75.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Temperature setpoint'),
      PlcTag(name: 'Temp_Ambient', path: 'Internal/Temp_Ambient', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Ambient temperature the reactor drifts toward with no actuation'),
      PlcTag(name: 'Auto_Mode', path: 'Inputs/Auto_Mode', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Auto / Manual selector switch'),
      PlcTag(name: 'Heat_Cmd', path: 'Outputs/Heat_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Heater element contactor'),
      PlcTag(name: 'Cool_Cmd', path: 'Outputs/Cool_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Cooling water valve'),
      PlcTag(name: 'Alarm_High', path: 'Outputs/Alarm_High', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'High temperature alarm (>95°C)'),
      PlcTag(name: 'Alarm_Low', path: 'Outputs/Alarm_Low', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Low temperature alarm (<5°C)'),
      PlcTag(name: 'Reactor_Ready', path: 'Outputs/Reactor_Ready', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reactor at setpoint ±2°C'),
      PlcTag(name: 'Recipe_Select', path: 'Inputs/Recipe_Select', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Load the setpoint from the recipe table'),
      PlcTag(name: 'Heat_Prev', path: 'Internal/Heat_Prev', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Previous-scan Heat_Cmd — the ST edge guard for the cycle counter'),
      PlcTag(name: 'Alarm_Latched', path: 'Outputs/Alarm_Latched', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Hot-vessel latch: sets above 60 °C, clears below 40 °C (Hysteresis FB deadband)'),
      PlcTag(
        name: 'Recipe_Setpoints',
        path: 'Recipe/Setpoints',
        dataType: 'INT16',
        arrayLength: 8,
        value: defaultValueFor(emptyScratchProject, 'INT16', 8),
        ioType: 'Internal',
        description: '8-step recipe setpoint table (°C); index 0 feeds Temp_SP on recipe select',
      ),
      PlcTag(
        name: 'Reactor_Status',
        path: 'Status/Reactor',
        dataType: 'Reactor_DUT',
        value: defaultValueFor(dutScratch, 'Reactor_DUT', 0),
        ioType: 'Internal',
        description: 'Reactor status struct written by ST member assignments',
      ),
      PlcTag(
        name: 'TempAlarmHyst',
        path: 'Internal/TempAlarmHyst',
        dataType: 'Hysteresis',
        value: defaultValueFor(fbScratch, 'Hysteresis', 0),
        ioType: 'Internal',
        description: 'Custom function block instance: hot-vessel hysteresis (60 °C set / 40 °C reset)',
      ),
    ],
    structDefs: structDefs,
    simRules: [
      // First-order thermal process: ambient pull always acts (the loss term),
      // heating/cooling add/remove energy while their contactors are closed.
      SimRule(id: 'sim0', name: 'Heating raises temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: 3.0, minValue: 0, maxValue: 150,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Cooling lowers temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: -3.0, minValue: 0, maxValue: 150,
          condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim2', name: 'Ambient pull (first-order lag)', targetPath: 'Temp_PV',
          behavior: 'firstOrderLag', sourcePath: 'Temp_Ambient', tauSec: 30, minValue: 0, maxValue: 150),
    ],
    programs: [
      PlcProgram(
        name: 'ReactorTemp_ST',
        language: 'StructuredText',
        description: 'Reactor temperature on/off deadband control with alarms, a recipe '
            'table lookup and a status struct',
        stSource: r'''// IEC 61131-3 Structured Text — Reactor Temperature Controller
// ±2°C deadband on/off control with high/low trip alarms

IF Recipe_Select THEN
    Temp_SP := Recipe_Setpoints[0];
END_IF;

IF Auto_Mode THEN
    IF Temp_PV < (Temp_SP - 2.0) THEN
        Heat_Cmd := TRUE;
        Cool_Cmd := FALSE;
    ELSIF Temp_PV > (Temp_SP + 2.0) THEN
        Heat_Cmd := FALSE;
        Cool_Cmd := TRUE;
    ELSE
        Heat_Cmd := FALSE;
        Cool_Cmd := FALSE;
    END_IF;
ELSE
    Heat_Cmd := FALSE;
    Cool_Cmd := FALSE;
END_IF;

Alarm_High    := Temp_PV > 95.0;
Alarm_Low     := Temp_PV < 5.0;
Reactor_Ready := NOT Alarm_High
             AND NOT Alarm_Low
             AND (Temp_PV >= Temp_SP - 2.0)
             AND (Temp_PV <= Temp_SP + 2.0);

// Status struct: member assignments into the Reactor_DUT instance.
Reactor_Status.Heating := Heat_Cmd;
Reactor_Status.Cooling := Cool_Cmd;
IF Heat_Cmd AND NOT Heat_Prev THEN
    Reactor_Status.Cycles := Reactor_Status.Cycles + 1;
END_IF;
Heat_Prev := Heat_Cmd;''',
      ),
      PlcProgram(
        name: 'ReactorAlarm_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Hot-vessel latch driven by the custom Hysteresis function block '
            '(60 °C set / 40 °C reset) — ST has no FB-call syntax, so the call lives here',
        fbdBlocks: [
          FbdBlock(id: 'ra_pv', type: 'TAG_INPUT', title: 'Reactor Temp', tagBinding: 'Temp_PV', x: 50, y: 200),
          FbdBlock(id: 'ra_high', type: 'CONST', title: 'High Threshold', tagBinding: '60.0', x: 50, y: 280),
          FbdBlock(id: 'ra_low', type: 'CONST', title: 'Low Threshold', tagBinding: '40.0', x: 50, y: 360),
          FbdBlock(id: 'ra_hyst', type: 'Hysteresis', title: 'Hot Vessel Hysteresis', tagBinding: 'TempAlarmHyst', x: 320, y: 280),
          FbdBlock(id: 'ra_out', type: 'TAG_OUTPUT', title: 'Alarm Latched', tagBinding: 'Alarm_Latched', x: 560, y: 280),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'ra_pv', fromPin: 'OUT', toBlockId: 'ra_hyst', toPin: 'PV'),
          FbdWire(fromBlockId: 'ra_high', fromPin: 'OUT', toBlockId: 'ra_hyst', toPin: 'High'),
          FbdWire(fromBlockId: 'ra_low', fromPin: 'OUT', toBlockId: 'ra_hyst', toPin: 'Low'),
          FbdWire(fromBlockId: 'ra_hyst', fromPin: 'Out', toBlockId: 'ra_out', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'TempControlTask', type: 'Continuous', periodMs: 100, programNames: ['ReactorTemp_ST', 'ReactorAlarm_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_st_reactor',
        title: 'Reactor Temperature HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'sr1', title: 'Reactor Temperature (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_PV', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'sr2', title: 'Temperature Setpoint', type: 'NumericSliderInput', tagBinding: 'Temp_SP', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'sr3', title: 'Auto Mode', type: 'ToggleSwitch', tagBinding: 'Auto_Mode', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'sr4', title: 'Heater ON', type: 'LedIndicatorLight', tagBinding: 'Heat_Cmd', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'sr5', title: 'Cooler ON', type: 'LedIndicatorLight', tagBinding: 'Cool_Cmd', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'sr6', title: 'Reactor Ready', type: 'LedIndicatorLight', tagBinding: 'Reactor_Ready', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'sr7', title: 'Recipe Select', type: 'ToggleSwitch', tagBinding: 'Recipe_Select', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'sr8', title: 'Recipe Step 0 (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Recipe_Setpoints[0]', gridSpanWidth: 3, accentColor: 'teal'),
          HmiComponent(id: 'sr9', title: 'Heat Cycles', type: 'DigitalGaugeDisplay', tagBinding: 'Reactor_Status.Cycles', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'sr10', title: 'HIGH TEMP ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_High', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'sr11', title: 'LOW TEMP ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_Low', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'sr12', title: 'HOT VESSEL LATCH (Hysteresis FB)', type: 'StatusPillDisplay', tagBinding: 'Alarm_Latched', gridSpanWidth: 2, accentColor: 'red'),
        ],
      ),
    ],
  );
}
```

- [ ] **Step 4: Run the new test**

Run: `/c/flutter/bin/flutter test test/defaults/st_reactor_control_test.dart`
Expected: PASS.
If the `Recipe_Setpoints[0]` assertion fails with `Temp_SP` unchanged, the ST
expression subset did not resolve the index — record it in `docs/DEFERRED.md`
under "Default projects redo (spec 2026-08-06)" and **reshape**: drop the
`IF Recipe_Select THEN Temp_SP := Recipe_Setpoints[0]; END_IF;` block from the
ST body, keep the array tag (it still feeds the HMI and the coverage matrix),
and delete that one test case. Do **not** edit `st_expr.dart`.

- [ ] **Step 5: Run analyze + full suite**

Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/data/default_projects/st_reactor_control.dart mobile/test/defaults/st_reactor_control_test.dart
git commit -m "feat(defaults): add ST — Reactor Temperature Controller showcase project

Keeps the deadband controller verbatim and gains an INT16 recipe array (ST index
read), a Reactor_DUT status struct (ST member writes) and the Hysteresis ST-bodied
FB moved over from the retired Noisy Level demo."
```

---

### Task 6: Flagship — Production Line (`proj_flagship_line`)

**Model:** opus · **Effort:** high

This is the largest project in the lineup: four areas, four programs (one per
IEC language), both custom-FB body kinds, three task types, seven of the eight
sim behaviours, three HMI dashboards (including the never-shipped
`TrendChartDisplay`, `TextInputField` and `System`-tag panel), and
pre-configured Modbus + OPC UA maps.

**Files:**
- Create: `mobile/lib/data/default_projects/flagship_production_line.dart`
- Create: `mobile/test/defaults/flagship_line_test.dart`

**Interfaces:**
- Consumes: `builders.dart` (`ldXic`, `ldXio`, `ldXicRising`, `ldOte`, `ldOtl`,
  `ldOtu`, `ldTon`, `ldCtu`, `ldMath`, `ldFbCall`, `emptyScratchProject`,
  `scratchProjectFor`), `models/ld_graph.dart` (`buildRung`, `BranchSpec`),
  `models/system_tags.dart` (`ensureSystemTag`), `models/modbus_map.dart`
  (`ModbusMap.autoGenerate`), `models/opcua_map.dart` (`OpcuaMap.autoGenerate`),
  `models/protocol_settings.dart` (`ProtocolSettings`, `ModbusProtocolConfig`,
  `OpcUaProtocolConfig`, `kDefaultGatewayUrl`).
- Produces: `PlcProject flagshipProductionLineProject()` — id
  `proj_flagship_line`, name `Flagship — Production Line`, four programs
  `Infeed_LD` / `Blend_FBD` / `Batch_SFC` / `Safety_ST`, two `FbDefinition`s
  `Scale` (ST-bodied) and `ZoneStarter` (ladder-bodied), three tasks
  `StartupTask` / `MainTask` / `BatchTask`, five `TrendPen`s, three HMI screens
  `hmi_flagship_overview` / `hmi_flagship_trends` / `hmi_flagship_diagnostics`,
  and a `ProtocolSettings` with Modbus + OPC UA enabled and auto-generated maps.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/defaults/flagship_line_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/flagship_production_line.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;
double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();
int _i(PlcProject p, String path) => (readPath(p, path) as num).toInt();

/// The full scan tick in the shell's order: sim -> LD -> FBD -> SFC -> ST.
class _Rig {
  final PlcProject p;
  final sim = SimRuntime();
  final ld = LdExecRuntime();
  final fbd = FbdRuntime();
  final sfc = SfcRuntime();
  final st = StRuntime();
  _Rig(this.p);

  void scan([int dtMs = 100]) {
    applySimRules(p, p.simRules, dtMs, sim);
    executeLdPrograms(p, dtMs, ld);
    executeFbdPrograms(p, dtMs, fbd, ldRt: ld);
    executeSfcPrograms(p, dtMs, sfc);
    executeStPrograms(p, dtMs, st);
  }
}

void main() {
  test('exactly three tasks — Startup, Continuous and Periodic — and every '
      'program is referenced by at least one of them', () {
    final p = flagshipProductionLineProject();
    expect(p.tasks.map((t) => t.type).toSet(), {'Startup', 'Continuous', 'Periodic'});
    expect(p.tasks.length, 3);
    final referenced = <String>{for (final t in p.tasks) ...t.programNames};
    for (final prog in p.programs) {
      expect(referenced, contains(prog.name), reason: '${prog.name} has no task');
    }
    expect(p.programs.map((x) => x.language).toSet(), {
      'LadderLogic',
      'FunctionBlockDiagram',
      'SequentialFunctionChart',
      'StructuredText',
    });
  });

  test('all four programs execute in the same scan pipeline', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    writePath(p, 'Line_Start', true);
    writePath(p, 'Batch_Start', true);
    rig.scan();
    rig.scan();

    // Every assertion below moves a tag OFF its declared initial value, so a
    // program that never ran would fail it.
    expect(_b(p, 'Line_Run'), isTrue, reason: 'Infeed_LD ran (initial false)');
    expect(_b(p, 'Conv1_Motor'), isTrue, reason: 'Infeed_LD ran (initial false)');
    expect(_d(p, 'Blend_mA'), greaterThan(4.0),
        reason: 'Blend_FBD ran — the Scale FB mapped the level off its 4.0 mA initial');
    expect(_d(p, 'Blend_mA'), lessThan(20.0));
    expect(_i(p, 'Batch_Step'), 1, reason: 'Batch_SFC ran and advanced IDLE -> CHARGE');
    expect(_b(p, 'Batch_Running'), isTrue);
    expect(_b(p, 'Alarm_Active'), isTrue,
        reason: 'Safety_ST ran — the guard interlock has not engaged yet '
            '(initial Alarm_Active is false)');
  });

  test('the Startup guard initialises the line exactly once', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    // Every tag checked here has exactly ONE writer (the startup block), so a
    // guard that never ran — or that ran every scan — fails.
    writePath(p, 'Batch_Count', 7);
    writePath(p, 'Part_Count', 42);
    writePath(p, 'Batch_Target', 99);
    writePath(p, 'System.FirstScan', true);
    rig.scan();
    expect(_i(p, 'Batch_Count'), 0, reason: 'the first-scan guard cleared the counters');
    expect(_i(p, 'Part_Count'), 0);
    expect(_i(p, 'Batch_Target'), 5, reason: 'the guard restored the planned batch count');

    writePath(p, 'System.FirstScan', false);
    writePath(p, 'Batch_Count', 3);
    writePath(p, 'Batch_Target', 99);
    rig.scan();
    expect(_i(p, 'Batch_Count'), 3, reason: 'the guard must not re-run after the first scan');
    expect(_i(p, 'Batch_Target'), 99, reason: 'the guard must not re-run after the first scan');
  });

  test('the PID drives Blend_Level to Blend_SP against a constant draw and '
      'holds it with a non-saturated valve', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    final sp = _d(p, 'Blend_SP');
    expect(_d(p, 'Blend_Level'), lessThan(sp));

    var minCv = double.infinity;
    var maxCv = -double.infinity;
    for (var i = 0; i < 6000; i++) {
      rig.scan();
      final cv = _d(p, 'Blend_Valve');
      expect(cv, greaterThanOrEqualTo(0.0));
      expect(cv, lessThanOrEqualTo(100.0));
      if (i > 3000) {
        minCv = cv < minCv ? cv : minCv;
        maxCv = cv > maxCv ? cv : maxCv;
      }
    }
    expect((_d(p, 'Blend_Level') - sp).abs(), lessThanOrEqualTo(5.0),
        reason: 'the loop must regulate to setpoint');
    expect(minCv, greaterThan(1.0), reason: 'the valve must not sit shut');
    expect(maxCv, lessThan(99.0), reason: 'the valve must not sit wide open');
  });

  test('the deadTime rule makes Line_Transfer lag Blend_Level', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    // 4.0 s of dead time at 100 ms/scan == 40 scans of delay.
    for (var i = 0; i < 20; i++) {
      rig.scan();
    }
    final levelEarly = _d(p, 'Blend_Level');
    final transferEarly = _d(p, 'Line_Transfer');
    expect(levelEarly, greaterThan(transferEarly + 0.5),
        reason: 'the transfer line has not yet seen the level rise');

    for (var i = 0; i < 120; i++) {
      rig.scan();
    }
    expect(_d(p, 'Line_Transfer'), greaterThan(transferEarly + 0.5),
        reason: 'after the dead time the transfer line follows the level');
  });

  test('setWhileCondition mirrors the compressor and delayedSet locks the guard '
      'only after 2 s', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);

    writePath(p, 'Guard_Closed', false);
    writePath(p, 'Compressor_On', false);
    rig.scan();
    expect(_b(p, 'Air_Pressure_OK'), isFalse);
    expect(_b(p, 'Guard_Locked'), isFalse);

    writePath(p, 'Compressor_On', true);
    rig.scan();
    expect(_b(p, 'Air_Pressure_OK'), isTrue, reason: 'setWhileCondition is immediate');

    writePath(p, 'Guard_Closed', true);
    for (var i = 0; i < 15; i++) {
      rig.scan();
      expect(_b(p, 'Guard_Locked'), isFalse, reason: 'still inside the 2 s delay (scan $i)');
    }
    for (var i = 0; i < 10; i++) {
      rig.scan();
    }
    expect(_b(p, 'Guard_Locked'), isTrue, reason: 'delayedSet fired after 2 s');

    writePath(p, 'Guard_Closed', false);
    rig.scan();
    expect(_b(p, 'Guard_Locked'), isFalse, reason: 'delayedSet drops immediately');
  });

  test('the batch SFC forks, joins and counts one batch per cycle', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);
    final prog = p.programs.firstWhere((x) => x.name == 'Batch_SFC');
    writePath(p, 'Batch_Start', true);

    var maxActive = 0;
    for (var i = 0; i < 2000 && _i(p, 'Batch_Count') < 1; i++) {
      rig.scan();
      final active = rig.sfc.active[prog.name] ?? <String>{};
      if (active.length > maxActive) {
        maxActive = active.length;
      }
    }
    expect(maxActive, greaterThanOrEqualTo(2), reason: 'the fork ran two branches at once');
    expect(_i(p, 'Batch_Count'), 1);
  });

  test('BOTH custom-FB kinds execute: the ST-bodied Scale maps 0-100 % to '
      '4-20 mA and the ladder-bodied ZoneStarter holds per-instance state', () {
    final p = flagshipProductionLineProject();
    final rig = _Rig(p);

    final scale = p.fbDefinitions.firstWhere((f) => f.name == 'Scale');
    expect(scale.stSource, isNotEmpty);
    expect(scale.ladderRungs, isEmpty);
    final zone = p.fbDefinitions.firstWhere((f) => f.name == 'ZoneStarter');
    expect(zone.ladderRungs, isNotEmpty);
    expect(zone.stSource, isEmpty);

    // The sim stage runs BEFORE the FBD stage, so the constant-draw rule (fl1)
    // has already nudged Blend_Level down by the time the Scale FB reads it —
    // assert the linear map against the level the FB actually saw, not 50.0.
    writePath(p, 'Blend_Level', 50.0);
    rig.scan();
    expect(_d(p, 'Blend_mA'), closeTo(4.0 + _d(p, 'Blend_Level') * 0.16, 1e-9),
        reason: 'Out = (In - 0) * (20 - 4) / (100 - 0) + 4');

    // Ladder-bodied FB: Conv2_Request is level-driven, but the FB's own TON
    // start delay lives INSIDE the instance, so Out lags the request by 2 s.
    writePath(p, 'Line_Start', true);
    rig.scan();
    expect(_b(p, 'Conv2_Request'), isTrue);
    expect(_b(p, 'Zone2Start.Seal'), isTrue, reason: 'the FB sealed in');
    expect(_b(p, 'Conv2_Motor'), isFalse, reason: 'the instance TON has not expired');
    for (var i = 0; i < 25; i++) {
      rig.scan();
    }
    expect(_b(p, 'Conv2_Motor'), isTrue, reason: 'the instance TON expired after 2 s');
    expect(_i(p, 'Zone2Start.T.PRE'), 2000,
        reason: 'the timer state lives inside the instance struct, not in a global tag');
    expect(p.tags.any((t) => t.name == 'Seal'), isFalse);
  });

  test('the reserved System tag ships with the project and its members update', () {
    final p = flagshipProductionLineProject();
    expect(p.tags.any((t) => t.name == 'System'), isTrue,
        reason: 'the builder calls ensureSystemTag before generating protocol maps');
    updateSystemStatus(
      p,
      const SystemSnapshot(
        fault: false, faultTask: '', faultCode: 0, running: true, firstScan: false,
        scanCount: 1234, scanTimeMs: 2.5, maxScanTimeMs: 9.5, minScanTimeMs: 0.5,
        freeRun: false, uptimeMs: 60000, year: 2026, month: 8, day: 6, hour: 12,
        minute: 0, second: 0, dateTime: '2026-08-06T12:00:00',
      ),
    );
    expect(_i(p, 'System.ScanCount'), 1234);
    expect(_d(p, 'System.ScanTimeMs'), 2.5);
    expect(_i(p, 'System.UptimeMs'), 60000);
    expect(_b(p, 'System.Running'), isTrue);
  });

  test('every trend pen and every HMI binding resolves to a real tag', () {
    final p = flagshipProductionLineProject();
    expect(p.trends.length, 5);
    final penPaths = p.trends.map((t) => t.tagPath).toSet();
    for (final pen in p.trends) {
      expect(readPath(p, pen.tagPath), isNotNull, reason: 'pen ${pen.tagPath} is dangling');
    }
    expect(p.hmis.length, 3);
    var trendComponents = 0;
    var textInputs = 0;
    var systemBindings = 0;
    for (final screen in p.hmis) {
      for (final c in screen.components) {
        if (c.type == kTrendChartDisplay) {
          trendComponents++;
          expect(c.trendPens, isNotEmpty);
          for (final ref in c.trendPens) {
            expect(penPaths, contains(ref.penTagPath),
                reason: '${ref.penTagPath} has no matching project pen');
          }
          continue;
        }
        if (c.type == 'TextInputField') {
          textInputs++;
        }
        if (c.tagBinding.startsWith('System.')) {
          systemBindings++;
        }
        expect(c.tagBinding, isNotEmpty, reason: '${c.id} has no binding');
        expect(readPath(p, c.tagBinding), isNotNull, reason: '${c.id} binds a missing tag');
      }
    }
    expect(trendComponents, 2, reason: 'one analog chart and one BOOL step-lane chart');
    expect(textInputs, 2);
    expect(systemBindings, greaterThanOrEqualTo(6));
  });

  test('the Modbus and OPC UA maps are pre-generated, enabled, and mark every '
      'System.* leaf ReadOnly', () {
    final p = flagshipProductionLineProject();
    final protocols = p.protocols;
    expect(protocols, isNotNull);
    final modbus = protocols!.modbus;
    final opcua = protocols.opcua;
    expect(modbus, isNotNull);
    expect(opcua, isNotNull);
    expect(modbus!.enabled, isTrue);
    expect(opcua!.enabled, isTrue);
    expect(modbus.map.entries, isNotEmpty);
    expect(opcua.map.nodes, isNotEmpty);
    expect(opcua.namespaceUri, 'urn:softplc:proj_flagship_line');

    final systemModbus = modbus.map.entries.where((e) => e.tag.startsWith('System.'));
    expect(systemModbus, isNotEmpty, reason: 'the System tag must reach the map');
    for (final e in systemModbus) {
      expect(e.access, 'ReadOnly', reason: '${e.tag} must not be externally writable');
    }
    final systemOpcua = opcua.map.nodes.where((n) => n.tag.startsWith('System.'));
    expect(systemOpcua, isNotEmpty);
    for (final n in systemOpcua) {
      expect(n.access, 'ReadOnly', reason: '${n.tag} must not be externally writable');
    }
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/defaults/flagship_line_test.dart`
Expected: FAIL — the library does not exist.

- [ ] **Step 3: Write the project builder**

Create `mobile/lib/data/default_projects/flagship_production_line.dart`:

```dart
/// **Flagship — Production Line** (`proj_flagship_line`).
///
/// (a) Story: a four-area plant with lots of moving parts. Two infeed conveyors
/// run under a seal-in with jam detection and part counting (LD); a blending
/// station holds tank level with a PID against a constant draw, picks a recipe
/// ratio and scales the level to a 4-20 mA transmitter signal (FBD); a batch
/// sequencer charges, then heats and agitates in parallel, holds, discharges
/// and counts (SFC); and a supervisor aggregates permissives, alarms,
/// `System`-derived health and run hours (ST).
///
/// (b) Showcase for everything no other default covers at once: **all three
/// task types** (`Startup` / `Continuous` / `Periodic`); **both custom-FB body
/// kinds** (`Scale` ST-bodied, `ZoneStarter` ladder-bodied with a scoped `TIMER`
/// var); seven of the eight sim behaviours — `integrate` (with a NON-LINEAR
/// `equalPercentage` valve curve), `firstOrderLag`, `deadTime`, `noise`
/// (gaussian + drift), `pulse`, **`setWhileCondition`** and **`delayedSet`**
/// (the last two showcased nowhere else); the reserved **`System` tag bound on
/// an HMI**; the **`TrendChartDisplay`** widget with project `TrendPen`s
/// (analog pens plus BOOL step lanes); the **`TextInputField`** widget; and
/// **pre-configured Modbus + OPC UA maps** so the Gateway screen shows live
/// content out of the box.
///
/// (c) Falsifiable: zeroing the PID gains pins `Blend_Valve` shut and the tank
/// drains to empty under the constant draw; deleting the `deadTime` rule makes
/// `Line_Transfer` track `Blend_Level` instantly; removing the `ZoneStarter`
/// body leaves `Conv2_Motor` dead; removing the `System.FirstScan` guard
/// re-initialises the counters every scan.
///
/// (d) Proof test: `test/defaults/flagship_line_test.dart`.
///
/// NOTE on `enabled: true` protocols: nothing in `workspace_shell.dart` starts a
/// protocol host on project load — `start()` is only reached from the Gateway
/// screen's toggle. Task 8 re-confirms this by test (`flagship_gateway_no_
/// autostart_test.dart`). If that ever changes, ship these configs with
/// `enabled: false` and record the finding in `docs/DEFERRED.md`.
library;

import '../../models/ld_graph.dart';
import '../../models/modbus_map.dart';
import '../../models/noise_model.dart';
import '../../models/opcua_map.dart';
import '../../models/project_model.dart';
import '../../models/protocol_settings.dart';
import '../../models/system_tags.dart';
import '../../models/tag_resolver.dart';
import '../../models/valve_curve.dart';
import 'builders.dart';

PlcProject flagshipProductionLineProject() {
  // ── Custom function blocks — one of each body kind ──────────────────────
  final scaleFb = FbDefinition(
    name: 'Scale',
    stSource: 'Out := (In - InLo) * (OutHi - OutLo) / (InHi - InLo) + OutLo;',
    vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'InLo', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 0.0),
      FbVar(name: 'InHi', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 100.0),
      FbVar(name: 'OutLo', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 4.0),
      FbVar(name: 'OutHi', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 20.0),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output, initialValue: 4.0),
    ],
  );

  // Ladder-bodied: the seal-in AND the 2 s start delay live inside the
  // instance — `T` is a TIMER var, so `T.ACC`/`T.PRE` resolve to
  // `<instance>.T.ACC` / `<instance>.T.PRE`, never to a global tag.
  final zoneStarterFb = FbDefinition(
    name: 'ZoneStarter',
    vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Permit', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Seal', dataType: 'BOOL', direction: FbVarDir.internal),
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ],
    ladderRungs: [
      buildRung(
        index: 0,
        comment: 'FB rung 0: seal in the run request while the permit holds',
        main: [ldXic('Run', 'Run request'), ldXic('Permit', 'Permit'), ldOte('Seal', 'Instance seal')],
        branches: [
          BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Seal', 'Seal-in aux')]),
        ],
      ),
      buildRung(
        index: 1,
        comment: 'FB rung 1: 2 s start delay inside the instance, then drive the output',
        main: [ldXic('Seal', 'Sealed'), ldTon('T', 2000, 'Instance start delay'), ldOte('Out', 'Zone output')],
      ),
    ],
  );

  final scaleScratch = scratchProjectFor(fbDefinitions: [scaleFb]);
  final zoneScratch = scratchProjectFor(fbDefinitions: [zoneStarterFb]);

  final project = PlcProject(
    id: 'proj_flagship_line',
    name: 'Flagship — Production Line',
    controllerName: 'PLC_LINE01',
    scanPeriodMs: 100,
    fbDefinitions: [scaleFb, zoneStarterFb],
    tags: [
      // ── Area 1: infeed conveyors (LD) ─────────────────────────────────
      PlcTag(name: 'Line_Start', path: 'Inputs/Line_Start', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Line start pushbutton'),
      PlcTag(name: 'Line_Stop', path: 'Inputs/Line_Stop', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Line stop pushbutton (NC)'),
      PlcTag(name: 'EStop_OK', path: 'Inputs/EStop_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Line emergency stop healthy'),
      PlcTag(name: 'Line_Run', path: 'Internal/Line_Run', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Line seal-in latch'),
      PlcTag(name: 'Conv1_Motor', path: 'Outputs/Conv1_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Infeed conveyor 1 contactor'),
      PlcTag(name: 'Conv2_Motor', path: 'Outputs/Conv2_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Infeed conveyor 2 contactor (ZoneStarter FB output)'),
      PlcTag(name: 'Conv2_Request', path: 'Internal/Conv2_Request', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Run request into the ZoneStarter FB'),
      PlcTag(name: 'Photo1', path: 'Inputs/Photo1', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Conveyor 1 part photo eye'),
      PlcTag(name: 'Photo2', path: 'Inputs/Photo2', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Conveyor 2 part photo eye'),
      PlcTag(name: 'Conv1_Jam', path: 'Outputs/Conv1_Jam', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Conveyor 1 jam alarm (latched)'),
      PlcTag(name: 'JamTimer1', path: 'Timers/JamTimer1', dataType: 'TIMER', value: defaultValueFor(emptyScratchProject, 'TIMER', 0), ioType: 'Internal', description: 'On-delay timer: 6 s with no part trips the conveyor 1 jam'),
      PlcTag(name: 'PartCtu', path: 'Counters/PartCtu', dataType: 'COUNTER', value: defaultValueFor(emptyScratchProject, 'COUNTER', 0), ioType: 'Internal', description: 'Count-up counter: parts per pallet (preset 5)'),
      PlcTag(name: 'Part_Count', path: 'Internal/Part_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Parts fed into the line'),
      PlcTag(name: 'Zone2Start', path: 'Internal/Zone2Start', dataType: 'ZoneStarter', value: defaultValueFor(zoneScratch, 'ZoneStarter', 0), ioType: 'Internal', description: 'Ladder-bodied ZoneStarter FB instance (seal-in + scoped start-delay TIMER)'),
      // ── Area 2: blending (FBD) ────────────────────────────────────────
      PlcTag(name: 'Blend_Level', path: 'Inputs/Blend_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Blend tank level'),
      PlcTag(name: 'Blend_SP', path: 'Internal/Blend_SP', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Blend tank level setpoint'),
      PlcTag(name: 'Blend_Valve', path: 'Outputs/Blend_Valve', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Blend trim valve (PID output, equal-percentage characteristic)'),
      PlcTag(name: 'Blend_Temp', path: 'Inputs/Blend_Temp', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Blend tank temperature (first-order lag toward Steam_Temp)'),
      PlcTag(name: 'Steam_Temp', path: 'Internal/Steam_Temp', dataType: 'FLOAT64', value: 85.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Jacket steam temperature the tank lags toward'),
      PlcTag(name: 'Line_Transfer', path: 'Internal/Line_Transfer', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal', engineeringUnits: '%', description: 'Downstream transport signal — Blend_Level delayed by 4 s (deadTime)'),
      PlcTag(name: 'Level_Meas', path: 'Inputs/Level_Meas', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Level transmitter reading — Blend_Level plus gaussian noise and slow drift'),
      PlcTag(name: 'Recipe_Select', path: 'Inputs/Recipe_Select', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Recipe A / B selector'),
      PlcTag(name: 'Recipe_A_Ratio', path: 'Internal/Recipe_A_Ratio', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Recipe A blend ratio'),
      PlcTag(name: 'Recipe_B_Ratio', path: 'Internal/Recipe_B_Ratio', dataType: 'FLOAT64', value: 40.0, ioType: 'Internal', engineeringUnits: '%', description: 'Recipe B blend ratio'),
      PlcTag(name: 'Ratio_SP', path: 'Internal/Ratio_SP', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Active blend ratio (SEL output)'),
      PlcTag(name: 'Blend_Rate', path: 'Internal/Blend_Rate', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: '%', description: 'Ratio_SP * Blend_Valve / 100 — the actual component feed rate'),
      PlcTag(name: 'Blend_mA', path: 'Internal/Blend_mA', dataType: 'FLOAT64', value: 4.0, ioType: 'Internal', engineeringUnits: 'mA', description: 'Blend_Level scaled to 4-20 mA by the Scale FB'),
      PlcTag(name: 'Blend_Scale', path: 'Internal/Blend_Scale', dataType: 'Scale', value: defaultValueFor(scaleScratch, 'Scale', 0), ioType: 'Internal', description: 'ST-bodied Scale FB instance (0-100 % -> 4-20 mA)'),
      // ── Area 3: batch sequencing (SFC) ────────────────────────────────
      PlcTag(name: 'Batch_Start', path: 'Inputs/Batch_Start', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Batch start command'),
      PlcTag(name: 'Batch_Running', path: 'Internal/Batch_Running', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Batch sequence active (trended as a BOOL step lane)'),
      PlcTag(name: 'Batch_Step', path: 'Internal/Batch_Step', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Current batch SFC step index (0–8)'),
      PlcTag(name: 'Charge_Level', path: 'Inputs/Charge_Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Batch vessel charge level'),
      PlcTag(name: 'Charge_Valve', path: 'Outputs/Charge_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Batch charge valve'),
      PlcTag(name: 'Heater', path: 'Outputs/Heater', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Batch vessel heater'),
      PlcTag(name: 'Agitator', path: 'Outputs/Agitator', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Batch vessel agitator'),
      PlcTag(name: 'Discharge_Pump', path: 'Outputs/Discharge_Pump', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Batch discharge pump'),
      PlcTag(name: 'Batch_Count', path: 'Internal/Batch_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Completed batches this run'),
      // ── Area 4: safety / supervision (ST) ─────────────────────────────
      PlcTag(name: 'Guard_Closed', path: 'Inputs/Guard_Closed', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Guard door closed sensor'),
      PlcTag(name: 'Guard_Locked', path: 'Inputs/Guard_Locked', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Guard interlock engaged 2 s after the door closes (delayedSet)'),
      PlcTag(name: 'Compressor_On', path: 'Internal/Compressor_On', dataType: 'BOOL', value: true, ioType: 'Internal', description: 'Instrument-air compressor running'),
      PlcTag(name: 'Air_Pressure_OK', path: 'Inputs/Air_Pressure_OK', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Instrument air healthy while the compressor runs (setWhileCondition)'),
      PlcTag(name: 'Permissives_OK', path: 'Internal/Permissives_OK', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'All supervisory permissives healthy'),
      PlcTag(name: 'Health_OK', path: 'Internal/Health_OK', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Controller health derived from the reserved System tag'),
      PlcTag(name: 'Alarm_Active', path: 'Outputs/Alarm_Active', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Plant alarm beacon (trended as a BOOL step lane)'),
      PlcTag(name: 'Run_Hours', path: 'Internal/Run_Hours', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: 'h', description: 'Accumulated line run hours'),
      PlcTag(name: 'Recipe_Name', path: 'Internal/Recipe_Name', dataType: 'STRING', value: 'BLEND-A', ioType: 'Internal', description: 'Recipe identifier (edited from the diagnostics dashboard)'),
      PlcTag(name: 'Batch_Target', path: 'Internal/Batch_Target', dataType: 'INT32', value: 5, ioType: 'Internal', description: 'Batches planned for this run (edited from the diagnostics dashboard, read by Safety_ST)'),
      PlcTag(name: 'Batch_Done', path: 'Outputs/Batch_Done', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Planned batch count reached (Batch_Count >= Batch_Target)'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'fl0', name: 'Blend inflow (equal-percentage valve)', targetPath: 'Blend_Level',
          behavior: 'integrate', ratePerSec: 6.0, sourcePath: 'Blend_Valve', refValue: 100.0,
          valveCurve: kValveEqualPercentage, minValue: 0, maxValue: 100),
      SimRule(id: 'fl1', name: 'Blend outflow (constant draw)', targetPath: 'Blend_Level',
          behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100),
      SimRule(id: 'fl2', name: 'Tank thermal lag toward steam', targetPath: 'Blend_Temp',
          behavior: 'firstOrderLag', sourcePath: 'Steam_Temp', tauSec: 20.0, minValue: 0, maxValue: 150),
      SimRule(id: 'fl3', name: 'Downstream transport delay', targetPath: 'Line_Transfer',
          behavior: 'deadTime', sourcePath: 'Blend_Level', tauSec: 4.0, minValue: 0, maxValue: 100),
      SimRule(id: 'fl4', name: 'Level transmitter noise + drift', targetPath: 'Level_Meas',
          behavior: 'noise', sourcePath: 'Blend_Level', targetValue: 1.5,
          noiseDistribution: kNoiseGaussian, driftAmplitude: 0.5, driftPeriodSec: 90.0,
          minValue: 0, maxValue: 100),
      SimRule(id: 'fl5', name: 'Conveyor 1 photo eye', targetPath: 'Photo1',
          behavior: 'pulse', onMs: 1500, offMs: 2000,
          condition: [SimClause(leftPath: 'Conv1_Motor', comparator: '==', operand: 'true')]),
      SimRule(id: 'fl6', name: 'Conveyor 2 photo eye', targetPath: 'Photo2',
          behavior: 'pulse', onMs: 1500, offMs: 2000,
          condition: [SimClause(leftPath: 'Conv2_Motor', comparator: '==', operand: 'true')]),
      SimRule(id: 'fl7', name: 'Instrument air healthy while the compressor runs',
          targetPath: 'Air_Pressure_OK', behavior: 'setWhileCondition',
          condition: [SimClause(leftPath: 'Compressor_On', comparator: '==', operand: 'true')]),
      SimRule(id: 'fl8', name: 'Guard interlock engages 2 s after the door closes',
          targetPath: 'Guard_Locked', behavior: 'delayedSet', delayMs: 2000,
          condition: [SimClause(leftPath: 'Guard_Closed', comparator: '==', operand: 'true')]),
      SimRule(id: 'fl9', name: 'Batch vessel charges', targetPath: 'Charge_Level',
          behavior: 'integrate', ratePerSec: 20.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Charge_Valve', comparator: '==', operand: 'true')]),
      SimRule(id: 'fl10', name: 'Batch vessel discharges', targetPath: 'Charge_Level',
          behavior: 'integrate', ratePerSec: -25.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Discharge_Pump', comparator: '==', operand: 'true')]),
    ],
    trends: [
      TrendPen(tagPath: 'Blend_Level', color: 'cyan', sampleIntervalMs: 250, retentionMode: 'time', windowMs: 300000),
      TrendPen(tagPath: 'Blend_Valve', color: 'amber', sampleIntervalMs: 250, retentionMode: 'time', windowMs: 300000),
      TrendPen(tagPath: 'Blend_Temp', color: 'teal', sampleIntervalMs: 250, retentionMode: 'time', windowMs: 300000),
      TrendPen(tagPath: 'Batch_Running', color: 'green', sampleIntervalMs: 250, retentionMode: 'time', windowMs: 300000),
      TrendPen(tagPath: 'Alarm_Active', color: 'red', sampleIntervalMs: 250, retentionMode: 'time', windowMs: 300000),
    ],
    programs: [
      // ── Infeed (LD) ───────────────────────────────────────────────────
      PlcProgram(
        name: 'Infeed_LD',
        language: 'LadderLogic',
        description: 'Two infeed conveyors: seal-in, jam TON, part CTU, and a ladder-bodied '
            'ZoneStarter FB call for conveyor 2',
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Line Seal-In',
            main: [
              ldXic('Line_Start', 'Start NO'),
              ldXio('Line_Stop', 'Stop NC'),
              ldXic('EStop_OK', 'E-Stop healthy'),
              ldOte('Line_Run', 'Line latch'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Line_Run', 'Seal-in aux')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Conveyor 1 Motor',
            main: [ldXic('Line_Run', 'Line running'), ldOte('Conv1_Motor', 'Conveyor 1')],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Conveyor 2 Run Request (blocked by a conveyor 1 jam)',
            main: [
              ldXic('Line_Run', 'Line running'),
              ldXio('Conv1_Jam', 'No jam NC'),
              ldOte('Conv2_Request', 'Zone 2 request'),
            ],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Count Parts per Pallet (CTU)',
            main: [ldXicRising('Photo1', 'Part edge'), ldCtu('PartCtu', 5, 'Parts per pallet')],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Total Parts Fed (ADD)',
            main: [ldXicRising('Photo1', 'Part edge'), ldMath('ADD', 'Part_Count', 'Part_Count', '1', 'Part_Count + 1')],
          ),
          buildRung(
            index: 5,
            comment: 'Rung 5: Conveyor 1 Jam Detection (TON, 6 s with no part)',
            main: [
              ldXic('Conv1_Motor', 'Conveyor 1 running'),
              ldXio('Photo1', 'No part NC'),
              ldTon('JamTimer1', 6000, '6s jam timer'),
            ],
          ),
          buildRung(
            index: 6,
            comment: 'Rung 6: Latch the Conveyor 1 Jam',
            main: [ldXic('JamTimer1.DN', 'Timer done'), ldOtl('Conv1_Jam', 'Latch jam')],
          ),
          buildRung(
            index: 7,
            comment: 'Rung 7: A Part Clears the Jam',
            main: [ldXic('Photo1', 'Part seen'), ldOtu('Conv1_Jam', 'Unlatch jam')],
          ),
          buildRung(
            index: 8,
            comment: 'Rung 8: Conveyor 2 Starter — LADDER-BODIED custom FB call. '
                'Unconditional (straight off the left rail) so the FB keeps evaluating '
                'its own Permit and can drop its seal when the request or permit goes away.',
            main: [
              ldFbCall('ZoneStarter', 'Zone2Start', {
                'Run': 'Conv2_Request',
                'Permit': 'EStop_OK',
                'Out': 'Conv2_Motor',
              }, 'Conveyor 2 starter instance'),
            ],
          ),
        ],
      ),
      // ── Blending (FBD) ────────────────────────────────────────────────
      PlcProgram(
        name: 'Blend_FBD',
        language: 'FunctionBlockDiagram',
        description: 'PID level control with a LIMIT clamp, a SEL recipe pick with MUL/DIV '
            'ratio maths, and an ST-bodied Scale FB producing a 4-20 mA transmitter signal',
        fbdNetworks: [
          FbdNetwork(comment: 'Blend tank level PID + output clamp'),
          FbdNetwork(comment: 'Recipe selection and ratio maths'),
          FbdNetwork(comment: 'Level to 4-20 mA transmitter scaling (Scale FB)'),
        ],
        fbdBlocks: [
          // Network 0.
          FbdBlock(id: 'bl_sp', type: 'TAG_INPUT', title: 'Blend SP', tagBinding: 'Blend_SP', x: 50, y: 80, network: 0),
          FbdBlock(id: 'bl_pv', type: 'TAG_INPUT', title: 'Blend Level', tagBinding: 'Blend_Level', x: 50, y: 190, network: 0),
          FbdBlock(id: 'bl_kp', type: 'CONST', title: 'Kp', tagBinding: '2.0', x: 50, y: 300, network: 0),
          FbdBlock(id: 'bl_ki', type: 'CONST', title: 'Ki', tagBinding: '0.5', x: 50, y: 380, network: 0),
          FbdBlock(id: 'bl_kd', type: 'CONST', title: 'Kd', tagBinding: '0.05', x: 50, y: 460, network: 0),
          FbdBlock(id: 'bl_pid', type: 'PID', title: 'Blend Level PID', x: 320, y: 240, network: 0),
          FbdBlock(id: 'bl_lo', type: 'CONST', title: 'Valve Min', tagBinding: '0.0', x: 320, y: 460, network: 0),
          FbdBlock(id: 'bl_hi', type: 'CONST', title: 'Valve Max', tagBinding: '100.0', x: 320, y: 540, network: 0),
          FbdBlock(id: 'bl_lim', type: 'LIMIT', title: 'Clamp 0..100', x: 560, y: 300, network: 0),
          FbdBlock(id: 'bl_cv', type: 'TAG_OUTPUT', title: 'Blend Valve', tagBinding: 'Blend_Valve', x: 800, y: 300, network: 0),
          // Network 1.
          FbdBlock(id: 'bl_rsel', type: 'TAG_INPUT', title: 'Recipe Select', tagBinding: 'Recipe_Select', x: 50, y: 80, network: 1),
          FbdBlock(id: 'bl_ra', type: 'TAG_INPUT', title: 'Recipe A Ratio', tagBinding: 'Recipe_A_Ratio', x: 50, y: 190, network: 1),
          FbdBlock(id: 'bl_rb', type: 'TAG_INPUT', title: 'Recipe B Ratio', tagBinding: 'Recipe_B_Ratio', x: 50, y: 300, network: 1),
          FbdBlock(id: 'bl_sel', type: 'SEL', title: 'Recipe Pick', x: 280, y: 190, network: 1),
          FbdBlock(id: 'bl_ratio', type: 'TAG_OUTPUT', title: 'Ratio SP', tagBinding: 'Ratio_SP', x: 520, y: 130, network: 1),
          FbdBlock(id: 'bl_v', type: 'TAG_INPUT', title: 'Blend Valve', tagBinding: 'Blend_Valve', x: 50, y: 420, network: 1),
          FbdBlock(id: 'bl_mul', type: 'MUL', title: 'Ratio * Valve', x: 520, y: 330, network: 1),
          FbdBlock(id: 'bl_c100', type: 'CONST', title: 'Percent Base', tagBinding: '100.0', x: 520, y: 470, network: 1),
          FbdBlock(id: 'bl_div', type: 'DIV', title: '/ 100', x: 760, y: 380, network: 1),
          FbdBlock(id: 'bl_rate', type: 'TAG_OUTPUT', title: 'Blend Rate', tagBinding: 'Blend_Rate', x: 1000, y: 380, network: 1),
          // Network 2.
          FbdBlock(id: 'bl_in', type: 'TAG_INPUT', title: 'Blend Level', tagBinding: 'Blend_Level', x: 50, y: 80, network: 2),
          FbdBlock(id: 'bl_inlo', type: 'CONST', title: 'In Lo', tagBinding: '0.0', x: 50, y: 190, network: 2),
          FbdBlock(id: 'bl_inhi', type: 'CONST', title: 'In Hi', tagBinding: '100.0', x: 50, y: 270, network: 2),
          FbdBlock(id: 'bl_outlo', type: 'CONST', title: 'Out Lo (mA)', tagBinding: '4.0', x: 50, y: 350, network: 2),
          FbdBlock(id: 'bl_outhi', type: 'CONST', title: 'Out Hi (mA)', tagBinding: '20.0', x: 50, y: 430, network: 2),
          FbdBlock(id: 'bl_scale', type: 'Scale', title: 'Level -> 4-20 mA', tagBinding: 'Blend_Scale', x: 320, y: 250, network: 2),
          FbdBlock(id: 'bl_ma', type: 'TAG_OUTPUT', title: 'Blend mA', tagBinding: 'Blend_mA', x: 600, y: 250, network: 2),
        ],
        fbdWires: [
          // Network 0.
          FbdWire(fromBlockId: 'bl_sp', fromPin: 'OUT', toBlockId: 'bl_pid', toPin: 'SP'),
          FbdWire(fromBlockId: 'bl_pv', fromPin: 'OUT', toBlockId: 'bl_pid', toPin: 'PV'),
          FbdWire(fromBlockId: 'bl_kp', fromPin: 'OUT', toBlockId: 'bl_pid', toPin: 'KP'),
          FbdWire(fromBlockId: 'bl_ki', fromPin: 'OUT', toBlockId: 'bl_pid', toPin: 'KI'),
          FbdWire(fromBlockId: 'bl_kd', fromPin: 'OUT', toBlockId: 'bl_pid', toPin: 'KD'),
          FbdWire(fromBlockId: 'bl_lo', fromPin: 'OUT', toBlockId: 'bl_lim', toPin: 'MN'),
          FbdWire(fromBlockId: 'bl_pid', fromPin: 'CV', toBlockId: 'bl_lim', toPin: 'IN'),
          FbdWire(fromBlockId: 'bl_hi', fromPin: 'OUT', toBlockId: 'bl_lim', toPin: 'MX'),
          FbdWire(fromBlockId: 'bl_lim', fromPin: 'OUT', toBlockId: 'bl_cv', toPin: 'IN'),
          // Network 1.
          FbdWire(fromBlockId: 'bl_rsel', fromPin: 'OUT', toBlockId: 'bl_sel', toPin: 'G'),
          FbdWire(fromBlockId: 'bl_ra', fromPin: 'OUT', toBlockId: 'bl_sel', toPin: 'IN0'),
          FbdWire(fromBlockId: 'bl_rb', fromPin: 'OUT', toBlockId: 'bl_sel', toPin: 'IN1'),
          FbdWire(fromBlockId: 'bl_sel', fromPin: 'OUT', toBlockId: 'bl_ratio', toPin: 'IN'),
          FbdWire(fromBlockId: 'bl_sel', fromPin: 'OUT', toBlockId: 'bl_mul', toPin: 'IN1'),
          FbdWire(fromBlockId: 'bl_v', fromPin: 'OUT', toBlockId: 'bl_mul', toPin: 'IN2'),
          FbdWire(fromBlockId: 'bl_mul', fromPin: 'OUT', toBlockId: 'bl_div', toPin: 'IN1'),
          FbdWire(fromBlockId: 'bl_c100', fromPin: 'OUT', toBlockId: 'bl_div', toPin: 'IN2'),
          FbdWire(fromBlockId: 'bl_div', fromPin: 'OUT', toBlockId: 'bl_rate', toPin: 'IN'),
          // Network 2.
          FbdWire(fromBlockId: 'bl_in', fromPin: 'OUT', toBlockId: 'bl_scale', toPin: 'In'),
          FbdWire(fromBlockId: 'bl_inlo', fromPin: 'OUT', toBlockId: 'bl_scale', toPin: 'InLo'),
          FbdWire(fromBlockId: 'bl_inhi', fromPin: 'OUT', toBlockId: 'bl_scale', toPin: 'InHi'),
          FbdWire(fromBlockId: 'bl_outlo', fromPin: 'OUT', toBlockId: 'bl_scale', toPin: 'OutLo'),
          FbdWire(fromBlockId: 'bl_outhi', fromPin: 'OUT', toBlockId: 'bl_scale', toPin: 'OutHi'),
          FbdWire(fromBlockId: 'bl_scale', fromPin: 'Out', toBlockId: 'bl_ma', toPin: 'IN'),
        ],
      ),
      // ── Batch sequencing (SFC) ────────────────────────────────────────
      PlcProgram(
        name: 'Batch_SFC',
        language: 'SequentialFunctionChart',
        description: 'Charge, then heat and agitate in parallel, join, hold, discharge and count',
        sfcSteps: [
          SfcStep(id: 'f_idle', name: 'IDLE', isInitial: true,
              actionSt: 'Batch_Step := 0;\nBatch_Running := FALSE;\nCharge_Valve := FALSE;\n'
                  'Heater := FALSE;\nAgitator := FALSE;\nDischarge_Pump := FALSE;\nCharge_Level := 0.0;'),
          SfcStep(id: 'f_charge', name: 'CHARGE',
              actionSt: 'Batch_Step := 1;\nBatch_Running := TRUE;\nCharge_Valve := TRUE;'),
          SfcStep(id: 'f_heat', name: 'HEAT', actionSt: 'Batch_Step := 2;\nCharge_Valve := FALSE;\nHeater := TRUE;'),
          SfcStep(id: 'f_heat_done', name: 'HEAT_DONE', actionSt: 'Batch_Step := 3;\nHeater := FALSE;'),
          SfcStep(id: 'f_agitate', name: 'AGITATE', actionSt: 'Batch_Step := 4;\nAgitator := TRUE;'),
          SfcStep(id: 'f_agit_done', name: 'AGIT_DONE', actionSt: 'Batch_Step := 5;\nAgitator := FALSE;'),
          SfcStep(id: 'f_hold', name: 'HOLD', actionSt: 'Batch_Step := 6;\n// 2s soak dwell'),
          SfcStep(id: 'f_discharge', name: 'DISCHARGE', actionSt: 'Batch_Step := 7;\nDischarge_Pump := TRUE;'),
          SfcStep(id: 'f_count', name: 'COUNT',
              actionSt: 'Batch_Step := 8;\nDischarge_Pump := FALSE;\nBatch_Running := FALSE;\n'
                  'Batch_Count := Batch_Count + 1;'),
        ],
        sfcTransitions: [
          SfcTransition(id: 'ft0', fromStepId: 'f_idle', toStepId: 'f_charge', conditionSt: 'Batch_Start'),
          SfcTransition(id: 'ft1', fromStepId: 'f_charge', toStepId: '', conditionSt: 'Charge_Level >= 80.0',
              kind: 'parallelFork', toStepIds: ['f_heat', 'f_agitate']),
          SfcTransition(id: 'ft2', fromStepId: 'f_heat', toStepId: 'f_heat_done', conditionSt: 'STEP_T >= 3000'),
          SfcTransition(id: 'ft3', fromStepId: 'f_agitate', toStepId: 'f_agit_done', conditionSt: 'STEP_T >= 2000'),
          SfcTransition(id: 'ftj', fromStepId: '', toStepId: 'f_hold', conditionSt: 'TRUE',
              kind: 'parallelJoin', fromStepIds: ['f_heat_done', 'f_agit_done']),
          SfcTransition(id: 'ft4', fromStepId: 'f_hold', toStepId: 'f_discharge', conditionSt: 'STEP_T >= 2000'),
          SfcTransition(id: 'ft5', fromStepId: 'f_discharge', toStepId: 'f_count', conditionSt: 'Charge_Level <= 5.0'),
          SfcTransition(id: 'ft6', fromStepId: 'f_count', toStepId: 'f_idle', conditionSt: 'TRUE'),
        ],
      ),
      // ── Safety / supervision (ST) ─────────────────────────────────────
      PlcProgram(
        name: 'Safety_ST',
        language: 'StructuredText',
        description: 'Startup initialisation (System.FirstScan guarded), supervisory '
            'permissives, alarm aggregation, System-derived health and run-hour accumulation',
        stSource: r'''// IEC 61131-3 Structured Text — Line Supervisor
// Runs from BOTH the Startup task (once) and the Continuous task (every scan).
// The System.FirstScan guard is what makes the initialisation block one-shot.

// NOTE: every tag initialised here must have NO other writer, or the assertion
// that the block ran exactly once is unfalsifiable. `Ratio_SP` is deliberately
// NOT initialised here — Blend_FBD's `bl_ratio` TAG_OUTPUT rewrites it every
// scan, so a first-scan value would be indistinguishable from the steady state.
IF System.FirstScan THEN
    Batch_Target := 5;
    Batch_Count := 0;
    Part_Count := 0;
    Run_Hours := 0.0;
END_IF;

Permissives_OK := EStop_OK AND Guard_Closed AND Guard_Locked AND Air_Pressure_OK;
Health_OK      := System.Running AND NOT System.Fault;
Alarm_Active   := (NOT Permissives_OK) OR Conv1_Jam OR (Blend_Level > 95.0);
Batch_Done     := Batch_Count >= Batch_Target;

// 100 ms of run time is 0.0000278 h.
IF Line_Run THEN
    Run_Hours := Run_Hours + 0.0000278;
END_IF;''',
      ),
    ],
    tasks: [
      PlcTask(name: 'StartupTask', type: 'Startup', periodMs: 100, programNames: ['Safety_ST']),
      PlcTask(name: 'MainTask', type: 'Continuous', periodMs: 100, programNames: ['Infeed_LD', 'Blend_FBD', 'Safety_ST']),
      PlcTask(name: 'BatchTask', type: 'Periodic', periodMs: 250, programNames: ['Batch_SFC']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_flagship_overview',
        title: 'Production Line Overview',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'fo1', title: 'START Line', type: 'PushbuttonSwitch', tagBinding: 'Line_Start', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fo2', title: 'STOP Line', type: 'PushbuttonSwitch', tagBinding: 'Line_Stop', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'fo3', title: 'E-Stop Healthy', type: 'ToggleSwitch', tagBinding: 'EStop_OK', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'fo4', title: 'START Batch', type: 'PushbuttonSwitch', tagBinding: 'Batch_Start', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fo5', title: 'Conveyor 1', type: 'LedIndicatorLight', tagBinding: 'Conv1_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fo6', title: 'Conveyor 2', type: 'LedIndicatorLight', tagBinding: 'Conv2_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fo7', title: 'Batch Running', type: 'LedIndicatorLight', tagBinding: 'Batch_Running', gridSpanWidth: 1, accentColor: 'teal'),
          HmiComponent(id: 'fo8', title: 'Permissives OK', type: 'LedIndicatorLight', tagBinding: 'Permissives_OK', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fo9', title: 'Blend Tank Level', type: 'TankGraphicDisplay', tagBinding: 'Blend_Level', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'fo10', title: 'Blend Setpoint', type: 'NumericSliderInput', tagBinding: 'Blend_SP', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'fo11', title: 'Blend Valve (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Blend_Valve', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'fo12', title: 'Blend Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Blend_Temp', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'fo13', title: 'Transmitter (mA)', type: 'DigitalGaugeDisplay', tagBinding: 'Blend_mA', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'fo14', title: 'Parts Fed', type: 'DigitalGaugeDisplay', tagBinding: 'Part_Count', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'fo15', title: 'Batches Complete', type: 'StatusPillDisplay', tagBinding: 'Batch_Count', gridSpanWidth: 2, accentColor: 'green'),
          HmiComponent(id: 'fo16', title: 'PLANT ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_Active', gridSpanWidth: 2, accentColor: 'red'),
          // The noise rule (fl4) writes Level_Meas; without a display it would
          // be a behaviour nothing in the app ever surfaces.
          HmiComponent(id: 'fo17', title: 'Level Transmitter (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Meas', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'fo18', title: 'Batch Target Reached', type: 'LedIndicatorLight', tagBinding: 'Batch_Done', gridSpanWidth: 1, accentColor: 'green'),
        ],
      ),
      HmiScreenDef(
        id: 'hmi_flagship_trends',
        title: 'Production Line Trends',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(
            id: 'ft_analog',
            title: 'Blend Loop (analog pens)',
            type: kTrendChartDisplay,
            tagBinding: '',
            gridSpanWidth: 4,
            accentColor: 'cyan',
            windowMs: 120000,
            trendPens: [
              TrendPenRef(penTagPath: 'Blend_Level'),
              TrendPenRef(penTagPath: 'Blend_Valve'),
              TrendPenRef(penTagPath: 'Blend_Temp'),
            ],
          ),
          HmiComponent(
            id: 'ft_bool',
            title: 'Line State (BOOL step lanes)',
            type: kTrendChartDisplay,
            tagBinding: '',
            gridSpanWidth: 4,
            accentColor: 'green',
            windowMs: 120000,
            trendPens: [
              TrendPenRef(penTagPath: 'Batch_Running'),
              TrendPenRef(penTagPath: 'Alarm_Active'),
            ],
          ),
        ],
      ),
      HmiScreenDef(
        id: 'hmi_flagship_diagnostics',
        title: 'Production Line Diagnostics',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'fd1', title: 'Recipe Name', type: 'TextInputField', tagBinding: 'Recipe_Name', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'fd2', title: 'Batch Target', type: 'TextInputField', tagBinding: 'Batch_Target', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'fd3', title: 'Scan Count', type: 'DigitalGaugeDisplay', tagBinding: 'System.ScanCount', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'fd4', title: 'Scan Time (ms)', type: 'DigitalGaugeDisplay', tagBinding: 'System.ScanTimeMs', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'fd5', title: 'Max Scan (ms)', type: 'DigitalGaugeDisplay', tagBinding: 'System.MaxScanTimeMs', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'fd6', title: 'Uptime (ms)', type: 'DigitalGaugeDisplay', tagBinding: 'System.UptimeMs', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'fd7', title: 'Run Hours', type: 'DigitalGaugeDisplay', tagBinding: 'Run_Hours', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'fd8', title: 'PLC Running', type: 'LedIndicatorLight', tagBinding: 'System.Running', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fd9', title: 'First Scan', type: 'LedIndicatorLight', tagBinding: 'System.FirstScan', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'fd10', title: 'Health OK', type: 'LedIndicatorLight', tagBinding: 'Health_OK', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'fd11', title: 'Guard Locked', type: 'LedIndicatorLight', tagBinding: 'Guard_Locked', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'fd12', title: 'Air Pressure OK', type: 'LedIndicatorLight', tagBinding: 'Air_Pressure_OK', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'fd13', title: 'CONVEYOR 1 JAM', type: 'StatusPillDisplay', tagBinding: 'Conv1_Jam', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'fd14', title: 'CONTROLLER FAULT', type: 'StatusPillDisplay', tagBinding: 'System.Fault', gridSpanWidth: 2, accentColor: 'red'),
        ],
      ),
    ],
  );

  // The reserved System tag must exist BEFORE the maps are generated so its 19
  // leaves land in both maps (marked ReadOnly by the generators' reserved-tag
  // special case) and so the diagnostics dashboard binds in headless tests.
  ensureSystemTag(project);

  // Two-phase: the autoGenerate helpers take the finished project.
  project.protocols = ProtocolSettings(
    gatewayUrl: kDefaultGatewayUrl,
    modbus: ModbusProtocolConfig(
      enabled: true,
      port: 502,
      map: ModbusMap.autoGenerate(project),
      wordSwap: false,
      byteSwap: false,
      unitId: 255,
      framing: 'tcp',
    ),
    opcua: OpcUaProtocolConfig(
      enabled: true,
      port: 4840,
      namespaceUri: 'urn:softplc:${project.id}',
      map: OpcuaMap.autoGenerate(project),
      securityModes: ['None'],
      credentials: [],
      allowAnonymous: true,
    ),
  );

  return project;
}
```

- [ ] **Step 4: Run the new test**

Run: `/c/flutter/bin/flutter test test/defaults/flagship_line_test.dart`
Expected: PASS.

Two failures are plausible and both are **content tuning, never engine edits**:

1. *The PID test does not settle within ±5 %.* The `equalPercentage` valve curve
   makes the loop gain much lower at mid-travel than a linear valve
   (`(50^f - 1)/49`; the inflow/outflow balance sits near 57 % open). Retune by
   running: raise `bl_ki` from `'0.5'` to `'1.0'`, then `bl_kp` from `'2.0'` to
   `'4.0'`, re-running the test after each change. Record the settled
   `Blend_Valve` value in the file's doc comment the way
   `_fbdPidTankLevelProject` documents its own gains.
2. *`Blend_mA` is not exactly 12.0.* Check the `Scale` FB wire order — `InLo`
   and `OutLo` are distinct pins and `fbdInputPinsFor` returns the FB's INPUT
   vars **in declaration order** (`In, InLo, InHi, OutLo, OutHi`), so every pin
   must be wired by name, not by position.

If either symptom turns out to be an engine defect rather than tuning, stop,
record it in `docs/DEFERRED.md` under "Default projects redo (spec 2026-08-06)",
and reshape the showcase around it.

- [ ] **Step 5: Run analyze + full suite**

Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/data/default_projects/flagship_production_line.dart mobile/test/defaults/flagship_line_test.dart
git commit -m "feat(defaults): add Flagship — Production Line showcase project

Four areas / four languages / three task types, both custom-FB body kinds,
seven sim behaviours (incl. the never-shipped setWhileCondition + delayedSet and
an equal-percentage valve curve), the reserved System tag on an HMI, trend charts
with analog + BOOL pens, TextInputField cards, and pre-generated Modbus + OPC UA maps."
```

---

### Task 7: Process Control Lab (`proj_process_lab`)

**Model:** sonnet · **Effort:** medium

**Files:**
- Create: `mobile/lib/data/default_projects/process_control_lab.dart`
- Create: `mobile/test/defaults/process_lab_test.dart`

**Interfaces:**
- Consumes: nothing from `builders.dart` (all four areas are FBD + sim rules).
- Produces: `PlcProject processControlLabProject()` — id `proj_process_lab`,
  name `Process Control Lab`, four `FunctionBlockDiagram` programs in this exact
  order — `LevelPID_FBD`, `TwoZone_FBD`, `CascadeMonitor_FBD`,
  `NoisyLevelMonitor_FBD` — one task `LabTask`, four HMI screens
  `hmi_lab_pid` / `hmi_lab_mimo` / `hmi_lab_cascade` / `hmi_lab_noise`.

**Two ordering constraints that are NOT cosmetic** (both verified against the
live screen code):

1. **`LevelPID_FBD` must be `programs[0]`.** `pid_autotune_screen_test` reads
   `programs.firstWhere((p) => p.language == 'FunctionBlockDiagram')` for its
   `p_kp` / `p_kd` block lookups, and `PidAutoTuneScreen.initState` prefills from
   `_loopOptions().first` — the first `PID` block in the first FBD program. Its
   block ids (`p_sp`, `p_pv`, `p_kp`, `p_ki`, `p_kd`, `p_pid`, `p_cv`) stay
   verbatim so the prefill resolves `Level_PV` / `Valve_CV`.
2. **The MIMO tags must be the first four analog tags declared.**
   `defaultInteractionAnalysisTags` (`interaction_analysis.dart:53`) stably sorts
   the tag list by priority and takes the first four, so `Heater_A`, `Heater_B`,
   `Temp_A`, `Temp_B` must be declared before any other `SimulatedInput` /
   `SimulatedOutput` / `*_PV` / `*_SP` / `*_CV` analog tag for
   `interaction_analysis_screen_test`'s prefill assertions to hold.

**Sim-rule id namespacing:** ids must be unique within a project. The MIMO ids
(`sa0`–`sa2`, `sb0`–`sb2`) are already unique and stay verbatim. The **noise
area keeps its original `sim0`–`sim3`** — `SimRule.noise` seeds its PRNG from
`_fnv1a(rule.id)`, so renaming those would change the noise sequence. The PID
area becomes `pid_sim0`/`pid_sim1` and the cascade area `casc_sim0`–`casc_sim4`
(neither behaviour uses the PRNG). Every *behavioural* field is copied verbatim.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/defaults/process_lab_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects/process_control_lab.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/interaction_analysis.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

double _d(PlcProject p, String path) => (readPath(p, path) as num).toDouble();

void main() {
  test('the four areas are laid out in the order the screens depend on', () {
    final p = processControlLabProject();
    expect(p.programs.map((x) => x.name).toList(), [
      'LevelPID_FBD',
      'TwoZone_FBD',
      'CascadeMonitor_FBD',
      'NoisyLevelMonitor_FBD',
    ]);
    expect(p.hmis.map((h) => h.id).toList(),
        ['hmi_lab_pid', 'hmi_lab_mimo', 'hmi_lab_cascade', 'hmi_lab_noise']);
    expect(p.tasks.length, 1);
    expect(p.tasks.single.programNames, p.programs.map((x) => x.name).toList());

    // The autotune screen resolves its loop from the FIRST PID in the FIRST
    // FBD program; the interaction screen prefills from the first four analog
    // tags in declaration order.
    final firstFbd = p.programs.firstWhere((x) => x.language == 'FunctionBlockDiagram');
    expect(firstFbd.name, 'LevelPID_FBD');
    expect(firstFbd.fbdBlocks.where((b) => b.type == 'PID').map((b) => b.id).toList(), ['p_pid']);
    expect(defaultInteractionAnalysisTags(p.tags),
        ['Heater_A', 'Heater_B', 'Temp_A', 'Temp_B']);
  });

  test('every sim rule id is unique and the noise rules keep their original ids', () {
    final p = processControlLabProject();
    final ids = p.simRules.map((r) => r.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate SimRule ids');
    final noiseRule = p.simRules.firstWhere((r) => r.behavior == 'noise');
    expect(noiseRule.id, 'sim2',
        reason: 'the noise PRNG is seeded from the rule id — renaming changes the sequence');
  });

  test('the PID area reaches and holds its setpoint with a modulating valve', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    final sp = _d(p, 'Level_SP');
    var minCv = double.infinity;
    var maxCv = -double.infinity;
    for (var i = 0; i < 600; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
      final cv = _d(p, 'Valve_CV');
      minCv = cv < minCv ? cv : minCv;
      maxCv = cv > maxCv ? cv : maxCv;
    }
    expect((_d(p, 'Level_PV') - sp).abs(), lessThanOrEqualTo(4.0));
    expect(maxCv - minCv, greaterThan(1.0), reason: 'the valve must modulate, not stick');
  });

  test('the MIMO area is genuinely cross-coupled', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    // Drive zone A only; zone B must warm through the shared wall.
    writePath(p, 'SP_A', 60.0);
    writePath(p, 'SP_B', 20.0);
    final startB = _d(p, 'Temp_B');
    for (var i = 0; i < 400; i++) {
      applySimRules(p, p.simRules, 200, sim);
      executeFbdPrograms(p, 200, fbd);
    }
    expect(_d(p, 'Temp_B'), greaterThan(startB + 1.0),
        reason: 'the A<->B conduction lag must move zone B when only zone A is driven');
  });

  test('the cascade area lags Tank B behind Tank A by the transport delay', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    for (var i = 0; i < 4; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
    }
    expect(_d(p, 'Tank_A_Level'), greaterThan(_d(p, 'Tank_B_Level')),
        reason: 'Tank B has not seen the transport-delayed signal yet');

    for (var i = 0; i < 60; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
    }
    expect(_d(p, 'Tank_B_Level'), greaterThan(11.0),
        reason: 'after the dead time Tank B fills from the transfer line');
  });

  test('the noise area jitters the raw measurement and the filter attenuates it', () {
    final p = processControlLabProject();
    final sim = SimRuntime();
    final fbd = FbdRuntime();
    final measErr = <double>[];
    final filtErr = <double>[];
    for (var i = 0; i < 300; i++) {
      applySimRules(p, p.simRules, 500, sim);
      executeFbdPrograms(p, 500, fbd);
      if (i > 100) {
        final clean = _d(p, 'Tank_Level');
        measErr.add((_d(p, 'Level_Meas') - clean).abs());
        filtErr.add((_d(p, 'Level_Filtered') - clean).abs());
      }
    }
    double mean(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
    expect(mean(measErr), greaterThan(0.0), reason: 'the raw reading must jitter');
    for (final e in measErr) {
      expect(e, lessThanOrEqualTo(2.5 + 1e-9), reason: 'jitter stays inside the noise band');
    }
    expect(mean(filtErr), lessThan(mean(measErr)),
        reason: 'the first-order lag must attenuate the measurement noise');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/defaults/process_lab_test.dart`
Expected: FAIL — the library does not exist.

- [ ] **Step 3: Write the project builder**

Create `mobile/lib/data/default_projects/process_control_lab.dart`. Each area's
plant and control are reproduced **verbatim in tag names, block ids, wiring and
sim-rule behavioural fields** from the retired demo it consolidates — copy them
out of `mobile/lib/data/default_projects/legacy_defaults.dart`:

- `LevelPID_FBD` ← `legacyFbdPidTankLevelProject()`'s program (block ids
  `p_sp`, `p_pv`, `p_kp` `'1.0'`, `p_ki` `'0.2'`, `p_kd` `'0.05'`, `p_pid`,
  `p_cv`; wires unchanged), and its two sim rules re-id'd to `pid_sim0`
  (`integrate`, `ratePerSec: 6.0`, `sourcePath: 'Valve_CV'`, `refValue: 100.0`,
  0–100) and `pid_sim1` (`integrate`, `ratePerSec: -1.0`, 0–100).
- `TwoZone_FBD` ← `legacyMimoTwoZoneProject()`'s program **and its six sim rules
  verbatim, ids included** (`sa0`–`sa2`, `sb0`–`sb2`).
- `CascadeMonitor_FBD` ← `legacyCascadeTanksProject()`'s program (block ids
  `k_in` / `k_out` renamed to `c_in` / `c_out` to avoid colliding with the noise
  area's monitor, which also used `k_in`/`k_out`), and its five sim rules re-id'd
  to `casc_sim0`–`casc_sim4` with every behavioural field verbatim.
- `NoisyLevelMonitor_FBD` ← `legacyNoisyLevelProject()`'s program **network 0
  only** (`k_in` / `k_out` pass-through monitor of `Fill_Valve`). Network 1 (the
  `Hysteresis` FB) does **not** come here — it moved to
  `proj_st_reactor_control` in Task 5, so this project declares **no**
  `fbDefinitions` and no `LevelAlarmHyst` / `Level_Alarm` tags. Its four sim
  rules keep their original ids `sim0`–`sim3` verbatim.

```dart
/// **Process Control Lab** (`proj_process_lab`).
///
/// (a) Story: a control-theory bench with four independent rigs in one project
/// — a single-loop PID level rig, a 2x2 cross-coupled thermal MIMO rig with a
/// static decoupler, a cascade-tank rig with a transport dead time, and a noisy
/// measurement rig with a first-order filter.
///
/// (b) Showcase for: `PID` and autotune-resolvable loops, multivariable
/// interaction analysis (`Heater_A/B` -> `Temp_A/B` with strong off-diagonal
/// gains), the `deadTime` sim behaviour, the `noise` sim behaviour with a
/// `firstOrderLag` filter, and a **multi-screen project** (four dashboards).
/// Each rig's plant and control are reproduced VERBATIM from the demo it
/// consolidates, so the re-pointed engine tests keep their exact meaning.
///
/// (c) Falsifiable: zeroing the PID gains pins `Valve_CV` and `Level_PV` never
/// moves; setting `tauSec: 0` on the transfer line makes `Tank_B_Level` rise in
/// lock-step with `Tank_A_Level`; a zero noise amplitude leaves `Level_Meas`
/// exactly equal to `Tank_Level` with nothing for the filter to smooth.
///
/// (d) Proof test: `test/defaults/process_lab_test.dart` (plus the re-pointed
/// `pid_loop_integration_test`, `pid_autotune_test`, `pid_autotune_screen_test`,
/// `deadtime_cascade_integration_test`, `noise_measurement_integration_test`,
/// `mimo_project_test` and `interaction_analysis_screen_test`).
///
/// ORDER IS LOAD-BEARING — see the two constraints in the plan's Task 7:
/// `LevelPID_FBD` must be `programs[0]`, and `Heater_A`/`Heater_B`/`Temp_A`/
/// `Temp_B` must be the first four analog tags declared.
library;

import '../../models/project_model.dart';

PlcProject processControlLabProject() => PlcProject(
      id: 'proj_process_lab',
      name: 'Process Control Lab',
      controllerName: 'PLC_LAB',
      scanPeriodMs: 500,
      tags: [
        // ── MIMO rig FIRST (interaction-analysis prefill order) ─────────
        PlcTag(name: 'Heater_A', path: 'Outputs/Heater_A', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Zone A heater power command (decoupler output)'),
        PlcTag(name: 'Heater_B', path: 'Outputs/Heater_B', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Zone B heater power command (decoupler output)'),
        PlcTag(name: 'Temp_A', path: 'Inputs/Temp_A', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Zone A temperature process value'),
        PlcTag(name: 'Temp_B', path: 'Inputs/Temp_B', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Zone B temperature process value'),
        PlcTag(name: 'SP_A', path: 'Internal/SP_A', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Zone A temperature setpoint'),
        PlcTag(name: 'SP_B', path: 'Internal/SP_B', dataType: 'FLOAT64', value: 40.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Zone B temperature setpoint'),
        PlcTag(name: 'Amb', path: 'Internal/Amb', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Ambient temperature both zones lose heat toward'),
        PlcTag(name: 'u_A', path: 'Internal/u_A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: '%', description: 'Zone A PID output before the static decoupler'),
        PlcTag(name: 'u_B', path: 'Internal/u_B', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: '%', description: 'Zone B PID output before the static decoupler'),
        // ── PID level rig ───────────────────────────────────────────────
        PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Tank level process value'),
        PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Tank level setpoint'),
        PlcTag(name: 'Valve_CV', path: 'Outputs/Valve_CV', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Inlet valve control variable (PID output)'),
        // ── Cascade rig ─────────────────────────────────────────────────
        PlcTag(name: 'Feed_Valve', path: 'Internal/Feed_Valve', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Manipulated feed valve opening driving inflow into Tank A'),
        PlcTag(name: 'Tank_A_Level', path: 'Inputs/Tank_A_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Upstream tank level'),
        PlcTag(name: 'Transfer_Line', path: 'Internal/Transfer_Line', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal', engineeringUnits: '%', description: 'Transport-delayed signal in the pipe carrying Tank A level to Tank B (deadTime of Tank_A_Level)'),
        PlcTag(name: 'Tank_B_Level', path: 'Inputs/Tank_B_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Downstream tank level, lags Tank A by the transport delay'),
        // ── Noise rig ───────────────────────────────────────────────────
        PlcTag(name: 'Fill_Valve', path: 'Internal/Fill_Valve', dataType: 'FLOAT64', value: 55.0, ioType: 'Internal', engineeringUnits: '%', description: 'Manipulated fill valve opening driving inflow into the tank'),
        PlcTag(name: 'Tank_Level', path: 'Inputs/Tank_Level', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Clean (true) tank level, driven by Fill_Valve minus a constant outflow'),
        PlcTag(name: 'Level_Meas', path: 'Inputs/Level_Meas', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Raw noisy sensor reading of Tank_Level (measurement noise behaviour)'),
        PlcTag(name: 'Level_Filtered', path: 'Inputs/Level_Filtered', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'First-order-lag-filtered reading of Level_Meas'),
      ],
      structDefs: [],
      simRules: [
        // PID level rig (re-id'd; behavioural fields verbatim).
        SimRule(id: 'pid_sim0', name: 'Inflow scaled by valve position', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: 6.0, sourcePath: 'Valve_CV', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'pid_sim1', name: 'Constant outflow disturbance', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100),
        // MIMO rig (ids verbatim — already unique).
        SimRule(id: 'sa0', name: 'Zone A heater', targetPath: 'Temp_A', behavior: 'integrate',
            ratePerSec: 3.0, sourcePath: 'Heater_A', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sa1', name: 'A<->B conduction', targetPath: 'Temp_A', behavior: 'firstOrderLag',
            sourcePath: 'Temp_B', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sa2', name: 'Zone A heat loss', targetPath: 'Temp_A', behavior: 'firstOrderLag',
            sourcePath: 'Amb', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sb0', name: 'Zone B heater', targetPath: 'Temp_B', behavior: 'integrate',
            ratePerSec: 3.0, sourcePath: 'Heater_B', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sb1', name: 'B<->A conduction', targetPath: 'Temp_B', behavior: 'firstOrderLag',
            sourcePath: 'Temp_A', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sb2', name: 'Zone B heat loss', targetPath: 'Temp_B', behavior: 'firstOrderLag',
            sourcePath: 'Amb', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
        // Cascade rig (re-id'd; behavioural fields verbatim).
        SimRule(id: 'casc_sim0', name: 'Tank A inflow scaled by Feed_Valve', targetPath: 'Tank_A_Level',
            behavior: 'integrate', ratePerSec: 4.0, sourcePath: 'Feed_Valve', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim1', name: 'Tank A constant outflow', targetPath: 'Tank_A_Level',
            behavior: 'integrate', ratePerSec: -0.5, minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim2', name: 'Transfer line transport delay', targetPath: 'Transfer_Line',
            behavior: 'deadTime', sourcePath: 'Tank_A_Level', tauSec: 3.0, minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim3', name: 'Tank B inflow scaled by Transfer Line', targetPath: 'Tank_B_Level',
            behavior: 'integrate', ratePerSec: 4.0, sourcePath: 'Transfer_Line', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim4', name: 'Tank B constant outflow', targetPath: 'Tank_B_Level',
            behavior: 'integrate', ratePerSec: -0.5, minValue: 0, maxValue: 100),
        // Noise rig — ids kept VERBATIM: the noise PRNG is seeded from the id.
        SimRule(id: 'sim0', name: 'Tank inflow scaled by Fill_Valve', targetPath: 'Tank_Level',
            behavior: 'integrate', ratePerSec: 3.0, sourcePath: 'Fill_Valve', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'sim1', name: 'Tank constant outflow', targetPath: 'Tank_Level',
            behavior: 'integrate', ratePerSec: -0.4, minValue: 0, maxValue: 100),
        SimRule(id: 'sim2', name: 'Level measurement noise', targetPath: 'Level_Meas',
            behavior: 'noise', sourcePath: 'Tank_Level', targetValue: 2.5,
            minValue: 0, maxValue: 100),
        SimRule(id: 'sim3', name: 'Level measurement filter', targetPath: 'Level_Filtered',
            behavior: 'firstOrderLag', sourcePath: 'Level_Meas', tauSec: 1.5,
            minValue: 0, maxValue: 100),
      ],
      programs: [
        // ── 1. LevelPID_FBD — MUST stay first (autotune prefill) ────────
        //     Copy the program body verbatim from legacyFbdPidTankLevelProject().
        // ── 2. TwoZone_FBD — copy verbatim from legacyMimoTwoZoneProject().
        // ── 3. CascadeMonitor_FBD — copy from legacyCascadeTanksProject(),
        //     renaming block ids k_in/k_out -> c_in/c_out.
        // ── 4. NoisyLevelMonitor_FBD — copy NETWORK 0 ONLY from
        //     legacyNoisyLevelProject(); the Hysteresis network moved to
        //     proj_st_reactor_control.
      ],
      tasks: [
        PlcTask(name: 'LabTask', type: 'Continuous', periodMs: 500, programNames: [
          'LevelPID_FBD',
          'TwoZone_FBD',
          'CascadeMonitor_FBD',
          'NoisyLevelMonitor_FBD',
        ]),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_lab_pid',
          title: 'Lab — Tank Level PID',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'lp1', title: 'Tank Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 4, accentColor: 'cyan'),
            HmiComponent(id: 'lp2', title: 'Level Setpoint', type: 'NumericSliderInput', tagBinding: 'Level_SP', gridSpanWidth: 4, accentColor: 'teal'),
            HmiComponent(id: 'lp3', title: 'Valve CV (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Valve_CV', gridSpanWidth: 4, accentColor: 'amber'),
          ],
        ),
        HmiScreenDef(
          id: 'hmi_lab_mimo',
          title: 'Lab — Two Thermal Zones (MIMO)',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'lm1', title: 'Zone A Setpoint', type: 'NumericSliderInput', tagBinding: 'SP_A', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 'lm2', title: 'Zone B Setpoint', type: 'NumericSliderInput', tagBinding: 'SP_B', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 'lm3', title: 'Zone A Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_A', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'lm4', title: 'Zone B Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_B', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'lm5', title: 'Heater A (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Heater_A', gridSpanWidth: 2, accentColor: 'amber'),
            HmiComponent(id: 'lm6', title: 'Heater B (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Heater_B', gridSpanWidth: 2, accentColor: 'amber'),
            HmiComponent(id: 'lm7', title: 'PID A Out u_A (%)', type: 'DigitalGaugeDisplay', tagBinding: 'u_A', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 'lm8', title: 'PID B Out u_B (%)', type: 'DigitalGaugeDisplay', tagBinding: 'u_B', gridSpanWidth: 2, accentColor: 'teal'),
          ],
        ),
        HmiScreenDef(
          id: 'hmi_lab_cascade',
          title: 'Lab — Cascade Tanks (Transport Delay)',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'lc1', title: 'Feed Valve (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Feed_Valve', gridSpanWidth: 4, accentColor: 'amber'),
            HmiComponent(id: 'lc2', title: 'Tank A Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Tank_A_Level', gridSpanWidth: 4, accentColor: 'cyan'),
            HmiComponent(id: 'lc3', title: 'Transfer Line (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Transfer_Line', gridSpanWidth: 4, accentColor: 'teal'),
            HmiComponent(id: 'lc4', title: 'Tank B Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Tank_B_Level', gridSpanWidth: 4, accentColor: 'teal'),
          ],
        ),
        HmiScreenDef(
          id: 'hmi_lab_noise',
          title: 'Lab — Noisy Measurement + Filter',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'ln1', title: 'Tank Level (%) — Clean', type: 'TankGraphicDisplay', tagBinding: 'Tank_Level', gridSpanWidth: 4, accentColor: 'cyan'),
            HmiComponent(id: 'ln2', title: 'Level Measured (%) — Noisy', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Meas', gridSpanWidth: 4, accentColor: 'amber'),
            HmiComponent(id: 'ln3', title: 'Level Filtered (%) — Smoothed', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Filtered', gridSpanWidth: 4, accentColor: 'teal'),
            HmiComponent(id: 'ln4', title: 'Fill Valve (%)', type: 'NumericSliderInput', tagBinding: 'Fill_Valve', gridSpanWidth: 4, accentColor: 'green'),
          ],
        ),
      ],
    );
```

- [ ] **Step 4: Fill in the four programs**

Open `mobile/lib/data/default_projects/legacy_defaults.dart` and copy the four
`PlcProgram(...)` literals into the `programs: [...]` list above, in the stated
order, applying only these edits:

1. `CascadeMonitor_FBD`: block ids `k_in` → `c_in`, `k_out` → `c_out` (and the
   one wire between them). Every other field verbatim.
2. `NoisyLevelMonitor_FBD`: keep **only** the two network-0 blocks (`k_in`,
   `k_out`) and the single wire between them; drop the `h_*` blocks/wires
   (`Hysteresis`) and shorten the program description to
   `'Pass-through monitor of Fill_Valve; the noisy-measurement rig itself is entirely sim-driven'`.
3. `LevelPID_FBD` and `TwoZone_FBD`: verbatim, block ids untouched.

- [ ] **Step 5: Run the new test**

Run: `/c/flutter/bin/flutter test test/defaults/process_lab_test.dart`
Expected: PASS.
If `defaultInteractionAnalysisTags` does not return
`['Heater_A','Heater_B','Temp_A','Temp_B']`, an analog `SimulatedInput`/
`SimulatedOutput`/`*_PV`/`*_SP`/`*_CV` tag was declared before them — move the
MIMO block back to the top of the tag list.

- [ ] **Step 6: Run analyze + full suite**

Run: `/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/data/default_projects/process_control_lab.dart mobile/test/defaults/process_lab_test.dart
git commit -m "feat(defaults): add Process Control Lab showcase project

Consolidates the retired PID tank, MIMO two-zone, cascade dead-time and noisy
measurement demos into one four-program, four-dashboard project, reproducing each
rig's plant and control verbatim so the re-pointed engine tests keep their meaning."
```

---

### Task 8: Catalog switchover, dependent-test re-points, guard tests and docs

**Model:** opus · **Effort:** high

This is the single atomic flip. Until now `DefaultProjects.all()` still returned
the old 14 and every existing test passed untouched. This task rewrites `all()`,
deletes the transit file, re-points every dependent test, adds the two mechanical
guard tests plus the protocol-autostart gate, and writes the docs.

**Files:**
- Modify: `mobile/lib/data/default_projects.dart`
- Delete: `mobile/lib/data/default_projects/legacy_defaults.dart`
- Create: `mobile/test/defaults/default_projects_coverage_test.dart`
- Create: `mobile/test/defaults/default_projects_integrity_test.dart`
- Create: `mobile/test/defaults/flagship_gateway_no_autostart_test.dart`
- Create: `docs/default-projects.md`
- Modify: `docs/DEFERRED.md`, `CLAUDE.md`
- Modify (re-points, 29 files): `mobile/test/ld_exec_integration_test.dart`,
  `fbd_exec_integration_test.dart`, `st_exec_integration_test.dart`,
  `sfc_exec_integration_test.dart`, `sfc_batchmix_showcase_test.dart`,
  `pid_loop_integration_test.dart`, `pid_autotune_test.dart`,
  `pid_autotune_screen_test.dart`, `deadtime_cascade_integration_test.dart`,
  `noise_measurement_integration_test.dart`, `hysteresis_fb_demo_test.dart`,
  `mimo_project_test.dart`, `interaction_analysis_screen_test.dart`,
  `memory_responsive_test.dart`, `sfc_view_no_mutation_test.dart`,
  `ld_branch_render_test.dart`, `ld_symbol_alignment_test.dart`,
  `widget_test.dart`, `ld_editor_responsive_test.dart`,
  `editors_responsive_test.dart`, `hmi_dashboard_builder_test.dart`,
  `simulated_io_screen_test.dart`, `drawer_icon_distinction_test.dart`,
  `project_transfer_test.dart`, `scan_count_continuity_test.dart`,
  `workspace_undo_redo_test.dart`, `delete_confirmation_policy_test.dart`,
  `app_responsive_smoke_test.dart`, `project_dropdown_polish_test.dart`
- Verify-only (no edit expected): `forms_responsive_test.dart`,
  `st_editor_quick_insert_scroll_test.dart`, `project_repository_test.dart`,
  `persistence_integration_test.dart`, `serialization_roundtrip_test.dart`,
  `ld_no_persist_test.dart`, `import/import_xml_flow_test.dart`,
  `widgets/task_management_test.dart`

**Interfaces:**
- Consumes: every `…Project()` builder produced by Tasks 1–7.
- Produces: `DefaultProjects.all()` returning exactly seven projects, in the
  order `[conveyor, hvac, sfc, st, water, flagship, lab]`.

- [ ] **Step 1: Flip the barrel**

Replace `mobile/lib/data/default_projects.dart` with:

```dart
// Barrel over `default_projects/` — one file per built-in project. This file's
// PATH and the `DefaultProjects.all()` signature are load-bearing: ~35 test
// files import `package:soft_plc_mobile/data/default_projects.dart`.
//
// ORDER IS LOAD-BEARING:
//  - all()[0] is the boot-active project (`workspace_shell.dart` activates
//    `catalog.first`). It must be a LadderLogic project whose FIRST tag is
//    `Start_PB` (persistence_integration_test.dart L96/L210).
//  - all().last is used by project_repository_test.dart:150 and
//    persistence_integration_test.dart:226 as "a default the catalog is
//    missing"; any project works, this just fixes which one.
library;

import '../models/project_model.dart';
import 'default_projects/all_water_treatment.dart';
import 'default_projects/fbd_hvac_zone.dart';
import 'default_projects/flagship_production_line.dart';
import 'default_projects/ladder_conveyor_line.dart';
import 'default_projects/process_control_lab.dart';
import 'default_projects/sfc_batch_production.dart';
import 'default_projects/st_reactor_control.dart';

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

Then delete the transit file:

```bash
git rm mobile/lib/data/default_projects/legacy_defaults.dart
```

- [ ] **Step 2: Run analyze to find every broken reference**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!` for `lib/`. (The two test fixtures in
`test/support/legacy_demo_projects.dart` are self-contained copies, so nothing
in `test/` references the deleted file.)

- [ ] **Step 3: Re-point the engine integration tests**

`mobile/test/ld_exec_integration_test.dart` — three id literals and the tag
names in the first two cases:

```dart
// Test 1 (was 'motor project'): rename to 'conveyor line' and re-point.
final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_ld_conveyor_line');
// Motor_Latch -> Line_Latch, Motor_Run -> Zone1_Motor throughout this test.
// Add, right after the firstWhere, so the photo-eye pulse cannot interfere:
for (final r in p.simRules) {
  r.enabled = false;
}
```

```dart
// Tests 2 and 3 (the conveyor cases): id 'proj_ld_conveyor' ->
// 'proj_ld_conveyor_line'; Belt_Motor -> Zone1_Motor; Belt_Jammed and
// JamTimer keep their names. Assertions and scan counts are UNCHANGED —
// the new rung 13 TON has the same 5000 ms preset and the same
// (Zone1_Motor AND NOT Part_Present) enable, and the new rung 1 carries the
// same jam interlock.
```

Leave the fourth (water) case exactly as it is.

`mobile/test/fbd_exec_integration_test.dart` — two id literals:

```dart
// 'HVAC diagram reproduces the hardcoded heat/cool/enable truth table'
final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_fbd_hvac_zone');
```

```dart
// 'tank TankLevel_FBD reproduces the retired hardcoded fill/drain/alarm'
final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_fbd_hvac_zone');
// Rename the test to '... absorbed into HVAC network 5 ...'. Tag names and
// every assertion are unchanged (Level_PV/Level_SP/Auto_Mode/Fill_Valve/
// Drain_Valve/High_Alarm carried over verbatim).
```

Leave both water cases as they are.

`mobile/test/st_exec_integration_test.dart` — two id literals:

```dart
final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_st_reactor_control');
```

In the closed-loop case, update the stale comment "proj_st_reactor has no
LD/FBD/SFC programs" to "proj_st_reactor_control's only other program is the
FBD alarm latch, which this ST-only harness deliberately does not run".

`mobile/test/sfc_exec_integration_test.dart` — the filler case:

```dart
final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_sfc_batch_production');
// Bottle_Present -> Container_Present.
// The merged cycle now also runs the batch fork/join before returning to IDLE,
// so raise the scan budget from 80 to 160 (still 500 ms/scan). Sfc_Step == 5
// is still the COUNT step and Filled_Count still increments exactly there.
for (int i = 0; i < 160 && counted < 2; i++) {
```

Update the reason string to `'two containers should complete within 80s sim time'`.

`mobile/test/sfc_batchmix_showcase_test.dart`:

```dart
PlcProject _batchMix() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_sfc_batch_production');
```
```dart
expect(p.name, 'SFC — Batch Production');
```
Add `setTag('Container_Present', true);` next to each existing
`setTag('Start_Cmd', true);` (the merged chart gates on the container sensor
before the fill segment). Raise **both** `for (var i = 0; i < 120; i++)` loop
bounds — in the fork/join test and in the REJECT-arm test — to
`for (var i = 0; i < 200; i++)`: the merged cycle needs ~95 scans at 200 ms,
and 200 gives it the same ~2x headroom the sibling one-shot test already has via
its `guard < 500`. The region-count assertions (1 parallel with 2 branches,
1 alternative with 2 arms) are **unchanged** — the merged chart has exactly one
of each.

`mobile/test/pid_loop_integration_test.dart`, `pid_autotune_test.dart`,
`deadtime_cascade_integration_test.dart`, `noise_measurement_integration_test.dart`,
`mimo_project_test.dart`, `interaction_analysis_screen_test.dart`,
`pid_autotune_screen_test.dart` — replace each id literal
(`proj_tank_level_pid`, `proj_cascade_tanks`, `proj_noisy_level`,
`proj_mimo_two_zone`) with `proj_process_lab`. No other change: every plant,
gain, block id and tag name was carried over verbatim in Task 7.

`mobile/test/hysteresis_fb_demo_test.dart` — the id, the program name, the
network index and three tag names:

```dart
/// The "ST — Reactor Temperature Controller" default project — chosen host for
/// the shipped custom-function-block demo (see
/// `default_projects/st_reactor_control.dart`).
PlcProject _proj() =>
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_st_reactor_control');
```
```dart
final tag = p.tags.firstWhere((t) => t.name == 'TempAlarmHyst');
```
```dart
final prog = p.programs.firstWhere((pr) => pr.name == 'ReactorAlarm_FBD');
final hystBlock = prog.fbdBlocks.firstWhere((b) => b.type == 'Hysteresis');
expect(hystBlock.tagBinding, 'TempAlarmHyst');
expect(hystBlock.network, 0,
    reason: 'ReactorAlarm_FBD is a single-network program dedicated to the FB call');
```
```dart
expect(outBlock.tagBinding, 'Alarm_Latched');
```
```dart
void runWith(double temp) {
  writePath(p, 'Temp_PV', temp);
  executeFbdPrograms(p, dtMs, rt, only: {'ReactorAlarm_FBD'});
}
```
and `readPath(p, 'Level_Alarm')` → `readPath(p, 'Alarm_Latched')` in **all six**
run assertions of the final test — one per `runWith(...)` call in the
20 / 65 / 50 / 45 / 35 / 50 sequence. Grep the file for `Level_Alarm` afterwards
and confirm zero hits. **The numeric sequence itself is unchanged** — the FBD
`CONST` thresholds are 60.0/40.0, matching the FB's declared initials.

- [ ] **Step 4: Run the re-pointed engine tests**

```bash
/c/flutter/bin/flutter test test/ld_exec_integration_test.dart test/fbd_exec_integration_test.dart \
  test/st_exec_integration_test.dart test/sfc_exec_integration_test.dart \
  test/sfc_batchmix_showcase_test.dart test/pid_loop_integration_test.dart \
  test/pid_autotune_test.dart test/deadtime_cascade_integration_test.dart \
  test/noise_measurement_integration_test.dart test/hysteresis_fb_demo_test.dart \
  test/mimo_project_test.dart
```
Expected: all pass.

- [ ] **Step 5: Re-point the screen and shell tests**

`mobile/test/sfc_view_no_mutation_test.dart` — the second test selects by
program name:

```dart
  test('the HVAC demo no longer ships an empty SFC assigned to the running task', () {
    final hvac = DefaultProjects.all().firstWhere(
        (p) => p.programs.any((prog) => prog.name == 'HvacZone_FBD'));

    expect(
        hvac.programs.any((p) => p.language == 'SequentialFunctionChart'), isFalse);

    final task = hvac.tasks.firstWhere((t) => t.name == 'HvacControlTask');
    expect(task.programNames, ['HvacZone_FBD']);
  });
```

`mobile/test/ld_branch_render_test.dart` and `ld_symbol_alignment_test.dart` —
replace the fragile name match with the id:

```dart
final PlcProject proj =
    DefaultProjects.all().firstWhere((p) => p.id == 'proj_ld_conveyor_line');
```

`mobile/test/widget_test.dart`, `ld_editor_responsive_test.dart`,
`editors_responsive_test.dart`, `hmi_dashboard_builder_test.dart`,
`simulated_io_screen_test.dart`, `drawer_icon_distinction_test.dart` — replace
the id literals:

| old id | new id |
|---|---|
| `proj_ld_conveyor` | `proj_ld_conveyor_line` |
| `proj_fbd_hvac` | `proj_fbd_hvac_zone` |
| `proj_sfc_filling` | `proj_sfc_batch_production` |
| `proj_st_reactor` | `proj_st_reactor_control` |

In `drawer_icon_distinction_test.dart` the view-id literal
`PROGRAM:ReactorTemp_ST` is **unchanged** (the program name was kept).
In `simulated_io_screen_test.dart` all 15 call sites change id only — the three
sim rules and their field values were carried over verbatim.

`mobile/test/memory_responsive_test.dart` — the two MIMO cases:

```dart
final mimo = DefaultProjects.all().firstWhere((p) => p.id == 'proj_process_lab');
```
(`edit_tag_Heater_A` still resolves — `Heater_A` is the lab's first tag.)

`mobile/test/app_responsive_smoke_test.dart` — the five `firstWhere` ids:

```dart
        // proj_ld_conveyor_line: dedicated LadderLogic project.
        final ldProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_ld_conveyor_line');
        ...
        // proj_fbd_hvac_zone: dedicated FunctionBlockDiagram project.
        final fbdProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_fbd_hvac_zone');
        ...
        // proj_sfc_batch_production: dedicated SequentialFunctionChart project.
        final sfcProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_sfc_batch_production');
        ...
        // proj_st_reactor_control: dedicated StructuredText project.
        final stProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_st_reactor_control');
```
(`proj_all_water` is unchanged. Every project-name dropdown string in this file
is already read from `project.name`, so no name literal needs editing.)

`mobile/test/project_dropdown_polish_test.dart` — the tooltip literal is the
boot project's name (this file is **not** in the spec's §6 table; it was found
by grepping the suite):

```dart
    expect(find.byTooltip('Ladder — Conveyor Line'), findsWidgets);
```

`mobile/test/project_transfer_test.dart` — the `proj_motor` literal is a
synthetic id in a collision test, not a real default. Rename it so it stops
implying a shipped project:

```dart
      final p = makeProject('proj_demo');
      final result = ProjectTransfer.reassignIdIfColliding(p, {'proj_demo'});
      expect(result.id, isNot('proj_demo'));
      expect(result.id, 'proj_demo_import');
```
```dart
      final p = makeProject('proj_demo');
      final result = ProjectTransfer.reassignIdIfColliding(
        p,
        {'proj_demo', 'proj_demo_import'},
      );
      expect(result.id, 'proj_demo_import_2');
```

- [ ] **Step 6: Replace the hardcoded "N Tags, M Structs" labels with computed ones**

These three shell tests hardcode the boot project's tag/struct counts. Rather
than swap one brittle literal for another, compute the label from the catalog —
the shell renders `'Tags & Structs (${tags.length} Tags, ${structDefs.length} Structs)'`
and `workspace_shell.dart` injects the reserved `System` tag at load, so the
rendered count is **declared tags + 1**.

`mobile/test/scan_count_continuity_test.dart`:

```dart
// Boot-active project (all()[0] = 'Ladder — Conveyor Line'). The shell injects
// the reserved System tag at load, so the rendered count is tags.length + 1.
String _tagsLabel({int extra = 0}) {
  final p = DefaultProjects.all().first;
  return 'Tags & Structs (${p.tags.length + 1 + extra} Tags, ${p.structDefs.length} Structs)';
}

final String _baseLabel = _tagsLabel();
final String _plusOneLabel = _tagsLabel(extra: 1);
```
(add `import 'package:soft_plc_mobile/data/default_projects.dart';` if absent,
and change the two `const String` declarations to `final String`).

At line 242 the dropdown tap names the second project:

```dart
    await tester.tap(find.text(DefaultProjects.all()[1].name).last);
```

`mobile/test/workspace_undo_redo_test.dart` — same helper, plus the second
project's own label and the two id literals (add
`import 'package:soft_plc_mobile/data/default_projects.dart';` and
`import 'package:soft_plc_mobile/models/project_model.dart';` if absent, and
change the three `const String` label declarations to `final String`):

```dart
String _tagsLabel(PlcProject p, {int extra = 0}) =>
    'Tags & Structs (${p.tags.length + 1 + extra} Tags, ${p.structDefs.length} Structs)';

final PlcProject _boot = DefaultProjects.all()[0];   // Ladder — Conveyor Line
final PlcProject _second = DefaultProjects.all()[1]; // FBD — HVAC Zone Controller

final String _baseLabel = _tagsLabel(_boot);
final String _plusOneLabel = _tagsLabel(_boot, extra: 1);
final String _plusTwoLabel = _tagsLabel(_boot, extra: 2);
```
```dart
    final tankBase = _tagsLabel(_second);
    final tankPlusOne = _tagsLabel(_second, extra: 1);
```
```dart
    await tester.tap(find.text(_second.name).last);   // was 'Tank Level Simulation'
```
```dart
      final st = state.debugAllProjects.firstWhere((p) => p.id == 'proj_st_reactor_control');
```
```dart
      final otherProject = state.debugAllProjects.firstWhere((p) => p.id == 'proj_fbd_hvac_zone');
```
(the old `proj_motor` reference just needs to be *some other* project than the
boot one; the HVAC controller is `all()[1]`.) Rename the local `tankBase`/
`tankPlusOne` variables to `secondBase`/`secondPlusOne` and update the two
comments that name "Tank Level Simulation" / "Basic Motor Start Stop".

`mobile/test/delete_confirmation_policy_test.dart`:

```dart
final String _baseLabel = () {
  final p = DefaultProjects.all().first;
  return 'Tags & Structs (${p.tags.length + 1} Tags, ${p.structDefs.length} Structs)';
}();
```
(this file already asserts `Start_PB` exists on the boot project — that still
holds, `Start_PB` is the conveyor's first tag.)

- [ ] **Step 7: Run the re-pointed screen/shell tests**

```bash
/c/flutter/bin/flutter test test/sfc_view_no_mutation_test.dart test/ld_branch_render_test.dart \
  test/ld_symbol_alignment_test.dart test/widget_test.dart test/ld_editor_responsive_test.dart \
  test/editors_responsive_test.dart test/hmi_dashboard_builder_test.dart \
  test/simulated_io_screen_test.dart test/drawer_icon_distinction_test.dart \
  test/memory_responsive_test.dart test/app_responsive_smoke_test.dart \
  test/project_dropdown_polish_test.dart test/project_transfer_test.dart \
  test/scan_count_continuity_test.dart test/workspace_undo_redo_test.dart \
  test/delete_confirmation_policy_test.dart test/pid_autotune_screen_test.dart \
  test/interaction_analysis_screen_test.dart
```
Expected: all pass.

If `pid_autotune_screen_test` or `interaction_analysis_screen_test` still
prefills the wrong loop, apply the spec's §7 fallback rather than reordering the
lab further: re-point just those two files at
`legacyTankLevelPidProject()` / `legacyMimoTwoZoneProject()` fixtures added to
`mobile/test/support/legacy_demo_projects.dart` (copy the builders out of this
task's deleted `legacy_defaults.dart` via `git show HEAD~1:…`), and add a
deferred row: "PID autotune / interaction-analysis prefill with multiple loops
in one project".

- [ ] **Step 8: Verify the eight "no edit expected" files**

```bash
/c/flutter/bin/flutter test test/forms_responsive_test.dart \
  test/st_editor_quick_insert_scroll_test.dart test/project_repository_test.dart \
  test/persistence_integration_test.dart test/serialization_roundtrip_test.dart \
  test/ld_no_persist_test.dart test/import/import_xml_flow_test.dart \
  test/widgets/task_management_test.dart
```
Expected: all pass with no source edits.

Notes on why each holds:
- `forms_responsive_test` / `st_editor_quick_insert_scroll_test` use
  `all().first`. The ST editor's QUICK INSERT row is built from
  `currentProject.tags` (`st_editor_screen.dart:360`) and renders
  unconditionally — it does **not** require an ST program — so the LD-only boot
  project is fine.
- `project_repository_test` / `persistence_integration_test` assert against
  `DefaultProjects.all().length` (self-adjusting), `all().last`, `catalog[1]`
  and the boot project's first tag `Start_PB` (guaranteed by §3 ordering).
- `serialization_roundtrip_test` / `ld_no_persist_test` loop over `all()`.
- `import_xml_flow_test` / `task_management_test` use relative deltas and
  `debugActiveProject` without naming an id.

If any of them fails, fix it here — do not defer it.

- [ ] **Step 9: Write the feature-coverage guard test**

Create `mobile/test/defaults/default_projects_coverage_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

/// Mechanical enforcement of the spec's §5 coverage matrix: the shipped
/// defaults must, between them, exercise every feature listed here. A cell may
/// never go from covered to uncovered without a conscious edit to this file.
void main() {
  final projects = DefaultProjects.all();

  /// LD blockTypes the defaults deliberately do NOT showcase (documented as a
  /// deferred row in docs/DEFERRED.md). Adding a default that uses one of these
  /// is fine — removing an entry from here is the conscious edit.
  const knownUncoveredLdBlockTypes = {'GE', 'LE', 'NE', 'MUL', 'DIV', 'TP', 'CTD', 'CTUD'};
  const knownUncoveredTaskTypes = {'Event'};

  test('every built-in FBD block type appears in some default project', () {
    final seen = <String>{
      for (final p in projects)
        for (final prog in p.programs)
          for (final b in prog.fbdBlocks) b.type,
    };
    for (final type in kFbdBuiltinBlockTypes) {
      expect(seen, contains(type), reason: 'FBD block $type is not showcased anywhere');
    }
  });

  test('LD contact and coil modifiers, and the claimed LD block set, all appear', () {
    final contactMods = <String>{};
    final coilMods = <String>{};
    final blockTypes = <String>{};
    void visit(LdRung r) {
      for (final n in r.nodes) {
        switch (n.kind) {
          case LdKind.contact:
            contactMods.add(n.modifier);
            break;
          case LdKind.coil:
            coilMods.add(n.modifier);
            break;
          case LdKind.block:
            blockTypes.add(n.blockType);
            break;
          default:
            break;
        }
      }
    }

    for (final p in projects) {
      for (final prog in p.programs) {
        prog.rungs.forEach(visit);
      }
      for (final fb in p.fbDefinitions) {
        fb.ladderRungs.forEach(visit);
      }
    }

    expect(contactMods, containsAll({'normal', 'negated', 'rising', 'falling'}));
    expect(coilMods,
        containsAll({'normal', 'negated', 'set', 'reset', 'rising', 'falling'}));
    expect(blockTypes,
        containsAll({'TON', 'TOF', 'CTU', 'GT', 'LT', 'EQ', 'ADD', 'SUB', 'MOVE'}));
    expect(blockTypes.intersection(knownUncoveredLdBlockTypes), isEmpty,
        reason: 'a default now uses a previously-uncovered LD block — remove it from '
            'knownUncoveredLdBlockTypes and strike its deferred row');
  });

  test('all eight sim behaviours appear', () {
    final seen = <String>{
      for (final p in projects)
        for (final r in p.simRules) r.behavior,
    };
    expect(seen, containsAll({
      'setWhileCondition', 'delayedSet', 'pulse', 'ramp', 'integrate',
      'firstOrderLag', 'deadTime', 'noise',
    }));
  });

  test('a non-linear valve curve and a gaussian noise distribution appear', () {
    final rules = [for (final p in projects) ...p.simRules];
    expect(rules.any((r) => r.valveCurve != 'linear'), isTrue);
    expect(rules.any((r) => r.noiseDistribution == 'gaussian' && r.driftAmplitude > 0), isTrue);
  });

  test('all nine HMI component types appear, and some component carries pens', () {
    final seen = <String>{
      for (final p in projects)
        for (final h in p.hmis)
          for (final c in h.components) c.type,
    };
    expect(seen, containsAll({
      'PushbuttonSwitch', 'ToggleSwitch', 'NumericSliderInput', 'TextInputField',
      'LedIndicatorLight', 'DigitalGaugeDisplay', 'StatusPillDisplay',
      'TankGraphicDisplay', kTrendChartDisplay,
    }));
    final withPens = [
      for (final p in projects)
        for (final h in p.hmis)
          for (final c in h.components)
            if (c.trendPens.isNotEmpty) c,
    ];
    expect(withPens, isNotEmpty);
    expect(projects.any((p) => p.trends.isNotEmpty), isTrue);
  });

  test('both FbDefinition body kinds are shipped', () {
    final fbs = [for (final p in projects) ...p.fbDefinitions];
    expect(fbs.any((f) => f.stSource.isNotEmpty && f.ladderRungs.isEmpty), isTrue,
        reason: 'no ST-bodied FB');
    expect(fbs.any((f) => f.ladderRungs.isNotEmpty), isTrue, reason: 'no ladder-bodied FB');
  });

  test('SFC fork, join, alternative divergence and a STEP_T dwell all appear', () {
    final transitions = [
      for (final p in projects)
        for (final prog in p.programs) ...prog.sfcTransitions,
    ];
    expect(transitions.any((t) => t.kind == 'parallelFork'), isTrue);
    expect(transitions.any((t) => t.kind == 'parallelJoin'), isTrue);
    expect(transitions.any((t) => t.conditionSt.contains('STEP_T')), isTrue);

    var sawAlternative = false;
    for (final p in projects) {
      for (final prog in p.programs) {
        final byFrom = <String, int>{};
        for (final t in prog.sfcTransitions) {
          if (t.kind == 'single' && t.fromStepId.isNotEmpty) {
            byFrom[t.fromStepId] = (byFrom[t.fromStepId] ?? 0) + 1;
          }
        }
        if (byFrom.values.any((n) => n >= 2)) {
          sawAlternative = true;
        }
      }
    }
    expect(sawAlternative, isTrue, reason: 'no alternative divergence anywhere');
  });

  test('the three covered task types appear and Event stays documented-uncovered', () {
    final seen = <String>{
      for (final p in projects)
        for (final t in p.tasks) t.type,
    };
    expect(seen, containsAll({'Startup', 'Continuous', 'Periodic'}));
    expect(seen.intersection(knownUncoveredTaskTypes), isEmpty,
        reason: 'a default now uses an Event task — remove it from '
            'knownUncoveredTaskTypes and strike its deferred row');
  });

  test('some default ships pre-configured Modbus + OPC UA maps', () {
    final configured = projects.where((p) =>
        p.protocols?.modbus != null &&
        p.protocols?.opcua != null &&
        p.protocols!.modbus!.map.entries.isNotEmpty &&
        p.protocols!.opcua!.map.nodes.isNotEmpty);
    expect(configured, isNotEmpty);
  });

  test('some HMI component binds a reserved System.* member', () {
    final bound = [
      for (final p in projects)
        for (final h in p.hmis)
          for (final c in h.components)
            if (c.tagBinding.startsWith('System.')) c.tagBinding,
    ];
    expect(bound, isNotEmpty);
  });

  test('array tags, DUTs and TIMER composites all appear', () {
    final tags = [for (final p in projects) ...p.tags];
    expect(tags.any((t) => t.arrayLength > 0), isTrue);
    expect(projects.any((p) => p.structDefs.isNotEmpty), isTrue);
    expect(tags.any((t) => t.dataType == 'TIMER'), isTrue);
  });
}
```

- [ ] **Step 10: Write the integrity guard test**

Create `mobile/test/defaults/default_projects_integrity_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

/// The spec's §7 invariants. A default project that violates one of these does
/// not throw at runtime — the engine silently reads null/0/false — so these are
/// the only thing standing between a typo and a dead demo.
void main() {
  final projects = DefaultProjects.all();

  /// True if [ref] is a real tag path in [p], a numeric/boolean literal, or a
  /// reserved System member.
  bool resolves(PlcProject p, String ref) {
    if (ref.isEmpty) return true;
    if (ref == 'true' || ref == 'false' || ref == 'TRUE' || ref == 'FALSE') return true;
    if (num.tryParse(ref) != null) return true;
    if (ref.startsWith('System.')) return true;
    final root = ref.split('.').first.split('[').first;
    return p.tags.any((t) => t.name == root);
  }

  test('project ids and names are unique across the catalog', () {
    final ids = projects.map((p) => p.id).toList();
    final names = projects.map((p) => p.name).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate project id');
    expect(names.toSet().length, names.length,
        reason: 'duplicate project NAME — the dropdown switches by name');
  });

  test('the catalog order the shell and the repository depend on holds', () {
    expect(projects.length, 7);
    expect(projects.first.id, 'proj_ld_conveyor_line');
    expect(projects.first.programs.first.language, 'LadderLogic');
    expect(projects.first.tags.first.name, 'Start_PB');
    expect(projects.last.id, 'proj_process_lab');
  });

  for (final p in projects) {
    group(p.id, () {
      test('ids are unique within the project', () {
        final tagNames = p.tags.map((t) => t.name).toList();
        expect(tagNames.toSet().length, tagNames.length, reason: 'duplicate tag name');
        final simIds = p.simRules.map((r) => r.id).toList();
        expect(simIds.toSet().length, simIds.length, reason: 'duplicate SimRule id');
        final taskNames = p.tasks.map((t) => t.name).toList();
        expect(taskNames.toSet().length, taskNames.length, reason: 'duplicate task name');
        final progNames = p.programs.map((x) => x.name).toList();
        expect(progNames.toSet().length, progNames.length, reason: 'duplicate program name');
        for (final prog in p.programs) {
          final blockIds = prog.fbdBlocks.map((b) => b.id).toList();
          expect(blockIds.toSet().length, blockIds.length,
              reason: 'duplicate FbdBlock id in ${prog.name}');
          final stepIds = prog.sfcSteps.map((s) => s.id).toList();
          expect(stepIds.toSet().length, stepIds.length,
              reason: 'duplicate SfcStep id in ${prog.name}');
          final transIds = prog.sfcTransitions.map((t) => t.id).toList();
          expect(transIds.toSet().length, transIds.length,
              reason: 'duplicate SfcTransition id in ${prog.name}');
        }
        final componentIds = [
          for (final h in p.hmis)
            for (final c in h.components) '${h.id}/${c.id}',
        ];
        expect(componentIds.toSet().length, componentIds.length,
            reason: 'duplicate HmiComponent id within a screen');
        final screenIds = p.hmis.map((h) => h.id).toList();
        expect(screenIds.toSet().length, screenIds.length, reason: 'duplicate HMI screen id');
      });

      test('every program is referenced by at least one enabled task', () {
        final referenced = <String>{
          for (final t in p.tasks)
            if (t.enabled) ...t.programNames,
        };
        for (final prog in p.programs) {
          expect(referenced, contains(prog.name), reason: '${prog.name} has no task');
        }
        for (final t in p.tasks) {
          for (final name in t.programNames) {
            expect(p.programs.any((x) => x.name == name), isTrue,
                reason: 'task ${t.name} names a missing program $name');
          }
        }
      });

      test('no FbDefinition name shadows a built-in block type', () {
        final reserved = {...kFbdBuiltinBlockTypes, ...kLdBuiltinBlockTypes};
        for (final fb in p.fbDefinitions) {
          expect(reserved, isNot(contains(fb.name)),
              reason: 'FB ${fb.name} would shadow the built-in block of the same name');
        }
      });

      test('every binding resolves to a real tag', () {
        for (final r in p.simRules) {
          expect(resolves(p, r.targetPath), isTrue, reason: 'sim ${r.id} target ${r.targetPath}');
          expect(resolves(p, r.sourcePath), isTrue, reason: 'sim ${r.id} source ${r.sourcePath}');
          for (final c in r.condition) {
            expect(resolves(p, c.leftPath), isTrue, reason: 'sim ${r.id} clause ${c.leftPath}');
          }
        }
        for (final prog in p.programs) {
          for (final rung in prog.rungs) {
            for (final n in rung.nodes) {
              expect(resolves(p, n.variable), isTrue,
                  reason: '${prog.name} rung ${rung.rungIndex} node ${n.id} -> ${n.variable}');
              expect(resolves(p, n.operandA), isTrue, reason: '${prog.name} operandA ${n.operandA}');
              expect(resolves(p, n.operandB), isTrue, reason: '${prog.name} operandB ${n.operandB}');
              n.pinBindings.forEach((pin, ref) {
                expect(resolves(p, ref), isTrue, reason: '${prog.name} pin $pin -> $ref');
              });
            }
          }
          for (final b in prog.fbdBlocks) {
            if (b.type == 'TAG_INPUT' || b.type == 'TAG_OUTPUT') {
              expect(resolves(p, b.tagBinding), isTrue,
                  reason: '${prog.name} block ${b.id} -> ${b.tagBinding}');
            }
            if (fbDefinitionFor(p, b.type) != null) {
              expect(b.tagBinding, isNotEmpty,
                  reason: '${prog.name} FB block ${b.id} has no instance tag');
              expect(resolves(p, b.tagBinding), isTrue,
                  reason: '${prog.name} FB instance ${b.tagBinding} is missing');
            }
          }
          for (final w in prog.fbdWires) {
            expect(prog.fbdBlocks.any((b) => b.id == w.fromBlockId), isTrue,
                reason: '${prog.name} wire from missing block ${w.fromBlockId}');
            expect(prog.fbdBlocks.any((b) => b.id == w.toBlockId), isTrue,
                reason: '${prog.name} wire to missing block ${w.toBlockId}');
          }
          for (final t in prog.sfcTransitions) {
            for (final id in [
              if (t.fromStepId.isNotEmpty) t.fromStepId,
              if (t.toStepId.isNotEmpty) t.toStepId,
              ...t.fromStepIds,
              ...t.toStepIds,
            ]) {
              expect(prog.sfcSteps.any((s) => s.id == id), isTrue,
                  reason: '${prog.name} transition ${t.id} names missing step $id');
            }
          }
        }
      });

      test('every HMI binding and every trend pen reference resolves', () {
        final penPaths = p.trends.map((t) => t.tagPath).toSet();
        for (final pen in p.trends) {
          expect(resolves(p, pen.tagPath), isTrue, reason: 'pen ${pen.tagPath}');
        }
        for (final h in p.hmis) {
          for (final c in h.components) {
            if (c.type == kTrendChartDisplay) {
              expect(c.trendPens, isNotEmpty, reason: '${c.id} is an empty trend chart');
              for (final ref in c.trendPens) {
                expect(penPaths, contains(ref.penTagPath),
                    reason: '${c.id} references pen ${ref.penTagPath} with no project pen');
              }
              continue;
            }
            expect(c.tagBinding, isNotEmpty, reason: '${c.id} has no binding');
            expect(resolves(p, c.tagBinding), isTrue,
                reason: '${h.id}/${c.id} -> ${c.tagBinding}');
          }
        }
      });
    });
  }
}
```

- [ ] **Step 11: Write the protocol-autostart gate test**

The flagship ships `enabled: true` protocol configs. The spec's §4.6 gate
requires proving that loading it does not bind a socket. `workspace_shell.dart`
never calls `OpcUaHost.start()` / `ModbusHost.start()` — only `stop()` — so the
only way a host could start is the Gateway screen's toggle.

Prove it **two ways**. The log check alone is a weak proxy: `AppLogger`'s
default minimum level is `LogLevel.info`, so a host that started but only logged
at DEBUG/TRACE would slip past it. The socket check is the direct evidence — if
a host had started, its port would already be taken and the bind would throw.

Create `mobile/test/defaults/flagship_gateway_no_autostart_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

/// §4.6 verification gate: the flagship ships Modbus + OPC UA with
/// `enabled: true` so the Gateway screen has live content out of the box. That
/// is only safe because nothing auto-starts a host on project load — `start()`
/// is reached exclusively from the Gateway screen's toggle. If this test ever
/// fails, ship those configs with `enabled: false` and record the finding in
/// docs/DEFERRED.md; do NOT change host code (no-engine-changes rule).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('booting the shell with the flagship in the catalog starts no '
      'protocol host', (tester) async {
    // Sanity: the flagship really does ship enabled protocol configs.
    final flagship =
        DefaultProjects.all().firstWhere((p) => p.id == 'proj_flagship_line');
    expect(flagship.protocols!.modbus!.enabled, isTrue);
    expect(flagship.protocols!.opcua!.enabled, isTrue);

    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    for (var i = 0; i < 5; i++) {
      state.debugRunScan();
    }
    await tester.pump();

    final hostEntries = state.debugLogger.entries.where(
        (e) => e.source == kLogSourceOpcUa || e.source == kLogSourceModbus);
    expect(hostEntries, isEmpty,
        reason: 'a protocol host logged during boot/scan — something auto-started it: '
            '${hostEntries.map((e) => "${e.source}: ${e.message}").join(" | ")}');

    // Direct evidence: both configured ports are still free. A started host
    // would be holding them and these binds would throw SocketException.
    // (The log check above cannot see a host that only logs below
    // AppLogger.kDefaultMinLevel, which is why this second check exists.)
    for (final port in [502, 4840]) {
      ServerSocket? probe;
      try {
        probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException catch (e) {
        fail('port $port is already bound after booting on the flagship — a '
            'protocol host auto-started (or another process holds it): $e');
      }
      expect(probe, isNotNull);
      await probe.close();
    }

    expect(tester.takeException(), isNull);
  });
}
```

If either bind fails on a developer machine because an unrelated process holds
502/4840 (a real OPC UA server, for instance), that is an environment
collision, not a regression — confirm with `netstat`/`ss` before touching the
project. If it fails in CI, treat it as a genuine auto-start: ship the flagship's
configs with `enabled: false` and add the deferred row.

If `WorkspaceShellState` is not the public state class name, read it from
`mobile/lib/screens/workspace_shell.dart` and use the real one (the existing
shell tests in `test/scan_count_continuity_test.dart` already do this — copy
their `_shell(tester)` helper).

- [ ] **Step 12: Run the three new guard tests**

```bash
/c/flutter/bin/flutter test test/defaults/
```
Expected: every file under `test/defaults/` passes, including the seven
per-project tests, the water snapshot, the coverage guard, the integrity guard
and the autostart gate.

Any coverage/integrity failure is a **content bug in one of Tasks 2–7** — fix it
in the project builder, not by weakening the guard.

- [ ] **Step 13: Run analyze + the FULL suite**

```bash
/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test
```
Expected: `No issues found!` and every test in the suite passes.

- [ ] **Step 14: Write `docs/default-projects.md`**

Create `docs/default-projects.md` with:

1. A one-paragraph intro: seven curated defaults replace the previous fourteen;
   the barrel keeps `DefaultProjects.all()` and its import path stable; one file
   per project under `mobile/lib/data/default_projects/`.
2. A section per project (in `all()` order) with: id, name, story, the exact
   feature list it is the showcase for, and the path of its proof test. Copy the
   (a)/(b)/(d) parts of each project file's library doc comment.
3. The full feature → project coverage table, transcribed from the spec's §5
   "After" column (FBD block types, LD elements, SFC/ST/FB/task/sim/HMI/protocol/
   system rows), so a reader has one place to answer "where do I see feature X?".
4. A "Migration behaviour" section transcribing the spec's §3 table (fresh
   install / existing install / Reset to Defaults / corrupt ledger) and the note
   that only **Reset to Defaults** yields exactly the seven.
5. A "Not covered" section listing the documented-uncovered set:
   LD-side `GE`/`LE`/`NE`/`MUL`/`DIV`/`TP`/`CTD`/`CTUD`, task type `Event`,
   `SignalGen` bulk test tags, and protocols beyond Modbus + OPC UA — each
   linking to `docs/DEFERRED.md`.

- [ ] **Step 15: Add the deferred rows**

Append to `docs/DEFERRED.md`, immediately before the `## Housekeeping` section:

```markdown
## Default projects redo (spec 2026-08-06)

| Item | Priority | Notes |
|---|---|---|
| Retired defaults linger on existing installs | near-term | `backfillNewDefaults` can only ADD a default whose id has never been seeded; it cannot remove or replace one the user already has. An existing install therefore shows up to 20 projects until the user runs Reset to Defaults, which is the only path that yields exactly the new 7. A "retire default ids" reconciliation pass (with user confirmation) is deferred. |
| `proj_all_water` refresh invisible to existing installs | later | Same root cause: backfill never overwrites an existing id, so any future data change to the water plant reaches only fresh installs. This is why §4.5 fixed its change list at "move to its own file + add the missing doc comment". A "refresh an existing default in place" migration is deferred. |
| LD-side `GE`/`LE`/`NE`/`MUL`/`DIV`/`TP`/`CTD`/`CTUD` | later | Supported by `ld_exec.dart` and the editor palette, still not showcased in any default project (unchanged from before the redo). Enforced as a set in `test/defaults/default_projects_coverage_test.dart`'s `knownUncoveredLdBlockTypes`. |
| Task type `Event` | later | No default project uses an event-triggered task; the approved flagship lineup fixes it at three tasks (Startup/Continuous/Periodic). Enforced as `knownUncoveredTaskTypes` in the coverage guard. |
| `SignalGen` / bulk simulated test tags | later | No default project ships signal generators. |
| Protocols beyond Modbus + OPC UA | later | MQTT, DNP3, EtherNet/IP, S7, FINS, SLMP and BACnet configs are not pre-populated in any default; the flagship configures Modbus + OPC UA only. |
| PID autotune / interaction-analysis prefill with multiple loops in one project | later | `PidAutoTuneScreen` prefills from the FIRST `PID` block in the FIRST FBD program and `defaultInteractionAnalysisTags` from the first four analog tags in declaration order. `proj_process_lab` works around this by fixing its program and tag ORDER; a loop-selection UI would be the real fix. |
```

If the implementation of Tasks 2–7 recorded anything else (an ST subset gap, a
renderer overflow, a PID retune), add it to this table too.

- [ ] **Step 16: Update `CLAUDE.md`**

In the "Project layout" section of `CLAUDE.md`, after the line about `mobile/`,
add:

```markdown
The seven built-in demo projects live one-per-file in
`mobile/lib/data/default_projects/`; `mobile/lib/data/default_projects.dart` is
a barrel that keeps `DefaultProjects.all()` and its import path stable (see
`docs/default-projects.md`).
```

- [ ] **Step 17: Final validation**

```bash
/c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test
```
Expected: `No issues found!` and the whole suite green.

Then confirm the catalog by eye:

```bash
/c/flutter/bin/flutter test test/defaults/default_projects_integrity_test.dart --plain-name 'the catalog order'
```
Expected: PASS.

- [ ] **Step 18: Commit**

```bash
git add -A mobile/lib/data mobile/test docs CLAUDE.md
git commit -m "feat(defaults): switch the catalog to the seven curated projects

DefaultProjects.all() now returns the seven showcase projects; the 13 retired
builders are gone from lib (two survive verbatim as test fixtures). Re-points the
~30 dependent tests, replaces the three hardcoded 'N Tags, M Structs' literals with
computed labels, and adds the mechanical coverage + integrity guards plus the
flagship protocol-autostart gate. Docs: docs/default-projects.md, DEFERRED rows,
CLAUDE.md pointer."
```

---

## Appendix A — Browser verification checklist (execution controller's final phase)

This is **not** a plan task. After Task 8 lands green, the execution controller
runs one headless-Playwright pass per `CLAUDE.md` before calling the workstream
done. Nothing here changes code unless it finds a problem.

**Setup**

```bash
scripts/serve-web.sh --build   # background; serves mobile/build/web on :8091
node scripts/browser-check.mjs # or drive the `playwright` MCP tools directly
```

Screenshots go to `.playwright-artifacts/screenshots/` named
`<project-slug>-<screen>-<viewport>.png`. Never launch a headed browser.

**Viewports:** 1440×900 (desktop) and 390×844 (mobile) for everything; add
768×1024 (tablet) for the flagship's three dashboards, which are the widest
content in the app.

**Per project — 13 dashboards and 12 program editors**

| Project | HMI screens | Program editors |
|---|---|---|
| Ladder — Conveyor Line | `hmi_ld_conveyor_line` | `ConveyorLine_LD` |
| FBD — HVAC Zone Controller | `hmi_fbd_hvac_zone`, `hmi_fbd_hvac_tank` | `HvacZone_FBD` |
| SFC — Batch Production | `hmi_sfc_batch_production` | `BatchProduction_SFC` |
| ST — Reactor Temperature Controller | `hmi_st_reactor` | `ReactorTemp_ST`, `ReactorAlarm_FBD` |
| All Languages — Water Treatment Plant | `hmi_all_water` | `Safety_ST`, `PumpControl_LD`, `WaterQuality_FBD`, `FilterBackwash_SFC` |
| Flagship — Production Line | `hmi_flagship_overview`, `hmi_flagship_trends`, `hmi_flagship_diagnostics` | `Infeed_LD`, `Blend_FBD`, `Batch_SFC`, `Safety_ST` |
| Process Control Lab | `hmi_lab_pid`, `hmi_lab_mimo`, `hmi_lab_cascade`, `hmi_lab_noise` | `LevelPID_FBD`, `TwoZone_FBD`, `CascadeMonitor_FBD`, `NoisyLevelMonitor_FBD` |

**Pass criteria (every screen, every viewport)**

- Console: **zero** `A RenderFlex overflowed` messages, zero errors, zero
  warnings from app code.
- Network: zero failed requests.
- No clipped or truncated card content; no horizontally scrolling page body.

**Eyeball specifically — these are brand new and have never been rendered**

1. **`hmi_flagship_trends`** — the analog chart auto-scales across
   `Blend_Level` / `Blend_Valve` / `Blend_Temp` (three distinct pen colours,
   visible axis labels), and the BOOL chart renders `Batch_Running` /
   `Alarm_Active` as **step lanes**, not as a 0/1 line squashed onto a shared
   analog axis. Let the scan run ~2 minutes so the 120 s window fills.
2. **`hmi_flagship_diagnostics`** — the two `TextInputField` cards
   (`Recipe_Name` STRING, `Batch_Target` INT32) render an editable field with a
   commit affordance and do not overflow at 390 px; the System panel
   (`ScanCount` / `ScanTimeMs` / `MaxScanTimeMs` / `UptimeMs` gauges,
   `Running` / `FirstScan` LEDs, `Fault` pill) populates with live values rather
   than zeros.
3. **`HvacZone_FBD` editor** — all seven network lanes render, each with its
   comment header; network 1's long LIMIT chain (widest content, x up to ~1160)
   pans rather than clipping; network 4's five-input `CTUD` shows all five pins.
4. **`ConveyorLine_LD` editor** — all 23 rungs render at phone width; rung 0's
   and rung 1's OR branches draw correctly; rung 17's bare FB-call block (no
   preceding contact) renders wired rail-to-rail.
5. **`Blend_FBD` editor** — the `Scale` custom-FB block shows its five named
   input pins (`In`, `InLo`, `InHi`, `OutLo`, `OutHi`) and its `Out` pin.
6. **`BatchProduction_SFC` and `Batch_SFC` editors** — the parallel fork/join
   double bars and the alternative divergence render as branches, not as
   overlapping arrows.
7. **Gateway screen on the flagship** — Modbus and OPC UA show non-empty maps
   with `System.*` rows marked ReadOnly, and neither host is running until the
   toggle is used.
8. **`hmi_lab_*`** — all four lab dashboards are reachable from the project's
   view tree (a four-screen project has never shipped).

Fix → rebuild → reload → re-screenshot. UI work is not done until this passes.
Any layout problem that would need an engine/widget change goes to
`docs/DEFERRED.md` and the dashboard is reshaped instead (the no-engine-changes
rule holds through the browser pass too).

---

## Appendix B — Execution handoff

Plan complete and saved to
`docs/superpowers/plans/2026-08-06-default-projects-redo.md`. Two execution
options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review
   between tasks, fast iteration. Use `superpowers:subagent-driven-development`.
   Model/effort dispatch is annotated on each task header.
2. **Inline Execution** — execute tasks in this session using
   `superpowers:executing-plans`, batch execution with checkpoints.

Tasks 2–7 touch disjoint files and none of them modifies `DefaultProjects.all()`,
so they can be dispatched **in parallel** after Task 1 lands. Task 8 must run
last, alone, after all six have merged.
