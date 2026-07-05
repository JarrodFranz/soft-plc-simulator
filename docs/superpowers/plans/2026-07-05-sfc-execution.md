# SFC Execution Engine (WS4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute SFC programs for real — an ST-subset evaluator runs step actions and transition conditions (with an implicit `STEP_T` step timer), replacing the hardcoded bottle-filler and water-backwash state machines.

**Architecture:** A pure `st_expr.dart` (lexer + recursive-descent evaluator for the ST expression/assignment subset the shipped charts use — the seed of the future full ST interpreter) is consumed by a pure `sfc_exec.dart` (one active step per program; N-action semantics each scan; first-true transition switches steps next scan; scan-tick `STEP_T`). `workspace_shell` runs sim → LD → **SFC** → remaining hardcoded logic.

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` must report **zero** issues. Braces on all flow-control bodies; prefer `const`; `x.isNotEmpty` not `x.length >= 1`; `withValues(alpha:)` not `withOpacity`; `initialValue:` not `value:` on dropdowns.
- No RenderFlex overflow. All shell commands run from `mobile/`.
- Clocks advance by scan ticks (`dtMs`). A forced ROOT tag is never overwritten (`root.isForced && path == root.name` → skip), matching `ld_exec.dart`/`sim_engine.dart`.
- Behavior parity with the removed hardcoded logic at the default 500 ms scan — EXCEPT the flagged, deliberate change: water backwash now starts after the ladder's 30 s `BackwashTimer` (rung 4 drives `Backwash_Active`) instead of instantly.
- Evaluators NEVER throw on malformed input (return null / skip statement).

**Sequencing:** Tasks 1-2 are additive/green. Task 3 wires SFC execution in and removes the replaced hardcoded logic in the SAME commit. Task 4 validates end-to-end.

---

### Task 1: ST-subset expression/assignment evaluator + tests

**Files:**
- Create: `mobile/lib/models/st_expr.dart`
- Test: `mobile/test/st_expr_test.dart`

**Interfaces:**
- Consumes: `PlcProject` from `project_model.dart`; `readPath` from `tag_resolver.dart`.
- Produces (used by Task 2): `dynamic evalExpr(PlcProject p, String source, {Map<String, dynamic> extraVars})`; `bool evalStCondition(PlcProject p, String source, {Map<String, dynamic> extraVars})`; `void runStatements(PlcProject p, String source, void Function(String path, dynamic value) write, {Map<String, dynamic> extraVars})`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/st_expr_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_expr.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _proj(List<PlcTag> tags) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [],
    );

void main() {
  final p = _proj([
    _tag('Start_Cmd', 'BOOL', true),
    _tag('Bottle_Present', 'BOOL', false),
    _tag('Fill_Level', 'FLOAT64', 96.5),
    _tag('Filled_Count', 'INT32', 7),
    _tag('Turbidity_SP', 'FLOAT64', 5.0),
  ]);

  test('literals and identifiers', () {
    expect(evalExpr(p, 'TRUE'), isTrue);
    expect(evalExpr(p, 'false'), isFalse);
    expect(evalExpr(p, '42'), equals(42));
    expect(evalExpr(p, '95.0'), equals(95.0));
    expect(evalExpr(p, 'Start_Cmd'), isTrue);
    expect(evalExpr(p, 'Filled_Count'), equals(7));
    expect(evalExpr(p, 'No_Such_Tag'), isNull);
  });

  test('extraVars shadow tags (STEP_T)', () {
    expect(evalExpr(p, 'STEP_T', extraVars: {'STEP_T': 1200}), equals(1200));
    expect(evalStCondition(p, 'STEP_T >= 3000', extraVars: {'STEP_T': 2999}), isFalse);
    expect(evalStCondition(p, 'STEP_T >= 3000', extraVars: {'STEP_T': 3000}), isTrue);
  });

  test('comparators', () {
    expect(evalExpr(p, 'Fill_Level >= 95.0'), isTrue);
    expect(evalExpr(p, 'Fill_Level < 95.0'), isFalse);
    expect(evalExpr(p, 'Filled_Count = 7'), isTrue);
    expect(evalExpr(p, 'Filled_Count <> 7'), isFalse);
    expect(evalExpr(p, 'Start_Cmd = TRUE'), isTrue);
    expect(evalExpr(p, 'Start_Cmd <> FALSE'), isTrue);
  });

  test('boolean operators and precedence', () {
    expect(evalExpr(p, 'Start_Cmd AND NOT Bottle_Present'), isTrue);
    expect(evalExpr(p, 'Bottle_Present OR Start_Cmd'), isTrue);
    expect(evalExpr(p, 'NOT Start_Cmd OR Start_Cmd AND Start_Cmd'), isTrue);
    expect(evalExpr(p, 'Start_Cmd AND (Bottle_Present OR TRUE)'), isTrue);
    expect(evalExpr(p, 'Start_Cmd XOR Start_Cmd'), isFalse);
  });

  test('arithmetic keeps int-ness and supports mixing', () {
    expect(evalExpr(p, 'Filled_Count + 1'), equals(8));
    expect(evalExpr(p, 'Filled_Count + 1') is int, isTrue);
    expect(evalExpr(p, '2 * 3 + 4'), equals(10));
    expect(evalExpr(p, '2 + 3 * 4'), equals(14));
    expect(evalExpr(p, '-Filled_Count'), equals(-7));
    expect(evalExpr(p, 'Turbidity_SP + 1'), equals(6.0));
    expect(evalExpr(p, '1 / 0'), isNull); // division by zero -> null
  });

  test('comments are stripped', () {
    expect(evalExpr(p, 'TRUE  (* 1s cap press timer *)'), isTrue);
    expect(evalStCondition(p, 'Start_Cmd (* gate *) AND TRUE'), isTrue);
  });

  test('malformed input returns null / false, never throws', () {
    expect(evalExpr(p, ''), isNull);
    expect(evalExpr(p, 'AND AND'), isNull);
    expect(evalExpr(p, 'Fill_Level >='), isNull);
    expect(evalExpr(p, '((('), isNull);
    expect(evalStCondition(p, 'garbage ~~ here'), isFalse);
  });

  test('runStatements executes assignment lists, skipping comments', () {
    final p2 = _proj([
      _tag('Fill_Valve', 'BOOL', false),
      _tag('Filled_Count', 'INT32', 7),
      _tag('Sfc_Step', 'INT32', 0),
    ]);
    final writes = <String, dynamic>{};
    runStatements(p2, '''
Fill_Valve := TRUE;
// line comment
Filled_Count := Filled_Count + 1;
Sfc_Step := 4;  (* display sync *)
''', (path, v) => writes[path] = v);
    expect(writes['Fill_Valve'], isTrue);
    expect(writes['Filled_Count'], equals(8));
    expect(writes['Sfc_Step'], equals(4));
  });

  test('runStatements skips malformed lines without throwing', () {
    final p2 = _proj([_tag('A', 'BOOL', false)]);
    final writes = <String, dynamic>{};
    runStatements(p2, 'A := TRUE;\nnonsense here;\nA := FALSE;',
        (path, v) => writes[path] = v);
    expect(writes['A'], isFalse); // both valid lines ran, bad one skipped
  });
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `flutter test test/st_expr_test.dart` → FAIL (`st_expr.dart` missing).

- [ ] **Step 3: Implement `st_expr.dart`**

Create `mobile/lib/models/st_expr.dart`:

```dart
import 'project_model.dart';
import 'tag_resolver.dart';

