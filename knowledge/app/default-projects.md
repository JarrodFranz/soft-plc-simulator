---
id: knowledge:app/default-projects
title: Default Projects
domain: app
version: "2026-08"
topics: [default-projects, seeding, backfill, retired-id, coverage-guard, integrity-guard, no-autostart]
summary: The seven-project default catalog and what each showcases, the id-gated backfill ledger that can only add a default and never overwrites or removes one (CL-12), and what the coverage/integrity/no-autostart guard tests actually enforce versus what they silently do not check.
related:
  - knowledge:app/index
  - knowledge:app/protocol-hosting
  - knowledge:app/tag-model
learnings: [CL-12]
---

# Default Projects

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `docs/default-projects.md`, `mobile/lib/data/default_projects.dart`,
> `mobile/lib/data/default_projects/`, `mobile/lib/data/project_repository.dart`
> (`backfillNewDefaults`, `deleteProject`), and the guard tests
> `mobile/test/defaults/default_projects_{integrity,coverage}_test.dart` and
> `flagship_gateway_no_autostart_test.dart`.
> **Read this before:** adding, removing, or renaming a default project; changing what a
> default showcases; or investigating why a shipped default didn't reach an existing install.

---

## 1. The headline rule

**The simulator ships exactly seven curated default projects; the seeding ledger can only
*add* a default whose id has never been seeded on a device, and can never overwrite or remove
one - so reusing a retired default's id silently suppresses the new content on every existing
install (CL-12).**

`backfillNewDefaults` (`mobile/lib/data/project_repository.dart:~284-315`):

```dart
for (final d in DefaultProjects.all()) {
  if (!seeded.contains(d.id)) {
    if (!catalogIds.contains(d.id)) {
      await saveProject(d);
    }
    seeded.add(d.id);
  }
}
```

