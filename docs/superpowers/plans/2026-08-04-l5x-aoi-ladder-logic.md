# Non-ST AOI Logic — RLL half + shared scoped-FB infra Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RLL-bodied Rockwell AOIs actually execute their ladder logic when imported, by giving `FbDefinition` a native ladder body, a scoped ladder executor (`LdScope`), and dispatch in `executeFbInstance` — the same infrastructure a future FBD-bodied AOI will reuse.

**Architecture:** `FbDefinition` gains `List<LdRung> ladderRungs` (non-empty ⇒ ladder-bodied, `stSource` ignored). `ld_exec.dart` gains `LdScope` (the exact ladder analog of `st_exec.dart`'s `StScope`) plus an optional `LdScope? scope` parameter on `executeRung` that is applied at **every** tag-path resolution site; `scope == null` is byte-identical to today. `runScopedLdBody` runs an FB's rungs under the synthetic program key `'fb:<instancePath>'` (sanitized program names can never contain `:`, so per-instance edge/pulse state is disjoint for free). `executeFbInstance` dispatches on `ladderRungs.isNotEmpty` and both engines thread their real `LdExecRuntime` + `dtMs` in. On the import side, an AOI whose `Logic` routine is RLL parses to a `NeutralLadderBody` (retaining `EnableIn`/`EnableOut` as internal vars) and `mapImportedFbs` compiles it with the existing `compileRllRungs`.

**Tech Stack:** Dart 3 / Flutter (package `soft_plc_mobile` in `mobile/`), `flutter_test`. Pure-Dart models + importers; the `xml` package stays confined to the parsers.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-27-l5x-aoi-ladder-logic-design.md`. Every § maps to a task below.
- **Pure Dart, in-app (ADR-010). Deterministic. Never-throws** — an AOI whose ladder cannot compile degrades to the existing empty-body no-op + warning; a runtime path that doesn't resolve reads 0/false.
- **Zero `flutter analyze` warnings.** Flutter is NOT on PATH: use `/c/flutter/bin/flutter`, run from `mobile/` (Bash tool).
- **Additive / backward-compatible:** every existing ST-bodied FB, the PLCopen import path, and all L5X foundation/RLL behaviour are unchanged. A project with no ladder-bodied FB behaves **byte-identically**. `FbDefinition` JSON round-trips; old saved projects (no `ladder_rungs` key) load unchanged; an ST-bodied FB must still serialize **without** a `ladder_rungs` key.
- **`scope == null` on `executeRung` must be byte-identical to today** — every existing caller passes no scope.
- **Runtime keying:** ladder FB bodies use the program key `'fb:$instancePath'`. Do not invent another scheme.
- **Do NOT use a copy-the-rungs approach** for scoping (no rewriting rung objects); scoping happens at read/write time.
- The `xml` package stays confined to `lib/import/*_parser.dart`; `rll_compile.dart` and the executors stay Flutter-free.
- **TDD:** every task writes the failing test first, watches it fail, then implements.
- Test command shape (from `mobile/`): `/c/flutter/bin/flutter test <path>`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `mobile/lib/models/project_model.dart` | `FbDefinition.ladderRungs` + JSON | 1 |
| `mobile/lib/models/ld_exec.dart` | `LdScope`, scoped `executeRung`, `runScopedLdBody` | 2, 4 |
| `mobile/lib/models/fb_exec.dart` | Body dispatch (ladder vs ST), recursion guard | 3 |
| `mobile/lib/models/fbd_exec.dart` | Threads `LdExecRuntime` to custom-FB calls | 4 |
| `mobile/lib/screens/scan_tick.dart` | Passes the shell's `LdExecRuntime` into FBD exec | 4 |
| `mobile/lib/import/l5x_parser.dart` | RLL AOI `Logic` → `NeutralLadderBody`; EnableIn/Out retention | 5 |
| `mobile/lib/import/rll_compile.dart` | AOI-call arity/binding over INTERFACE vars only | 5 |
| `mobile/lib/import/fb_import.dart` | `NeutralLadderBody` branch + compile counters | 5 |
| `mobile/lib/import/ir_to_project.dart` | Folds AOI-body counters into the RLL report fields | 5 |
| `docs/iec61131/FUNCTION_BLOCKS.md`, `docs/import/L5X.md`, `docs/DEFERRED.md` | Docs | 6 |

---

### Task 1: Model — `FbDefinition.ladderRungs`

**Model:** sonnet · **Effort:** medium

Implements spec §1.

**Files:**
- Modify: `mobile/lib/models/project_model.dart:200-224` (`FbDefinition`)
- Test: `mobile/test/models/fb_model_test.dart` (existing file — append tests)

**Interfaces:**
- Produces: `FbDefinition({required String name, List<FbVar>? vars, String stSource = '', List<LdRung>? ladderRungs})` with field `List<LdRung> ladderRungs` (never null, defaults `[]`). JSON key `'ladder_rungs'`, emitted **only when non-empty**. `LdRung` (same file, line ~322) already round-trips via `LdRung.toJson()` / `LdRung.fromJson(Map)`.

- [ ] **Step 1: Write the failing tests**

Append to `mobile/test/models/fb_model_test.dart` (inside the existing `void main() {`, after the last test):

```dart
  test('ladder-bodied FbDefinition round-trips its rungs', () {
    final fb = FbDefinition(name: 'Latch', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      LdRung(rungIndex: 0, comment: 'XIC(In)OTE(Out)', nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'm0', kind: LdKind.contact, variable: 'In'),
        LdNode(id: 'm1', kind: LdKind.coil, variable: 'Out'),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [
        LdWire(fromId: 'L', toId: 'm0'),
        LdWire(fromId: 'm0', toId: 'm1'),
        LdWire(fromId: 'm1', toId: 'R'),
      ]),
    ]);

    final rt = FbDefinition.fromJson(fb.toJson());
    expect(rt.ladderRungs, hasLength(1));
    expect(rt.ladderRungs.single.rungIndex, 0);
    expect(rt.ladderRungs.single.comment, 'XIC(In)OTE(Out)');
    expect(rt.ladderRungs.single.nodes.map((n) => n.id), ['L', 'm0', 'm1', 'R']);
    expect(rt.ladderRungs.single.nodes[1].variable, 'In');
    expect(rt.ladderRungs.single.wires, hasLength(3));
    expect(rt.stSource, ''); // ladder-bodied FBs carry no ST source
  });

  test('an ST-bodied FbDefinition serializes with NO ladder_rungs key (byte-identical)', () {
    final fb = FbDefinition(name: 'Scaler', stSource: 'Out := In * 2.0;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final json = fb.toJson();
    expect(json.containsKey('ladder_rungs'), isFalse);
    expect(json.keys.toList(), ['name', 'vars', 'st_source']);
    expect(fb.ladderRungs, isEmpty);
  });

  test('legacy JSON without ladder_rungs loads with an empty ladder body', () {
    final rt = FbDefinition.fromJson({
      'name': 'Old',
      'vars': [
        {'name': 'In', 'data_type': 'BOOL', 'direction': 'input', 'initial_value': null},
      ],
      'st_source': 'Out := In;',
    });
    expect(rt.ladderRungs, isEmpty);
    expect(rt.stSource, 'Out := In;');
    expect(rt.vars.single.name, 'In');
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `mobile/`): `/c/flutter/bin/flutter test test/models/fb_model_test.dart`
Expected: FAIL — compile error `The named parameter 'ladderRungs' isn't defined` / `The getter 'ladderRungs' isn't defined for the class 'FbDefinition'`.

- [ ] **Step 3: Add the field, constructor param, and JSON**

In `mobile/lib/models/project_model.dart`, replace the whole `FbDefinition` class (lines 200-224):

```dart
class FbDefinition {
  String name;
  List<FbVar> vars;
  String stSource;
```

with:

```dart
class FbDefinition {
  String name;
  List<FbVar> vars;
  String stSource;

  /// Native ladder body. Non-empty => this FB is LADDER-bodied: [stSource] is
  /// ignored and these rungs run scoped to the instance (see `fb_exec.dart`
  /// and `ld_exec.dart`'s `runScopedLdBody`). Empty (the default) => the
  /// existing ST path, byte-identical. `LdRung` is declared further down this
  /// file and already round-trips (it backs `PlcProgram.rungs`).
  List<LdRung> ladderRungs;
```

Then replace the constructor + `fromJson` + `toJson` (lines 205-224) — old:

```dart
  FbDefinition({
    required this.name,
    List<FbVar>? vars,
    this.stSource = '',
  }) : vars = vars ?? [];

  factory FbDefinition.fromJson(Map<String, dynamic> json) {
    return FbDefinition(
      name: json['name'] ?? '',
      vars: (json['vars'] as List? ?? []).map((v) => FbVar.fromJson(v)).toList(),
      stSource: json['st_source'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'vars': vars.map((v) => v.toJson()).toList(),
    'st_source': stSource,
  };
}
```

new:

```dart
  FbDefinition({
    required this.name,
    List<FbVar>? vars,
    this.stSource = '',
    List<LdRung>? ladderRungs,
  })  : vars = vars ?? [],
        ladderRungs = ladderRungs ?? [];

  factory FbDefinition.fromJson(Map<String, dynamic> json) {
    return FbDefinition(
      name: json['name'] ?? '',
      vars: (json['vars'] as List? ?? []).map((v) => FbVar.fromJson(v)).toList(),
      stSource: json['st_source'] ?? '',
      ladderRungs: (json['ladder_rungs'] as List? ?? [])
          .map((r) => LdRung.fromJson(r))
          .toList(),
    );
  }

  // `ladder_rungs` is emitted ONLY when non-empty so an ST-bodied FB's JSON is
  // byte-identical to what shipped before this feature (old projects reload
  // unchanged, and diffs of existing projects stay clean).
  Map<String, dynamic> toJson() => {
    'name': name,
    'vars': vars.map((v) => v.toJson()).toList(),
    'st_source': stSource,
    if (ladderRungs.isNotEmpty)
      'ladder_rungs': ladderRungs.map((r) => r.toJson()).toList(),
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/c/flutter/bin/flutter test test/models/fb_model_test.dart`
Expected: PASS — all tests in the file (including the three pre-existing ones).

- [ ] **Step 5: Run the serialization + FB regression suites**

Run: `/c/flutter/bin/flutter test test/serialization_roundtrip_test.dart test/models/fb_exec_test.dart test/models/fb_instance_tag_test.dart test/fb_editor_test.dart`
Expected: PASS, no change in counts.

- [ ] **Step 6: Analyze**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/test/models/fb_model_test.dart
git commit -m "feat(model): FbDefinition.ladderRungs (native ladder FB body) + JSON round-trip

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Scoped ladder executor — `LdScope`, `executeRung(scope:)`, `runScopedLdBody`

**Model:** opus · **Effort:** high

Implements spec §2. This is the load-bearing task: **every** tag-path resolution site in `executeRung` must go through the scope, and the null-scope path must stay byte-identical.

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart` (add `LdScope` after `LdExecRuntime` at line 17; `_operandValue` at 40-53; `executeRung` at 95-461; add `runScopedLdBody` at end of file)
- Test: `mobile/test/models/ld_scope_test.dart` (new)

**Interfaces:**
- Consumes: `FbDefinition.ladderRungs` (Task 1) is not needed here; this task only touches ladder execution.
- Produces:
  - `class LdScope { final String instancePath; final Set<String> localVars; LdScope(this.instancePath, this.localVars); String rewrite(String path); }`
  - `void executeRung(PlcProject p, String progName, LdRung rung, int dtMs, LdExecRuntime rt, void Function(String path, dynamic value) write, {LdMonitor? monitor, LdScope? scope})`
  - `void runScopedLdBody(PlcProject p, List<LdRung> rungs, LdScope scope, int dtMs, LdExecRuntime rt)` — runs `rungs` under program key `'fb:${scope.instancePath}'` with force-aware writes.
  - `double _operandValue(PlcProject p, String s, [LdScope? scope])` (library-private; listed so Task 4's reader knows the shape).

**The complete list of tag-path sites to scope** (verified by reading `ld_exec.dart` in full): contact `n.variable` read; coil `n.variable` write (all 6 modifier branches); block `base` (= `n.variable`, feeds every `$base.*` timer/counter member path); compare `operandA`/`operandB`; math `operandA`/`operandB` **and** the destination `n.variable` (both the `_rootTagOf` type probe and the `write`); `CTUD`'s `n.operandA` down-input read; the custom-FB branch's `pinBindings` input values, its instance name (`n.variable`), and its output-write target tags. Nothing else in the function touches a tag path.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/models/ld_scope_test.dart`:

```dart
// Scoped ladder execution: LdScope's path rewriting, executeRung's optional
// `scope`, and runScopedLdBody. The null-scope regression test is the
// backward-compat guard — every existing caller passes no scope.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal',
        isForced: forced, forcedValue: fv);

/// Builds the structural default Map for [fbName] from [fb] alone.
Map<String, dynamic> _instanceValue(FbDefinition fb) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
  return Map<String, dynamic>.from(
      defaultValueFor(defaults, fb.name, 0) as Map);
}

/// BOOL-in / BOOL-out FB, used for its var NAMES + instance struct shape.
FbDefinition _gateFb() => FbDefinition(name: 'Gate', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);

/// One rung: L -- In(contact) -- Out(coil) -- R.
LdRung _gateRung() => buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'In'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
    ]);

void main() {
  test('LdScope.rewrite maps FB-var roots (bare, dotted, indexed) and leaves globals', () {
    final s = LdScope('A1', {'In', 'T', 'Buf'});
    expect(s.rewrite('In'), 'A1.In');
    expect(s.rewrite('T.ACC'), 'A1.T.ACC');
    expect(s.rewrite('Buf[2]'), 'A1.Buf[2]');
    expect(s.rewrite('Buf[2].X'), 'A1.Buf[2].X');
    expect(s.rewrite('GlobalTag'), 'GlobalTag');
    expect(s.rewrite('Other.In'), 'Other.In'); // the ROOT segment decides
    expect(LdScope('A1.Inner', {'In'}).rewrite('In'), 'A1.Inner.In'); // nested
  });

  test('a scoped rung reads/writes the instance struct, never the same-named globals', () {
    final fb = _gateFb();
    final inst = _instanceValue(fb)..['In'] = true;
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('In', 'BOOL', false), _tag('Out', 'BOOL', false), _tag('A1', 'Gate', inst)],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    executeRung(p, 'fb:A1', _gateRung(), 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('A1', {'In', 'Out'}));

    expect(readPath(p, 'A1.Out'), isTrue); // instance In(true) drove instance Out
    expect(readPath(p, 'Out'), isFalse);   // same-named global untouched
  });

  test('scope == null is byte-identical to today: the SAME rung hits globals only', () {
    final fb = _gateFb();
    final inst = _instanceValue(fb)..['In'] = false;
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('In', 'BOOL', true), _tag('Out', 'BOOL', false), _tag('A1', 'Gate', inst)],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    executeRung(p, 'P1', _gateRung(), 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v));

    expect(readPath(p, 'Out'), isTrue);     // global In(true) drove global Out
    expect(readPath(p, 'A1.Out'), isFalse); // instance untouched
  });

  test('a compare operand that names an FB var is scoped; a numeric literal is not', () {
    final fb = FbDefinition(name: 'Cmp', vars: [
      FbVar(name: 'Level', dataType: 'FLOAT64', direction: FbVarDir.internal, initialValue: 7.0),
      FbVar(name: 'Hi', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Level', 'FLOAT64', 0.0), // global decoy: would make 'Level > 5' false
          _tag('Hi', 'BOOL', false),
          _tag('C1', 'Cmp', _instanceValue(fb)),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'GT', operandA: 'Level', operandB: '5'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Hi'),
    ]);
    executeRung(p, 'fb:C1', rung, 100, LdExecRuntime(),
        (path, v) => writePath(p, path, v),
        scope: LdScope('C1', {'Level', 'Hi'}));

    expect(readPath(p, 'C1.Hi'), isTrue); // C1.Level(7) > literal 5
    expect(readPath(p, 'Hi'), isFalse);   // global untouched
  });

  test('a scoped timer accumulates inside the instance, not in a same-named global', () {
    final fb = FbDefinition(name: 'Del', vars: [
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Q', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final base = PlcProject(id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('T', 'TIMER', defaultValueFor(base, 'TIMER', 0)), // global decoy
          _tag('Q', 'BOOL', false),
          _tag('D1', 'Del', _instanceValue(fb)),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
      LdNode(id: '', kind: LdKind.coil, variable: 'Q'),
    ]);
    final rt = LdExecRuntime();
    final scope = LdScope('D1', {'T', 'Q'});
    executeRung(p, 'fb:D1', rung, 100, rt, (path, v) => writePath(p, path, v), scope: scope);
    executeRung(p, 'fb:D1', rung, 100, rt, (path, v) => writePath(p, path, v), scope: scope);

    expect(readPath(p, 'D1.T.ACC'), 200);
    expect(readPath(p, 'D1.T.PRE'), 300);
    expect(readPath(p, 'D1.Q'), isFalse);  // 200 < 300
    expect(readPath(p, 'T.ACC'), 0);       // global timer never touched
  });

  test('runScopedLdBody runs every rung scoped and keeps writes force-aware', () {
    final fb = FbDefinition(name: 'Sig', vars: [
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('S1', 'Sig', _instanceValue(fb)),
          _tag('Lamp', 'BOOL', false),                            // plain global
          _tag('Locked', 'BOOL', false, forced: true, fv: false), // forced global
        ],
        structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

    // Rung 0: L -- Out(coil) -- R   (scoped -> S1.Out)
    // Rung 1: L -- Lamp(coil) -- R  (not an FB var -> global)
    // Rung 2: L -- Locked(coil) -- R (global, forced false: force must win)
    final rungs = [
      buildRung(index: 0, main: [LdNode(id: '', kind: LdKind.coil, variable: 'Out')]),
      buildRung(index: 1, main: [LdNode(id: '', kind: LdKind.coil, variable: 'Lamp')]),
      buildRung(index: 2, main: [LdNode(id: '', kind: LdKind.coil, variable: 'Locked')]),
    ];

    runScopedLdBody(p, rungs, LdScope('S1', {'Out'}), 100, LdExecRuntime());

    expect(readPath(p, 'S1.Out'), isTrue); // scoped write landed in the instance
    expect(readPath(p, 'Lamp'), isTrue);   // non-var reference fell through global
    expect(readPath(p, 'Locked'), isFalse); // force wins over executed logic
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `mobile/`): `/c/flutter/bin/flutter test test/models/ld_scope_test.dart`
Expected: FAIL — compile errors `Undefined class 'LdScope'`, `No named parameter with the name 'scope'`, `The function 'runScopedLdBody' isn't defined`.

- [ ] **Step 3: Add `LdScope`**

In `mobile/lib/models/ld_exec.dart`, insert immediately after the `LdExecRuntime` class (after line 17, before `PlcTag? _rootTagOf`):

```dart
/// Scopes ladder execution to one FB instance: bare references to the FB's own
/// vars resolve/write against `<instancePath>.<var>` instead of a global tag
/// path. Mirrors `StScope` (st_exec.dart) exactly — same root-segment test,
/// same "anything else falls through global" rule.
class LdScope {
  final String instancePath; // e.g. 'A1' (or 'A1.Inner' for a nested FB call)
  final Set<String> localVars; // the FB's var names

  LdScope(this.instancePath, this.localVars);

  /// Rewrites a tag path into the instance's namespace when its root segment
  /// is one of this scope's local vars (handles `x`, `x.y`, and `x[i]`);
  /// otherwise the path is left untouched (falls through global).
  String rewrite(String path) {
    final root = path.split('.').first.split('[').first;
    return localVars.contains(root) ? '$instancePath.$path' : path;
  }
}
```

- [ ] **Step 4: Scope `_operandValue`**

Replace lines 37-45 of `mobile/lib/models/ld_exec.dart`:

```dart
/// Resolves a compare/math operand: a numeric literal parses directly,
/// otherwise it is treated as a tag path. Never throws — a non-numeric or
/// absent tag resolves to 0.
double _operandValue(PlcProject p, String s) {
  final lit = num.tryParse(s);
  if (lit != null) {
    return lit.toDouble();
  }
  final v = readPath(p, s);
```

with:

```dart
/// Resolves a compare/math operand: a numeric literal parses directly,
/// otherwise it is treated as a tag path (scoped through [scope] when one is
/// supplied — a LITERAL is parsed first and is therefore never rewritten).
/// Never throws — a non-numeric or absent tag resolves to 0.
double _operandValue(PlcProject p, String s, [LdScope? scope]) {
  final lit = num.tryParse(s);
  if (lit != null) {
    return lit.toDouble();
  }
  final v = readPath(p, scope == null ? s : scope.rewrite(s));
```

- [ ] **Step 5: Add the `scope` parameter + the `sp` path helper to `executeRung`**

Replace lines 95-98:

```dart
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write,
    {LdMonitor? monitor}) {
  final col = colAssignment(rung);
```

with:

```dart
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write,
    {LdMonitor? monitor, LdScope? scope}) {
  // EVERY tag path this rung touches goes through `sp`. With no scope it is
  // the identity, so program-rung execution is byte-identical to before this
  // feature; inside an FB body it maps the FB's own var names into the
  // instance struct. Runtime/monitor state keys are NOT scoped here — the
  // caller supplies a per-instance `progName` (see `runScopedLdBody`).
  String sp(String path) => scope == null ? path : scope.rewrite(path);
  final col = colAssignment(rung);
```

- [ ] **Step 6: Scope the contact read**

Replace line 130:

```dart
        final val = readPath(p, n.variable) == true;
```

with:

```dart
        final val = readPath(p, sp(n.variable)) == true;
```

- [ ] **Step 7: Scope the coil writes**

Replace the coil case body (lines 151-181) — old:

```dart
      case LdKind.coil:
        final inP = inputPower(n);
        power[n.id] = inP;
        elemTrue[n.id] = inP; // glow when this coil is energized
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
```

new:

```dart
      case LdKind.coil:
        final inP = inputPower(n);
        power[n.id] = inP;
        elemTrue[n.id] = inP; // glow when this coil is energized
        final key = '$progName|${rung.rungIndex}|${n.id}';
        final prevP = rt.prevBool[key] ?? inP;
        rt.prevBool[key] = inP;
        final target = sp(n.variable);
        switch (n.modifier) {
          case 'negated':
            write(target, !inP);
            break;
          case 'set':
            if (inP) {
              write(target, true);
            }
            break;
          case 'reset':
            if (inP) {
              write(target, false);
            }
            break;
          case 'rising':
            write(target, inP && !prevP); // one-scan pulse on power edge
            break;
          case 'falling':
            write(target, !inP && prevP);
            break;
          default:
            write(target, inP); // OTE
        }
        break;
```

- [ ] **Step 8: Scope the block `base` (all `$base.*` timer/counter member paths)**

Replace line 184:

```dart
        final base = n.variable;
```

with:

```dart
        // Scoping `base` is what moves an FB-local timer/counter's `.ACC`/
        // `.PRE`/`.CV` members inside the instance (`T` -> `A1.T`).
        final base = sp(n.variable);
```

- [ ] **Step 9: Scope compare + math operands and the math destination**

Replace lines 192-193:

```dart
          final a = _operandValue(p, n.operandA);
          final b = _operandValue(p, n.operandB);
```

with:

```dart
          final a = _operandValue(p, n.operandA, scope);
          final b = _operandValue(p, n.operandB, scope);
```

Replace lines 221-222 (inside the `mathOps` branch):

```dart
            final a = _operandValue(p, n.operandA);
            final b = _operandValue(p, n.operandB);
```

with:

```dart
            final a = _operandValue(p, n.operandA, scope);
            final b = _operandValue(p, n.operandB, scope);
```

Replace lines 240-243:

```dart
            final outRoot = _rootTagOf(p, n.variable);
            final dynamic outVal =
                outRoot != null && isIntegerType(outRoot.dataType) ? r.truncate() : r;
            write(n.variable, outVal);
```

with:

```dart
            // NOTE: the integer-truncation probe stays a ROOT-tag lookup (not
            // a per-member type walk) so global behaviour is unchanged — a
            // dotted destination (`Struct.Member`, and now `A1.Var`) already
            // did not truncate before this feature. Tracked in
            // docs/DEFERRED.md.
            final dest = sp(n.variable);
            final outRoot = _rootTagOf(p, dest);
            final dynamic outVal =
                outRoot != null && isIntegerType(outRoot.dataType) ? r.truncate() : r;
            write(dest, outVal);
```

- [ ] **Step 10: Scope the CTUD down-input read**

Replace line 335:

```dart
          final downIn = readPath(p, n.operandA) == true;
```

with:

```dart
          final downIn = readPath(p, sp(n.operandA)) == true;
```

- [ ] **Step 11: Scope the custom-FB call branch (pin bindings, instance name, output writes)**

Replace lines 371-376 — old:

```dart
          if (inP) {
            final inputs = <String, dynamic>{};
            for (final v in fb.vars) {
              if (v.direction == FbVarDir.input) {
                final tag = n.pinBindings[v.name];
                if (tag != null && tag.isNotEmpty) {
```

new (keep the long explanatory comment that follows in the file untouched):

```dart
          if (inP) {
            final inputs = <String, dynamic>{};
            for (final v in fb.vars) {
              if (v.direction == FbVarDir.input) {
                final raw = n.pinBindings[v.name];
                if (raw != null && raw.isNotEmpty) {
                  // Scoped so a nested FB call inside an FB body binds the
                  // OUTER FB's own vars. A literal binding is unaffected: its
                  // root segment can never match a var name.
                  final tag = sp(raw);
```

Then replace lines 398-404 — old:

```dart
            final outputs = executeFbInstance(p, fb, n.variable, inputs);
            outputs.forEach((name, value) {
              final tag = n.pinBindings[name];
              if (tag != null && tag.isNotEmpty && value != null) {
                write(tag, value);
              }
            });
```

new:

```dart
            // The instance name is scoped too: a nested call's instance var
            // lives inside the outer instance ('Inner' -> 'A1.Inner'), which
            // also keeps its 'fb:<path>' runtime keys disjoint.
            final outputs = executeFbInstance(p, fb, sp(n.variable), inputs);
            outputs.forEach((name, value) {
              final tag = n.pinBindings[name];
              if (tag != null && tag.isNotEmpty && value != null) {
                write(sp(tag), value);
              }
            });
```

- [ ] **Step 12: Add `runScopedLdBody`**

Append to the end of `mobile/lib/models/ld_exec.dart` (after `executeRung`'s closing brace):

```dart
/// Runs a ladder FB body scoped to one instance: every rung executes through
/// [executeRung] with [scope] applied to every tag path, under the synthetic
/// program key `'fb:<instancePath>'`. Sanitized program names can never
/// contain `:`, so these keys never collide with a real program's edge/pulse
/// state, and two instances of the same FB get disjoint state for free.
/// Writes are force-aware, exactly like program-rung execution. Placeholder
/// rungs (rails + one wire) execute as harmless no-ops. Never throws.
/// (The ladder analog of `runScopedStBody` in st_exec.dart.)
void runScopedLdBody(PlcProject p, List<LdRung> rungs, LdScope scope, int dtMs,
    LdExecRuntime rt) {
  final progKey = 'fb:${scope.instancePath}';
  for (final rung in rungs) {
    executeRung(p, progKey, rung, dtMs, rt,
        (path, v) => _forceAwareWrite(p, path, v), scope: scope);
  }
}
```

- [ ] **Step 13: Run the new tests**

Run: `/c/flutter/bin/flutter test test/models/ld_scope_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 14: Run the full ladder-execution regression set (byte-identical guard)**

Run: `/c/flutter/bin/flutter test test/ld_exec_test.dart test/ld_exec_integration_test.dart test/fb_ld_exec_test.dart test/ld_monitor_test.dart test/ld_online_highlight_test.dart test/ld_online_truestate_test.dart test/ld_online_values_test.dart test/models/executor_gating_test.dart test/models/executor_readonly_test.dart test/counter_loop_integration_test.dart test/pulse_loop_integration_test.dart test/import/ld_translate_exec_test.dart`
Expected: PASS, zero failures — this is the proof that `scope == null` changed nothing.

- [ ] **Step 15: Analyze**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 16: Commit**

```bash
git add mobile/lib/models/ld_exec.dart mobile/test/models/ld_scope_test.dart
git commit -m "feat(ld): LdScope + scoped executeRung + runScopedLdBody (null scope byte-identical)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `executeFbInstance` ladder dispatch

**Model:** opus · **Effort:** high

Implements spec §3's dispatch half (call-site threading is Task 4).

**Files:**
- Modify: `mobile/lib/models/fb_exec.dart` (whole file — it is 28 lines)
- Test: `mobile/test/models/fb_ladder_exec_test.dart` (new)

**Interfaces:**
- Consumes: `FbDefinition.ladderRungs` (Task 1); `LdScope`, `runScopedLdBody(PlcProject, List<LdRung>, LdScope, int dtMs, LdExecRuntime)`, `LdExecRuntime` (Task 2).
- Produces: `Map<String, dynamic> executeFbInstance(PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs, {int dtMs = 0, LdExecRuntime? ldRt})`. Existing 4-positional-arg callers keep compiling unchanged.

**Note on imports:** `fb_exec.dart` will import `ld_exec.dart`, which already imports `fb_exec.dart`. A mutual import between two Dart libraries is legal and used widely; there is no top-level initialization cycle here (both files only declare functions/classes plus one library-private `int` counter).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/models/fb_ladder_exec_test.dart`:

```dart
// Ladder-bodied FB dispatch: executeFbInstance runs `ladderRungs` scoped to
// the instance, with per-instance edge state ('fb:<instance>' keys) and
// per-instance timer accumulators. ST-bodied FBs are unaffected.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fb_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

Map<String, dynamic> _instanceValue(FbDefinition fb) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
  return Map<String, dynamic>.from(defaultValueFor(defaults, fb.name, 0) as Map);
}

PlcProject _proj(FbDefinition fb, List<String> instanceNames) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [for (final n in instanceNames) _tag(n, fb.name, _instanceValue(fb))],
      structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

/// Ladder-bodied threshold FB: `Out := In > 10`.
FbDefinition _threshFb() => FbDefinition(name: 'Thresh', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.block, blockType: 'GT', operandA: 'In', operandB: '10'),
        LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
      ]),
    ]);

/// Ladder-bodied edge detector: `Out` pulses for one call per rising `Trig`.
FbDefinition _edgeFb() => FbDefinition(name: 'Edge', vars: [
      FbVar(name: 'Trig', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Trig', modifier: 'rising'),
        LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
      ]),
    ]);

/// Ladder-bodied on-delay: an FB-local TIMER var accumulates per instance.
FbDefinition _delayFb() => FbDefinition(name: 'Delay', vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Done', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Run'),
        LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
        LdNode(id: '', kind: LdKind.coil, variable: 'Done'),
      ]),
    ]);

void main() {
  test('a ladder-bodied FB takes inputs, runs its rungs, and returns outputs', () {
    final fb = _threshFb();
    final p = _proj(fb, ['A1']);

    expect(executeFbInstance(p, fb, 'A1', {'In': 12.0})['Out'], isTrue);
    expect(readPath(p, 'A1.In'), 12.0);
    expect(executeFbInstance(p, fb, 'A1', {'In': 5.0})['Out'], isFalse);
  });

  test('two instances have independent edge state (disjoint "fb:<instance>" keys)', () {
    final fb = _edgeFb();
    final p = _proj(fb, ['A1', 'A2']);
    final rt = LdExecRuntime();

    // Scan 1: A1 already true (no spurious first-scan edge), A2 false.
    executeFbInstance(p, fb, 'A1', {'Trig': true}, ldRt: rt);
    executeFbInstance(p, fb, 'A2', {'Trig': false}, ldRt: rt);
    expect(readPath(p, 'A1.Out'), isFalse);
    expect(readPath(p, 'A2.Out'), isFalse);

    // Scan 2: both true. A1 has no edge (already true); A2 rises.
    // Had the two instances SHARED an edge key, this would be inverted.
    final o1 = executeFbInstance(p, fb, 'A1', {'Trig': true}, ldRt: rt);
    final o2 = executeFbInstance(p, fb, 'A2', {'Trig': true}, ldRt: rt);
    expect(o1['Out'], isFalse);
    expect(o2['Out'], isTrue);
  });

  test('a scoped TON accumulates per instance across calls using dtMs', () {
    final fb = _delayFb();
    final p = _proj(fb, ['D1', 'D2']);
    final rt = LdExecRuntime();

    for (var i = 0; i < 3; i++) {
      executeFbInstance(p, fb, 'D1', {'Run': true}, dtMs: 100, ldRt: rt);
    }
    executeFbInstance(p, fb, 'D2', {'Run': true}, dtMs: 100, ldRt: rt);

    expect(readPath(p, 'D1.T.ACC'), 300);
    expect(readPath(p, 'D1.Done'), isTrue);
    expect(readPath(p, 'D2.T.ACC'), 100);
    expect(readPath(p, 'D2.Done'), isFalse);
  });

  test('no ldRt still runs (ephemeral fallback) — only edge detection degrades', () {
    final fb = _delayFb();
    final p = _proj(fb, ['D1']);
    expect(() => executeFbInstance(p, fb, 'D1', {'Run': true}, dtMs: 100),
        returnsNormally);
    expect(readPath(p, 'D1.T.ACC'), 100);
  });

  test('an ST-bodied FB is unaffected by the new dispatch (regression)', () {
    final fb = FbDefinition(name: 'Accum', stSource: 'Sum := Sum + In; Out := Sum;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Sum', dataType: 'FLOAT64', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final p = _proj(fb, ['S1']);
    expect(executeFbInstance(p, fb, 'S1', {'In': 3.0})['Out'], 3.0);
    expect(executeFbInstance(p, fb, 'S1', {'In': 4.0})['Out'], 7.0);
  });

  test('an empty instance name still refuses to run (unchanged)', () {
    final fb = _threshFb();
    final p = _proj(fb, ['A1']);
    expect(executeFbInstance(p, fb, '', {'In': 12.0}), isEmpty);
  });

  test('a self-calling ladder FB is depth-capped instead of overflowing the stack', () {
    // Not reachable via import (the FB registry only holds FBs defined EARLIER
    // in the file), but reachable from hand-edited/legacy JSON. Never-throws.
    final fb = FbDefinition(name: 'Loop', vars: [
      FbVar(name: 'X', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Self', dataType: 'BOOL', direction: FbVarDir.internal),
    ]);
    fb.ladderRungs.add(buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.block, blockType: 'Loop', variable: 'Self',
          pinBindings: {'X': 'X'}),
    ]));
    final p = _proj(fb, ['L1']);
    expect(() => executeFbInstance(p, fb, 'L1', {'X': true}), returnsNormally);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/c/flutter/bin/flutter test test/models/fb_ladder_exec_test.dart`
Expected: FAIL — `No named parameter with the name 'ldRt'` / `'dtMs'`, and the ladder tests fail because `executeFbInstance` still runs the (empty) ST body.

- [ ] **Step 3: Rewrite `fb_exec.dart` with ladder dispatch**

Replace the entire contents of `mobile/lib/models/fb_exec.dart` with:

```dart
import 'project_model.dart';
import 'ld_exec.dart';
import 'st_exec.dart';
import 'tag_resolver.dart';

/// Maximum nesting depth of FB-inside-FB execution. A ladder-bodied FB can
/// call another FB (an AOI calling an AOI), so a cyclic definition graph —
/// unreachable from import (the FB registry only ever holds FBs defined
/// EARLIER in the file) but reachable from hand-edited/legacy JSON — would
/// otherwise recurse into the uncatchable `StackOverflowError`, breaking the
/// never-throws invariant. Beyond this depth the call is a no-op.
const int _kMaxFbCallDepth = 16;
int _fbCallDepth = 0;

/// Runs one FB instance for a single scan: writes [inputs] into the instance
/// struct, executes the FB's body scoped to that instance (bare vars resolve
/// to `<instanceName>.<var>`, else global), and returns the output-var values.
///
/// Body dispatch: a non-empty [FbDefinition.ladderRungs] runs the native
/// ladder body via `runScopedLdBody` — [dtMs] drives its timers and [ldRt]
/// carries its edge/pulse state (both engine call sites pass their real
/// runtime; the `LdExecRuntime()` fallback is unreachable in the scan and only
/// degrades edge detection if ever hit). Otherwise the existing scoped-ST path
/// runs, unchanged.
///
/// `readOnly` is deliberately not threaded into FB bodies — parity with the ST
/// path. Pure/deterministic; never throws.
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs,
    {int dtMs = 0, LdExecRuntime? ldRt}) {
  // An empty instance name has no struct to scope into: paths like `.In` would
  // strip to bare `In` and alias onto same-named GLOBAL tags. Refuse to run
  // rather than read/write unrelated globals (dangling/unbound binding).
  if (instanceName.isEmpty) return const {};
  if (_fbCallDepth >= _kMaxFbCallDepth) return const {};
  _fbCallDepth++;
  try {
    // 1. Write inputs into the instance struct.
    for (final v in fb.vars) {
      if (v.direction == FbVarDir.input && inputs.containsKey(v.name)) {
        writePath(p, '$instanceName.${v.name}', inputs[v.name]);
      }
    }
    // 2. Run the scoped body.
    final varNames = {for (final v in fb.vars) v.name};
    if (fb.ladderRungs.isNotEmpty) {
      runScopedLdBody(p, fb.ladderRungs, LdScope(instanceName, varNames), dtMs,
          ldRt ?? LdExecRuntime());
    } else {
      runScopedStBody(p, fb.stSource, StScope(instanceName, varNames));
    }
    // 3. Read outputs out.
    return {
      for (final v in fb.vars)
        if (v.direction == FbVarDir.output) v.name: readPath(p, '$instanceName.${v.name}'),
    };
  } finally {
    _fbCallDepth--;
  }
}
```

- [ ] **Step 4: Run the new tests**

Run: `/c/flutter/bin/flutter test test/models/fb_ladder_exec_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the FB + engine regression set**

Run: `/c/flutter/bin/flutter test test/models/fb_exec_test.dart test/fb_ld_exec_test.dart test/fb_fbd_exec_test.dart test/hysteresis_fb_demo_test.dart test/models/ld_scope_test.dart`
Expected: PASS.

- [ ] **Step 6: Analyze**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/fb_exec.dart mobile/test/models/fb_ladder_exec_test.dart
git commit -m "feat(fb): executeFbInstance dispatches ladder bodies (dtMs/ldRt, fb: keys, depth cap)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Engine threading — ld_exec call site, `executeFbdPrograms(ldRt:)`, `scan_tick`

**Model:** opus · **Effort:** medium

Implements spec §3's call-site-threading half.

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart` (the FB-call `executeFbInstance` line inside `executeRung`)
- Modify: `mobile/lib/models/fbd_exec.dart:1-5` (import), `:167-174` (`_evalBlock` signature), `:197` (custom-FB branch), `:528` (`executeFbdPrograms` signature), `:637` and `:649` (both `_evalBlock` call sites)
- Modify: `mobile/lib/screens/scan_tick.dart:77`
- Test: `mobile/test/models/fb_ladder_engine_test.dart` (new)

**Interfaces:**
- Consumes: `executeFbInstance(..., {int dtMs = 0, LdExecRuntime? ldRt})` (Task 3); `LdExecRuntime` (existing).
- Produces: `void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt, {Set<String>? only, Set<String>? readOnly, FbdMonitor? monitor, LdExecRuntime? ldRt})` — existing callers that omit `ldRt` still compile and still run (ephemeral fallback inside `executeFbInstance`).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/models/fb_ladder_engine_test.dart`:

```dart
// Engine threading: both engines hand their real dtMs + LdExecRuntime to a
// ladder-bodied FB, so an FB-local TON accumulates across scans instead of
// restarting every scan.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

/// Ladder-bodied on-delay FB with an instance-local TIMER var.
FbDefinition _delayFb() => FbDefinition(name: 'Delay', vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Done', dataType: 'BOOL', direction: FbVarDir.output),
    ], ladderRungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Run'),
        LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'T', presetMs: 300),
        LdNode(id: '', kind: LdKind.coil, variable: 'Done'),
      ]),
    ]);

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

Map<String, dynamic> _instanceValue(FbDefinition fb) {
  final defaults = PlcProject(id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);
  return Map<String, dynamic>.from(defaultValueFor(defaults, fb.name, 0) as Map);
}

void main() {
  test('an LD program calling a ladder FB threads dtMs + runtime into the body', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'P1', language: 'LadderLogic', rungs: [
      buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Start'),
        LdNode(id: '', kind: LdKind.block, blockType: 'Delay', variable: 'D1',
            pinBindings: {'Run': 'Start', 'Done': 'Lamp'}),
      ]),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Start', 'BOOL', true),
          _tag('Lamp', 'BOOL', false),
          _tag('D1', 'Delay', _instanceValue(fb)),
        ],
        structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb]);

    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'D1.T.ACC'), 100); // NOT restarted at 0 each scan
    executeLdPrograms(p, 100, rt);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'D1.T.ACC'), 300);
    expect(readPath(p, 'D1.Done'), isTrue);
    expect(readPath(p, 'Lamp'), isTrue); // output pin written back out
  });

  test('an FBD program calling a ladder FB threads dtMs + the supplied ldRt', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: '', tagBinding: 'Start'),
      FbdBlock(id: 'd1', type: 'Delay', title: '', tagBinding: 'D1'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lamp'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'd1', toPin: 'Run'),
      FbdWire(fromBlockId: 'd1', fromPin: 'Done', toBlockId: 'to', toPin: 'IN'),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Start', 'BOOL', true),
          _tag('Lamp', 'BOOL', false),
          _tag('D1', 'Delay', _instanceValue(fb)),
        ],
        structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb]);

    final fbdRt = FbdRuntime();
    final ldRt = LdExecRuntime();
    executeFbdPrograms(p, 100, fbdRt, ldRt: ldRt);
    executeFbdPrograms(p, 100, fbdRt, ldRt: ldRt);
    expect(readPath(p, 'D1.T.ACC'), 200);
    expect(readPath(p, 'D1.Done'), isFalse);
    executeFbdPrograms(p, 100, fbdRt, ldRt: ldRt);
    expect(readPath(p, 'D1.Done'), isTrue);
    expect(readPath(p, 'Lamp'), isTrue);
  });

  test('executeFbdPrograms without ldRt still runs the ladder body (never-throws)', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: '', tagBinding: 'Start'),
      FbdBlock(id: 'd1', type: 'Delay', title: '', tagBinding: 'D1'),
    ]);
    prog.fbdWires.add(FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'd1', toPin: 'Run'));
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [_tag('Start', 'BOOL', true), _tag('D1', 'Delay', _instanceValue(fb))],
        structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb]);

    expect(() => executeFbdPrograms(p, 100, FbdRuntime()), returnsNormally);
    expect(readPath(p, 'D1.T.ACC'), 100);
  });

  test('runScanTick drives an FBD-hosted ladder FB timer across ticks', () {
    final fb = _delayFb();
    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: '', tagBinding: 'Start'),
      FbdBlock(id: 'd1', type: 'Delay', title: '', tagBinding: 'D1'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lamp'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'd1', toPin: 'Run'),
      FbdWire(fromBlockId: 'd1', fromPin: 'Done', toBlockId: 'to', toPin: 'IN'),
    ]);
    final p = PlcProject(id: 'p', name: 'p', controllerName: 'c',
        tags: [
          _tag('Start', 'BOOL', true),
          _tag('Lamp', 'BOOL', false),
          _tag('D1', 'Delay', _instanceValue(fb)),
        ],
        structDefs: [], programs: [prog],
        tasks: [PlcTask(name: 'Main', type: 'Continuous', programNames: ['F1'])],
        hmis: [], fbDefinitions: [fb]);

    final rt = ScanTickRuntime();
    runScanTick(p, 150, rt);
    runScanTick(p, 150, rt);
    expect(readPath(p, 'D1.T.ACC'), 300);
    expect(readPath(p, 'Lamp'), isTrue);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/c/flutter/bin/flutter test test/models/fb_ladder_engine_test.dart`
Expected: FAIL — `No named parameter with the name 'ldRt'` on `executeFbdPrograms`; the LD test fails with `D1.T.ACC == 100` on every scan (the FB body gets a fresh `LdExecRuntime` and `dtMs: 0`... in fact `ACC` stays `0` because `dtMs` defaults to 0).

- [ ] **Step 3: Thread `dtMs` + `rt` from the LD engine**

In `mobile/lib/models/ld_exec.dart`, inside `executeRung`'s custom-FB branch, replace:

```dart
            final outputs = executeFbInstance(p, fb, sp(n.variable), inputs);
```

with:

```dart
            // This rung's own dtMs + runtime flow into the FB body: a ladder
            // body's timers advance with the scan and its edge/pulse state
            // persists (keys are 'fb:<instance>'-prefixed, so they can never
            // collide with this program's rung keys). Nested AOI-in-AOI
            // recursion reuses the same runtime for the same reason.
            final outputs = executeFbInstance(p, fb, sp(n.variable), inputs,
                dtMs: dtMs, ldRt: rt);
```

- [ ] **Step 4: Thread `ldRt` through `fbd_exec.dart`**

(a) Add the import — replace lines 1-5 of `mobile/lib/models/fbd_exec.dart`:

```dart
import 'project_model.dart';
import 'fbd_pins.dart';
import 'tag_resolver.dart';
import 'fbd_monitor.dart';
import 'fb_exec.dart';
```

with:

```dart
import 'project_model.dart';
import 'fbd_pins.dart';
import 'tag_resolver.dart';
import 'fbd_monitor.dart';
import 'fb_exec.dart';
import 'ld_exec.dart';
```

(b) Add the parameter to `_evalBlock` — replace lines 167-174:

```dart
Map<String, dynamic> _evalBlock(
  PlcProject p,
  FbdBlock b,
  List<dynamic> inputs,
  int dtMs,
  FbdRuntime rt,
  Set<String>? readOnly,
) {
```

with:

```dart
Map<String, dynamic> _evalBlock(
  PlcProject p,
  FbdBlock b,
  List<dynamic> inputs,
  int dtMs,
  FbdRuntime rt,
  Set<String>? readOnly,
  LdExecRuntime? ldRt,
) {
```

(c) Pass it into the custom-FB call — replace line 197:

```dart
    return executeFbInstance(p, fb, b.tagBinding, inputMap);
```

with:

```dart
    // A ladder-bodied FB needs the scan's dtMs (timers) and a persistent
    // LdExecRuntime (edge/pulse). An ST-bodied FB ignores both.
    return executeFbInstance(p, fb, b.tagBinding, inputMap, dtMs: dtMs, ldRt: ldRt);
```

(d) Add the optional parameter to `executeFbdPrograms` — replace line 528:

```dart
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt, {Set<String>? only, Set<String>? readOnly, FbdMonitor? monitor}) {
```

with:

```dart
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt, {Set<String>? only, Set<String>? readOnly, FbdMonitor? monitor, LdExecRuntime? ldRt}) {
```

(e) Pass it at both `_evalBlock` call sites — replace line 637:

```dart
          cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt, readOnly);
```

with:

```dart
          cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt, readOnly, ldRt);
```

and line 649:

```dart
        cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt, readOnly);
```

with:

```dart
        cache[b.id] = _evalBlock(p, b, orderedInputs(b), dtMs, rt, readOnly, ldRt);
```

- [ ] **Step 5: Hand the shell's ladder runtime to the FBD engine**

In `mobile/lib/screens/scan_tick.dart`, replace line 77:

```dart
    executeFbdPrograms(p, dtMs, rt.fbd, only: only, readOnly: readOnly, monitor: rt.fbdMonitor);
```

with:

```dart
    // The SAME LdExecRuntime the LD engine uses: a ladder-bodied FB called
    // from FBD keeps its edge/pulse state across scans. Instance-prefixed
    // ('fb:<instance>') keys keep FB-body state disjoint from program-rung
    // state, so sharing one runtime is safe.
    executeFbdPrograms(p, dtMs, rt.fbd, only: only, readOnly: readOnly,
        monitor: rt.fbdMonitor, ldRt: rt.ld);
```

- [ ] **Step 6: Run the new tests**

Run: `/c/flutter/bin/flutter test test/models/fb_ladder_engine_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 7: Run the engine regression set**

Run: `/c/flutter/bin/flutter test test/fbd_exec_test.dart test/fbd_exec_integration_test.dart test/fbd_networks_exec_test.dart test/fb_fbd_exec_test.dart test/fb_ld_exec_test.dart test/scan_scheduling_test.dart test/scan_signal_test.dart test/scan_ld_monitor_test.dart test/scan_pause_hmi_gate_test.dart`
Expected: PASS.

- [ ] **Step 8: Analyze**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/models/ld_exec.dart mobile/lib/models/fbd_exec.dart mobile/lib/screens/scan_tick.dart mobile/test/models/fb_ladder_engine_test.dart
git commit -m "feat(exec): thread dtMs + LdExecRuntime into FB bodies from both engines

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Import — RLL AOI `Logic` → compiled ladder FB body

**Model:** opus · **Effort:** high

Implements spec §4 (and the §5 error table's import rows).

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart:185-245` (`_l5xAois`)
- Modify: `mobile/lib/import/rll_compile.dart:305-322` (AOI-call arity/binding)
- Modify: `mobile/lib/import/fb_import.dart` (whole `FbImportResult` + `mapImportedFbs`)
- Modify: `mobile/lib/import/ir_to_project.dart:196-199` (seed the RLL counters)
- Modify: `mobile/test/import/l5x_parser_test.dart:146-149` (the existing RLL-AOI expectation flips)
- Test: `mobile/test/import/fb_import_ladder_test.dart` (new)
- Test: `mobile/test/import/rll_compile_test.dart` (append one test)

**Interfaces:**
- Consumes: `FbDefinition(..., ladderRungs: ...)` (Task 1); `compileRllRungs(NeutralLadderBody body, {required String pouName, Map<String, FbDefinition> fbRegistry = const {}, Map<String, String> fbRenameMap = const {}}) -> RllTranslation` with fields `rungs`, `translatedRungCount`, `stubbedRungCount`, `unsupportedInstructions` (`Set<String>`), `stubReasons` (`Map<String,int>`), `warnings` (existing).
- Produces: `FbImportResult(List<FbDefinition> defs, Map<String, FbDefinition> registry, Map<String, String> renameMap, {int translatedRllRungCount = 0, int stubbedRllRungCount = 0, Set<String> unsupportedRllInstructions = const {}, Map<String, int> rllStubReasons = const {}})` — the first three stay positional so existing construction/consumption is unchanged.

**Why `rll_compile.dart` changes too (spec gap resolved):** `_instrToNode`'s AOI-call arm compares `ops.length - 1` against `fb.vars.length` — **all** vars, internal ones included. Rockwell neutral text passes the instance tag plus the AOI's *interface* parameters only; it never passes LocalTags, and never passes `EnableIn`/`EnableOut`. Retaining `EnableIn`/`EnableOut` as internal vars (spec §4) would therefore make every call to an RLL AOI stub with `aoi-mismatch` — including the spec's own §6 e2e. The fix is to run both the arity check and the positional binding over non-internal vars. This is strictly more permissive: when an FB has no internal vars the two counts are identical, so **no rung that compiles today changes behaviour**.

What *does* change: rungs that **stub today start compiling**. Any AOI with LocalTags is affected — e.g. the `Scaler` fixture in `l5x_parser_test.dart` has a `Tmp` LocalTag, so today *every* call to it stubs with `aoi-mismatch` even though the call site is perfectly well-formed. After this change those calls bind correctly. Nothing asserts on the old (wrong) numbers: the only corpus-wide assertion is the loose `expect(res.report.translatedRllRungCount, greaterThan(0))` at `mobile/test/import/import_l5x_rll_e2e_test.dart:70`, which can only get further from failing, and `rll_compile_test.dart`'s `AOI arity mismatch stubs the rung` fixture has no internal vars so it still stubs. Expect corpus RLL counts to tick **up**, never down.

- [ ] **Step 1: Write the failing parser test (extend the fixture, then update the expectation)**

**(a) Extend the `LadderAoi` fixture first.** The existing fixture declares only
`X`, and the parser *retains* `EnableIn`/`EnableOut` parameters — it never
synthesizes them — so the new expectations cannot go green until the fixture
actually declares them. In `mobile/test/import/l5x_parser_test.dart`, replace
line 130:

```
      <Parameters><Parameter Name="X" DataType="BOOL" Usage="Input" Visible="true"/></Parameters>
```

with:

```
      <Parameters><Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/><Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/><Parameter Name="X" DataType="BOOL" Usage="Input" Visible="true"/></Parameters>
```

**(b) Update the expectation.** In the same file, replace lines 146-149:

```dart
    // RLL-bodied AOI: interface imported, empty body + warning.
    final ladder = ir.pous.firstWhere((p) => p.name == 'LadderAoi');
    expect((ladder.body as TextBody).source, '');
    expect(ir.warnings.any((w) => w.message.contains('LadderAoi') && w.message.contains('logic')), isTrue);
```

with:

```dart
    // RLL-bodied AOI: rungs captured as a NeutralLadderBody, EnableIn/Out
    // RETAINED as internal (local) vars so the ladder's XIC(EnableIn)
    // resolves per-instance. No "not translated" warning any more.
    final ladder = ir.pous.firstWhere((p) => p.name == 'LadderAoi');
    expect(ladder.lang, PouLanguage.ld);
    final body = ladder.body as NeutralLadderBody;
    expect(body.rungs, hasLength(1));
    expect(body.rungs.single.text, 'NOP();');
    expect(ladder.localVars.map((v) => v.name), ['EnableIn', 'EnableOut', 'X']);
    expect(ladder.localVars[0].scope, VarScope.local);
    expect(ladder.localVars[0].baseType, 'BOOL');
    expect(ladder.localVars[0].initialValue, true);
    expect(ladder.localVars[1].initialValue, false);
    expect(ir.warnings.any((w) =>
        w.message.contains('LadderAoi') && w.message.contains('not yet translated')), isFalse);
```

Also append a new test after that one (still inside `main()`), proving FBD-logic AOIs are unchanged:

```dart
  test('an FBD-logic AOI still imports interface-only with a warning (unchanged)', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="GraphAoi">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="X" DataType="BOOL" Usage="Input" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="FBD"/></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final pou = ir.pous.single;
    expect(pou.lang, PouLanguage.st);
    expect((pou.body as TextBody).source, '');
    expect(pou.localVars.map((v) => v.name), ['X']); // EnableIn/Out still skipped
    expect(ir.warnings.any((w) =>
        w.message.contains('GraphAoi') && w.message.contains('not yet translated')), isTrue);
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: FAIL — `type 'TextBody' is not a subtype of type 'NeutralLadderBody' in type cast`.

- [ ] **Step 3: Rewrite `_l5xAois`**

In `mobile/lib/import/l5x_parser.dart`, replace the whole body of the `for (final aoi in ...)` loop (lines 189-242) with:

```dart
    for (final aoi in _children(defs, 'AddOnInstructionDefinition')) {
      final name = aoi.getAttribute('Name') ?? '';
      if (name.isEmpty) continue;
      // Logic routine: named "Logic" else the first routine. Resolved BEFORE
      // the parameter loop because an RLL-logic AOI keeps EnableIn/EnableOut
      // while every other logic language keeps the historic skip.
      XmlElement? logic;
      for (final rs in _children(aoi, 'Routines')) {
        for (final r in _children(rs, 'Routine')) {
          logic ??= r;
          if (r.getAttribute('Name') == 'Logic') logic = r;
        }
      }
      final logicType = logic?.getAttribute('Type');
      final isRll = logicType == 'RLL';

      final vars = <ImportedVar>[];
      for (final params in _children(aoi, 'Parameters')) {
        for (final p in _children(params, 'Parameter')) {
          final pn = p.getAttribute('Name') ?? '';
          if (pn.isEmpty) continue;
          if (pn == 'EnableIn' || pn == 'EnableOut') {
            if (!isRll) continue; // ST/FBD/SFC AOIs: historic skip, unchanged
            // Rockwell RLL AOI logic commonly does XIC(EnableIn)/OTE(EnableOut).
            // Retained as INTERNAL vars so those references resolve per
            // instance via LdScope instead of falling through to absent
            // globals. The body only runs when the call executes, so
            // EnableIn = true during execution is the faithful mapping.
            vars.add(ImportedVar(name: pn, baseType: 'BOOL',
                scope: VarScope.local, initialValue: pn == 'EnableIn'));
            continue;
          }
          vars.add(ImportedVar(
            name: pn,
            baseType: p.getAttribute('DataType') ?? 'DINT',
            arrayLength: _l5xArrayLen(p.getAttribute('Dimensions'), warnings,
                'AOI "$name" parameter "$pn"'),
            scope: _usageScope(p.getAttribute('Usage')),
            initialValue: _defaultDataScalar(p),
          ));
        }
      }
      for (final lts in _children(aoi, 'LocalTags')) {
        for (final lt in _children(lts, 'LocalTag')) {
          final ln = lt.getAttribute('Name') ?? '';
          if (ln.isEmpty) continue;
          vars.add(ImportedVar(
            name: ln,
            baseType: lt.getAttribute('DataType') ?? 'DINT',
            arrayLength: _l5xArrayLen(lt.getAttribute('Dimensions'), warnings,
                'AOI "$name" local tag "$ln"'),
            scope: VarScope.local,
            initialValue: _defaultDataScalar(lt),
          ));
        }
      }

      PouBody body = TextBody('');
      var lang = PouLanguage.st;
      if (logic != null) {
        if (logicType == 'ST') {
          body = TextBody(_stLines(logic));
        } else if (isRll) {
          // Same rung capture _l5xRoutines uses; the mapper compiles it via
          // compileRllRungs into the FB's native ladder body.
          final rungs = <RllRung>[];
          for (final content in _children(logic, 'RLLContent')) {
            for (final rung in _children(content, 'Rung')) {
              final num = int.tryParse(rung.getAttribute('Number') ?? '') ?? rungs.length;
              final text = (_firstChild(rung, 'Text')?.innerText ?? '').trim();
              final comment = _firstChild(rung, 'Comment')?.innerText.trim() ?? '';
              rungs.add(RllRung(number: num, text: text, comment: comment));
            }
          }
          body = NeutralLadderBody(rungs: rungs);
          lang = PouLanguage.ld;
        } else {
          warnings.add(ImportWarning(severity: WarningSeverity.info,
              message: 'AOI "$name" logic is ${logicType ?? '?'} — interface '
                  'imported, logic not yet translated.'));
        }
      }
      out.add(ImportedPou(name: name, kind: PouKind.functionBlock,
          lang: lang, localVars: vars, body: body));
    }
```

- [ ] **Step 4: Run the parser tests**

Run: `/c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing `rll_compile` arity test**

Append to `mobile/test/import/rll_compile_test.dart` (inside `main()`):

```dart
  test('AOI arity/binding ignores INTERNAL vars (LocalTags, EnableIn/EnableOut)', () {
    // Neutral text passes the instance tag + the AOI's interface params only.
    final aoi = FbDefinition(name: 'Latch', vars: [
      FbVar(name: 'EnableIn', dataType: 'BOOL', direction: FbVarDir.internal, initialValue: true),
      FbVar(name: 'EnableOut', dataType: 'BOOL', direction: FbVarDir.internal, initialValue: false),
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Tmp', dataType: 'BOOL', direction: FbVarDir.internal),
    ]);
    final tr = compileRllRungs(_body(['Latch(A1,Src,Dst);']),
        pouName: 'P', fbRegistry: {'Latch': aoi});
    expect(tr.translatedRungCount, 1);
    final node = tr.rungs.single.nodes.firstWhere((n) => n.blockType == 'Latch');
    expect(node.variable, 'A1');
    expect(node.pinBindings, {'In': 'Src', 'Out': 'Dst'});
  });
```

- [ ] **Step 6: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/import/rll_compile_test.dart`
Expected: FAIL — `Expected: <1> Actual: <0>` (the call stubs as `aoi-mismatch`: 2 args vs 5 vars).

- [ ] **Step 7: Bind AOI calls over interface vars only**

In `mobile/lib/import/rll_compile.dart`, replace lines 305-322:

```dart
  // Custom-AOI call: a mnemonic that (after fbRenameMap) names an imported AOI
  // routes to an FB-call node. Strict: the arg count must match the interface.
  final effective = fbRenameMap[instr.mnemonic] ?? instr.mnemonic;
  final fb = fbRegistry[effective];
  if (fb != null) {
    final ops = instr.operands;
    if (ops.isEmpty || ops.length - 1 != fb.vars.length) {
      unsupported.add(instr.mnemonic);
      throw _RllStub('aoi-mismatch',
          'AOI "$effective" arg count ${ops.isEmpty ? 0 : ops.length - 1} != ${fb.vars.length}');
    }
    final pin = <String, String>{};
    for (var k = 0; k < fb.vars.length; k++) {
      pin[fb.vars[k].name] = ops[k + 1];
    }
    return LdNode(id: '', kind: LdKind.block, blockType: effective,
        variable: ops[0], pinBindings: pin);
  }
```

with:

```dart
  // Custom-AOI call: a mnemonic that (after fbRenameMap) names an imported AOI
  // routes to an FB-call node. Strict: the arg count must match the interface.
  //
  // Neutral text passes the INSTANCE tag then the AOI's INTERFACE parameters,
  // in declaration order. Internal vars — AOI LocalTags, and the EnableIn/
  // EnableOut an RLL-logic AOI retains — are never passed, so they take part
  // in neither the arity check nor the positional binding. (An FB with no
  // internal vars binds exactly as before: same count, same order.)
  final effective = fbRenameMap[instr.mnemonic] ?? instr.mnemonic;
  final fb = fbRegistry[effective];
  if (fb != null) {
    final iface = [
      for (final v in fb.vars)
        if (v.direction != FbVarDir.internal) v,
    ];
    final ops = instr.operands;
    if (ops.isEmpty || ops.length - 1 != iface.length) {
      unsupported.add(instr.mnemonic);
      throw _RllStub('aoi-mismatch',
          'AOI "$effective" arg count ${ops.isEmpty ? 0 : ops.length - 1} != ${iface.length}');
    }
    final pin = <String, String>{};
    for (var k = 0; k < iface.length; k++) {
      pin[iface[k].name] = ops[k + 1];
    }
    return LdNode(id: '', kind: LdKind.block, blockType: effective,
        variable: ops[0], pinBindings: pin);
  }
```

- [ ] **Step 8: Run the compile tests**

Run: `/c/flutter/bin/flutter test test/import/rll_compile_test.dart test/import/rll_parse_test.dart`
Expected: PASS (including the pre-existing `AOI arity mismatch stubs the rung` test — its fixture has no internal vars).

- [ ] **Step 9: Write the failing mapper tests**

Create `mobile/test/import/fb_import_ladder_test.dart`:

```dart
// mapImportedFbs' NeutralLadderBody branch: an RLL-Logic AOI compiles to a
// native ladder FB body; a body where nothing compiles falls back to today's
// no-op + a warning; ST-bodied FBs are untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fb_import.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

ImportedVar _v(String name, String type, VarScope scope, {dynamic init}) =>
    ImportedVar(name: name, baseType: type, scope: scope, initialValue: init);

ImportedPou _ladderAoi(String name, List<ImportedVar> vars, List<String> rungTexts) =>
    ImportedPou(name: name, kind: PouKind.functionBlock, lang: PouLanguage.ld,
        localVars: vars,
        body: NeutralLadderBody(rungs: [
          for (var i = 0; i < rungTexts.length; i++)
            RllRung(number: i, text: rungTexts[i]),
        ]));

List<ImportedVar> _latchVars() => [
      _v('EnableIn', 'BOOL', VarScope.local, init: true),
      _v('EnableOut', 'BOOL', VarScope.local, init: false),
      _v('In', 'BOOL', VarScope.input),
      _v('Out', 'BOOL', VarScope.output),
    ];

void main() {
  test('a NeutralLadderBody AOI compiles to ladderRungs with an empty stSource', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Latch', _latchVars(), ['XIC(EnableIn)XIC(In)OTE(Out);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final fb = res.defs.single;
    expect(fb.name, 'Latch');
    expect(fb.stSource, '');
    expect(fb.ladderRungs, hasLength(1));
    expect(fb.ladderRungs.single.nodes.where((n) => n.kind == LdKind.contact)
        .map((n) => n.variable), ['EnableIn', 'In']);
    expect(fb.ladderRungs.single.nodes.where((n) => n.kind == LdKind.coil)
        .single.variable, 'Out');
    // EnableIn/EnableOut land as internal vars with their initial values.
    expect(fb.vars.map((v) => v.name), ['EnableIn', 'EnableOut', 'In', 'Out']);
    expect(fb.vars[0].direction, FbVarDir.internal);
    expect(fb.vars[0].initialValue, true);
    expect(fb.vars[1].initialValue, false);
    expect(res.registry['Latch'], same(fb));
    expect(res.renameMap['Latch'], 'Latch');
  });

  test('AOI-body compile counters ride on FbImportResult', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Mix', _latchVars(),
          ['XIC(In)OTE(Out);', 'CPT(Dest,Expr);']), // 2nd is unsupported
    ], structs: [], dutNames: {}, warnings: warnings);

    expect(res.translatedRllRungCount, 1);
    expect(res.stubbedRllRungCount, 1);
    expect(res.unsupportedRllInstructions, contains('CPT'));
    expect(res.rllStubReasons['unsupported-instruction'], 1);
    expect(res.defs.single.ladderRungs, hasLength(2)); // stub kept as placeholder
  });

  test('an AOI where NOTHING compiles falls back to the no-op body + a warning', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Bad', _latchVars(), ['CPT(A,B);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final fb = res.defs.single;
    expect(fb.ladderRungs, isEmpty); // no-op, exactly like before this feature
    expect(fb.stSource, '');
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.warning &&
        w.message.contains('Bad') &&
        w.message.contains('ladder')), isTrue);
  });

  test('an AOI ladder calling an EARLIER AOI routes to that FB', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Inner', [_v('X', 'BOOL', VarScope.input)], ['XIC(X)OTE(X);']),
      _ladderAoi('Outer', [_v('Y', 'BOOL', VarScope.input)], ['Inner(I1,Y);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final outer = res.defs.firstWhere((d) => d.name == 'Outer');
    expect(outer.ladderRungs.single.nodes.any((n) => n.blockType == 'Inner'), isTrue);
  });

  test('an AOI ladder calling an AOI defined LATER stubs that rung (ordering limit)', () {
    // Spec §5's documented forward-reference limitation: the registry grows in
    // document order, so the callee must precede the caller. Rockwell exports
    // list dependencies first, so this is rare — but it must degrade, not throw.
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _ladderAoi('Outer', [_v('Y', 'BOOL', VarScope.input)], ['Callee(C1,Y);']),
      _ladderAoi('Callee', [_v('Z', 'BOOL', VarScope.input)], ['XIC(Z)OTE(Z);']),
    ], structs: [], dutNames: {}, warnings: warnings);

    final outer = res.defs.firstWhere((d) => d.name == 'Outer');
    // The forward reference is an unknown mnemonic: that rung stubs to an
    // inert rail-to-rail placeholder, and the caller has NO real logic left.
    expect(outer.ladderRungs, isEmpty);
    expect(outer.stSource, '');
    expect(res.unsupportedRllInstructions, contains('Callee'));
    expect(res.rllStubReasons['unsupported-instruction'], 1);
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.warning && w.message.contains('Outer')), isTrue);

    // The callee itself, defined later, still compiles normally.
    expect(res.defs.firstWhere((d) => d.name == 'Callee').ladderRungs, hasLength(1));
  });

  test('ST-bodied FBs are untouched (regression)', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      ImportedPou(name: 'Scaler', kind: PouKind.functionBlock, lang: PouLanguage.st,
          localVars: [_v('In', 'REAL', VarScope.input), _v('Out', 'REAL', VarScope.output)],
          body: TextBody('Out := In * 2.0;')),
    ], structs: [], dutNames: {}, warnings: warnings);

    expect(res.defs.single.stSource, 'Out := In * 2.0;');
    expect(res.defs.single.ladderRungs, isEmpty);
    expect(res.translatedRllRungCount, 0);
  });
}
```

- [ ] **Step 10: Run it to verify it fails**

Run: `/c/flutter/bin/flutter test test/import/fb_import_ladder_test.dart`
Expected: FAIL — `The getter 'translatedRllRungCount' isn't defined for the class 'FbImportResult'`, and the ladder AOIs are skipped as "graphical body".

- [ ] **Step 11: Extend `FbImportResult` and add the `NeutralLadderBody` branch**

In `mobile/lib/import/fb_import.dart`:

(a) Add the import — replace line 4:

```dart
import 'import_ir.dart';
```

with:

```dart
import 'import_ir.dart';
import 'rll_compile.dart';
```

(b) Replace the `FbImportResult` class (lines 7-16):

```dart
/// Result of mapping the `functionBlock` POUs of an imported project into
/// native FB definitions. [registry] is keyed by FINAL FB name; [renameMap]
/// maps each imported FB POU's ORIGINAL name to its final name so the LD
/// translator can retarget call blocks that referenced the old name.
class FbImportResult {
  final List<FbDefinition> defs;
  final Map<String, FbDefinition> registry;
  final Map<String, String> renameMap;
  FbImportResult(this.defs, this.registry, this.renameMap);
}
```

with:

```dart
/// Result of mapping the `functionBlock` POUs of an imported project into
/// native FB definitions. [registry] is keyed by FINAL FB name; [renameMap]
/// maps each imported FB POU's ORIGINAL name to its final name so the LD
/// translator can retarget call blocks that referenced the old name.
///
/// The `*Rll*` counters cover LADDER-bodied FB (Rockwell RLL-Logic AOI) bodies
/// compiled here. `mapImportedProject` folds them into the EXISTING RLL report
/// fields — AOI-body rungs are RLL rungs, so no new preview UI is needed.
class FbImportResult {
  final List<FbDefinition> defs;
  final Map<String, FbDefinition> registry;
  final Map<String, String> renameMap;
  final int translatedRllRungCount;
  final int stubbedRllRungCount;
  final Set<String> unsupportedRllInstructions;
  final Map<String, int> rllStubReasons;
  FbImportResult(
    this.defs,
    this.registry,
    this.renameMap, {
    this.translatedRllRungCount = 0,
    this.stubbedRllRungCount = 0,
    this.unsupportedRllInstructions = const {},
    this.rllStubReasons = const {},
  });
}
```

(c) Update the doc comment + accept `NeutralLadderBody` — replace lines 32-63:

```dart
/// Maps the ST-bodied `functionBlock` POUs of [pous] to `FbDefinition`s.
/// Graphical-bodied FBs are skipped with a warning (ST-bodied FBs only).
/// Names are sanitized and collision-resolved against [structs] + the FBs
/// built so far (via `fbNameValidationError`), avoiding reserved block types,
/// builtin composites, struct names, and `kSystemTagName`. Pure; never throws.
FbImportResult mapImportedFbs(
  List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
}) {
  final defs = <FbDefinition>[];
  final registry = <String, FbDefinition>{};
  final renameMap = <String, String>{};
  // Growing scratch: structs known + FBs built so far, so name collisions
  // against earlier-imported FBs are caught. fbDefinitions is a mutable list.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], tags: [],
      structDefs: structs, fbDefinitions: defs);

  for (final pou in pous) {
    if (pou.kind != PouKind.functionBlock) continue;
    final body = pou.body;
    if (body is! TextBody) {
      final n = body is GraphBody ? body.nodes.length : 0;
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'Function block "${pou.name}" has a graphical body '
              '(${pou.lang.name}) — not imported (ST-bodied FBs only). '
              '$n elements captured.'));
      continue;
    }
```

with:

```dart
/// Maps the ST-bodied and LADDER-bodied `functionBlock` POUs of [pous] to
/// `FbDefinition`s. A `TextBody` becomes the FB's `stSource`; a
/// `NeutralLadderBody` (a Rockwell RLL-Logic AOI) is compiled by
/// [compileRllRungs] into the FB's native `ladderRungs`. Other graphical
/// bodies are still skipped with a warning. Names are sanitized and
/// collision-resolved against [structs] + the FBs built so far (via
/// `fbNameValidationError`), avoiding reserved block types, builtin
/// composites, struct names, and `kSystemTagName`. Pure; never throws.
FbImportResult mapImportedFbs(
  List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
}) {
  final defs = <FbDefinition>[];
  final registry = <String, FbDefinition>{};
  final renameMap = <String, String>{};
  var translatedRllRungCount = 0;
  var stubbedRllRungCount = 0;
  final unsupportedRllInstructions = <String>{};
  final rllStubReasons = <String, int>{};
  // Growing scratch: structs known + FBs built so far, so name collisions
  // against earlier-imported FBs are caught. fbDefinitions is a mutable list.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], tags: [],
      structDefs: structs, fbDefinitions: defs);

  for (final pou in pous) {
    if (pou.kind != PouKind.functionBlock) continue;
    final body = pou.body;
    if (body is! TextBody && body is! NeutralLadderBody) {
      final n = body is GraphBody ? body.nodes.length : 0;
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'Function block "${pou.name}" has a graphical body '
              '(${pou.lang.name}) — not imported (ST-bodied FBs only). '
              '$n elements captured.'));
      continue;
    }
```

(d) Replace the definition construction (lines 107-112):

```dart
    final def = FbDefinition(name: name, vars: vars, stSource: body.source);
    defs.add(def); // scratch.fbDefinitions IS defs, so the next FB sees it
    registry[name] = def;
    renameMap[pou.name] = name;
  }
  return FbImportResult(defs, registry, renameMap);
}
```

with:

```dart
    final FbDefinition def;
    if (body is NeutralLadderBody) {
      // Compiled against the registry/renameMap built SO FAR: an AOI ladder
      // calling an AOI defined EARLIER in the file routes to a real FB-call
      // node; one defined later stubs as an unknown mnemonic (documented
      // ordering limitation — Rockwell exports list dependencies first).
      final tr = compileRllRungs(body, pouName: name,
          fbRegistry: registry, fbRenameMap: renameMap);
      warnings.addAll(tr.warnings);
      translatedRllRungCount += tr.translatedRungCount;
      stubbedRllRungCount += tr.stubbedRungCount;
      unsupportedRllInstructions.addAll(tr.unsupportedInstructions);
      tr.stubReasons.forEach((k, v) =>
          rllStubReasons[k] = (rllStubReasons[k] ?? 0) + v);
      if (tr.translatedRungCount > 0) {
        // >= 1 rung compiled: the AOI executes (stubbed rungs are inert
        // rail-to-rail placeholders, their reasons already warned above).
        def = FbDefinition(name: name, vars: vars, ladderRungs: tr.rungs);
      } else {
        // Nothing compiled -> today's interface-only no-op. An AOI whose
        // RLLContent is empty/absent has NOTHING to fail at, so it gets no
        // "none of its 0 rungs compiled" noise — only a real compile failure
        // warns.
        if (body.rungs.isNotEmpty) {
          warnings.add(ImportWarning(severity: WarningSeverity.warning,
              message: 'Function block "$name": none of its ${body.rungs.length} '
                  'ladder rungs compiled — interface imported, logic not '
                  'translated (the instance is a no-op).'));
        }
        def = FbDefinition(name: name, vars: vars);
      }
    } else {
      def = FbDefinition(name: name, vars: vars,
          stSource: body is TextBody ? body.source : '');
    }
    defs.add(def); // scratch.fbDefinitions IS defs, so the next FB sees it
    registry[name] = def;
    renameMap[pou.name] = name;
  }
  return FbImportResult(defs, registry, renameMap,
      translatedRllRungCount: translatedRllRungCount,
      stubbedRllRungCount: stubbedRllRungCount,
      unsupportedRllInstructions: unsupportedRllInstructions,
      rllStubReasons: rllStubReasons);
}
```

- [ ] **Step 12: Run the mapper tests**

Run: `/c/flutter/bin/flutter test test/import/fb_import_ladder_test.dart test/import/fb_import_test.dart`
Expected: PASS.

- [ ] **Step 13: Fold the AOI-body counters into the RLL report fields**

In `mobile/lib/import/ir_to_project.dart`, replace lines 196-199:

```dart
  var translatedRllRungCount = 0;
  var stubbedRllRungCount = 0;
  final unsupportedRllInstructions = <String>{};
  final rllStubReasons = <String, int>{};
```

with:

```dart
  // AOI ladder bodies compiled by `mapImportedFbs` are RLL rungs too — seed
  // the RLL counters with them so the preview's EXISTING RLL fields cover both
  // program routines and AOI bodies (no new report fields, no new preview UI).
  var translatedRllRungCount = fbRes.translatedRllRungCount;
  var stubbedRllRungCount = fbRes.stubbedRllRungCount;
  final unsupportedRllInstructions = <String>{...fbRes.unsupportedRllInstructions};
  final rllStubReasons = <String, int>{...fbRes.rllStubReasons};
```

- [ ] **Step 14: Add the report-folding test**

Append to `mobile/test/import/fb_import_ladder_test.dart` a second `import` and test — add at the top:

```dart
import 'package:soft_plc_mobile/import/ir_to_project.dart';
```

and inside `main()`:

```dart
  test('AOI-body rungs fold into the report\'s existing RLL fields', () {
    final ir = ImportedProject(name: 'P', types: const [], globalVars: const [],
        warnings: const [],
        pous: [_ladderAoi('Latch', _latchVars(), ['XIC(In)OTE(Out);'])]);
    final res = mapImportedProject(ir, projectName: 'P', projectId: 'x');
    expect(res.report.translatedRllRungCount, 1);
    expect(res.report.importedFbCount, 1);
    expect(res.project.fbDefinitions.single.ladderRungs, hasLength(1));
  });
```

- [ ] **Step 15: Run the import suite**

Run: `/c/flutter/bin/flutter test test/import/`
Expected: PASS across every file in the folder (corpus tests skip if the gitignored fixtures are absent).

- [ ] **Step 16: Analyze**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 17: Commit**

```bash
git add mobile/lib/import/l5x_parser.dart mobile/lib/import/rll_compile.dart mobile/lib/import/fb_import.dart mobile/lib/import/ir_to_project.dart mobile/test/import/
git commit -m "feat(import): RLL-Logic AOIs compile to native ladder FB bodies

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end proof + docs + full-suite validation

**Model:** sonnet · **Effort:** high

Implements spec §6's e2e row, §7 (docs) and §8 (deferred registry).

**Files:**
- Test: `mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart` (new)
- Modify: `docs/iec61131/FUNCTION_BLOCKS.md`
- Modify: `docs/import/L5X.md`
- Modify: `docs/DEFERRED.md`

**Interfaces:**
- Consumes: `parseL5x(String) -> ImportedProject` (existing); `mapImportedProject(ImportedProject, {required String projectName, required String projectId}) -> ImportResult` with `.project` / `.report.translatedRllRungCount` (existing); `executeLdPrograms(PlcProject, int dtMs, LdExecRuntime, {Set<String>? only, Set<String>? readOnly, LdMonitor? monitor})` (existing); `readPath` / `writePath` (existing).

- [ ] **Step 1: Write the failing e2e test**

Create `mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart`:

```dart
// End-to-end: a handcrafted L5X whose AOI has an RLL `Logic` routine compiles
// to a ladder-bodied FbDefinition and EXECUTES — two instances stay
// independent. Pipeline: parseL5x -> mapImportedProject -> executeLdPrograms.
//
// Corpus note: every AOI in the available Rockwell corpus is ST-bodied, so
// this feature is provable only against handcrafted, spec-faithful fixtures.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Latch">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Out" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[XIC(EnableIn)XIC(In)OTE(Out);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags>
    <Tag Name="A1" DataType="Latch"/>
    <Tag Name="A2" DataType="Latch"/>
    <Tag Name="Src1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Src2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Latch(A1,Src1,Dst1);]]></Text></Rung>
        <Rung Number="1"><Text><![CDATA[Latch(A2,Src2,Dst2);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';

void main() {
  test('an RLL-Logic AOI imports as a ladder-bodied FB and executes per instance', () {
    final ir = parseL5x(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'aoi_ladder_e2e');
    final p = res.project;

    // The AOI became a LADDER-bodied FbDefinition (no ST source).
    final fb = p.fbDefinitions.singleWhere((f) => f.name == 'Latch');
    expect(fb.stSource, '');
    expect(fb.ladderRungs, hasLength(1));
    expect(fb.vars.map((v) => v.name), ['EnableIn', 'EnableOut', 'In', 'Out']);
    expect(fb.vars.firstWhere((v) => v.name == 'EnableIn').direction, FbVarDir.internal);

    // Both AOI-typed controller tags resolved to the FB's composite shape.
    expect(readPath(p, 'A1.EnableIn'), isTrue);
    expect(readPath(p, 'A2.EnableIn'), isTrue);

    // 1 AOI-body rung + 2 program rungs, all counted as RLL.
    expect(res.report.translatedRllRungCount, 3);

    final prog = p.programs.firstWhere((pr) => pr.name == 'Main_Logic');
    expect(prog.language, 'LadderLogic');
    expect(prog.rungs, hasLength(2));

    final rt = LdExecRuntime();

    // Nothing driven yet.
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'Dst1'), isFalse);
    expect(readPath(p, 'Dst2'), isFalse);

    // Drive instance 1 only.
    writePath(p, 'Src1', true);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'A1.Out'), isTrue);
    expect(readPath(p, 'Dst1'), isTrue);
    expect(readPath(p, 'A2.Out'), isFalse);
    expect(readPath(p, 'Dst2'), isFalse); // the second instance is independent

    // Swap: instance 2 only.
    writePath(p, 'Src1', false);
    writePath(p, 'Src2', true);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'Dst1'), isFalse);
    expect(readPath(p, 'Dst2'), isTrue);
  });

  test('an AOI whose RLL logic cannot compile degrades to a no-op + warning', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Bad">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[CPT(Dest,Expr);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags><Tag Name="B1" DataType="Bad"/></Tags>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'aoi_ladder_bad');
    final fb = res.project.fbDefinitions.single;
    expect(fb.name, 'Bad');
    expect(fb.ladderRungs, isEmpty);   // no-op, exactly as before this feature
    expect(fb.stSource, '');
    expect(res.report.unsupportedRllInstructions, contains('CPT'));
    expect(res.report.warnings.any((w) => w.message.contains('Bad')), isTrue);
  });
}
```

- [ ] **Step 2: Run it**

Run (from `mobile/`): `/c/flutter/bin/flutter test test/import/import_l5x_aoi_ladder_e2e_test.dart`
Expected: PASS (2 tests). If Tasks 1-5 are complete this passes first time; if it fails, the failure localizes the gap (parser → mapper → executor).

- [ ] **Step 3: Run the FULL test suite**

Run: `/c/flutter/bin/flutter test`
Expected: PASS — zero failures. (Corpus/fixture-dependent tests may report `skipped`; that is fine.)

- [ ] **Step 4: Analyze**

Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Document ladder-bodied FBs**

In `docs/iec61131/FUNCTION_BLOCKS.md`, replace the first paragraph (lines 3-7):

```markdown
A **function block (FB)** definition is a reusable, project-level type: a
typed interface (input/output/internal vars) plus a Structured Text body.
Instantiating one creates a struct-typed tag that holds the instance's
state — so **every instance has independent state**, the same way two
`TON` timers never share a preset/elapsed.
```

with:

```markdown
A **function block (FB)** definition is a reusable, project-level type: a
typed interface (input/output/internal vars) plus a body — either Structured
Text or a native **ladder** body. Instantiating one creates a struct-typed tag
that holds the instance's state — so **every instance has independent state**,
the same way two `TON` timers never share a preset/elapsed.
```

Then insert this new section immediately before `## What's deferred` (line 57):

```markdown
## Ladder-bodied FBs

An FB can carry a native **ladder body** instead of ST: `FbDefinition.
ladderRungs` (JSON key `ladder_rungs`, absent when empty) holds real `LdRung`s.
A non-empty `ladderRungs` is the discriminator — that FB runs its ladder and
its `stSource` is ignored; an empty one is the ST path, unchanged.

Ladder bodies exist because a Rockwell **RLL-bodied AOI** cannot be honestly
transpiled to the app's ST subset (IF + assignment only — no timers, no
`OTL`/`OTU` latches, no edge instructions). They are produced by the L5X
importer (see `docs/import/L5X.md`); the FB editor does not create them.

Execution mirrors the ST path exactly. `executeFbInstance` writes the wired
inputs into the instance struct, then runs `runScopedLdBody` (`models/
ld_exec.dart`), which executes every rung through `executeRung` with an
`LdScope`: a tag path whose **root segment** names one of the FB's vars
resolves against `<instance>.<var>`, anything else falls through to the global
namespace. So an FB-local `TON` on var `T` accumulates in `A1.T.ACC`, and two
instances never share it. Edge/pulse state (rising contacts, pulse coils) is
keyed under the synthetic program name `'fb:<instance>'` — a sanitized program
name can never contain `:`, so those keys can never collide with a real
program's, and per-instance edge detection is disjoint for free. Writes are
force-aware, and the scan's `dtMs` + `LdExecRuntime` are threaded in from
whichever engine made the call (LD block, FBD block, or `scan_tick`).

The FB editor does **not** view or edit ladder bodies yet — a ladder-bodied FB
shows its (empty) ST source. Tracked in `docs/DEFERRED.md`.
```

- [ ] **Step 6: Document the import behaviour**

In `docs/import/L5X.md`, replace the "Non-ST AOI logic" bullet under `## What's captured but not yet translated` (lines 63-66):

```markdown
- **Non-ST AOI logic** (an AOI whose `Logic` routine is RLL/FBD/SFC rather
  than ST) imports the AOI's *interface* (parameters + local tags) as a real
  `FbDefinition`, but the logic itself is not translated — a warning names the
  AOI and its logic language.
```

with:

```markdown
- **FBD/SFC AOI logic** (an AOI whose `Logic` routine is FBD or SFC) imports
  the AOI's *interface* (parameters + local tags) as a real `FbDefinition`,
  but the logic itself is not translated — a warning names the AOI and its
  logic language. (RLL AOI logic now executes — see below.)
```

Then insert this section immediately after the `## RLL (ladder) compile` section (after line 55, before `## What's captured but not yet translated`):

```markdown
## RLL-Logic AOIs execute

An `<AddOnInstructionDefinition>` whose `Logic` routine is `Type="RLL"` now
imports as a **ladder-bodied function block**: its rungs go through the same
`compileRllRungs` compiler as program routines and land in
`FbDefinition.ladderRungs`, so every AOI-typed tag actually runs the AOI's
logic — per instance, with independent timers, counters, and edge state (see
`docs/iec61131/FUNCTION_BLOCKS.md`). Its rung counts, unsupported-instruction
inventory, and stub reasons fold into the same RLL fields of the import
preview as program rungs.

`EnableIn`/`EnableOut` are **retained as internal vars** for RLL-Logic AOIs
only (`EnableIn` defaults `true`, `EnableOut` `false`): Rockwell RLL AOI logic
commonly does `XIC(EnableIn)`, and since the body only runs when the call
executes, `EnableIn = true` during execution is the faithful mapping. Keeping
them as vars makes those references resolve per instance instead of falling
through to absent globals. ST-Logic AOIs keep the historic skip. Call sites are
unaffected — neutral text passes the instance tag plus the AOI's *interface*
parameters, so internal vars (LocalTags, `EnableIn`/`EnableOut`) take no part
in AOI-call arity or binding.

If **no** rung of an AOI's ladder compiles, the FB falls back to the previous
interface-only no-op plus a warning naming the AOI. An AOI ladder that calls an
AOI defined *later* in the same file stubs that rung (unknown mnemonic,
inventoried) — Rockwell exports list dependencies first, so this is rare.
Only the `Logic` routine runs; `Prescan`/`Postscan`/`EnableInFalse` are not
executed. Proven end-to-end in
`mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart`.
```

Finally, replace the first `## Deferred` bullet (lines 93-94):

```markdown
- **Non-ST AOI logic translation** — sub-project 3: translating an AOI's
  RLL/FBD/SFC `Logic` routine body (interface-only import ships today).
```

with:

```markdown
- **FBD-bodied AOI logic** — blocked on the L5X FBD front-end (sub-project 4);
  it will reuse the same scoped-FB infrastructure with a scoped FBD executor.
  (The RLL half shipped — see "RLL-Logic AOIs execute" above.)
- **AOI auxiliary routines** — only the main `Logic` routine executes;
  `Prescan`/`Postscan`/`EnableInFalse` are ignored.
- **AOI-in-AOI forward references** — the callee must precede the caller in
  the file.
```

- [ ] **Step 7: Update the deferred registry**

In `docs/DEFERRED.md`, replace the "Non-ST AOI logic translation" row (line 107):

```markdown
| Non-ST AOI logic translation | later | Sub-project 3: an AOI whose `Logic` routine is RLL/FBD/SFC imports its interface (parameters + local tags) as a real `FbDefinition`, but the logic body itself is not translated (warning only). |
```

with these rows:

```markdown
| ~~Non-ST AOI logic translation (RLL half)~~ | ~~later~~ | **Shipped** (2026-08-04, L5X sub-project 3): an AOI whose `Logic` routine is RLL imports as a **ladder-bodied** `FbDefinition` (`FbDefinition.ladderRungs`) and executes per instance via the scoped ladder executor (`LdScope` + `runScopedLdBody`, `'fb:<instance>'` runtime keys). `EnableIn`/`EnableOut` are retained as internal vars for RLL-logic AOIs. Proven end-to-end in `mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart`. See `docs/import/L5X.md`'s "RLL-Logic AOIs execute" and `docs/iec61131/FUNCTION_BLOCKS.md`'s "Ladder-bodied FBs". |
| FBD-bodied AOI logic | later | Blocked on the L5X FBD front-end (sub-project 4). Once that parses an AOI's FBD `Logic` routine, a **scoped FBD executor** slots onto the same infrastructure this sub-project built (`FbDefinition` body discriminator + `executeFbInstance` dispatch + engine runtime threading). FBD/SFC-logic AOIs stay interface-only until then. |
| AOI auxiliary routines (`Prescan`/`Postscan`/`EnableInFalse`) | later | Only the main `Logic` routine is imported and executed; Rockwell's scan-phase routines have no equivalent in the app's scan model. |
| AOI-in-AOI forward references | later | The FB registry grows in document order, so an AOI ladder calling an AOI defined **later** in the file stubs that rung (unknown mnemonic, inventoried). Rockwell exports list dependencies first, so this is rare. |
| FB editor support for ladder bodies | later | A ladder-bodied `FbDefinition` shows its (empty) ST source in the FB editor; there is no view/edit UI for `ladderRungs`. Import is the only producer today. |
| Integer truncation on dotted/scoped math destinations | later | An LD math/MOVE block truncates its result only when the DESTINATION's ROOT tag is an integer type; a dotted destination (`Struct.Member`, and an FB-scoped `A1.Var`) stores the raw double. Pre-existing behaviour, unchanged by the scoped executor. |
```

Then, in the "L5X import" section's intro paragraph (lines 95-105), append after the existing "RLL (ladder) routine translation shipped separately …" sentence:

```markdown
RLL-bodied AOI logic shipped on top of that (2026-08-04, L5X sub-project 3 —
see the rows below).
```

- [ ] **Step 8: Re-run the full suite + analyze after the doc edits**

Run: `/c/flutter/bin/flutter test`
Expected: PASS.
Run: `/c/flutter/bin/flutter analyze`
Expected: `No issues found!`

- [ ] **Step 9: Commit**

```bash
git add mobile/test/import/import_l5x_aoi_ladder_e2e_test.dart docs/iec61131/FUNCTION_BLOCKS.md docs/import/L5X.md docs/DEFERRED.md
git commit -m "test+docs(l5x): AOI ladder e2e proof; document ladder-bodied FBs and deferrals

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage**

| Spec § | Requirement | Task |
|---|---|---|
| §1 | `FbDefinition.ladderRungs`, `'ladder_rungs'` JSON, `fromJson` default `[]`, `isNotEmpty` discriminator, editor NOT extended | 1 (field/JSON), 6 (DEFERRED row for the editor) |
| §2 | `LdScope{instancePath, localVars, rewrite}`; `executeRung`'s optional scope applied at contacts, coils, `_operandValue` (literals never rewritten), timer/counter `base`, MOVE/math destinations, FB-call pin bindings; `scope == null` byte-identical; `'fb:<instance>'` runtime keying | 2 |
| §3 | `executeFbInstance({dtMs, ldRt})`, ladder dispatch with `LdScope` + ephemeral `LdExecRuntime()` fallback, placeholder rungs inert, ST path unchanged; ld_exec threads `dtMs`+`rt`; `executeFbdPrograms(ldRt:)` → `_evalBlock`; `scan_tick` passes `rt.ld`; `readOnly` parity | 3 (dispatch), 4 (threading) |
| §4 | Parser RLL arm → `NeutralLadderBody`; EnableIn/EnableOut retained internal for RLL AOIs only; FBD/SFC unchanged; `mapImportedFbs` `NeutralLadderBody` branch with registry/renameMap so far; 0 rungs → empty body + warning; counters on `FbImportResult` folded into existing RLL report fields; AOI-in-AOI ordering; PLCopen inert | 5 |
| §5 | Every error-table row: partial compile, zero compile, FBD/SFC AOI, `XIC(EnableIn)`, scoped timer, forward reference (tested — "calling an AOI defined LATER stubs that rung"), empty instance name, unresolvable path | 3 (empty name, never-throws), 5 (import rows incl. forward reference), 2 (unresolvable path = `readPath` → 0/false) |
| §6 | Scoped-executor unit; dispatch unit incl. two-instance edge + scoped TON; model round-trip; import unit; e2e; whole-suite backward-compat | 2, 3, 1, 5, 6, 6 |
| §7 | `FUNCTION_BLOCKS.md`, `L5X.md`, `DEFERRED.md` | 6 |
| §8 | All five deferred rows recorded | 6 |

No gaps. One addition beyond the spec — the `_kMaxFbCallDepth` guard in Task 3 — is required by the "never-throws" global constraint, since ladder bodies (unlike ST bodies) can call other FBs and a cyclic definition graph would otherwise raise the uncatchable `StackOverflowError`.

**2. Placeholder scan** — no "TBD", "TODO", "similar to Task N", or "add error handling". Every code step shows complete code; **every Edit quotes its old text verbatim** (including `project_model.dart:205-224` in Task 1 Step 3 and the `l5x_parser_test.dart:130` fixture line in Task 5 Step 1a), read from the live files at plan time. Line numbers are pre-edit and shift as a task proceeds — match on the quoted text, not the number.

**2b. Fixture prerequisites** — checked that every test expectation is satisfiable by the fixture it runs against. One gap found and fixed: Task 5's `EnableIn`/`EnableOut` retention expectations require the `LadderAoi` fixture to *declare* those parameters (the parser retains, it never synthesizes), so Task 5 Step 1a extends the fixture before Step 1b asserts on it.

**3. Type consistency** — cross-checked:
- `FbDefinition.ladderRungs` (`List<LdRung>`) — declared Task 1, consumed Tasks 3/5/6 under the same name.
- `LdScope(String instancePath, Set<String> localVars)` positional, `.rewrite(String) -> String` — declared Task 2, used Tasks 2/3.
- `runScopedLdBody(PlcProject, List<LdRung>, LdScope, int, LdExecRuntime)` — declared Task 2, called Task 3 with exactly that order.
- `executeFbInstance(..., {int dtMs = 0, LdExecRuntime? ldRt})` — declared Task 3, called Task 4 (both engines) and Task 2's existing FB-call site (4 positional args, still valid).
- `executeFbdPrograms(..., {..., LdExecRuntime? ldRt})` — declared Task 4, called by `scan_tick` and Task 4's tests.
- `FbImportResult(defs, registry, renameMap, {translatedRllRungCount, stubbedRllRungCount, unsupportedRllInstructions, rllStubReasons})` — declared Task 5, consumed by `ir_to_project` (same names as `ImportReport.translatedRllRungCount` / `stubbedRllRungCount` / `unsupportedRllInstructions` / `rllStubReasons`, which already exist).
- `RllTranslation` fields used (`rungs`, `translatedRungCount`, `stubbedRungCount`, `unsupportedInstructions`, `stubReasons`, `warnings`) match `rll_compile.dart:155-170` verbatim.
- `ImportedVar(name:, baseType:, arrayLength:, initialValue:, scope:, retain:)`, `NeutralLadderBody(rungs:)`, `RllRung(number:, text:, comment:)`, `PlcTask(name:, type:, programNames:)` all match their declarations.