/// Minimal ST expression/assignment subset used by SFC charts (and the seed
/// of the future full ST interpreter): tag-path identifiers, TRUE/FALSE,
/// int/double literals, AND/OR/XOR/NOT, comparators (= <> < > <= >=),
/// + - * /, parentheses, `(* *)` and `//` comments, `path := expr;`
/// statements. Malformed input yields null / is skipped — never throws.

String _stripComments(String src) {
  final sb = StringBuffer();
  int i = 0;
  while (i < src.length) {
    if (i + 1 < src.length && src[i] == '(' && src[i + 1] == '*') {
      final end = src.indexOf('*)', i + 2);
      if (end == -1) {
        break; // unterminated block comment: drop the rest
      }
      i = end + 2;
    } else if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
      final nl = src.indexOf('\n', i);
      if (nl == -1) {
        break;
      }
      i = nl;
    } else {
      sb.write(src[i]);
      i++;
    }
  }
  return sb.toString();
}

class _Tok {
  final String kind; // 'num','ident','op','kw'
  final String text;
  final num? number;
  _Tok(this.kind, this.text, [this.number]);
}

const Set<String> _keywords = {'TRUE', 'FALSE', 'AND', 'OR', 'XOR', 'NOT'};

List<_Tok>? _lex(String src) {
  final toks = <_Tok>[];
  int i = 0;
  bool isIdentStart(String c) => RegExp(r'[A-Za-z_]').hasMatch(c);
  bool isIdentPart(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);
  while (i < src.length) {
    final c = src[i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      i++;
      continue;
    }
    if (RegExp(r'[0-9]').hasMatch(c)) {
      int j = i;
      bool isDouble = false;
      while (j < src.length && RegExp(r'[0-9]').hasMatch(src[j])) {
        j++;
      }
      if (j < src.length && src[j] == '.' && j + 1 < src.length &&
          RegExp(r'[0-9]').hasMatch(src[j + 1])) {
        isDouble = true;
        j++;
        while (j < src.length && RegExp(r'[0-9]').hasMatch(src[j])) {
          j++;
        }
      }
      final text = src.substring(i, j);
      toks.add(_Tok('num', text, isDouble ? double.parse(text) : int.parse(text)));
      i = j;
      continue;
    }
    if (isIdentStart(c)) {
      int j = i;
      final sb = StringBuffer();
      // A path identifier: word, then any run of .word / .digits / [digits]
      while (j < src.length && isIdentPart(src[j])) {
        sb.write(src[j]);
        j++;
      }
      while (j < src.length) {
        if (src[j] == '.' && j + 1 < src.length &&
            RegExp(r'[A-Za-z0-9_]').hasMatch(src[j + 1])) {
          sb.write('.');
          j++;
          while (j < src.length && isIdentPart(src[j])) {
            sb.write(src[j]);
            j++;
          }
        } else if (src[j] == '[') {
          final close = src.indexOf(']', j);
          if (close == -1) {
            return null;
          }
          sb.write(src.substring(j, close + 1));
          j = close + 1;
        } else {
          break;
        }
      }
      final word = sb.toString();
      final upper = word.toUpperCase();
      if (_keywords.contains(upper) && !word.contains('.') && !word.contains('[')) {
        toks.add(_Tok('kw', upper));
      } else {
        toks.add(_Tok('ident', word));
      }
      i = j;
      continue;
    }
    // multi-char operators first
    if (i + 1 < src.length) {
      final two = src.substring(i, i + 2);
      if (two == ':=' || two == '<>' || two == '<=' || two == '>=') {
        toks.add(_Tok('op', two));
        i += 2;
        continue;
      }
    }
    if ('=<>+-*/();'.contains(c)) {
      toks.add(_Tok('op', c));
      i++;
      continue;
    }
    return null; // unknown character -> lex failure
  }
  return toks;
}

