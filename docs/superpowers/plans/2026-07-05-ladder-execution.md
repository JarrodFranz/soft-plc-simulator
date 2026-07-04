# Ladder Execution Engine (WS4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the ladder programs for real — power-flow evaluation of the rung graphs (contacts, coils, TON/TOF timers writing live TIMER struct tags) drives the outputs each scan, replacing the hardcoded LD-control logic for the motor, conveyor, and water-pump projects.

**Architecture:** A pure `ld_exec.dart` evaluates each rung's node graph in column order (left rail powered; a node's input power = OR of inbound wires — series therefore ANDs, parallel converges ORs, identical to the boolean code a reference IEC compiler emits). Coils write tags immediately (visible to later rungs); TON/TOF state lives in the real `TIMER` struct tags advanced by scan-dt (matching the reference runtime's tick clock). `workspace_shell` runs sim inputs → `executeLdPrograms` → remaining hardcoded (non-LD) control.

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`, Chrome preview.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` must report **zero** issues. Use `withValues(alpha:)` (not `withOpacity`), `initialValue:` (not `value:`) on `DropdownButtonFormField`, braces on all flow-control bodies, prefer `const`, `x.isNotEmpty` not `x.length >= 1`.
- No RenderFlex overflow.
- All shell commands run from `mobile/`.
- Timer clock = scan dt (`dtMs` per call). A forced **root** tag is never overwritten by execution (same rule as `sim_engine.dart`).
- Behavior parity with the removed hardcoded control logic at the default scan speed.

**Sequencing:** Task 1 is additive/green (pure engine + tests). Task 2 wires execution in and removes the replaced hardcoded logic **in the same commit** (no double-drive window). Task 3 validates.

---

### Task 1: Pure ladder execution engine + tests

**Files:**
- Create: `mobile/lib/models/ld_exec.dart`
- Test: `mobile/test/ld_exec_test.dart`

**Interfaces:**
- Consumes: `PlcProject`, `PlcProgram`, `PlcTag`, `LdRung`, `LdNode`, `LdWire`, `LdKind` from `project_model.dart`; `colAssignment` from `ld_graph.dart`; `readPath`/`writePath` from `tag_resolver.dart`.
- Produces (used by Task 2): `class LdExecRuntime { Map<String,bool> prevBool; void clear(); }`; `void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt)`; `void executeRung(PlcProject p, String progName, LdRung rung, int dtMs, LdExecRuntime rt, void Function(String path, dynamic value) write)`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/ld_exec_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProject _proj(List<PlcTag> tags, List<PlcProgram> programs) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: programs, tasks: [], hmis: [],
    );

LdNode _no(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode _nc(String v) => LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'negated');
LdNode _coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);