The outer `if (!seeded.contains(d.id))` is the whole guard: an id already recorded in the
`seeded_default_ids` ledger is never revisited, regardless of whether its content changed. The
inner `if (!catalogIds.contains(d.id))` is belt-and-suspenders against clobbering an
already-present catalog entry even within that first pass. **CL-12's failure mode, precisely:**
if a *new* default project is assigned an id that was ever seeded before - including by a
now-retired default - `seeded.contains(d.id)` is already `true` on every install that received
that earlier rollout, so the `if` body never runs and the new content is never inserted there.
Only a genuinely fresh install (empty ledger) receives it. This is why
`default_projects_integrity_test.dart` pins the 13 ids retired by the "default-projects redo"
(`proj_motor`, `proj_tank`, `proj_st_reactor`, `proj_ld_conveyor`, `proj_fbd_hvac`,
`proj_sfc_filling`, `proj_sfc_batchmix`, `proj_tank_level_pid`, `proj_batch_counter`,
`proj_pulse_output`, `proj_cascade_tanks`, `proj_noisy_level`, `proj_mimo_two_zone`) and asserts
the current seven never intersect that set (reason string: *"reusing a retired id suppresses
backfill on every existing install"*). `proj_all_water` is the one legacy id deliberately
*reused* - its content is treated as frozen/unchanged for old installs that already have it.

```
Wrong:  give a brand-new default project an id copied from (or resembling) a retired one.
Correct: mint a fresh, never-before-seeded id for every genuinely new default - the ledger
        has no way to distinguish "resurrect the old meaning" from "reuse the id by accident."
```

## 2. The seven-project catalog

`DefaultProjects.all()` (`mobile/lib/data/default_projects.dart:24-32`) returns exactly these
seven, in a **load-bearing order**: `all()[0]` is the project the shell boots into (must be a
`LadderLogic` project whose first tag is `Start_PB`); `all().last` is used by repository/
persistence tests as "a default the catalog is missing."

| # | Name | id | Showcase headline |
|---|---|---|---|
| 1 | Ladder - Conveyor Line | `proj_ld_conveyor_line` | Full LD element set; first-ever ladder-bodied `FbDefinition` (`MotorStarter`) |
| 2 | FBD - HVAC Zone Controller | `proj_fbd_hvac_zone` | Whole FBD palette across 7 networks; ST-bodied custom FB (`SetpointShift`); 2-screen HMI |
| 3 | SFC - Batch Production | `proj_sfc_batch_production` | `single`/`isInitial`/`STEP_T`, `parallelFork`/`parallelJoin`, alternative divergence, `Periodic` task |
| 4 | ST - Reactor Temperature Controller | `proj_st_reactor_control` | ST array-index read, struct-member write, ST-bodied FB (`Hysteresis`, state persists across scans) |
| 5 | All Languages - Water Treatment Plant | `proj_all_water` | All four IEC 61131-3 languages in one project; byte-identical snapshot-guarded |
| 6 | Flagship - Production Line | `proj_flagship_line` | All 3 task types, both FB body kinds, 7/8 sim behaviors, `TrendChartDisplay` (6 pens), `System` tag on HMI, pre-configured Modbus + OPC UA |
| 7 | Process Control Lab | `proj_process_lab` | PID + autotune, MIMO interaction analysis, `deadTime`, `noise` + `firstOrderLag` filter, 4-screen |

Each has a dedicated proof test under `mobile/test/defaults/` (e.g.
`flagship_line_test.dart`) that fails if its showcase content is gutted, in addition to the
catalog-wide guards in §4.

**Deliberately not covered by any default** (each pinned as a negative assertion in the
coverage guard, §4, so silent drift is impossible): LD `GE`/`LE`/`NE`/`MUL`/`DIV`/`TP`/`CTD`/
`CTUD` (supported by the engine, just not showcased); the `Event` task type; `SignalGen` bulk
test tags; and any protocol beyond Modbus + OPC UA (MQTT, DNP3, EtherNet/IP, S7, FINS, SLMP,
BACnet configs are not pre-populated in any default).

## 3. Migration behavior on an existing install

| Install state | Result on next launch |
|---|---|
| Fresh install, or after Reset to Defaults | Ledger empty -> all 7 seeded. Exactly this lineup. |
| Existing install with some/all of the old 14 | The 6 genuinely new ids are added; the 13 retired ids **remain on device as ordinary user projects** (their ledger entries are inert, never resurrected). `proj_all_water`'s id is already seeded, so its refreshed content does **not** reach this install. |
| Existing install, user runs Reset to Defaults | Ledger and catalog cleared, then backfilled -> exactly the new 7. |
| Corrupt ledger | Decodes to an empty set -> every default not currently in the catalog is (re-)added - a safe degrade, not data loss. |

**Retired defaults are never actively removed.** `deleteProject`
(`mobile/lib/data/project_repository.dart:~197-201`) removes a project's stored blob and its
catalog entry, but never touches the seeding ledger - there is no un-seed/removal mechanism
anywhere in the repository. A retired default that a device already seeded simply persists as
an ordinary, undeleted user project unless the user deletes it manually or runs Reset to
Defaults.

## 4. What the guard tests actually check

**`default_projects_integrity_test.dart`** - the spec's structural invariants, per-project and
catalog-wide: unique ids/names across the catalog; the retired-id-never-resurrected assertion
backing CL-12 (§1); catalog length/order/boot invariants (`length == 7`, `first.id ==
'proj_ld_conveyor_line'`, first program is `LadderLogic`, first tag is `Start_PB`, `last.id ==
'proj_process_lab'`); per-project uniqueness of tag/`SimRule`/task/program/`FbdBlock`/
`SfcStep`/`SfcTransition`/`HmiComponent`/HMI-screen ids; every program referenced by at least
one enabled task and every task's `programNames` resolving to a real program; no
`FbDefinition` name shadowing a built-in FBD/LD block type; and that every binding (sim-rule
target/source/condition, LD node operands/pin bindings, FBD tag bindings/wire endpoints, SFC
transition step references, HMI bindings, trend-pen references) resolves to a real tag.

**The "resolves to a real tag" check has a root-only ceiling.** Its `resolves()` helper strips
a path down to the segment before the first `.` or `[` and checks only that a tag with that
**root name** exists:

```dart
final root = ref.split('.').first.split('[').first;
return p.tags.any((t) => t.name == root);
```

It never validates that a dotted path names a real field inside the referenced struct/FB
definition, nor that an array index is within `arrayLength`. A typo'd struct-member write
(`Reactor_Status.Heeting := ...`) or an out-of-bounds array index (`Recipe_Steps[99]`) passes
this guard as long as the root tag exists - the engine itself reads/writes such a path as `null`/
no-op at runtime (see [tag-model.md](./tag-model.md) §2) without throwing, so this guard is the
only structural check standing between a typo and a silently-dead demo, and it does not catch
every typo.

**`default_projects_coverage_test.dart`** - mechanical enforcement of the feature-coverage
matrix: every `kFbdBuiltinBlockTypes` value appears somewhere; a specific LD block/modifier set
appears while a `knownUncoveredLdBlockTypes` set stays empty of intersection; all 8 `SimRule`
behaviors appear; a non-linear valve curve and gaussian+drift noise both appear; all 9 HMI
component types appear and at least one carries trend pens; both `FbDefinition` body kinds
ship; SFC fork/join/alternative-divergence/`STEP_T`/`isInitial` all appear; the three covered
task types appear while `Event` stays in `knownUncoveredTaskTypes`; a default ships
pre-configured Modbus + OPC UA maps; some HMI component binds `System.*`; array/DUT/`TIMER`
tags all appear; a custom FB is wired into an FBD network; ST array-read and struct-write
regex checks pass; a multi-screen HMI exists; a PID loop the autotune screen can resolve
exists. Two assertions are explicitly **negative and pinned**: no default ships a `SignalGen`,
and no default configures a protocol beyond Modbus + OPC UA - either becoming true would fail
the build, forcing a conscious edit to this file and to `docs/default-projects.md`'s "Not
covered" section rather than a silent coverage change.

**`flagship_gateway_no_autostart_test.dart`** - proves the Flagship's `enabled: true` Modbus +
OPC UA configs are safe; see [protocol-hosting.md](./protocol-hosting.md) §3 for the full
mechanism.

---

## What this means practically

### "I want to add an eighth default project - what id should I use?"
Anything that has never appeared in `DefaultProjects.all()` before, including a retired id -
reusing one silently suppresses the new project on every device that already has that id in
its seeding ledger (§1, CL-12). Add the new id to the integrity test's expectations rather than
reusing a name that "feels" like a natural successor to a retired demo.

### "A default project's HMI binds a struct field that doesn't exist - why didn't the integrity test catch it?"
Its `resolves()` check only validates the root tag name, not struct fields or array bounds
(§4) - that gap is a known, documented ceiling, not a missed regression.

### "I deleted an old default project from my device but it came back - why?"
It didn't come back from the catalog - `deleteProject` never touches the seeding ledger (§3),
so if the same id is still present in `DefaultProjects.all()` (unlikely for a genuinely retired
id) or if Reset to Defaults was run, it can reappear through the normal seeding path, not as a
bug in delete.

---

## Related

- [tag-model.md](./tag-model.md) - the `resolves()` root-only limitation is a direct
  consequence of how paths are structured; see §2 there.
- [protocol-hosting.md](./protocol-hosting.md) - the no-autostart guarantee the Flagship's
  pre-configured protocols depend on.
- [index.md](./index.md) - domain hub.