class _Parser {
  final PlcProject p;
  final List<_Tok> toks;
  final Map<String, dynamic> vars;
  int pos = 0;
  bool failed = false;
  _Parser(this.p, this.toks, this.vars);

  _Tok? get _peek => pos < toks.length ? toks[pos] : null;
  _Tok? _take() => pos < toks.length ? toks[pos++] : null;
  bool _isOp(String t) => _peek != null && _peek!.kind == 'op' && _peek!.text == t;
  bool _isKw(String t) => _peek != null && _peek!.kind == 'kw' && _peek!.text == t;

  bool? _truthy(dynamic v) {
    if (v is bool) {
      return v;
    }
    if (v is num) {
      return v != 0;
    }
    return null;
  }

  dynamic parseExpr() => _or();

  dynamic _or() {
    var left = _xor();
    while (_isKw('OR')) {
      _take();
      final right = _xor();
      final l = _truthy(left), r = _truthy(right);
      left = (l == null || r == null) ? null : (l || r);
    }
    return left;
  }

  dynamic _xor() {
    var left = _and();
    while (_isKw('XOR')) {
      _take();
      final right = _and();
      final l = _truthy(left), r = _truthy(right);
      left = (l == null || r == null) ? null : (l ^ r);
    }
    return left;
  }

  dynamic _and() {
    var left = _not();
    while (_isKw('AND')) {
      _take();
      final right = _not();
      final l = _truthy(left), r = _truthy(right);
      left = (l == null || r == null) ? null : (l && r);
    }
    return left;
  }

  dynamic _not() {
    if (_isKw('NOT')) {
      _take();
      final v = _truthy(_not());
      return v == null ? null : !v;
    }
    return _cmp();
  }

