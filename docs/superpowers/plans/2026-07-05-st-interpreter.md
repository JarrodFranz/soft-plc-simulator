# Structured Text Interpreter (WS4d) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute Structured Text programs each scan — a statement interpreter (IF/ELSIF/ELSE/END_IF + assignments) built on the WS4b `st_expr` expression evaluator — and retire the last hardcoded logic (`_evaluateActiveLogic`).

**Architecture:** `st_exec.dart` (pure Dart) strips comments, tokenizes with source offsets, parses a nested statement AST, and executes it — delegating every expression to `st_expr`'s `evalExpr`/`evalStCondition` via exact source substrings. `workspace_shell` runs sim → LD → FBD → SFC → **ST** (last), and `_evaluateActiveLogic` is deleted. Reactor control and water safety supervision move to their ST programs; the redundant tank ST is removed (tank stays FBD-owned).

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` reports **zero** issues. Braces on all flow-control bodies; prefer `const`; `x.isNotEmpty` not `x.length >= 1`.
- No RenderFlex overflow. All shell commands run from `mobile/`.
- Clocks advance by scan ticks. A forced ROOT tag is never overwritten (`root.isForced && path == root.name` → skip), matching `ld_exec`/`fbd_exec`/`sfc_exec`.
- Behavior parity with the removed hardcoded logic at the default 500 ms scan, EXCEPT two flagged intentional refinements: reactor `Reactor_Ready` uses the explicit ST form; water `Alarm_Active` turbidity margin is `+5.0` (the ST source) not the old hardcoded `+8.0`.
- The interpreter NEVER throws on malformed input (skip statement) and NEVER hangs (no loops in the subset).

**Sequencing:** Task 1 is additive (interpreter + tests, plus a one-line public helper on `st_expr`). Task 2 wires ST in, migrates the three projects, and deletes `_evaluateActiveLogic` in the SAME commit. Task 3 validates end-to-end.

---

### Task 1: ST statement interpreter + tests

**Files:**
- Create: `mobile/lib/models/st_exec.dart`
- Modify: `mobile/lib/models/st_expr.dart` (expose a public comment-stripper)
- Test: `mobile/test/st_exec_test.dart`

**Interfaces:**
- Consumes: `PlcProject`, `PlcProgram`, `PlcTag` from `project_model.dart`; `evalExpr`, `evalStCondition` from `st_expr.dart`; `writePath` from `tag_resolver.dart`.
- Produces (used by Tasks 2/3): `class StRuntime { void clear(); }`; `void executeStPrograms(PlcProject p, int dtMs, StRuntime rt)`.

- [ ] **Step 1: Expose the comment-stripper on `st_expr.dart`**

`st_exec` must strip `(* *)`/`//` comments before tokenizing. `st_expr.dart` already has a private `_stripComments`. Add a public one-line wrapper near the top-level functions (do NOT change `_stripComments` or any existing behavior):

```dart
/// Strips `(* *)` block and `// ` line comments (shared with the ST interpreter).
String stripStComments(String src) => _stripComments(src);
```

Verify WS4b's `st_expr_test.dart` still passes unchanged after this addition.

- [ ] **Step 2: Write the failing tests**

Create `mobile/test/st_exec_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProgram _st(String src) =>
    PlcProgram(name: 'P', language: 'StructuredText', stSource: src);

PlcProject _proj(List<PlcTag> tags, PlcProgram prog) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

void _run(PlcProject p) => executeStPrograms(p, 500, StRuntime());
dynamic _v(PlcProject p, String path) => readPath(p, path);

