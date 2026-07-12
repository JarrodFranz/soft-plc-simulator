# Task-Type Scheduler, Watchdog, Free-Run & System Tags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the soft PLC honor IEC task types with a priority scheduler + per-task watchdog, add a free-run scan mode, let operators create/manage tasks of all four types, and expose a reserved `System` UDT (fault/scan/first-scan/wall-clock status + alarm-reset control).

**Architecture:** A new **pure** scheduler (`task_scheduler.dart`) decides, each scan tick, which tasks are *due* in priority order (Startup→Event→Periodic→Continuous, Continuous skipped when anything higher is due) with per-task deduped program lists. The four language executors gain an optional `only` filter. The shell drives the tick — measuring time (fixed or free-run), timing each task for the watchdog, faulting+stopping on overrun, and writing a reserved `System` tag via a second **pure** unit (`system_tags.dart`). All timing/clock reads live in the shell; the two new model units stay pure and deterministic.

**Tech Stack:** Flutter/Dart (pure Dart in `mobile/lib/models/**`); existing `tag_resolver.dart` composites + `readPath`/`writePath`; `flutter_test`.

## Global Constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); IEC 61131-3 terms fine.
- Dark theme; zero `flutter analyze` warnings; use `withValues(alpha:)` not `withOpacity`.
- Braces on all control flow; prefer `const`. No RenderFlex overflow at 320 / 360 / 1400 px.
- `mobile/lib/models/**` stays **pure Dart** — no `dart:io`, no Flutter imports. `task_scheduler.dart` and `system_tags.dart` take time/values as inputs; only `workspace_shell.dart` reads the clock/timers.
- All tag writes go through `writePath`; reads through `readPath` (forcing stays authoritative).
- Additive persistence: new `PlcTask` fields + the `System` tag are additive; the WS6 lossless round-trip must stay green; a project with no task-type features behaves exactly as before.
- Use `INT32` (not `INT64`) for new numeric fields (`UptimeMs`, wall-clock components) — dart2js-safe.
- Priority order is **Startup → Event → Periodic → Continuous**; Continuous is **skipped** on any tick where a higher-priority task is due.
- Every program belongs to **≥1 task**; a program may be in multiple tasks; it runs **at most once per scan** (deduped in priority order).
- The reserved `System` tag cannot be deleted or renamed; status fields are read-only in the tag inspector; control bits remain writable.

**Test/analyze commands** (run from `mobile/`):
- Single test file: `flutter test test/<path>_test.dart`
- Full suite: `flutter test`
- Analyze: `flutter analyze` (expect **No issues found!**)

---

## Phase A — Model + pure scheduler + executor gating

### Task 1: `PlcTask` additive fields (`triggerTag`, `watchdogMs`)

**Files:**
- Modify: `mobile/lib/models/project_model.dart:451-483` (`PlcTask`)
- Test: `mobile/test/models/plc_task_test.dart` (create)