  dynamic _cmp() {
    final left = _add();
    if (_peek != null && _peek!.kind == 'op' &&
        ['=', '<>', '<', '>', '<=', '>='].contains(_peek!.text)) {
      final op = _take()!.text;
      final right = _add();
      if (left is num && right is num) {
        switch (op) {
          case '=':
            return left == right;
          case '<>':
            return left != right;
          case '<':
            return left < right;
          case '>':
            return left > right;
          case '<=':
            return left <= right;
          case '>=':
            return left >= right;
        }
      }
      if (left is bool && right is bool) {
        if (op == '=') {
          return left == right;
        }
        if (op == '<>') {
          return left != right;
        }
      }
      return null;
    }
    return left;
  }

  dynamic _add() {
    var left = _mul();
    while (_isOp('+') || _isOp('-')) {
      final op = _take()!.text;
      final right = _mul();
      if (left is num && right is num) {
        left = op == '+' ? left + right : left - right;
      } else {
        left = null;
      }
    }
    return left;
  }

  dynamic _mul() {
    var left = _unary();
    while (_isOp('*') || _isOp('/')) {
      final op = _take()!.text;
      final right = _unary();
      if (left is num && right is num) {
        if (op == '*') {
          left = left * right;
        } else {
          left = right == 0 ? null : left / right;
        }
      } else {
        left = null;
      }
    }
    return left;
  }

  dynamic _unary() {
    if (_isOp('-')) {
      _take();
      final v = _unary();
      return v is num ? -v : null;
    }
    return _primary();
  }

  dynamic _primary() {
    final t = _take();
    if (t == null) {
      failed = true;
      return null;
    }
    if (t.kind == 'num') {
      return t.number;
    }
    if (t.kind == 'kw') {
      if (t.text == 'TRUE') {
        return true;
      }
      if (t.text == 'FALSE') {
        return false;
      }
      failed = true;
      return null;
    }
    if (t.kind == 'ident') {
      if (vars.containsKey(t.text)) {
        return vars[t.text];
      }
      return readPath(p, t.text);
    }
    if (t.kind == 'op' && t.text == '(') {
      final v = parseExpr();
      if (_isOp(')')) {
        _take();
        return v;
      }
      failed = true;
      return null;
    }
    failed = true;
    return null;
  }
}

/// Evaluates an ST expression; null on any lex/parse/type error.
dynamic evalExpr(PlcProject p, String source, {Map<String, dynamic> extraVars = const {}}) {
  final toks = _lex(_stripComments(source));
  if (toks == null || toks.isEmpty) {
    return null;
  }
  final parser = _Parser(p, toks, extraVars);
  final v = parser.parseExpr();
  if (parser.failed || parser.pos != toks.length) {
    return null;
  }
  return v;
}

/// True when the expression evaluates truthy (true, or a non-zero number).
bool evalStCondition(PlcProject p, String source, {Map<String, dynamic> extraVars = const {}}) {
  final v = evalExpr(p, source, extraVars: extraVars);
  if (v is bool) {
    return v;
  }
  if (v is num) {
    return v != 0;
  }
  return false;
}

/// Runs a `;`-separated list of `path := expr` assignments through [write].
/// Comments/blank statements are skipped; malformed statements are skipped.
void runStatements(PlcProject p, String source,
    void Function(String path, dynamic value) write,
    {Map<String, dynamic> extraVars = const {}}) {
  final clean = _stripComments(source);
  for (final raw in clean.split(';')) {
    final stmt = raw.trim();
    if (stmt.isEmpty) {
      continue;
    }
    final idx = stmt.indexOf(':=');
    if (idx <= 0) {
      continue;
    }
    final path = stmt.substring(0, idx).trim();
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_\.\[\]]*$').hasMatch(path)) {
      continue;
    }
    final value = evalExpr(p, stmt.substring(idx + 2), extraVars: extraVars);
    if (value != null) {
      write(path, value);
    }
  }
}
```

- [ ] **Step 4: Run tests → PASS (9 tests). Step 5: `flutter analyze` → No issues found!**

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/st_expr.dart mobile/test/st_expr_test.dart
git commit -m "feat(st): ST-subset expression/assignment evaluator (seed of the ST interpreter)"
```

---

### Task 2: SFC execution engine + tests