void main() {
  test('assignment list runs top to bottom', () {
    final p = _proj([
      _tag('A', 'BOOL', false), _tag('B', 'INT32', 0), _tag('C', 'FLOAT64', 0.0),
    ], _st('A := TRUE;\nB := 3 + 4;\nC := B * 2;'));
    _run(p);
    expect(_v(p, 'A'), isTrue);
    expect(_v(p, 'B'), equals(7));
    expect(_v(p, 'C'), equals(14.0));
  });

  test('IF/ELSIF/ELSE selects the correct branch', () {
    PlcProject build(double t) => _proj([
          _tag('Temp', 'FLOAT64', t), _tag('SP', 'FLOAT64', 50.0),
          _tag('Heat', 'BOOL', false), _tag('Cool', 'BOOL', false),
        ], _st('''
IF Temp < (SP - 2.0) THEN
    Heat := TRUE; Cool := FALSE;
ELSIF Temp > (SP + 2.0) THEN
    Heat := FALSE; Cool := TRUE;
ELSE
    Heat := FALSE; Cool := FALSE;
END_IF;'''));
    final cold = build(40.0);
    _run(cold);
    expect(_v(cold, 'Heat'), isTrue);
    expect(_v(cold, 'Cool'), isFalse);
    final hot = build(60.0);
    _run(hot);
    expect(_v(hot, 'Cool'), isTrue);
    expect(_v(hot, 'Heat'), isFalse);
    final band = build(50.0);
    _run(band);
    expect(_v(band, 'Heat'), isFalse);
    expect(_v(band, 'Cool'), isFalse);
  });

  test('nested IF executes inner branch', () {
    PlcProject build(bool auto, double t) => _proj([
          _tag('Auto', 'BOOL', auto), _tag('Temp', 'FLOAT64', t), _tag('SP', 'FLOAT64', 50.0),
          _tag('Heat', 'BOOL', true), _tag('Cool', 'BOOL', true),
        ], _st('''
IF Auto THEN
    IF Temp < (SP - 2.0) THEN
        Heat := TRUE; Cool := FALSE;
    ELSE
        Heat := FALSE; Cool := FALSE;
    END_IF;
ELSE
    Heat := FALSE; Cool := FALSE;
END_IF;'''));
    final autoCold = build(true, 40.0);
    _run(autoCold);
    expect(_v(autoCold, 'Heat'), isTrue);
    expect(_v(autoCold, 'Cool'), isFalse);
    final manual = build(false, 40.0);
    _run(manual);
    expect(_v(manual, 'Heat'), isFalse); // outer ELSE
    expect(_v(manual, 'Cool'), isFalse);
  });

  test('multi-line boolean expression assignment', () {
    final p = _proj([
      _tag('AH', 'BOOL', false), _tag('AL', 'BOOL', false),
      _tag('Temp', 'FLOAT64', 50.0), _tag('SP', 'FLOAT64', 50.0),
      _tag('Ready', 'BOOL', false),
    ], _st('''
Ready := NOT AH
     AND NOT AL
     AND (Temp >= SP - 2.0)
     AND (Temp <= SP + 2.0);'''));
    _run(p);
    expect(_v(p, 'Ready'), isTrue);
  });

  test('comments are ignored', () {
    final p = _proj([_tag('A', 'BOOL', false)], _st('''
(* block comment *)
A := TRUE; // line comment
'''));
    _run(p);
    expect(_v(p, 'A'), isTrue);
  });

  test('forced tag is not overwritten', () {
    final p = _proj([_tag('A', 'BOOL', false, forced: true, fv: false)],
        _st('A := TRUE;'));
    _run(p);
    expect(_v(p, 'A'), isFalse);
  });

  test('malformed statements are skipped, valid ones still run', () {
    final p = _proj([_tag('A', 'BOOL', false), _tag('B', 'BOOL', false)],
        _st('A := TRUE;\n@@ garbage @@;\nB := TRUE;'));
    _run(p);
    expect(_v(p, 'A'), isTrue);
    expect(_v(p, 'B'), isTrue);
  });

  test('non-ST and empty-source programs are skipped without throwing', () {
    final ld = PlcProgram(name: 'L', language: 'LadderLogic');
    final p = _proj([_tag('A', 'BOOL', true)], ld);
    _run(p);
    final empty = PlcProgram(name: 'E', language: 'StructuredText', stSource: '');
    final p2 = _proj([], empty);
    _run(p2);
    expect(true, isTrue);
  });
}
```

- [ ] **Step 3: Run to confirm failure**

Run: `flutter test test/st_exec_test.dart` → FAIL (`st_exec.dart` missing).

- [ ] **Step 4: Implement `st_exec.dart`**

Create `mobile/lib/models/st_exec.dart`:

```dart
import 'project_model.dart';
import 'st_expr.dart';
import 'tag_resolver.dart';

/// Reserved for future stateful ST (in-body timers/counters); unused today.
class StRuntime {
  void clear() {}
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
    return; // forcing wins
  }
  writePath(p, path, value);
}

// ── Tokens ────────────────────────────────────────────────────────────────
class _Tok {
  final String kind; // 'kw' | 'assign' | 'semi' | 'expr'
  final String text; // uppercased keyword for 'kw', else raw
  final int start;
  final int end;
  _Tok(this.kind, this.text, this.start, this.end);
}