PlcProgram _ldProg(List<LdRung> rungs) =>
    PlcProgram(name: 'P1', language: 'LadderLogic', rungs: rungs);

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('series contacts AND to the coil', () {
    final r = buildRung(index: 0, main: [_no('A'), _no('B'), _coil('Y')]);
    final p = _proj([_tag('A', 'BOOL', true), _tag('B', 'BOOL', false), _tag('Y', 'BOOL', false)],
        [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Y'), isFalse);
    writePath(p, 'B', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Y'), isTrue);
  });

  test('parallel branch ORs (seal-in holds, Stop NC drops it)', () {
    final r = buildRung(
      index: 0,
      main: [_no('Start'), _nc('Stop'), _coil('Motor')],
      branches: [BranchSpec(startIndex: 0, endIndex: 0, nodes: [_no('Motor')])],
    );
    final p = _proj(
        [_tag('Start', 'BOOL', false), _tag('Stop', 'BOOL', false), _tag('Motor', 'BOOL', false)],
        [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isFalse);
    writePath(p, 'Start', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isTrue);
    writePath(p, 'Start', false); // seal-in must hold via the Motor branch
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isTrue);
    writePath(p, 'Stop', true); // NC contact opens
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Motor'), isFalse);
  });

  test('set/reset coils latch and unlatch', () {
    final r0 = buildRung(index: 0, main: [
      _no('SetBtn'),
      LdNode(id: '', kind: LdKind.coil, variable: 'L', modifier: 'set'),
    ]);
    final r1 = buildRung(index: 1, main: [
      _no('RstBtn'),
      LdNode(id: '', kind: LdKind.coil, variable: 'L', modifier: 'reset'),
    ]);
    final p = _proj(
        [_tag('SetBtn', 'BOOL', true), _tag('RstBtn', 'BOOL', false), _tag('L', 'BOOL', false)],
        [_ldProg([r0, r1])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'L'), isTrue);
    writePath(p, 'SetBtn', false); // latch holds without power
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'L'), isTrue);
    writePath(p, 'RstBtn', true);
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'L'), isFalse);
  });

  test('rising-edge contact fires for exactly one scan', () {
    final r = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'In', modifier: 'rising'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Out', modifier: 'set'),
    ]);
    final p = _proj([_tag('In', 'BOOL', false), _tag('Out', 'BOOL', false)], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // establishes prev=false, no edge on first scan
    expect(_b(p, 'Out'), isFalse);
    writePath(p, 'In', true);
    executeLdPrograms(p, 100, rt); // edge -> latch Out
    expect(_b(p, 'Out'), isTrue);
  });

  test('TON accumulates by dt, DN at PRE, resets when IN drops', () {
    final r = buildRung(index: 0, main: [
      _no('Run'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
      _coil('Done'),
    ]);
    final p = _proj([
      _tag('Run', 'BOOL', true),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Done', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt); // ACC=100
    expect(_b(p, 'T.DN'), isFalse);
    expect(_b(p, 'Done'), isFalse);
    executeLdPrograms(p, 100, rt); // 200
    executeLdPrograms(p, 100, rt); // 300 -> DN
    expect(_b(p, 'T.DN'), isTrue);
    expect(_b(p, 'Done'), isTrue); // block output power = DN drives the coil
    expect((readPath(p, 'T.PRE') as num).toInt(), equals(300)); // PRE synced from block
    writePath(p, 'Run', false);
    executeLdPrograms(p, 100, rt); // IN drops -> reset
    expect(_b(p, 'T.DN'), isFalse);
    expect((readPath(p, 'T.ACC') as num).toInt(), equals(0));
  });

  test('TOF holds Q for PRE after IN drops', () {
    final r = buildRung(index: 0, main: [
      _no('Run'),
      LdNode(id: '', kind: LdKind.block, blockType: 'TOF', variable: 'T', presetMs: 200),
      _coil('Q'),
    ]);
    final p = _proj([
      _tag('Run', 'BOOL', true),
      _tag('T', 'TIMER', defaultValueFor(_proj([], []), 'TIMER', 0)),
      _tag('Q', 'BOOL', false),
    ], [_ldProg([r])]);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(_b(p, 'Q'), isTrue); // Q while IN
    writePath(p, 'Run', false);
    executeLdPrograms(p, 100, rt); // 100 elapsed of 200 hold
    expect(_b(p, 'Q'), isTrue);
    executeLdPrograms(p, 100, rt); // 200 -> hold expires
    expect(_b(p, 'Q'), isFalse);
  });

  test('writes are visible to later rungs in the same scan', () {
    final r0 = buildRung(index: 0, main: [_no('A'), _coil('Mid')]);
    final r1 = buildRung(index: 1, main: [_no('Mid'), _coil('Out')]);
    final p = _proj(
        [_tag('A', 'BOOL', true), _tag('Mid', 'BOOL', false), _tag('Out', 'BOOL', false)],
        [_ldProg([r0, r1])]);
    executeLdPrograms(p, 100, LdExecRuntime());
    expect(_b(p, 'Out'), isTrue); // rung 1 saw rung 0's write this scan
  });

  test('a forced root tag is not overwritten by a coil', () {
    final r = buildRung(index: 0, main: [_no('A'), _coil('Y')]);
    final p = _proj(
        [_tag('A', 'BOOL', true), _tag('Y', 'BOOL', false, forced: true, fv: false)],
        [_ldProg([r])]);
    executeLdPrograms(p, 100, LdExecRuntime());
    expect(readPath(p, 'Y'), isFalse); // untouched (forced)
  });

  test('unknown contact tag reads as false, no throw', () {
    final r = buildRung(index: 0, main: [_no('Ghost'), _coil('Y')]);
    final p = _proj([_tag('Y', 'BOOL', true)], [_ldProg([r])]);
    executeLdPrograms(p, 100, LdExecRuntime());
    expect(_b(p, 'Y'), isFalse); // Ghost=false -> coil de-energized
  });

  test('non-LD programs are skipped', () {
    final p = _proj([_tag('Y', 'BOOL', false)],
        [PlcProgram(name: 'S', language: 'StructuredText')]);
    executeLdPrograms(p, 100, LdExecRuntime()); // must not throw
    expect(_b(p, 'Y'), isFalse);
  });
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `flutter test test/ld_exec_test.dart`
Expected: FAIL — `ld_exec.dart` does not exist.

- [ ] **Step 3: Implement `ld_exec.dart`**

Create `mobile/lib/models/ld_exec.dart`:

```dart
import 'project_model.dart';
import 'ld_graph.dart';
import 'tag_resolver.dart';

/// Prev-scan state for edge contacts and pulse coils, keyed by
/// "program|rungIndex|nodeId".
class LdExecRuntime {
  final Map<String, bool> prevBool = {};
  void clear() => prevBool.clear();
}

PlcTag? _rootTagOf(PlcProject p, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in p.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

void _forceAwareWrite(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins over executed logic
  }
  writePath(p, path, value);
}

/// Executes every LadderLogic program in [p], rungs top-to-bottom, once.
/// Writes are immediately visible to later rungs (seal-in works).
void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'LadderLogic') {
      continue;
    }
    for (final rung in prog.rungs) {
      executeRung(p, prog.name, rung, dtMs, rt, (path, v) => _forceAwareWrite(p, path, v));
    }
  }
}

/// Power-flow evaluation of one rung: nodes in column (topological) order;
/// a node's input power is the OR of its inbound wires' source powers, so
/// series chains AND and parallel convergences OR.
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write) {
  final col = colAssignment(rung);
  final ordered = [...rung.nodes]
    ..sort((a, b) => (col[a.id] ?? 0).compareTo(col[b.id] ?? 0));
  final power = <String, bool>{};

  bool inputPower(LdNode n) {
    bool any = false;
    for (final w in rung.wires) {
      if (w.toId == n.id && (power[w.fromId] ?? false)) {
        any = true;
      }
    }
    return any;
  }

  for (final n in ordered) {
    switch (n.kind) {
      case LdKind.leftRail:
        power[n.id] = true;
        break;
      case LdKind.rightRail:
        power[n.id] = inputPower(n);
        break;
      case LdKind.contact:
        final inP = inputPower(n);
        final val = readPath(p, n.variable) == true;
        final key = '$progName|${rung.rungIndex}|${n.id}';
        final prev = rt.prevBool[key] ?? val; // no spurious edge on first scan
        rt.prevBool[key] = val;
        bool cond;
        switch (n.modifier) {
          case 'negated':
            cond = !val;
            break;
          case 'rising':
            cond = val && !prev;
            break;
          case 'falling':
            cond = !val && prev;
            break;
          default:
            cond = val;
        }
        power[n.id] = inP && cond;
        break;
      case LdKind.coil:
        final inP = inputPower(n);
        power[n.id] = inP;
        final key = '$progName|${rung.rungIndex}|${n.id}';
        final prevP = rt.prevBool[key] ?? inP;
        rt.prevBool[key] = inP;
        switch (n.modifier) {
          case 'negated':
            write(n.variable, !inP);
            break;
          case 'set':
            if (inP) {
              write(n.variable, true);
            }
            break;
          case 'reset':
            if (inP) {
              write(n.variable, false);
            }
            break;
          case 'rising':
            write(n.variable, inP && !prevP); // one-scan pulse on power edge
            break;
          case 'falling':
            write(n.variable, !inP && prevP);
            break;
          default:
            write(n.variable, inP); // OTE
        }
        break;
      case LdKind.block:
        final inP = inputPower(n);
        final base = n.variable;
        final pre = n.presetMs;
        int acc = (readPath(p, '$base.ACC') as num?)?.toInt() ?? 0;
        bool dn;
        if (n.blockType == 'TOF') {
          if (inP) {
            acc = 0;
            dn = true; // Q true while IN
          } else {
            acc = acc + dtMs;
            if (acc > pre) {
              acc = pre;
            }
            dn = acc < pre; // holds until the off-delay expires
          }
        } else {
          // TON (default)
          if (inP) {
            acc = acc + dtMs;
            if (acc > pre) {
              acc = pre;
            }
            dn = acc >= pre;
          } else {
            acc = 0;
            dn = false;
          }
        }
        write('$base.EN', inP);
        write('$base.PRE', pre); // keep the visible tag synced to the block
        write('$base.ACC', acc);
        write('$base.DN', dn);
        write('$base.TT', n.blockType == 'TOF' ? (!inP && dn) : (inP && !dn));
        power[n.id] = dn; // block output (Q) feeds downstream elements
        break;
    }
  }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `flutter test test/ld_exec_test.dart`
Expected: PASS (10 tests).

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze` → **No issues found!**

```bash
git add mobile/lib/models/ld_exec.dart mobile/test/ld_exec_test.dart
git commit -m "feat(ld-exec): pure ladder power-flow execution engine with TON/TOF timers"
```

---

### Task 2: Scan integration + replace hardcoded LD control

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Modify: `mobile/lib/data/default_projects.dart`

**Interfaces:**
- Consumes: `executeLdPrograms`, `LdExecRuntime` from `ld_exec.dart` (Task 1).

**No double-drive window:** the execution wiring and the removal of the replaced hardcoded writes land in the SAME commit.

- [ ] **Step 1: Wire execution into the scan**

In `workspace_shell.dart`: add `import '../models/ld_exec.dart';` and a field `final LdExecRuntime _ldRuntime = LdExecRuntime();`. In `_executeScan()`, between the existing `applySimRules(...)` call and `_evaluateActiveLogic();`, add:

```dart
      executeLdPrograms(_activeProject, scanSpeedMs, _ldRuntime);
```

Where the active project is switched (the same place `_simRuntime.byRuleId.clear();` runs), also add `_ldRuntime.clear();`.

- [ ] **Step 2: Pre-populate the motor project's rungs**

`MotorControl_LD` in `_motorProject` (`default_projects.dart`) currently ships with NO rungs (they were only created by the LD editor's `_ensureDefaultRungs` on open — execution would have nothing to run). Add a `rungs:` list to that `PlcProgram` reproducing the hardcoded behavior exactly (the project file already has `_xic/_xio/_ote` helpers and imports `ld_graph.dart`):

```dart
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Motor Latch Seal-In',
            main: [
              _xic('Start_PB', 'Start NO'),
              _xio('Stop_PB', 'Stop NC'),
              _ote('Motor_Latch', 'Seal-in latch'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Motor_Latch', 'Seal-in aux')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Motor Run Permissives',
            main: [
              _xic('Motor_Latch', 'Latched'),
              _xic('EStop_OK', 'E-Stop healthy'),
              _xic('Overload_OK', 'Overload healthy'),
              _ote('Motor_Run', 'Starter coil'),
            ],
          ),
        ],
```

(Verify the motor project's actual tag names — `EStop_OK`, `Overload_OK` — against its `tags:` list and use exactly those.)

- [ ] **Step 3: Remove the replaced hardcoded control logic**

In `workspace_shell._evaluateActiveLogic`, carefully:

- **`proj_motor`**: delete the whole block (its only writes were `Motor_Latch` and `Motor_Run` — now rungs 0/1).
- **`proj_ld_conveyor`**: delete the control-logic writes now produced by the shipped rungs: `Belt_Motor` (rung 0), `Belt_Latch` set/unlatch (rungs 1 & 5), `Belt_Jammed` (rung 4 via `JamTimer.DN`), and `Part_Present` if any write remains (rung 2 drives it). If the block contains anything NOT expressible by the rungs, keep that remainder and note it in your report.
- **`proj_all_water`**: delete only the writes `PumpControl_LD`'s rungs produce: `Pump_Latch` (OTL, rung 1), `Pump_Motor` (rung 0), `Treat_Dosing` (rung 2), `Backwash_Active` (rung 4 via `BackwashTimer.DN`). KEEP `Quality_OK` (FBD logic), `Alarm_Active`/`System_Ready` (ST supervisor), backwash valve/pump sequencing (SFC), and any process resets. If the hardcoded `Backwash_Active` behavior differs materially from the rung (e.g. latching/duration the rung can't express), KEEP the hardcoded write, add a code comment `// Backwash_Active stays hardcoded until SFC execution (WS4b)`, and flag it in your report.
- Compare each removed write against the rung that replaces it (read `default_projects.dart` rungs) — behavior parity is the gate, matching the original semantics at the default scan speed.

- [ ] **Step 4: Remove the redundant conveyor sim rule**

In `_ldConveyorProject.simRules`, delete the rule named "Part present follows photo eye" (`setWhileCondition` targeting `Part_Present`) — rung 2 (`Photo_Eye → OTE Part_Present`) now computes it; keeping both would double-drive. Keep the Photo_Eye pulse rule.

- [ ] **Step 5: Analyze, test, build**

Run: `flutter analyze` → **No issues found!**
Run: `flutter test` → all pass.
Run: `flutter build web --release` → succeeds.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/data/default_projects.dart
git commit -m "feat(ld-exec): run ladder programs each scan; replace hardcoded LD control for motor/conveyor/water"
```

---

### Task 3: Final validation

**Files:** none (verification; small fixes only if a regression surfaces).

- [ ] **Step 1: Full suite + analyze + build**

Run: `flutter test` → all pass (ld_exec, sim_engine, tag_resolver, ld_graph, ld_layout, widget tests).
Run: `flutter analyze` → **No issues found!**
Run: `flutter build web --release` → succeeds.

- [ ] **Step 2: Behavioral walkthrough (controller; Chrome if capture works)**

- Motor project: force/press `Start_PB` → `Motor_Latch` latches, `Motor_Run` energizes; `Stop_PB` drops both — all driven by the ladder.
- Conveyor: belt start seals in; `JamTimer.ACC` visibly counts in the Tag Inspector while the belt runs with no part; `Belt_Jammed` trips at 5000 ms; a photo-eye pulse unlatches per rung 5.
- Water plant: pump seal-in, dosing on bad quality, backwash timer — from the ladder; Quality_OK/alarms still from the remaining hardcoded logic.
- Edit a rung (e.g. delete the seal-in branch) and confirm runtime behavior changes accordingly.

- [ ] **Step 3: Branding sweep**

Run: `grep -ri "openplc" mobile/lib mobile/test` → no matches.

- [ ] **Step 4: Commit (only if fixes were made)**

```bash
git add -A
git commit -m "test(ld-exec): validate executed ladder across projects"
```

---

## Self-review notes

- **Spec coverage:** power-flow engine w/ column-order eval (Task 1) ✓; contacts NO/NC/rising/falling, coils OTE/negated/set/reset/pulse (Task 1 code+tests) ✓; TON/TOF writing live TIMER tags, PRE synced from block, output=Q (Task 1) ✓; scan-dt clock ✓; forcing respected ✓; scan ordering sim→LD→hardcoded + runtime reset (Task 2) ✓; motor rung pre-population ✓; per-project replacement incl. water partial + escape hatch (Task 2 Step 3) ✓; conveyor sim-rule dedup (Task 2 Step 4) ✓; parity + behavioral walkthrough (Task 3) ✓.
- **Type consistency:** `LdExecRuntime`, `executeLdPrograms(p, dtMs, rt)`, `executeRung(p, progName, rung, dtMs, rt, write)` used identically across tasks; modifiers/blockType strings match the editor's (`normal|negated|rising|falling|set|reset`, `TON|TOF`).
- **Known simplification:** rightRail power is computed but unused (harmless); counters/math blocks out of scope per spec.