**Files:**
- Create: `mobile/lib/models/sfc_exec.dart`
- Test: `mobile/test/sfc_exec_test.dart`

**Interfaces:**
- Consumes: `evalStCondition`, `runStatements` from Task 1; `PlcProject`, `PlcProgram`, `SfcStep`, `SfcTransition` from `project_model.dart`; `writePath` from `tag_resolver.dart`.
- Produces (used by Task 3): `class SfcRuntime { Map<String,String> activeStepId; Map<String,int> stepElapsedMs; void clear(); }`; `void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt)`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/sfc_exec_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProgram _sfc(List<SfcStep> steps, List<SfcTransition> ts) {
  final prog = PlcProgram(name: 'S1', language: 'SequentialFunctionChart');
  prog.sfcSteps.addAll(steps);
  prog.sfcTransitions.addAll(ts);
  return prog;
}

PlcProject _proj(List<PlcTag> tags, PlcProgram prog) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('initial step activates and its N-action runs every scan', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'IDLE', isInitial: true, actionSt: 'Out := TRUE;'),
      SfcStep(id: 's1', name: 'RUN', actionSt: 'Out := FALSE;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
    ]);
    final p = _proj([_tag('Out', 'BOOL', false), _tag('Go', 'BOOL', false)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt);
    expect(_b(p, 'Out'), isTrue);
    writePath(p, 'Out', false);
    executeSfcPrograms(p, 100, rt); // still IDLE, N-action re-runs
    expect(_b(p, 'Out'), isTrue);
  });

  test('transition fires and the new step acts on the NEXT scan', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'A', isInitial: true, actionSt: 'X := 1;'),
      SfcStep(id: 's1', name: 'B', actionSt: 'X := 2;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Go'),
    ]);
    final p = _proj([_tag('X', 'INT32', 0), _tag('Go', 'BOOL', true)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt); // A acts, then transition fires
    expect(readPath(p, 'X'), equals(1));
    executeSfcPrograms(p, 100, rt); // B acts now
    expect(readPath(p, 'X'), equals(2));
  });

  test('STEP_T gates a timed transition and resets on step entry', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'HOLD', isInitial: true, actionSt: ''),
      SfcStep(id: 's1', name: 'DONE', actionSt: 'Done := TRUE;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'STEP_T >= 300'),
    ]);
    final p = _proj([_tag('Done', 'BOOL', false)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt); // T=100
    executeSfcPrograms(p, 100, rt); // T=200
    expect(_b(p, 'Done'), isFalse);
    executeSfcPrograms(p, 100, rt); // T=300 -> fires
    executeSfcPrograms(p, 100, rt); // DONE acts
    expect(_b(p, 'Done'), isTrue);
  });

  test('one-scan step executes its action exactly once (COUNT idiom)', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'WAIT', isInitial: true, actionSt: ''),
      SfcStep(id: 'sc', name: 'COUNT', actionSt: 'N := N + 1;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 'sc', conditionSt: 'Go'),
      SfcTransition(id: 't1', fromStepId: 'sc', toStepId: 's0', conditionSt: 'TRUE'),
    ]);
    final p = _proj([_tag('N', 'INT32', 0), _tag('Go', 'BOOL', true)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt); // WAIT -> fires to COUNT
    writePath(p, 'Go', false);      // only one visit
    executeSfcPrograms(p, 100, rt); // COUNT acts once, fires back to WAIT
    executeSfcPrograms(p, 100, rt); // WAIT again
    executeSfcPrograms(p, 100, rt);
    expect(readPath(p, 'N'), equals(1));
  });

  test('first true transition wins in list order', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'A', isInitial: true, actionSt: ''),
      SfcStep(id: 's1', name: 'B', actionSt: 'X := 1;'),
      SfcStep(id: 's2', name: 'C', actionSt: 'X := 2;'),
    ], [
      SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'TRUE'),
      SfcTransition(id: 't1', fromStepId: 's0', toStepId: 's2', conditionSt: 'TRUE'),
    ]);
    final p = _proj([_tag('X', 'INT32', 0)], prog);
    final rt = SfcRuntime();
    executeSfcPrograms(p, 100, rt);
    executeSfcPrograms(p, 100, rt);
    expect(readPath(p, 'X'), equals(1)); // went to B, not C
  });

  test('a forced root tag is not overwritten by an action', () {
    final prog = _sfc([
      SfcStep(id: 's0', name: 'A', isInitial: true, actionSt: 'Y := TRUE;'),
    ], []);
    final p = _proj([_tag('Y', 'BOOL', false, forced: true, fv: false)], prog);
    executeSfcPrograms(p, 100, SfcRuntime());
    expect(readPath(p, 'Y'), isFalse);
  });

  test('non-SFC programs and empty charts are skipped without throwing', () {
    final prog = PlcProgram(name: 'L', language: 'LadderLogic');
    final p = _proj([_tag('Y', 'BOOL', false)], prog);
    executeSfcPrograms(p, 100, SfcRuntime());
    final empty = PlcProgram(name: 'E', language: 'SequentialFunctionChart');
    final p2 = _proj([], empty);
    executeSfcPrograms(p2, 100, SfcRuntime());
    expect(true, isTrue); // reached without exception
  });
}
```

- [ ] **Step 2: Run → FAIL. Step 3: Implement `sfc_exec.dart`:**

```dart
import 'project_model.dart';
import 'st_expr.dart';
import 'tag_resolver.dart';