const Set<String> _stKeywords = {'IF', 'THEN', 'ELSIF', 'ELSE', 'END_IF'};

bool _idStart(String c) => RegExp(r'[A-Za-z_]').hasMatch(c);
bool _idPart(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);
bool _digit(String c) => RegExp(r'[0-9]').hasMatch(c);

List<_Tok> _tokenize(String src) {
  final toks = <_Tok>[];
  int i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      i++;
      continue;
    }
    if (i + 1 < src.length && src[i] == ':' && src[i + 1] == '=') {
      toks.add(_Tok('assign', ':=', i, i + 2));
      i += 2;
      continue;
    }
    if (c == ';') {
      toks.add(_Tok('semi', ';', i, i + 1));
      i++;
      continue;
    }
    if (_idStart(c)) {
      final start = i;
      while (i < src.length && _idPart(src[i])) {
        i++;
      }
      // dotted / indexed path runs stay in one token
      while (i < src.length) {
        if (src[i] == '.' && i + 1 < src.length && _idPart(src[i + 1])) {
          i++;
          while (i < src.length && _idPart(src[i])) {
            i++;
          }
        } else if (src[i] == '[') {
          final close = src.indexOf(']', i);
          if (close == -1) {
            i = src.length;
            break;
          }
          i = close + 1;
        } else {
          break;
        }
      }
      final text = src.substring(start, i);
      final up = text.toUpperCase();
      if (_stKeywords.contains(up) && !text.contains('.') && !text.contains('[')) {
        toks.add(_Tok('kw', up, start, i));
      } else {
        toks.add(_Tok('expr', text, start, i));
      }
      continue;
    }
    if (_digit(c)) {
      final start = i;
      while (i < src.length && (_digit(src[i]) || src[i] == '.')) {
        i++;
      }
      toks.add(_Tok('expr', src.substring(start, i), start, i));
      continue;
    }
    // operators / parens: two-char first
    if (i + 1 < src.length) {
      final two = src.substring(i, i + 2);
      if (two == '<=' || two == '>=' || two == '<>') {
        toks.add(_Tok('expr', two, i, i + 2));
        i += 2;
        continue;
      }
    }
    if ('=<>+-*/()'.contains(c)) {
      toks.add(_Tok('expr', c, i, i + 1));
      i++;
      continue;
    }
    // unknown char: emit as an expr atom so a bad statement is skippable, advance
    toks.add(_Tok('expr', c, i, i + 1));
    i++;
  }
  return toks;
}

// ── Statement AST ───────────────────────────────────────────────────────────
abstract class _Stmt {}

class _Assign extends _Stmt {
  final String path;
  final int rhsStart;
  final int rhsEnd;
  _Assign(this.path, this.rhsStart, this.rhsEnd);
}

class _Branch {
  final int condStart;
  final int condEnd;
  final List<_Stmt> body;
  _Branch(this.condStart, this.condEnd, this.body);
}

class _If extends _Stmt {
  final List<_Branch> branches; // IF + ELSIF...
  final List<_Stmt>? elseBody;
  _If(this.branches, this.elseBody);
}

// ── Parser ──────────────────────────────────────────────────────────────────
class _Parser {
  final List<_Tok> toks;
  int pos = 0;
  _Parser(this.toks);

  _Tok? get _peek => pos < toks.length ? toks[pos] : null;
  bool _isKw(String k) => _peek != null && _peek!.kind == 'kw' && _peek!.text == k;

  /// Parses statements until a block terminator (ELSIF/ELSE/END_IF) or EOF.
  List<_Stmt> parseBlock() {
    final out = <_Stmt>[];
    while (_peek != null) {
      if (_isKw('ELSIF') || _isKw('ELSE') || _isKw('END_IF')) {
        break;
      }
      final s = _parseStatement();
      if (s != null) {
        out.add(s);
      }
    }
    return out;
  }