**Interfaces:**
- Produces: `PlcTask` gains `String triggerTag` (default `''`) and `int watchdogMs` (default `0`); JSON keys `trigger_tag`, `watchdog_ms`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/plc_task_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  group('PlcTask new fields', () {
    test('defaults: triggerTag empty, watchdogMs 0', () {
      final t = PlcTask(name: 'T', type: 'Continuous', programNames: []);
      expect(t.triggerTag, '');
      expect(t.watchdogMs, 0);
    });

    test('round-trips triggerTag + watchdogMs through JSON', () {
      final t = PlcTask(
        name: 'EvtT',
        type: 'Event',
        programNames: ['P1'],
        triggerTag: 'Start_PB',
        watchdogMs: 250,
      );
      final back = PlcTask.fromJson(t.toJson());
      expect(back.triggerTag, 'Start_PB');
      expect(back.watchdogMs, 250);
      expect(back.type, 'Event');
      expect(back.programNames, ['P1']);
    });

    test('fromJson tolerates missing new keys (legacy projects)', () {
      final back = PlcTask.fromJson({
        'name': 'Legacy',
        'type': 'Continuous',
        'period_ms': 100,
        'programs': ['A'],
        'enabled': true,
      });
      expect(back.triggerTag, '');
      expect(back.watchdogMs, 0);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/plc_task_test.dart`
Expected: FAIL — `triggerTag`/`watchdogMs` not defined.

- [ ] **Step 3: Implement the fields**

In `project_model.dart`, replace the `PlcTask` class body's fields/ctor/JSON with:

```dart
class PlcTask {
  String name;
  String type; // 'Startup', 'Continuous', 'Periodic', 'Event'
  int periodMs;
  List<String> programNames;
  bool enabled;
  String triggerTag; // Event task: BOOL trigger tag path; '' = none
  int watchdogMs;    // per-task watchdog limit in ms; 0 = disabled

  PlcTask({
    required this.name,
    required this.type,
    this.periodMs = 100,
    required this.programNames,
    this.enabled = true,
    this.triggerTag = '',
    this.watchdogMs = 0,
  });

  factory PlcTask.fromJson(Map<String, dynamic> json) {
    return PlcTask(
      name: json['name'] ?? '',
      type: json['type'] ?? 'Continuous',
      periodMs: json['period_ms'] ?? 100,
      programNames: List<String>.from(json['programs'] ?? []),
      enabled: json['enabled'] ?? true,
      triggerTag: json['trigger_tag'] ?? '',
      watchdogMs: json['watchdog_ms'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'period_ms': periodMs,
    'programs': programNames,
    'enabled': enabled,
    'trigger_tag': triggerTag,
    'watchdog_ms': watchdogMs,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/plc_task_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/test/models/plc_task_test.dart
git commit -m "feat(tasks): add PlcTask triggerTag + watchdogMs (additive)"
```

---

### Task 2: Pure task scheduler (`task_scheduler.dart`)

**Files:**
- Create: `mobile/lib/models/task_scheduler.dart`
- Test: `mobile/test/models/task_scheduler_test.dart` (create)

**Interfaces:**
- Consumes: `PlcTask` (with `triggerTag`, `watchdogMs`).
- Produces:
  - `class DueTask { final String taskName; final int watchdogMs; final List<String> programs; }`
  - `class TaskSchedulerRuntime { bool startupFired; Map<String,int> periodicAccumMs; Map<String,bool> eventPrevTrigger; void reset(); }`
  - `List<DueTask> scheduleTick(List<PlcTask> tasks, int dtMs, TaskSchedulerRuntime rt, bool Function(String path) boolLookup)`

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/task_scheduler_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/task_scheduler.dart';

PlcTask _t(String name, String type,
        {int period = 100, List<String>? progs, String trigger = '', bool enabled = true, int wd = 0}) =>
    PlcTask(
      name: name,
      type: type,
      periodMs: period,
      programNames: progs ?? [name.toLowerCase()],
      enabled: enabled,
      triggerTag: trigger,
      watchdogMs: wd,
    );

List<String> _names(List<DueTask> d) => d.expand((t) => t.programs).toList();

void main() {
  bool noTags(String _) => false;

  test('startup fires once on the first tick, never again', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('Boot', 'Startup', progs: ['b']), _t('Main', 'Continuous', progs: ['m'])];
    // First tick: startup due -> continuous skipped.
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['b']);
    // Second tick: startup done -> continuous runs.
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['m']);
    // Third tick: still continuous.
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['m']);
  });

  test('periodic fires at period boundary and carries remainder', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 250, progs: ['p']), _t('C', 'Continuous', progs: ['c'])];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']); // 100 < 250
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']); // 200 < 250
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['p']); // 300 >= 250 -> periodic, continuous skipped
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']); // carry 50, 150 < 250
  });

  test('event fires only on rising edge of its BOOL tag', () {
    final rt = TaskSchedulerRuntime();
    var trig = false;
    bool look(String p) => p == 'Btn' ? trig : false;
    final tasks = [_t('E', 'Event', trigger: 'Btn', progs: ['e']), _t('C', 'Continuous', progs: ['c'])];
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['c']); // false
    trig = true;
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['e']); // rising edge -> event, continuous skipped
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['c']); // sustained true -> no edge
    trig = false;
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['c']); // falling edge -> nothing
    trig = true;
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['e']); // rising again
  });

  test('disabled task never fires', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 50, progs: ['p'], enabled: false), _t('C', 'Continuous', progs: ['c'])];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']);
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']);
  });

  test('program in two due tasks is deduped, priority order', () {
    final rt = TaskSchedulerRuntime();
    // Safety in Startup + Continuous. First tick: startup claims 'safety'; continuous skipped anyway.
    final tasks = [
      _t('Boot', 'Startup', progs: ['safety']),
      _t('Main', 'Continuous', progs: ['safety', 'motor']),
    ];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['safety']); // startup only
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['safety', 'motor']); // continuous
  });

  test('multiple periodic due same tick both run; continuous skipped', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [
      _t('P1', 'Periodic', period: 100, progs: ['a']),
      _t('P2', 'Periodic', period: 100, progs: ['b']),
      _t('C', 'Continuous', progs: ['c']),
    ];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['a', 'b']);
  });

  test('DueTask carries watchdogMs from its task', () {
    final rt = TaskSchedulerRuntime();
    final due = scheduleTick([_t('C', 'Continuous', progs: ['c'], wd: 42)], 100, rt, noTags);
    expect(due.single.watchdogMs, 42);
    expect(due.single.taskName, 'C');
  });

  test('reset re-arms startup', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('Boot', 'Startup', progs: ['b']), _t('C', 'Continuous', progs: ['c'])];
    scheduleTick(tasks, 100, rt, noTags);
    scheduleTick(tasks, 100, rt, noTags);
    rt.reset();
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['b']); // startup fires again
  });

  test('deterministic: same inputs -> same output', () {
    final a = TaskSchedulerRuntime();
    final b = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 300, progs: ['p']), _t('C', 'Continuous', progs: ['c'])];
    for (var i = 0; i < 10; i++) {
      expect(_names(scheduleTick(tasks, 100, a, noTags)), _names(scheduleTick(tasks, 100, b, noTags)));
    }
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/task_scheduler_test.dart`
Expected: FAIL — `task_scheduler.dart` does not exist.

- [ ] **Step 3: Implement the scheduler**

Create `mobile/lib/models/task_scheduler.dart`:

```dart
import 'project_model.dart';

/// One task that is due to run this scan tick, with its already-deduped,
/// ordered program list (programs claimed by a higher-priority due task in the
/// same tick are removed) and its watchdog budget.
class DueTask {
  final String taskName;
  final int watchdogMs;
  final List<String> programs;
  DueTask({required this.taskName, required this.watchdogMs, required this.programs});
}

/// Per-run-session scheduler state. Reset at run-session boundaries (Run
/// pressed from stopped, project switch).
class TaskSchedulerRuntime {
  bool startupFired = false;
  final Map<String, int> periodicAccumMs = {};
  final Map<String, bool> eventPrevTrigger = {};

  void reset() {
    startupFired = false;
    periodicAccumMs.clear();
    eventPrevTrigger.clear();
  }
}

/// Priority order: Startup > Event > Periodic > Continuous.
const List<String> _priority = ['Startup', 'Event', 'Periodic', 'Continuous'];

/// Decide which tasks are due this tick, in priority order, with per-task
/// deduped program lists. Pure + deterministic: all time enters via [dtMs];
/// [boolLookup] returns the current BOOL value of an Event task's trigger tag
/// (false for unknown / non-BOOL paths). Advances [rt] (startup flag, periodic
/// accumulators, event edge memory) as a side effect.
List<DueTask> scheduleTick(
  List<PlcTask> tasks,
  int dtMs,
  TaskSchedulerRuntime rt,
  bool Function(String path) boolLookup,
) {
  final isFirstScan = !rt.startupFired;

  // Periodic accumulation (enabled periodic tasks only). Fires at most once per
  // tick; carries the remainder, clamped so a task that cannot keep up does not
  // accumulate unbounded time.
  final periodicDue = <String, bool>{};
  for (final t in tasks) {
    if (!t.enabled || t.type != 'Periodic') {
      continue;
    }
    final acc = (rt.periodicAccumMs[t.name] ?? 0) + dtMs;
    final due = t.periodMs <= 0 ? true : acc >= t.periodMs;
    periodicDue[t.name] = due;
    var next = due ? (t.periodMs <= 0 ? 0 : acc - t.periodMs) : acc;
    if (t.periodMs > 0 && next > t.periodMs) {
      next = t.periodMs;
    }
    rt.periodicAccumMs[t.name] = next;
  }

  bool dueStartup(PlcTask t) => t.type == 'Startup' && isFirstScan;
  bool dueEvent(PlcTask t) {
    if (t.type != 'Event') {
      return false;
    }
    final now = boolLookup(t.triggerTag);
    final prev = rt.eventPrevTrigger[t.name] ?? false;
    return now && !prev;
  }

  final anyHigherDue = tasks.any((t) =>
      t.enabled &&
      (dueStartup(t) || dueEvent(t) || (periodicDue[t.name] ?? false)));

  bool isDue(PlcTask t) {
    switch (t.type) {
      case 'Startup':
        return dueStartup(t);
      case 'Event':
        return dueEvent(t);
      case 'Periodic':
        return periodicDue[t.name] ?? false;
      case 'Continuous':
        return !anyHigherDue;
      default:
        return false;
    }
  }

  final claimed = <String>{};
  final out = <DueTask>[];
  for (final type in _priority) {
    for (final t in tasks) {
      if (!t.enabled || t.type != type || !isDue(t)) {
        continue;
      }
      final progs = <String>[];
      for (final pn in t.programNames) {
        if (claimed.add(pn)) {
          progs.add(pn);
        }
      }
      if (progs.isNotEmpty) {
        out.add(DueTask(taskName: t.name, watchdogMs: t.watchdogMs, programs: progs));
      }
    }
  }

  // Advance edge memory for all Event tasks (even not-due / disabled), so a
  // re-enabled task detects a fresh edge rather than a stale one.
  for (final t in tasks) {
    if (t.type == 'Event') {
      rt.eventPrevTrigger[t.name] = boolLookup(t.triggerTag);
    }
  }
  rt.startupFired = true;
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/models/task_scheduler_test.dart`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/task_scheduler.dart mobile/test/models/task_scheduler_test.dart
git commit -m "feat(scheduler): pure priority task scheduler (startup/event/periodic/continuous)"
```

---

### Task 3: Executor `only` gating (LD/FBD/SFC/ST)

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart:55` (`executeLdPrograms`)
- Modify: `mobile/lib/models/fbd_exec.dart:492` (`executeFbdPrograms`)
- Modify: `mobile/lib/models/sfc_exec.dart:37` (`executeSfcPrograms`)
- Modify: `mobile/lib/models/st_exec.dart:284` (`executeStPrograms`)
- Test: `mobile/test/models/executor_gating_test.dart` (create)

**Interfaces:**
- Produces: each `executeXxxPrograms(PlcProject p, int dtMs, XxxRuntime rt, {Set<String>? only})`. `only == null` runs all (unchanged); non-null runs only programs whose `name ∈ only`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/executor_gating_test.dart`. This uses ST programs (simplest to assert): two ST programs each writing a tag; `only` restricts which runs.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj() {
  final p = PlcProject(id: 'x', name: 'x');
  p.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'));
  p.tags.add(PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: false, ioType: 'Internal'));
  p.programs.add(PlcProgram(name: 'ProgA', language: 'StructuredText', stSource: 'A := TRUE;'));
  p.programs.add(PlcProgram(name: 'ProgB', language: 'StructuredText', stSource: 'B := TRUE;'));
  return p;
}

void main() {
  test('only=null runs all programs (unchanged behavior)', () {
    final p = _proj();
    executeStPrograms(p, 100, StRuntime());
    expect(readPath(p, 'A'), true);
    expect(readPath(p, 'B'), true);
  });

  test('only={ProgA} runs just ProgA', () {
    final p = _proj();
    executeStPrograms(p, 100, StRuntime(), only: {'ProgA'});
    expect(readPath(p, 'A'), true);
    expect(readPath(p, 'B'), false);
  });

  test('only={} runs nothing', () {
    final p = _proj();
    executeStPrograms(p, 100, StRuntime(), only: <String>{});
    expect(readPath(p, 'A'), false);
    expect(readPath(p, 'B'), false);
  });
}
```

> If `PlcProject`/`PlcProgram` constructors differ, the implementer must read `project_model.dart` and adapt the fixture (keep the three assertions identical).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/executor_gating_test.dart`
Expected: FAIL — `only` named parameter not defined.

- [ ] **Step 3: Add the `only` filter to each executor**

In each of the four executors, add `{Set<String>? only}` to the signature and, right after the language-filter `continue` inside the `for (final prog in p.programs)` loop, add the gate. Example for `ld_exec.dart`:

```dart
void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt, {Set<String>? only}) {
  for (final prog in p.programs) {
    if (prog.language != 'LadderLogic') {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    for (final rung in prog.rungs) {
      executeRung(p, prog.name, rung, dtMs, rt, (path, v) => _forceAwareWrite(p, path, v));
    }
  }
}
```

Apply the identical `{Set<String>? only}` param + `if (only != null && !only.contains(prog.name)) { continue; }` guard to:
- `executeFbdPrograms` (after the `language != 'FunctionBlockDiagram' || fbdBlocks.isEmpty` continue),
- `executeSfcPrograms` (after the `language != 'SequentialFunctionChart' || sfcSteps.isEmpty` continue),
- `executeStPrograms` (after the `language != 'StructuredText' || stSource.trim().isEmpty` continue).

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/executor_gating_test.dart`
Expected: PASS (3 tests).
Run: `flutter test test/models/` — existing executor tests still pass (the `only` param is optional).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/ld_exec.dart mobile/lib/models/fbd_exec.dart mobile/lib/models/sfc_exec.dart mobile/lib/models/st_exec.dart mobile/test/models/executor_gating_test.dart
git commit -m "feat(exec): optional 'only' program filter on all four executors"
```

---

## Phase C — System UDT (built before shell wiring so the shell can use it)

### Task 4: `SYSTEM` built-in composite + `system_tags.dart` (pure)

**Files:**
- Modify: `mobile/lib/models/tag_resolver.dart:22-39` (`_builtinComposites`)
- Create: `mobile/lib/models/system_tags.dart`
- Test: `mobile/test/models/system_tags_test.dart` (create)

**Interfaces:**
- Consumes: `lookupComposite`, `readPath`, `writePath`, `defaultValueFor` from `tag_resolver.dart`; `PlcTag`/`PlcProject` from `project_model.dart`.
- Produces:
  - const `kSystemTagName = 'System'`, `kSystemTypeName = 'SYSTEM'`
  - `void ensureSystemTag(PlcProject p)` — inject the reserved `System` tag if absent; back-fill missing fields without clobbering existing values.
  - `class SystemSnapshot { ... }` (all status fields)
  - `void updateSystemStatus(PlcProject p, SystemSnapshot s)`
  - `bool consumeAlarmReset(PlcProject p)` — if `System.AlarmReset` is true, set it false and return true.
  - A `SYSTEM` entry in `_builtinComposites` so `System.*` paths resolve.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/models/system_tags_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

void main() {
  test('ensureSystemTag injects a reserved System tag when absent', () {
    final p = PlcProject(id: 'x', name: 'x');
    expect(p.tags.any((t) => t.name == 'System'), isFalse);
    ensureSystemTag(p);
    final sys = p.tags.firstWhere((t) => t.name == 'System');
    expect(sys.dataType, 'SYSTEM');
    expect(readPath(p, 'System.Fault'), false);
    expect(readPath(p, 'System.AlarmReset'), false);
    expect(readPath(p, 'System.Hour'), 0);
    expect(readPath(p, 'System.DateTime'), '');
  });

  test('ensureSystemTag back-fills missing fields, keeps existing values', () {
    final p = PlcProject(id: 'x', name: 'x');
    // Simulate a legacy System tag missing newer fields but with a set value.
    p.tags.add(PlcTag(
      name: 'System', path: 'System', dataType: 'SYSTEM',
      value: <String, dynamic>{'ScanCount': 7}, ioType: 'Internal',
    ));
    ensureSystemTag(p);
    expect(readPath(p, 'System.ScanCount'), 7); // preserved
    expect(readPath(p, 'System.Fault'), false); // back-filled
    expect(p.tags.where((t) => t.name == 'System').length, 1); // no duplicate
  });

  test('updateSystemStatus writes status fields incl. wall clock', () {
    final p = PlcProject(id: 'x', name: 'x');
    ensureSystemTag(p);
    updateSystemStatus(p, const SystemSnapshot(
      fault: true, faultTask: 'PumpTask', faultCode: 1,
      running: true, firstScan: false, scanCount: 12,
      scanTimeMs: 3.5, maxScanTimeMs: 9.0, minScanTimeMs: 1.0,
      freeRun: true, uptimeMs: 4200,
      year: 2026, month: 7, day: 13, hour: 14, minute: 5, second: 32,
      dateTime: '2026-07-13 14:05:32',
    ));
    expect(readPath(p, 'System.Fault'), true);
    expect(readPath(p, 'System.FaultTask'), 'PumpTask');
    expect(readPath(p, 'System.FaultCode'), 1);
    expect(readPath(p, 'System.ScanCount'), 12);
    expect(readPath(p, 'System.FreeRun'), true);
    expect(readPath(p, 'System.UptimeMs'), 4200);
    expect(readPath(p, 'System.Hour'), 14);
    expect(readPath(p, 'System.DateTime'), '2026-07-13 14:05:32');
  });

  test('consumeAlarmReset returns true + self-clears only when set', () {
    final p = PlcProject(id: 'x', name: 'x');
    ensureSystemTag(p);
    expect(consumeAlarmReset(p), isFalse); // default false
    writePath(p, 'System.AlarmReset', true);
    expect(consumeAlarmReset(p), isTrue);
    expect(readPath(p, 'System.AlarmReset'), false); // self-cleared
    expect(consumeAlarmReset(p), isFalse); // stays cleared
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/models/system_tags_test.dart`
Expected: FAIL — `system_tags.dart` does not exist.

- [ ] **Step 3a: Register the `SYSTEM` composite**

In `tag_resolver.dart`, add a third entry to the `_builtinComposites` list (after `COUNTER`):

```dart
  PlcStructDef(name: 'SYSTEM', fields: [
    StructFieldDef(name: 'Fault', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'FaultTask', dataType: 'STRING', defaultValue: ''),
    StructFieldDef(name: 'FaultCode', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'FirstScan', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'ScanCount', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'ScanTimeMs', dataType: 'FLOAT64', defaultValue: 0.0),
    StructFieldDef(name: 'MaxScanTimeMs', dataType: 'FLOAT64', defaultValue: 0.0),
    StructFieldDef(name: 'MinScanTimeMs', dataType: 'FLOAT64', defaultValue: 0.0),
    StructFieldDef(name: 'FreeRun', dataType: 'BOOL', defaultValue: false),
    StructFieldDef(name: 'UptimeMs', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Year', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Month', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Day', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Hour', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Minute', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'Second', dataType: 'INT32', defaultValue: 0),
    StructFieldDef(name: 'DateTime', dataType: 'STRING', defaultValue: ''),
    StructFieldDef(name: 'AlarmReset', dataType: 'BOOL', defaultValue: false),
  ]),
```

- [ ] **Step 3b: Create `system_tags.dart`**

```dart
import 'project_model.dart';
import 'tag_resolver.dart';

const String kSystemTagName = 'System';
const String kSystemTypeName = 'SYSTEM';

/// A snapshot of PLC status the shell computes each scan and writes into the
/// reserved `System` tag. Pure data; the shell supplies the clock/timers.
class SystemSnapshot {
  final bool fault;
  final String faultTask;
  final int faultCode;
  final bool running;
  final bool firstScan;
  final int scanCount;
  final double scanTimeMs;
  final double maxScanTimeMs;
  final double minScanTimeMs;
  final bool freeRun;
  final int uptimeMs;
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final String dateTime;

  const SystemSnapshot({
    required this.fault,
    required this.faultTask,
    required this.faultCode,
    required this.running,
    required this.firstScan,
    required this.scanCount,
    required this.scanTimeMs,
    required this.maxScanTimeMs,
    required this.minScanTimeMs,
    required this.freeRun,
    required this.uptimeMs,
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    required this.dateTime,
  });
}

PlcTag? _systemTag(PlcProject p) {
  for (final t in p.tags) {
    if (t.name == kSystemTagName) {
      return t;
    }
  }
  return null;
}

/// Inject the reserved `System` tag if absent; otherwise coerce its type and
/// back-fill any missing fields without clobbering existing values.
void ensureSystemTag(PlcProject p) {
  final comp = lookupComposite(p, kSystemTypeName);
  if (comp == null) {
    return; // SYSTEM built-in missing (should never happen)
  }
  var tag = _systemTag(p);
  if (tag == null) {
    tag = PlcTag(
      name: kSystemTagName,
      path: kSystemTagName,
      dataType: kSystemTypeName,
      value: defaultValueFor(p, kSystemTypeName, 0),
      ioType: 'Internal',
      access: 'ReadOnly',
      description: 'SoftPLC system status (read-only; AlarmReset writable)',
    );
    p.tags.add(tag);
    return;
  }
  tag.dataType = kSystemTypeName;
  if (tag.value is! Map) {
    tag.value = <String, dynamic>{};
  }
  final m = tag.value as Map;
  for (final f in comp.fields) {
    if (!m.containsKey(f.name)) {
      m[f.name] = f.defaultValue;
    }
  }
}

/// Write the status fields (leaves control fields like AlarmReset untouched).
void updateSystemStatus(PlcProject p, SystemSnapshot s) {
  ensureSystemTag(p);
  writePath(p, 'System.Fault', s.fault);
  writePath(p, 'System.FaultTask', s.faultTask);
  writePath(p, 'System.FaultCode', s.faultCode);
  writePath(p, 'System.Running', s.running);
  writePath(p, 'System.FirstScan', s.firstScan);
  writePath(p, 'System.ScanCount', s.scanCount);
  writePath(p, 'System.ScanTimeMs', s.scanTimeMs);
  writePath(p, 'System.MaxScanTimeMs', s.maxScanTimeMs);
  writePath(p, 'System.MinScanTimeMs', s.minScanTimeMs);
  writePath(p, 'System.FreeRun', s.freeRun);
  writePath(p, 'System.UptimeMs', s.uptimeMs);
  writePath(p, 'System.Year', s.year);
  writePath(p, 'System.Month', s.month);
  writePath(p, 'System.Day', s.day);
  writePath(p, 'System.Hour', s.hour);
  writePath(p, 'System.Minute', s.minute);
  writePath(p, 'System.Second', s.second);
  writePath(p, 'System.DateTime', s.dateTime);
}

/// If `System.AlarmReset` is set, clear it and return true (one-shot). Level +
/// self-clear gives the same observable effect as a rising edge: each set
/// triggers exactly one reset.
bool consumeAlarmReset(PlcProject p) {
  ensureSystemTag(p);
  if (readPath(p, 'System.AlarmReset') == true) {
    writePath(p, 'System.AlarmReset', false);
    return true;
  }
  return false;
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/models/system_tags_test.dart`
Expected: PASS (4 tests).
Run: `flutter test test/tag_resolver_test.dart` — existing composite tests still pass.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/tag_resolver.dart mobile/lib/models/system_tags.dart mobile/test/models/system_tags_test.dart
git commit -m "feat(system): SYSTEM built-in composite + pure system-tag ensure/update/reset"
```

---

## Phase B — Shell scan integration, watchdog, free-run, fault lifecycle

### Task 5: Scheduler-driven `_executeScan` + per-task watchdog + System status write

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (state fields near `:63-71`; `_executeScan` `:208-217`; `_startScanLoop` `:199-206`; project load `:180-197`; `_switchActiveProject` `:219-246`)
- Test: `mobile/test/scan_scheduling_test.dart` (create)

**Interfaces:**
- Consumes: `scheduleTick`, `TaskSchedulerRuntime`, `DueTask` (Task 2); executor `only` param (Task 3); `ensureSystemTag`, `updateSystemStatus`, `consumeAlarmReset`, `SystemSnapshot` (Task 4); `readPath` (BOOL lookup).
- Produces: shell state `_scheduler`, `_freeRun`, `_faulted`, `_faultTaskName`, `_faultCode`, scan-time stats; a scheduler-driven `_executeScan`. A run session resets the scheduler + stats.

> Because much of this is `StatefulWidget` glue, the implementer must read the surrounding `workspace_shell.dart` regions before editing. The **behavioral contract** below is what the test asserts; keep those names/effects exact.

- [ ] **Step 1: Write the failing test**

The pure decision logic is already covered by `task_scheduler_test.dart`. Here we test the **shell-level BOOL lookup + scan-time/first-scan snapshot** via a small pure helper we extract, so the scan tick is testable without pumping a widget. Create `mobile/test/scan_scheduling_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/task_scheduler.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

void main() {
  test('runScanTick runs only due programs and reports timing/first-scan', () {
    final p = PlcProject(id: 'x', name: 'x');
    p.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'));
    p.tags.add(PlcTag(name: 'Btn', path: 'Btn', dataType: 'BOOL', value: false, ioType: 'Internal'));
    p.programs.add(PlcProgram(name: 'Boot', language: 'StructuredText', stSource: 'A := TRUE;'));
    p.tasks.add(PlcTask(name: 'BootTask', type: 'Startup', programNames: ['Boot']));
    p.tasks.add(PlcTask(name: 'Main', type: 'Continuous', programNames: ['Boot']));

    final rt = ScanTickRuntime();
    // First tick: firstScan true, Boot runs (startup), A set.
    final r1 = runScanTick(p, 100, rt);
    expect(r1.firstScan, isTrue);
    expect(readPath(p, 'A'), true);
    expect(r1.faulted, isFalse);

    // Second tick: firstScan false.
    final r2 = runScanTick(p, 100, rt);
    expect(r2.firstScan, isFalse);
  });

  test('runScanTick faults when a task exceeds its watchdog', () {
    final p = PlcProject(id: 'x', name: 'x');
    p.programs.add(PlcProgram(name: 'Slow', language: 'StructuredText', stSource: '// nop'));
    // watchdogMs of 0 = disabled; use a negative sentinel budget to force a trip
    // deterministically via the injectable clock in ScanTickRuntime (see impl).
    p.tasks.add(PlcTask(name: 'SlowTask', type: 'Continuous', programNames: ['Slow'], watchdogMs: 1));
    final rt = ScanTickRuntime()..elapsedForTest = 5; // 5ms measured > 1ms budget
    final r = runScanTick(p, 100, rt);
    expect(r.faulted, isTrue);
    expect(r.faultTask, 'SlowTask');
    expect(r.faultCode, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/scan_scheduling_test.dart`
Expected: FAIL — `screens/scan_tick.dart` does not exist.

- [ ] **Step 3: Extract a testable scan-tick core (`scan_tick.dart`)**

Create `mobile/lib/screens/scan_tick.dart` — a pure-ish core that owns the per-tick scheduling + watchdog decision (no Flutter deps), so the shell just calls it. The watchdog uses a real `Stopwatch` in production but an injectable `elapsedForTest` override for deterministic tests.

```dart
import '../models/project_model.dart';
import '../models/sim_engine.dart';
import '../models/ld_exec.dart';
import '../models/fbd_exec.dart';
import '../models/sfc_exec.dart';
import '../models/st_exec.dart';
import '../models/task_scheduler.dart';
import '../models/tag_resolver.dart';

/// Holds the engine runtimes + scheduler state across ticks (owned by the shell).
class ScanTickRuntime {
  final SimRuntime sim = SimRuntime();
  final LdExecRuntime ld = LdExecRuntime();
  final FbdRuntime fbd = FbdRuntime();
  final SfcRuntime sfc = SfcRuntime();
  final StRuntime st = StRuntime();
  final TaskSchedulerRuntime scheduler = TaskSchedulerRuntime();

  /// When >= 0, used instead of a real Stopwatch as the measured per-task
  /// execution time (ms). Test-only; production leaves it at -1.
  int elapsedForTest = -1;

  void resetSession() {
    sim.byRuleId.clear();
    ld.clear();
    fbd.clear();
    sfc.clear();
    st.clear();
    scheduler.reset();
  }
}

/// Result of one scan tick: whether a watchdog faulted, and first-scan flag.
class ScanTickResult {
  final bool firstScan;
  final bool faulted;
  final String faultTask;
  final int faultCode;
  const ScanTickResult({
    required this.firstScan,
    required this.faulted,
    required this.faultTask,
    required this.faultCode,
  });
}

/// One scan: sim rules (always), then due tasks in priority order with per-task
/// watchdog timing. Stops at the first watchdog trip. Pure w.r.t. wall-clock
/// (timing is measured with a Stopwatch here, or overridden for tests).
ScanTickResult runScanTick(PlcProject p, int dtMs, ScanTickRuntime rt) {
  final firstScan = !rt.scheduler.startupFired;
  applySimRules(p, p.simRules, dtMs, rt.sim);

  final due = scheduleTick(
    p.tasks,
    dtMs,
    rt.scheduler,
    (path) => readPath(p, path) == true,
  );

  for (final task in due) {
    final only = task.programs.toSet();
    final sw = Stopwatch()..start();
    executeLdPrograms(p, dtMs, rt.ld, only: only);
    executeFbdPrograms(p, dtMs, rt.fbd, only: only);
    executeSfcPrograms(p, dtMs, rt.sfc, only: only);
    executeStPrograms(p, dtMs, rt.st, only: only);
    sw.stop();
    final elapsed = rt.elapsedForTest >= 0 ? rt.elapsedForTest : sw.elapsedMilliseconds;
    if (task.watchdogMs > 0 && elapsed > task.watchdogMs) {
      return ScanTickResult(
        firstScan: firstScan, faulted: true, faultTask: task.taskName, faultCode: 1);
    }
  }
  return ScanTickResult(
    firstScan: firstScan, faulted: false, faultTask: '', faultCode: 0);
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/scan_scheduling_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire the shell to `runScanTick` + System status**

In `workspace_shell.dart`:

1. Replace the five separate runtime fields (`_simRuntime`, `_ldRuntime`, `_fbdRuntime`, `_sfcRuntime`, `_stRuntime`) with a single `final ScanTickRuntime _scan = ScanTickRuntime();` — and update the several `.clear()` reset sites (search for `_ldRuntime.clear()`) to call `_scan.resetSession()`. Add imports for `scan_tick.dart` + `system_tags.dart`.
2. Add state fields:

```dart
bool _freeRun = false;
bool _faulted = false;
String _faultTaskName = '';
int _faultCode = 0;
double _lastScanMs = 0, _maxScanMs = 0, _minScanMs = 0;
int _sessionScans = 0;
final Stopwatch _uptime = Stopwatch();
final Stopwatch _sinceLast = Stopwatch();
```

3. Rewrite `_executeScan()`:

```dart
void _executeScan() {
  if (_faulted) {
    return;
  }
  final dtMs = _freeRun
      ? (_sinceLast.elapsedMilliseconds.clamp(0, 1000))
      : scanSpeedMs;
  _sinceLast
    ..reset()
    ..start();
  final tickSw = Stopwatch()..start();

  final result = runScanTick(_activeProject, dtMs, _scan);

  tickSw.stop();
  final now = DateTime.now();
  setState(() {
    scanCount++;
    _sessionScans++;
    _lastScanMs = tickSw.elapsedMicroseconds / 1000.0;
    if (_sessionScans == 1 || _lastScanMs > _maxScanMs) {
      _maxScanMs = _lastScanMs;
    }
    if (_sessionScans == 1 || _lastScanMs < _minScanMs) {
      _minScanMs = _lastScanMs;
    }
    if (result.faulted) {
      _faulted = true;
      _faultTaskName = result.faultTask;
      _faultCode = result.faultCode;
      isRunning = false;
    }
    updateSystemStatus(_activeProject, SystemSnapshot(
      fault: _faulted,
      faultTask: _faultTaskName,
      faultCode: _faultCode,
      running: isRunning && !_faulted,
      firstScan: result.firstScan,
      scanCount: _sessionScans,
      scanTimeMs: _lastScanMs,
      maxScanTimeMs: _maxScanMs,
      minScanTimeMs: _minScanMs,
      freeRun: _freeRun,
      uptimeMs: _uptime.elapsedMilliseconds,
      year: now.year, month: now.month, day: now.day,
      hour: now.hour, minute: now.minute, second: now.second,
      dateTime: _formatClock(now),
    ));
    if (consumeAlarmReset(_activeProject)) {
      _clearFault();
    }
  });
}

String _two(int v) => v.toString().padLeft(2, '0');
String _formatClock(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

void _clearFault() {
  _faulted = false;
  _faultTaskName = '';
  _faultCode = 0;
  _maxScanMs = 0;
  _minScanMs = 0;
}
```

4. In the run/pause toggle `onPressed` (`:1088`), when transitioning **stopped→running**, start a fresh session:

```dart
onPressed: () {
  setState(() {
    if (!isRunning) {
      _startRunSession();
    }
    isRunning = !isRunning;
  });
},
```

Add:

```dart
void _startRunSession() {
  _scan.resetSession();
  _sessionScans = 0;
  _lastScanMs = _maxScanMs = _minScanMs = 0;
  _uptime
    ..reset()
    ..start();
  _sinceLast
    ..reset()
    ..start();
}
```

5. In `_switchActiveProject` (`:219`), call `ensureSystemTag(proj);` and `_scan.resetSession();` (replace the individual runtime `.clear()` calls there). In the bootstrap load (`:181-194`), after `_allProjects = loadedProjects;`, call `for (final pr in loadedProjects) { ensureSystemTag(pr); }` so defaults and persisted projects all get the tag.

- [ ] **Step 6: Verify**

Run: `flutter test` (full suite green) and `flutter analyze` (No issues found!).

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/scan_tick.dart mobile/lib/screens/workspace_shell.dart mobile/test/scan_scheduling_test.dart
git commit -m "feat(scan): scheduler-driven scan tick + per-task watchdog + System status write"
```

---

### Task 6: Free-run toggle, fault banner, Clear Fault, supervisor poll

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (`_startScanLoop` `:199`; app-bar actions `:1123+`; add a fault banner + run-mode control)
- Test: `mobile/test/widgets/fault_banner_test.dart` (create)

**Interfaces:**
- Consumes: `_freeRun`, `_faulted`, `_clearFault`, `_startRunSession`, `consumeAlarmReset`.
- Produces: a fixed/free-run run loop; a fault banner with a **Clear Fault** button; a run-mode toggle; a supervisor poll that observes external `System.AlarmReset` writes while faulted.

- [ ] **Step 1: Write the failing widget test**

Create `mobile/test/widgets/fault_banner_test.dart`. It pumps the shell into a faulted state and taps Clear Fault. (The implementer wires a test ent/hook: expose `@visibleForTesting void debugForceFault(String task)` on the shell state, or drive it via a public constructor flag. Keep the assertions below exact.)

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  testWidgets('fault banner shows task name and Clear Fault dismisses it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugForceFault('PumpTask');
    await tester.pump();

    expect(find.textContaining('PumpTask'), findsWidgets);
    expect(find.text('Clear Fault'), findsOneWidget);

    await tester.tap(find.text('Clear Fault'));
    await tester.pump();
    expect(find.text('Clear Fault'), findsNothing);
  });
}
```

> If the shell's `State` class is private (`_WorkspaceShellState`), the implementer renames it to a public `WorkspaceShellState` (or adds a `@visibleForTesting` accessor) so the test can reach `debugForceFault`. Add:
> ```dart
> @visibleForTesting
> void debugForceFault(String task) => setState(() {
>   _faulted = true; _faultTaskName = task; _faultCode = 1; isRunning = false;
> });
> ```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/fault_banner_test.dart`
Expected: FAIL — no fault banner / `debugForceFault` yet.

- [ ] **Step 3: Implement free-run loop + banner + supervisor**

1. `_startScanLoop` becomes mode-aware. Fixed mode keeps `Timer.periodic`; free-run re-arms a zero-delay timer each tick so the UI can paint, and a slow **supervisor** timer always runs to catch external AlarmReset writes while faulted:

```dart
void _startScanLoop() {
  _scanTimer?.cancel();
  if (_freeRun) {
    void arm() {
      _scanTimer = Timer(Duration.zero, () {
        if (isRunning && !_faulted) {
          _executeScan();
        }
        arm();
      });
    }
    arm();
  } else {
    _scanTimer = Timer.periodic(Duration(milliseconds: scanSpeedMs), (t) {
      if (isRunning && !_faulted) {
        _executeScan();
      }
    });
  }
  _supervisorTimer?.cancel();
  _supervisorTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
    if (_faulted && consumeAlarmReset(_activeProject)) {
      setState(_clearFault);
    }
  });
}
```

Add `Timer? _supervisorTimer;` state and cancel it in `dispose`. Call `_startScanLoop()` again after toggling `_freeRun` so the loop switches modes.

2. Add a run-mode toggle to the app-bar actions (both compact + expanded return lists) — an `IconButton` toggling `_freeRun` with tooltip `Free-run (as fast as allowed)` / `Fixed scan`:

```dart
IconButton(
  icon: Icon(_freeRun ? Icons.fast_forward : Icons.timer_outlined,
      color: _freeRun ? Colors.orangeAccent : Colors.grey, size: 24),
  tooltip: _freeRun ? 'Free-run (as fast as allowed)' : 'Fixed scan (${scanSpeedMs}ms)',
  onPressed: () {
    setState(() => _freeRun = !_freeRun);
    _startScanLoop();
  },
),
```

3. Add a fault banner above the center workspace (in `build`, wrap the body so the banner sits at the top when `_faulted`). Use `MaterialBanner` or a `Container`:

```dart
if (_faulted)
  MaterialBanner(
    backgroundColor: Colors.red.shade900,
    content: Text('PLC FAULT — watchdog on task "$_faultTaskName" (code $_faultCode). '
        'Scan halted.', style: const TextStyle(color: Colors.white)),
    leading: const Icon(Icons.warning_amber, color: Colors.white),
    actions: [
      TextButton(
        onPressed: () {
          setState(() {
            writePath(_activeProject, 'System.AlarmReset', true);
            consumeAlarmReset(_activeProject);
            _clearFault();
          });
        },
        child: const Text('Clear Fault', style: TextStyle(color: Colors.white)),
      ),
    ],
  ),
```

(Import `writePath`/`consumeAlarmReset`. Clear Fault pulses `System.AlarmReset` so logic/HMI observers see the reset too, then clears shell fault state. The PLC stays stopped; the user presses Run to resume — which calls `_startRunSession`.)

- [ ] **Step 4: Run tests**

Run: `flutter test test/widgets/fault_banner_test.dart`
Expected: PASS.
Run: `flutter test` + `flutter analyze` — full suite green, no issues.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/test/widgets/fault_banner_test.dart
git commit -m "feat(scan): free-run mode + watchdog fault banner + Clear Fault + supervisor poll"
```

---

## Phase D — Task-management & Add-Program UI

### Task 7: Add / edit / delete tasks (with no-orphan guard)

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (task tree folders `:1467-1470`, `_buildTaskCategoryFolder` `:1511`; add task dialogs)
- Test: `mobile/test/widgets/task_management_test.dart` (create)

**Interfaces:**
- Consumes: `_activeProject.tasks`, `_markDirtyAndAutosave`, the type-ahead tag field (WS7 Task 3 — find it via `grep` for the autocomplete field widget) for the Event `triggerTag` picker.
- Produces: `_showAddTaskDialog()`, `_showEditTaskDialog(PlcTask)`, `_deleteTask(PlcTask)` with orphan guard; per-folder Add-Task + per-task edit/delete affordances.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/task_management_test.dart` — drives the state methods directly (dialog UI is exercised in Step 3 manually; here we lock the **logic**: creating a task of each type, and the orphan guard).

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  testWidgets('addTask appends a task; deleteTask blocked if it would orphan', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    final before = state.debugActiveProject.tasks.length;
    state.debugAddTask(PlcTask(name: 'PollTask', type: 'Periodic', periodMs: 500, programNames: []));
    expect(state.debugActiveProject.tasks.length, before + 1);

    // A program that is ONLY in PollTask cannot be orphaned by deleting PollTask.
    final proj = state.debugActiveProject;
    proj.programs.add(PlcProgram(name: 'Lonely', language: 'StructuredText', stSource: ''));
    proj.tasks.firstWhere((t) => t.name == 'PollTask').programNames.add('Lonely');
    final blocked = state.debugDeleteTask(proj.tasks.firstWhere((t) => t.name == 'PollTask'));
    expect(blocked, isFalse); // delete refused
    expect(proj.tasks.any((t) => t.name == 'PollTask'), isTrue); // still there
  });
}
```

Add `@visibleForTesting` accessors on the state: `PlcProject get debugActiveProject => _activeProject;`, `void debugAddTask(PlcTask t) => setState(() => _activeProject.tasks.add(t));`, and `bool debugDeleteTask(PlcTask t) => _deleteTask(t);` where `_deleteTask` returns `true` if it deleted, `false` if refused.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/task_management_test.dart`
Expected: FAIL — accessors / `_deleteTask` not defined.

- [ ] **Step 3: Implement task CRUD**

Add to the shell state:

```dart
/// Delete [task], unless doing so would leave any of its programs in no task.
/// Returns true if deleted, false if refused (orphan guard).
bool _deleteTask(PlcTask task) {
  for (final prog in task.programNames) {
    final elsewhere = _activeProject.tasks
        .any((t) => t != task && t.programNames.contains(prog));
    if (!elsewhere) {
      return false; // 'prog' would be orphaned
    }
  }
  setState(() => _activeProject.tasks.remove(task));
  _markDirtyAndAutosave();
  return true;
}
```

Add `_showAddTaskDialog()` and `_showEditTaskDialog(PlcTask)` — an `AlertDialog` with: a name `TextField`; a type `DropdownButton` (`Startup`/`Continuous`/`Periodic`/`Event`); a `periodMs` field shown only when type == `Periodic`; the type-ahead tag field for `triggerTag` shown only when type == `Event`; a `watchdogMs` field; an `enabled` `Switch`. On save, add/update the task and `_markDirtyAndAutosave()`. When `_deleteTask` returns false, show a `SnackBar`: `Can't delete — "<prog>" would be left with no task. Assign it elsewhere first.`

Wire an **Add Task** `OutlinedButton.icon` next to the existing **Add New Program** button (`:1475`), and add edit/delete `IconButton`s (compact `iconSize`) to each task row inside `_buildTaskCategoryFolder`. Guard against RenderFlex overflow at 320/360 (wrap the row controls; use `Flexible`/`overflow: TextOverflow.ellipsis`).

- [ ] **Step 4: Run tests**

Run: `flutter test test/widgets/task_management_test.dart` → PASS.
Run: `flutter test` + `flutter analyze` → green / no issues.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/test/widgets/task_management_test.dart
git commit -m "feat(tasks): add/edit/delete tasks of all four types + no-orphan guard"
```

---

### Task 8: Add-Program dialog "＋ New task…" + run-mode readout + reserved-tag protection

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (`_showAddProgramDialog` `:1583-1650`)
- Modify: the Memory Manager screen (find via `grep -rl "MemoryManagerScreen"`) — protect the `System` tag from delete/rename; render status fields read-only.
- Test: `mobile/test/widgets/add_program_newtask_test.dart` (create)

**Interfaces:**
- Consumes: `_activeProject.tasks`, `kSystemTagName`.
- Produces: an Add-Program task selector that includes a "＋ New task…" branch creating a task inline and assigning the new program to it.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/add_program_newtask_test.dart` — assert the pure helper that the dialog uses to create + assign, so we don't fight dialog plumbing:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  testWidgets('adding a program with a new Periodic task files it under that task', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

    state.debugAddProgramToNewTask(
      programName: 'Housekeeping',
      language: 'StructuredText',
      taskName: 'HousekeepingTask',
      taskType: 'Periodic',
      periodMs: 1000,
    );

    final proj = state.debugActiveProject;
    expect(proj.programs.any((p) => p.name == 'Housekeeping'), isTrue);
    final task = proj.tasks.firstWhere((t) => t.name == 'HousekeepingTask');
    expect(task.type, 'Periodic');
    expect(task.periodMs, 1000);
    expect(task.programNames, contains('Housekeeping'));
  });
}
```

Add `@visibleForTesting void debugAddProgramToNewTask({...})` that mirrors the dialog's "＋ New task…" save path.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/add_program_newtask_test.dart`
Expected: FAIL — helper not defined.

- [ ] **Step 3: Implement**

In `_showAddProgramDialog`, replace the task `DropdownButton` (`:1615-1620`) with one whose items are the existing tasks **plus** a sentinel `'＋ New task…'`. When the sentinel is selected, reveal inline fields (task name, type dropdown, period/trigger as in Task 7). On **Add Program**:
- if an existing task is chosen → current behavior (assign to it);
- if "＋ New task…" → create the `PlcTask` (with type/period/trigger/watchdog), add it to `_activeProject.tasks`, then add the program and assign.

Factor the create+assign into `debugAddProgramToNewTask(...)` (also called by the dialog) so the test and UI share one path.

For the Memory Manager: locate where tags are deleted/renamed; add `if (tag.name == kSystemTagName) { return; }` guards (or hide the delete/rename affordance) and render the `System` tag's status fields as read-only (the existing tag inspector already shows composite children; ensure no edit control is offered for `System.*` except `AlarmReset`). Import `kSystemTagName` from `system_tags.dart`.

- [ ] **Step 4: Run tests**

Run: `flutter test test/widgets/add_program_newtask_test.dart` → PASS.
Run: `flutter test` + `flutter analyze` → green / no issues.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/screens/*memory* mobile/test/widgets/add_program_newtask_test.dart
git commit -m "feat(tasks): inline new-task creation in Add Program; protect reserved System tag"
```

---

## Phase E — Validation, docs, final review

### Task 9: Whole-workstream validation + docs + ROADMAP

**Files:**
- Create: `docs/protocols/` is protocol-only — instead create `docs/task-scheduling.md`
- Modify: `ROADMAP.md`
- Test: full suite

- [ ] **Step 1: Full green gate**

Run from `mobile/`:
- `flutter test` → all pass (report the count).
- `flutter analyze` → **No issues found!**
- `flutter build web --release` → compiles.

Fix anything that fails before proceeding.

- [ ] **Step 2: Round-trip guard**

Confirm the WS6 lossless round-trip test still passes (find it: `grep -rl "round" mobile/test | grep -i serial` or the persistence test). If it enumerates fields, ensure `trigger_tag`, `watchdog_ms`, and the `System` tag survive save→load. Add an assertion if the guard is field-driven.

- [ ] **Step 3: Manual responsive check**

Launch the app; verify no RenderFlex overflow at 320 / 360 / 1400 px on: the task tree with edit/delete controls, the Add-Task dialog, the Add-Program dialog with "＋ New task…" expanded, and the fault banner. Verify the run-mode toggle switches Fixed/Free-run and the fault banner clears via Clear Fault.

- [ ] **Step 4: Write `docs/task-scheduling.md`**

Document: the four task types + priority order; Continuous-skip-on-higher-due; Event rising-edge trigger; Periodic accumulation; the watchdog (per-task `watchdogMs`, fault+stop, Clear Fault / `System.AlarmReset`); free-run vs fixed scan; and the `System` UDT field table (status + control + wall clock). No vendor branding.

- [ ] **Step 5: Update ROADMAP + commit**

Add a ROADMAP entry marking the task scheduler / watchdog / free-run / system tags complete.

```bash
git add docs/task-scheduling.md ROADMAP.md
git commit -m "docs(scheduler): task-scheduling + System UDT reference; ROADMAP"
```

- [ ] **Step 6: Final whole-branch review**

Dispatch the final code review (opus) over the full branch diff; fix any Critical/Important findings; then finish the branch (merge `--no-ff` to main + push) per finishing-a-development-branch.

---

## Self-Review notes (author)

- **Spec coverage:** priority scheduler (T2), Continuous-skip (T2 tests), Event edge (T2), Periodic carry (T2), executor gating (T3), watchdog fault+stop (T5), free-run + measured dt (T5/T6), fault banner + Clear Fault + supervisor + AlarmReset recovery (T6), System UDT incl. wall clock (T4), ensure/back-fill on load (T5 wiring), task CRUD + no-orphan (T7), Add-Program new-task (T8), reserved-tag protection (T8), validation/docs (T9). All spec sections mapped.
- **Type consistency:** `scheduleTick`/`DueTask`/`TaskSchedulerRuntime` names identical across T2/T5; `only` param identical across T3/T5; `SystemSnapshot`/`ensureSystemTag`/`updateSystemStatus`/`consumeAlarmReset` identical across T4/T5/T6/T8; `_scan` (`ScanTickRuntime`) + `_startRunSession`/`_clearFault` consistent across T5/T6.
- **Ordering:** Phase C (System unit) is implemented **before** Phase B shell wiring because Task 5 writes System status — sequence is A(1-3) → C(4) → B(5-6) → D(7-8) → E(9).