/// Active-step state per SFC program, keyed by program name.
class SfcRuntime {
  final Map<String, String> activeStepId = {};
  final Map<String, int> stepElapsedMs = {};
  void clear() {
    activeStepId.clear();
    stepElapsedMs.clear();
  }
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

/// Executes every SequentialFunctionChart program: the active step's action
/// runs each scan (N semantics), STEP_T accumulates by scan ticks, and the
/// first true outgoing transition (list order) switches the active step —
/// the new step acts from the next scan.
void executeSfcPrograms(PlcProject p, int dtMs, SfcRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'SequentialFunctionChart' || prog.sfcSteps.isEmpty) {
      continue;
    }
    // Resolve (or initialize) the active step.
    SfcStep? active;
    final currentId = rt.activeStepId[prog.name];
    if (currentId != null) {
      for (final s in prog.sfcSteps) {
        if (s.id == currentId) {
          active = s;
          break;
        }
      }
    }
    if (active == null) {
      for (final s in prog.sfcSteps) {
        if (s.isInitial) {
          active = s;
          break;
        }
      }
      active ??= prog.sfcSteps.first;
      rt.activeStepId[prog.name] = active.id;
      rt.stepElapsedMs[prog.name] = 0;
    }

    final elapsed = (rt.stepElapsedMs[prog.name] ?? 0) + dtMs;
    rt.stepElapsedMs[prog.name] = elapsed;
    final vars = {'STEP_T': elapsed};

    // N-action: every scan while the step is active.
    runStatements(p, active.actionSt, (path, v) => _forceAwareWrite(p, path, v),
        extraVars: vars);

    // First true outgoing transition switches the step (effective next scan).
    for (final t in prog.sfcTransitions) {
      if (t.fromStepId != active.id) {
        continue;
      }
      if (evalStCondition(p, t.conditionSt, extraVars: vars)) {
        final targetExists = prog.sfcSteps.any((s) => s.id == t.toStepId);
        if (targetExists) {
          rt.activeStepId[prog.name] = t.toStepId;
          rt.stepElapsedMs[prog.name] = 0;
        }
        break;
      }
    }
  }
}
```

- [ ] **Step 4: Run → PASS (7 tests). Step 5: `flutter analyze` → No issues found!**

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/sfc_exec.dart mobile/test/sfc_exec_test.dart
git commit -m "feat(sfc-exec): SFC step-machine execution with ST actions/conditions and STEP_T"
```

---

### Task 3: Scan wiring + migrate the hardcoded state machines

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Modify: `mobile/lib/data/default_projects.dart`

**Interfaces:**
- Consumes: `executeSfcPrograms`, `SfcRuntime` from Task 2.

**Same-commit rule:** SFC wiring and the removal of the replaced hardcoded logic land together (no double-drive window).

- [ ] **Step 1: Wire SFC into the scan**

In `workspace_shell.dart`: `import '../models/sfc_exec.dart';`, field `final SfcRuntime _sfcRuntime = SfcRuntime();`. In `_executeScan`, after `executeLdPrograms(...)` and before `_evaluateActiveLogic();`:

```dart
      executeSfcPrograms(_activeProject, scanSpeedMs, _sfcRuntime);
```

Where the active project switches (alongside `_simRuntime.byRuleId.clear();` and `_ldRuntime.clear();`), add `_sfcRuntime.clear();`.