  _Stmt? _parseStatement() {
    final t = _peek!;
    if (t.kind == 'kw' && t.text == 'IF') {
      return _parseIf();
    }
    if (t.kind == 'expr') {
      // assignment: expr(path) := ... ;
      final pathTok = t;
      if (pos + 1 < toks.length && toks[pos + 1].kind == 'assign') {
        pos += 2; // past path and ':='
        final rhsStart = _peek?.start ?? pathTok.end;
        int rhsEnd = rhsStart;
        while (_peek != null && _peek!.kind != 'semi' &&
            !(_peek!.kind == 'kw')) {
          rhsEnd = _peek!.end;
          pos++;
        }
        if (_peek != null && _peek!.kind == 'semi') {
          pos++; // consume ';'
        }
        if (_validPath(pathTok.text) && rhsEnd > rhsStart) {
          return _Assign(pathTok.text, rhsStart, rhsEnd);
        }
        return null;
      }
    }
    // Unrecognized token: skip to the next ';' or terminator to recover.
    _skipToStatementEnd();
    return null;
  }

  _Stmt _parseIf() {
    pos++; // past IF
    final branches = <_Branch>[];
    branches.add(_parseBranch());
    while (_isKw('ELSIF')) {
      pos++;
      branches.add(_parseBranch());
    }
    List<_Stmt>? elseBody;
    if (_isKw('ELSE')) {
      pos++;
      elseBody = parseBlock();
    }
    if (_isKw('END_IF')) {
      pos++;
    }
    if (_peek != null && _peek!.kind == 'semi') {
      pos++; // optional ';' after END_IF
    }
    return _If(branches, elseBody);
  }

  _Branch _parseBranch() {
    final condStart = _peek?.start ?? 0;
    int condEnd = condStart;
    while (_peek != null && !_isKw('THEN')) {
      condEnd = _peek!.end;
      pos++;
    }
    if (_isKw('THEN')) {
      pos++;
    }
    final body = parseBlock();
    return _Branch(condStart, condEnd, body);
  }

  void _skipToStatementEnd() {
    while (_peek != null && _peek!.kind != 'semi' && _peek!.kind != 'kw') {
      pos++;
    }
    if (_peek != null && _peek!.kind == 'semi') {
      pos++;
    }
  }

  bool _validPath(String s) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_\.\[\]]*$').hasMatch(s);
}

// ── Executor ────────────────────────────────────────────────────────────────
void _execBlock(PlcProject p, String src, List<_Stmt> stmts) {
  for (final s in stmts) {
    if (s is _Assign) {
      final v = evalExpr(p, src.substring(s.rhsStart, s.rhsEnd));
      if (v != null) {
        _forceAwareWrite(p, s.path, v);
      }
    } else if (s is _If) {
      bool taken = false;
      for (final b in s.branches) {
        if (evalStCondition(p, src.substring(b.condStart, b.condEnd))) {
          _execBlock(p, src, b.body);
          taken = true;
          break;
        }
      }
      if (!taken && s.elseBody != null) {
        _execBlock(p, src, s.elseBody!);
      }
    }
  }
}

/// Executes every StructuredText program's `stSource` each scan: IF/ELSIF/ELSE
/// control flow plus `path := expr;` assignments, with all expressions
/// evaluated by `st_expr` and writes made force-aware. Never throws.
void executeStPrograms(PlcProject p, int dtMs, StRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'StructuredText' || prog.stSource.trim().isEmpty) {
      continue;
    }
    final src = stripStComments(prog.stSource);
    final toks = _tokenize(src);
    if (toks.isEmpty) {
      continue;
    }
    final stmts = _Parser(toks).parseBlock();
    _execBlock(p, src, stmts);
  }
}
```

- [ ] **Step 5: Run tests → PASS (8 tests). Step 6: `flutter analyze` → No issues found!** (also re-run `flutter test test/st_expr_test.dart` — WS4b tests must still pass.)

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/st_exec.dart mobile/lib/models/st_expr.dart mobile/test/st_exec_test.dart
git commit -m "feat(st-exec): ST statement interpreter (IF/ELSIF/ELSE + assignments) over the st_expr core"
```

---

### Task 2: Scan wiring + migrate the three projects + delete `_evaluateActiveLogic`

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Modify: `mobile/lib/data/default_projects.dart`

**Interfaces:**
- Consumes: `executeStPrograms`, `StRuntime` from Task 1.

**Same-commit rule:** ST wiring, the three migrations, and the deletion of the hardcoded logic land together (no scan where both an ST program and hardcoded code drive the same tag).

- [ ] **Step 1: Wire ST into the scan (last stage)**

In `workspace_shell.dart`: `import '../models/st_exec.dart';`; add field `final StRuntime _stRuntime = StRuntime();`. In `_executeScan`, replace the `_evaluateActiveLogic();` call with:

```dart
      executeStPrograms(_activeProject, scanSpeedMs, _stRuntime);
```

Add `_stRuntime.clear();` alongside the existing `_simRuntime`/`_ldRuntime`/`_fbdRuntime`/`_sfcRuntime` clears on project switch.

- [ ] **Step 2: Delete the `_evaluateActiveLogic` method**

Remove the entire `_evaluateActiveLogic()` method (its remaining body is the `proj_st_reactor` branch and the `proj_all_water` `Alarm_Active`/`System_Ready` block — both migrated below). Remove any `_getTag*`/`_setTag*` helpers or fields that become unused ONLY after this deletion (keep any still used by the scan accessors / other call sites — check references first; `flutter analyze` must end clean).

- [ ] **Step 3: `proj_st_reactor` — execute `ReactorTemp_ST` (already correct)**

No data change needed — `ReactorTemp_ST`'s `stSource` already computes `Heat_Cmd`/`Cool_Cmd`/`Alarm_High`/`Alarm_Low`/`Reactor_Ready`. Deleting the hardcoded branch (Step 2) makes the executed ST the sole owner. Confirm no other program in `proj_st_reactor` writes those tags.

- [ ] **Step 4: `proj_all_water` — trim `Safety_ST` to its own domain**

Edit `Safety_ST`'s `stSource` so it keeps ONLY the ST-domain supervisory outputs and drops what FBD/LD own. The `Quality_OK` line and the `Treat_Dosing` IF block are removed; the result is:

```dart
        stSource: r'''// IEC 61131-3 Structured Text — WTP Safety Supervisor
// Runs every scan — supervisory alarms and system-ready permissive.
// (Quality_OK is computed by WaterQuality_FBD; Treat_Dosing by PumpControl_LD.)

Alarm_Active := (NOT EStop) OR (Level_PV < 5.0) OR (Turbidity_PV > (Turbidity_SP + 5.0));
System_Ready := Pump_Motor AND Quality_OK AND NOT Alarm_Active;''',
```

(`System_Ready` reads `Quality_OK` — computed this scan by FBD, which runs before ST — and `Pump_Motor` from LD. No write to `Quality_OK` or `Treat_Dosing`.)

- [ ] **Step 5: `proj_tank` — remove the redundant `TankLevelControl_ST`**

Delete the `TankLevelControl_ST` `PlcProgram(...)` entry from `proj_tank.programs`, and remove `'TankLevelControl_ST'` from the `ProcessLoopTask` `programNames` list. `TankLevel_FBD` remains the tank's authoritative controller. (Leave `TankLevel_FBD` and the empty `TankSequence_SFC` as they are.)

- [ ] **Step 6: Verify**