- [ ] **Step 2: Migrate the bottle filler (`proj_sfc_filling`)**

In `default_projects.dart` (`_sfcFillingProject`), replace the `BottleFill_SFC` steps/transitions with (parity at the 500 ms default; `Sfc_Step := N` keeps the HMI display live; `COUNT` is the one-scan increment step):

```dart
        sfcSteps: [
          SfcStep(id: 's0', name: 'IDLE', isInitial: true,
            actionSt: 'Sfc_Step := 0;\nFill_Valve := FALSE;\nCap_Solenoid := FALSE;\nEject_Cyl := FALSE;\nSequence_Running := FALSE;\nFill_Level := 0.0;'),
          SfcStep(id: 's1', name: 'WAIT_BOTTLE',
            actionSt: 'Sfc_Step := 1;\nSequence_Running := TRUE;\nFill_Valve := FALSE;\nEject_Cyl := FALSE;\nFill_Level := 0.0;'),
          SfcStep(id: 's2', name: 'FILLING',
            actionSt: 'Sfc_Step := 2;\nFill_Valve := TRUE;'),
          SfcStep(id: 's3', name: 'CAPPING',
            actionSt: 'Sfc_Step := 3;\nFill_Valve := FALSE;\nCap_Solenoid := TRUE;'),
          SfcStep(id: 's4', name: 'EJECTING',
            actionSt: 'Sfc_Step := 4;\nCap_Solenoid := FALSE;\nEject_Cyl := TRUE;'),
          SfcStep(id: 's5', name: 'COUNT',
            actionSt: 'Sfc_Step := 5;\nFilled_Count := Filled_Count + 1;\nEject_Cyl := FALSE;'),
        ],
        sfcTransitions: [
          SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Start_Cmd'),
          SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Bottle_Present'),
          SfcTransition(id: 't2', fromStepId: 's2', toStepId: 's3', conditionSt: 'Fill_Level >= 95.0'),
          SfcTransition(id: 't3', fromStepId: 's3', toStepId: 's4', conditionSt: 'STEP_T >= 3000  (* cap press dwell *)'),
          SfcTransition(id: 't4', fromStepId: 's4', toStepId: 's5', conditionSt: 'STEP_T >= 2000  (* eject stroke *)'),
          SfcTransition(id: 't5', fromStepId: 's5', toStepId: 's1', conditionSt: 'TRUE'),
        ],
```

(Match the actual field/parameter shape in the file — if steps/transitions are added via `..sfcSteps.addAll([...])` or constructor params, keep that structure and swap the contents.) Then DELETE the entire `proj_sfc_filling` block from `_evaluateActiveLogic` (all of it — outputs, step machine, `Sfc_Step`/`Step_Delay` writes, and the `Fill_Level` reset; the SFC now owns all of it).

- [ ] **Step 3: Migrate the water backwash (`proj_all_water`)**

In `_allWaterProject`'s `FilterBackwash_SFC`, make the timed placeholders real:
- `bt1` condition → `'STEP_T >= 5000  (* valve open dwell *)'`
- `bt3` condition → `'STEP_T >= 10000  (* rinse cycle *)'`
(leave `bt0` `Backwash_Active`, `bt2` `Quality_OK ...`, `bt4` `NOT Backwash_Active` as they are).

In `workspace_shell._evaluateActiveLogic`'s `proj_all_water` block: DELETE the `Backwash_Active`, `Backwash_Valve`, and `Backwash_Pump` writes and the WS4a "stays hardcoded until SFC execution" comment block. Rung 4 of `PumpControl_LD` (`BackwashTimer.DN → OTE Backwash_Active`) now genuinely drives `Backwash_Active` (its shadow-write conflict is gone), and the SFC drives valve/pump. KEEP `Quality_OK` (FBD — WS4c) and `Alarm_Active`/`System_Ready` (ST — WS4d). Add a short comment noting the split.

- [ ] **Step 4: Verify**