`flutter analyze` → No issues found! · `flutter test` → all pass · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz" lib` → no matches. Grep `_evaluateActiveLogic` → no remaining references.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/data/default_projects.dart
git commit -m "feat(st-exec): run ST each scan; execute reactor + water safety ST; retire _evaluateActiveLogic"
```

---

### Task 3: End-to-end validation

**Files:**
- Create: `mobile/test/st_exec_integration_test.dart`

- [ ] **Step 1: Integration tests against the REAL default projects**

Replicate the shell's scan order and assert parity. Confirm the real accessors/signatures (`DefaultProjects.all()`, `applySimRules`, `executeLdPrograms`, `executeFbdPrograms`, `SimRuntime`, `LdExecRuntime`, `FbdRuntime`) by reading the model files; adjust the harness to match.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('reactor ST reproduces the retired hardcoded deadband + alarms', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_st_reactor');
    final sim = SimRuntime();
    final st = StRuntime();

    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeStPrograms(p, 500, st);
    }

    void setInputs(bool auto, double temp, double sp) {
      writePath(p, 'Auto_Mode', auto);
      writePath(p, 'Temp_PV', temp);
      writePath(p, 'Temp_SP', sp);
    }

    // Auto, cold -> heat, ready false (outside deadband).
    setInputs(true, 40.0, 50.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isTrue); // 40 < 50-2
    expect(_b(p, 'Cool_Cmd'), isFalse);
    expect(_b(p, 'Reactor_Ready'), isFalse);

    // Auto, hot -> cool.
    setInputs(true, 60.0, 50.0);
    scan();
    expect(_b(p, 'Cool_Cmd'), isTrue); // 60 > 50+2
    expect(_b(p, 'Heat_Cmd'), isFalse);

    // Auto, in-band -> neither, ready true.
    setInputs(true, 50.0, 50.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
    expect(_b(p, 'Reactor_Ready'), isTrue);

    // Manual -> commands off regardless of temp.
    setInputs(false, 40.0, 50.0);
    scan();
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);

    // Over-temp alarm and under-temp alarm.
    setInputs(true, 96.0, 50.0);
    scan();
    expect(_b(p, 'Alarm_High'), isTrue); // 96 > 95
    expect(_b(p, 'Reactor_Ready'), isFalse);
    setInputs(true, 4.0, 50.0);
    scan();
    expect(_b(p, 'Alarm_Low'), isTrue); // 4 < 5
  });

  test('water Safety_ST drives Alarm_Active/System_Ready; leaves Quality_OK to '
      'FBD and Treat_Dosing to LD', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();
    final st = StRuntime();

    void scan() {
      applySimRules(p, p.simRules, 500, sim);
      executeLdPrograms(p, 500, ld);
      executeFbdPrograms(p, 500, fbd);
      executeStPrograms(p, 500, st);
    }

    // Start the pump (LD seal-in), healthy water.
    writePath(p, 'Start_PB', true);
    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 50.0);
    scan();
    writePath(p, 'Start_PB', false);
    scan();
    expect(_b(p, 'Pump_Motor'), isTrue);
    expect(_b(p, 'Quality_OK'), isTrue);   // FBD still owns this
    expect(_b(p, 'Alarm_Active'), isFalse); // EStop healthy, level ok, turb ok
    expect(_b(p, 'System_Ready'), isTrue);  // pump && quality && !alarm

    // Low level trips Alarm_Active and drops System_Ready.
    writePath(p, 'Level_PV', 3.0);
    scan();
    expect(_b(p, 'Alarm_Active'), isTrue); // level < 5
    expect(_b(p, 'System_Ready'), isFalse);

    // Treat_Dosing remains LD-driven (rung 2: dose while running with bad
    // quality). Bad turbidity, pump running -> LD sets Treat_Dosing; ST must
    // not touch it.
    writePath(p, 'Level_PV', 50.0);
    writePath(p, 'Turbidity_PV', 20.0);
    scan();
    expect(_b(p, 'Quality_OK'), isFalse);
    expect(_b(p, 'Treat_Dosing'), isTrue); // owned by PumpControl_LD rung 2
  });
}
```

Adjust asserted values to what the real projects produce if the initial tags/sim differ (read `default_projects.dart`) — HONEST parity assertions. If a genuine parity bug surfaces, STOP and report DONE_WITH_CONCERNS.

- [ ] **Step 2: Full suite + analyze + build**

`flutter test` → all pass · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz" lib test` → no matches.

- [ ] **Step 3: Commit**

```bash
git add mobile/test/st_exec_integration_test.dart
git commit -m "test(st-exec): end-to-end reactor deadband/alarms and water safety supervision"
```

---

## Self-review notes

- **Spec coverage:** statement interpreter IF/ELSIF/ELSE/END_IF (nested) + assignments + comments + multi-line expressions + never-throw, reusing `st_expr` via source substrings (Task 1) ✓; public `stripStComments` helper (Task 1) ✓; scan pipeline sim→LD→FBD→SFC→ST + runtime clear + `_evaluateActiveLogic` deleted (Task 2) ✓; reactor executes + hardcoded branch deleted (Task 2) ✓; Safety_ST trimmed to Alarm_Active/System_Ready, Quality_OK/Treat_Dosing left to FBD/LD (Task 2) ✓; proj_tank redundant ST removed + task programNames updated (Task 2) ✓; integration parity for reactor + water incl. Quality_OK-still-FBD and Treat_Dosing-still-LD (Task 3) ✓.
- **Type consistency:** `executeStPrograms(p, dtMs, rt)`, `StRuntime`/`.clear()`, `_forceAwareWrite`, `stripStComments` used identically across tasks; `evalExpr`/`evalStCondition` are the WS4b public names (NOT `evalCondition`).
- **Known limitations (per spec):** no loops/CASE/functions/VAR; stateful ST reserved but unused; SFC actions stay on `runStatements`.
- **Flagged intentional refinements:** reactor `Reactor_Ready` explicit form; water `Alarm_Active` turbidity margin `+5.0` (ST source) vs old `+8.0`.