`flutter analyze` → No issues found! · `flutter test` → all pass · `flutter build web --release` → succeeds.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/data/default_projects.dart
git commit -m "feat(sfc-exec): run SFC programs each scan; migrate bottle filler and water backwash to executed charts"
```

---

### Task 4: End-to-end validation

**Files:**
- Create: `mobile/test/sfc_exec_integration_test.dart`

- [ ] **Step 1: Write integration tests against the REAL default projects**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

// One scan tick exactly as the workspace shell runs it.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, SfcRuntime sfc,
    [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeSfcPrograms(p, dtMs, sfc);
}

bool _b(PlcProject p, String path) => readPath(p, path) == true;
int _i(PlcProject p, String path) => (readPath(p, path) as num?)?.toInt() ?? 0;

void main() {
  test('bottle filler: two full cycles, one count each, display tag tracks', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_sfc_filling');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final sfc = SfcRuntime();

    _scan(p, sim, ld, sfc); // IDLE
    expect(_i(p, 'Sfc_Step'), equals(0));
    writePath(p, 'Start_Cmd', true);
    _scan(p, sim, ld, sfc); // IDLE fires -> WAIT_BOTTLE next
    writePath(p, 'Bottle_Present', true);

    int counted = 0;
    for (int i = 0; i < 80 && counted < 2; i++) {
      _scan(p, sim, ld, sfc);
      if (_i(p, 'Sfc_Step') == 5) {
        counted++;
        // one-scan COUNT step: after it, the count must have incremented once
      }
    }
    expect(counted, equals(2), reason: 'two bottles should complete within 40s sim time');
    expect(_i(p, 'Filled_Count'), equals(2)); // exactly one increment per bottle
  });

  test('water plant: 30s ladder timer starts backwash; SFC sequences valve/pump', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final sfc = SfcRuntime();

    writePath(p, 'Start_PB', true);
    _scan(p, sim, ld, sfc);
    writePath(p, 'Start_PB', false);
    expect(_b(p, 'Pump_Motor'), isTrue);

    // Force bad quality persistently: pin turbidity above SP so the FBD-domain
    // hardcoded Quality_OK stays false and the ladder's 30s BackwashTimer runs.
    final turb = p.tags.firstWhere((t) => t.name == 'Turbidity_PV');
    turb.isForced = true;
    turb.forcedValue = 12.0;
    turb.value = 12.0;

    // Note: _evaluateActiveLogic (Quality_OK etc.) is not run here; emulate
    // its FBD-domain output for the harness:
    writePath(p, 'Quality_OK', false);

    bool sawBackwash = false;
    bool sawValve = false;
    for (int i = 0; i < 70; i++) {
      _scan(p, sim, ld, sfc);
      writePath(p, 'Quality_OK', false); // keep FBD-domain emulation pinned
      if (_b(p, 'Backwash_Active')) {
        sawBackwash = true;
      }
      if (_b(p, 'Backwash_Valve')) {
        sawValve = true;
      }
    }
    expect(sawBackwash, isTrue, reason: 'BackwashTimer (30s) should trip within 35s');
    expect(sawValve, isTrue, reason: 'SFC should open the backwash valve');
  });
}
```

- [ ] **Step 2: Full suite + analyze + build**

`flutter test` → all pass · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds.
`grep -ri "openplc" mobile/lib mobile/test` → no matches.

- [ ] **Step 3: Commit**

```bash
git add mobile/test/sfc_exec_integration_test.dart
git commit -m "test(sfc-exec): end-to-end bottle cycles and water backwash sequencing"
```

---

## Self-review notes

- **Spec coverage:** ST-subset evaluator w/ comments + never-throws (Task 1) ✓; SFC engine (initial step, N-actions, STEP_T, first-true, next-scan switch, force-aware) (Task 2) ✓; scan pipeline sim→LD→SFC→hardcoded + runtime reset (Task 3) ✓; filling migration incl. `Sfc_Step` sync, WAIT_BOTTLE `Fill_Level` reset, COUNT one-shot, STEP_T dwells (Task 3) ✓; water migration incl. deleting the WS4a shadow-write, rung-driven `Backwash_Active`, STEP_T valve/rinse timers (Task 3) ✓; flagged backwash-delay behavior change carried in constraints ✓; integration tests for two-cycle counting + backwash sequencing (Task 4) ✓.
- **Type consistency:** `evalExpr`/`evalStCondition`/`runStatements` (note: NOT `evalCondition` — that name is taken by `sim_engine.dart`), `SfcRuntime`, `executeSfcPrograms(p, dtMs, rt)` used identically across tasks.
- **Known limitations (per spec):** single active step; N-only qualifiers; no IF/loops; `Step_Delay` tag retained but unwritten.
