# FBD Execution Engine (WS4c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute Function Block Diagram programs for real — a pure dataflow evaluator runs the block graph each scan, replacing the hardcoded HVAC controller and water-quality gate with faithful executable diagrams.

**Architecture:** `fbd_exec.dart` (pure Dart) topologically evaluates `FbdBlock`/`FbdWire` graphs with a well-defined block set (logic, arithmetic, comparators, CONST, LIMIT clamp, TAG_INPUT/OUTPUT), input order = wire order. `workspace_shell` runs sim → LD → **FBD** → SFC → remaining ST leftovers. The two shipped diagrams are redrawn to be behaviorally identical to the deleted hardcoded logic; the editor palette gains the new block types.

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` reports **zero** issues. Braces on all flow-control bodies; prefer `const`; `x.isNotEmpty` not `x.length >= 1`; `withValues(alpha:)` not `withOpacity`; `initialValue:` not `value:` on `DropdownButtonFormField`.
- No RenderFlex overflow. All shell commands run from `mobile/`.
- Clocks advance by scan ticks (`dtMs`). A forced ROOT tag is never overwritten (`root.isForced && path == root.name` → skip), matching `ld_exec.dart`/`sfc_exec.dart`.
- Behavior parity with the removed hardcoded logic at the default 500 ms scan — no behavior change (the migrated diagrams reproduce the hardcoded formulas exactly).
- Evaluators NEVER throw on malformed input (return null / skip) and NEVER hang (cycles terminate).

**Sequencing:** Task 1 is additive (engine + tests). Task 2 wires FBD in, migrates both diagrams, and deletes the replaced hardcoded logic in the SAME commit. Task 3 adds editor palette entries. Task 4 validates end-to-end.

---

### Task 1: FBD dataflow evaluator + tests

**Files:**
- Create: `mobile/lib/models/fbd_exec.dart`
- Test: `mobile/test/fbd_exec_test.dart`

**Interfaces:**
- Consumes: `PlcProject`, `PlcProgram`, `FbdBlock`, `FbdWire`, `PlcTag` from `project_model.dart`; `readPath`, `writePath` from `tag_resolver.dart`.
- Produces (used by Tasks 2/4): `class FbdRuntime { void clear(); }`; `void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt)`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/fbd_exec_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProgram _fbd(List<FbdBlock> blocks, List<FbdWire> wires) {
  final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
  prog.fbdBlocks.addAll(blocks);
  prog.fbdWires.addAll(wires);
  return prog;
}

PlcProject _proj(List<PlcTag> tags, PlcProgram prog) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

void _run(PlcProject p) => executeFbdPrograms(p, 500, FbdRuntime());

void main() {
  test('TAG_INPUT -> NOT -> TAG_OUTPUT', () {
    final prog = _fbd([
      FbdBlock(id: 'i', type: 'TAG_INPUT', title: 'In', tagBinding: 'A'),
      FbdBlock(id: 'n', type: 'NOT', title: 'Not'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'B'),
    ], [
      FbdWire(fromBlockId: 'i', toBlockId: 'n'),
      FbdWire(fromBlockId: 'n', toBlockId: 'o'),
    ]);
    final p = _proj([_tag('A', 'BOOL', true), _tag('B', 'BOOL', false)], prog);
    _run(p);
    expect(readPath(p, 'B'), isFalse);
  });

  test('AND / OR truthiness incl. numeric input and empty AND', () {
    final prog = _fbd([
      FbdBlock(id: 'a', type: 'TAG_INPUT', title: '', tagBinding: 'A'),
      FbdBlock(id: 'b', type: 'TAG_INPUT', title: '', tagBinding: 'B'),
      FbdBlock(id: 'and', type: 'AND', title: ''),
      FbdBlock(id: 'or', type: 'OR', title: ''),
      FbdBlock(id: 'oand', type: 'TAG_OUTPUT', title: '', tagBinding: 'AndOut'),
      FbdBlock(id: 'oor', type: 'TAG_OUTPUT', title: '', tagBinding: 'OrOut'),
    ], [
      FbdWire(fromBlockId: 'a', toBlockId: 'and'),
      FbdWire(fromBlockId: 'b', toBlockId: 'and'),
      FbdWire(fromBlockId: 'a', toBlockId: 'or'),
      FbdWire(fromBlockId: 'b', toBlockId: 'or'),
      FbdWire(fromBlockId: 'and', toBlockId: 'oand'),
      FbdWire(fromBlockId: 'or', toBlockId: 'oor'),
    ]);
    final p = _proj([
      _tag('A', 'BOOL', true), _tag('B', 'INT32', 0), // B numeric 0 -> false
      _tag('AndOut', 'BOOL', false), _tag('OrOut', 'BOOL', false),
    ], prog);
    _run(p);
    expect(readPath(p, 'AndOut'), isFalse); // true AND 0
    expect(readPath(p, 'OrOut'), isTrue);   // true OR 0
  });

  test('SUB respects wire order; DIV by zero -> no write', () {
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: '', tagBinding: 'X'),
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: '1.0'),
      FbdBlock(id: 'sub', type: 'SUB', title: ''),
      FbdBlock(id: 'osub', type: 'TAG_OUTPUT', title: '', tagBinding: 'Sub'),
      FbdBlock(id: 'z', type: 'CONST', title: '', tagBinding: '0'),
      FbdBlock(id: 'div', type: 'DIV', title: ''),
      FbdBlock(id: 'odiv', type: 'TAG_OUTPUT', title: '', tagBinding: 'Div'),
    ], [
      FbdWire(fromBlockId: 'x', toBlockId: 'sub'),   // X first
      FbdWire(fromBlockId: 'c', toBlockId: 'sub'),   // 1.0 second -> X - 1.0
      FbdWire(fromBlockId: 'sub', toBlockId: 'osub'),
      FbdWire(fromBlockId: 'x', toBlockId: 'div'),
      FbdWire(fromBlockId: 'z', toBlockId: 'div'),   // divide by zero
      FbdWire(fromBlockId: 'div', toBlockId: 'odiv'),
    ]);
    final p = _proj([
      _tag('X', 'FLOAT64', 5.0), _tag('Sub', 'FLOAT64', -99.0),
      _tag('Div', 'FLOAT64', -99.0),
    ], prog);
    _run(p);
    expect(readPath(p, 'Sub'), equals(4.0));
    expect(readPath(p, 'Div'), equals(-99.0)); // null result -> not written
  });

  test('comparators on wire-ordered inputs', () {
    FbdBlock cmp(String id, String type) => FbdBlock(id: id, type: type, title: '');
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'TAG_INPUT', title: '', tagBinding: 'X'),
      FbdBlock(id: 'y', type: 'TAG_INPUT', title: '', tagBinding: 'Y'),
      cmp('gt', 'GT'), cmp('lt', 'LT'), cmp('ge', 'GE'),
      FbdBlock(id: 'ogt', type: 'TAG_OUTPUT', title: '', tagBinding: 'Gt'),
      FbdBlock(id: 'olt', type: 'TAG_OUTPUT', title: '', tagBinding: 'Lt'),
      FbdBlock(id: 'oge', type: 'TAG_OUTPUT', title: '', tagBinding: 'Ge'),
    ], [
      FbdWire(fromBlockId: 'x', toBlockId: 'gt'), FbdWire(fromBlockId: 'y', toBlockId: 'gt'),
      FbdWire(fromBlockId: 'x', toBlockId: 'lt'), FbdWire(fromBlockId: 'y', toBlockId: 'lt'),
      FbdWire(fromBlockId: 'x', toBlockId: 'ge'), FbdWire(fromBlockId: 'y', toBlockId: 'ge'),
      FbdWire(fromBlockId: 'gt', toBlockId: 'ogt'),
      FbdWire(fromBlockId: 'lt', toBlockId: 'olt'),
      FbdWire(fromBlockId: 'ge', toBlockId: 'oge'),
    ]);
    final p = _proj([
      _tag('X', 'FLOAT64', 7.0), _tag('Y', 'FLOAT64', 7.0),
      _tag('Gt', 'BOOL', false), _tag('Lt', 'BOOL', false), _tag('Ge', 'BOOL', false),
    ], prog);
    _run(p);
    expect(readPath(p, 'Gt'), isFalse); // 7 > 7
    expect(readPath(p, 'Lt'), isFalse); // 7 < 7
    expect(readPath(p, 'Ge'), isTrue);  // 7 >= 7
  });

  test('LIMIT clamps (MN, IN, MX)', () {
    FbdBlock c(String id, String v) => FbdBlock(id: id, type: 'CONST', title: '', tagBinding: v);
    final prog = _fbd([
      c('mn', '0.0'),
      FbdBlock(id: 'in', type: 'TAG_INPUT', title: '', tagBinding: 'In'),
      c('mx', '100.0'),
      FbdBlock(id: 'lim', type: 'LIMIT', title: ''),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
    ], [
      FbdWire(fromBlockId: 'mn', toBlockId: 'lim'),
      FbdWire(fromBlockId: 'in', toBlockId: 'lim'),
      FbdWire(fromBlockId: 'mx', toBlockId: 'lim'),
      FbdWire(fromBlockId: 'lim', toBlockId: 'o'),
    ]);
    final p = _proj([_tag('In', 'FLOAT64', 150.0), _tag('Out', 'FLOAT64', 0.0)], prog);
    _run(p);
    expect(readPath(p, 'Out'), equals(100.0)); // clamped to max
    writePath(p, 'In', -20.0);
    _run(p);
    expect(readPath(p, 'Out'), equals(0.0)); // clamped to min
    writePath(p, 'In', 42.0);
    _run(p);
    expect(readPath(p, 'Out'), equals(42.0)); // within
  });

  test('CONST parses num/bool, garbage -> null (no write)', () {
    final prog = _fbd([
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: 'garbage'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
    ], [FbdWire(fromBlockId: 'c', toBlockId: 'o')]);
    final p = _proj([_tag('Out', 'FLOAT64', -1.0)], prog);
    _run(p);
    expect(readPath(p, 'Out'), equals(-1.0)); // unparseable const -> null -> no write
  });

  test('forced output tag is not overwritten', () {
    final prog = _fbd([
      FbdBlock(id: 'c', type: 'CONST', title: '', tagBinding: 'TRUE'),
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Y'),
    ], [FbdWire(fromBlockId: 'c', toBlockId: 'o')]);
    final p = _proj([_tag('Y', 'BOOL', false, forced: true, fv: false)], prog);
    _run(p);
    expect(readPath(p, 'Y'), isFalse);
  });

  test('multi-layer topological order resolves deep chains', () {
    // o = NOT(NOT(A)) == A, but blocks listed out of dependency order.
    final prog = _fbd([
      FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out'),
      FbdBlock(id: 'n2', type: 'NOT', title: ''),
      FbdBlock(id: 'n1', type: 'NOT', title: ''),
      FbdBlock(id: 'i', type: 'TAG_INPUT', title: '', tagBinding: 'A'),
    ], [
      FbdWire(fromBlockId: 'i', toBlockId: 'n1'),
      FbdWire(fromBlockId: 'n1', toBlockId: 'n2'),
      FbdWire(fromBlockId: 'n2', toBlockId: 'o'),
    ]);
    final p = _proj([_tag('A', 'BOOL', true), _tag('Out', 'BOOL', false)], prog);
    _run(p);
    expect(readPath(p, 'Out'), isTrue);
  });

  test('a cycle terminates without hanging', () {
    final prog = _fbd([
      FbdBlock(id: 'x', type: 'AND', title: ''),
      FbdBlock(id: 'y', type: 'AND', title: ''),
    ], [
      FbdWire(fromBlockId: 'x', toBlockId: 'y'),
      FbdWire(fromBlockId: 'y', toBlockId: 'x'),
    ]);
    final p = _proj([], prog);
    _run(p); // must return, not hang
    expect(true, isTrue);
  });

  test('non-FBD and empty programs are skipped', () {
    final ld = PlcProgram(name: 'L', language: 'LadderLogic');
    final p = _proj([_tag('A', 'BOOL', true)], ld);
    _run(p);
    final empty = PlcProgram(name: 'E', language: 'FunctionBlockDiagram');
    final p2 = _proj([], empty);
    _run(p2);
    expect(true, isTrue);
  });
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `flutter test test/fbd_exec_test.dart` → FAIL (`fbd_exec.dart` missing).

- [ ] **Step 3: Implement `fbd_exec.dart`**

Create `mobile/lib/models/fbd_exec.dart`:

```dart
import 'project_model.dart';
import 'tag_resolver.dart';

/// Reserved for stateful FBD blocks (e.g. TON); the combinational blocks the
/// shipped diagrams use hold no state. Cleared on project switch.
class FbdRuntime {
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

bool? _truthy(dynamic v) {
  if (v is bool) {
    return v;
  }
  if (v is num) {
    return v != 0;
  }
  return null;
}

dynamic _parseConst(String s) {
  final t = s.trim();
  if (t.isEmpty) {
    return null;
  }
  final up = t.toUpperCase();
  if (up == 'TRUE') {
    return true;
  }
  if (up == 'FALSE') {
    return false;
  }
  final i = int.tryParse(t);
  if (i != null) {
    return i;
  }
  return double.tryParse(t);
}

dynamic _arith(String op, List<dynamic> inputs) {
  final nums = <num>[];
  for (final i in inputs) {
    if (i is num) {
      nums.add(i);
    } else {
      return null;
    }
  }
  if (nums.isEmpty) {
    return null;
  }
  num acc = nums.first;
  for (int k = 1; k < nums.length; k++) {
    final n = nums[k];
    switch (op) {
      case 'ADD':
        acc = acc + n;
        break;
      case 'SUB':
        acc = acc - n;
        break;
      case 'MUL':
        acc = acc * n;
        break;
      case 'DIV':
        if (n == 0) {
          return null;
        }
        acc = acc / n;
        break;
    }
  }
  return acc;
}

dynamic _compare(String op, List<dynamic> inputs) {
  if (inputs.length < 2) {
    return null;
  }
  final a = inputs[0];
  final b = inputs[1];
  if (a is num && b is num) {
    switch (op) {
      case 'GT':
        return a > b;
      case 'LT':
        return a < b;
      case 'GE':
        return a >= b;
      case 'LE':
        return a <= b;
      case 'EQ':
        return a == b;
      case 'NE':
        return a != b;
    }
  }
  if (op == 'EQ') {
    return a == b;
  }
  if (op == 'NE') {
    return a != b;
  }
  return null;
}

dynamic _evalBlock(PlcProject p, FbdBlock b, List<dynamic> inputs) {
  switch (b.type) {
    case 'TAG_INPUT':
      return b.tagBinding.isEmpty ? null : readPath(p, b.tagBinding);
    case 'CONST':
      return _parseConst(b.tagBinding);
    case 'AND':
      if (inputs.isEmpty) {
        return false;
      }
      for (final i in inputs) {
        final t = _truthy(i);
        if (t == null) {
          return null;
        }
        if (!t) {
          return false;
        }
      }
      return true;
    case 'OR':
      if (inputs.isEmpty) {
        return false;
      }
      bool any = false;
      for (final i in inputs) {
        final t = _truthy(i);
        if (t == null) {
          return null;
        }
        if (t) {
          any = true;
        }
      }
      return any;
    case 'NOT':
      if (inputs.isEmpty) {
        return null;
      }
      final t = _truthy(inputs.first);
      return t == null ? null : !t;
    case 'ADD':
    case 'SUB':
    case 'MUL':
    case 'DIV':
      return _arith(b.type, inputs);
    case 'GT':
    case 'LT':
    case 'GE':
    case 'LE':
    case 'EQ':
    case 'NE':
      return _compare(b.type, inputs);
    case 'LIMIT':
      if (inputs.length < 3) {
        return null;
      }
      final mn = inputs[0];
      final inp = inputs[1];
      final mx = inputs[2];
      if (mn is num && inp is num && mx is num) {
        if (inp < mn) {
          return mn;
        }
        if (inp > mx) {
          return mx;
        }
        return inp;
      }
      return null;
    case 'TAG_OUTPUT':
      if (inputs.isEmpty) {
        return null;
      }
      final v = inputs.first;
      if (v != null && b.tagBinding.isNotEmpty) {
        _forceAwareWrite(p, b.tagBinding, v);
      }
      return v;
    default:
      return null; // TON and unknown block types are not executed this release
  }
}

/// Executes every FunctionBlockDiagram program: evaluates the block graph in
/// dependency (topological) order — a block after all blocks feeding it — and
/// TAG_OUTPUT blocks write their input to the bound tag (force-aware). Input
/// order for a block is the order of the matching wires in `fbdWires`. Cycles
/// (not present in shipped diagrams) terminate deterministically without
/// hanging. Never throws.
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt) {
  for (final prog in p.programs) {
    if (prog.language != 'FunctionBlockDiagram' || prog.fbdBlocks.isEmpty) {
      continue;
    }
    final byId = <String, FbdBlock>{};
    for (final b in prog.fbdBlocks) {
      byId[b.id] = b;
    }
    final inputsOf = <String, List<String>>{};
    for (final b in prog.fbdBlocks) {
      inputsOf[b.id] = <String>[];
    }
    for (final w in prog.fbdWires) {
      if (inputsOf.containsKey(w.toBlockId) && byId.containsKey(w.fromBlockId)) {
        inputsOf[w.toBlockId]!.add(w.fromBlockId);
      }
    }
    final cache = <String, dynamic>{};
    final done = <String>{};

    // Evaluate blocks whose inputs are all resolved; repeat until stable.
    bool progressed = true;
    while (progressed) {
      progressed = false;
      for (final b in prog.fbdBlocks) {
        if (done.contains(b.id)) {
          continue;
        }
        final srcs = inputsOf[b.id]!;
        if (!srcs.every(done.contains)) {
          continue;
        }
        cache[b.id] = _evalBlock(p, b, srcs.map((s) => cache[s]).toList());
        done.add(b.id);
        progressed = true;
      }
    }
    // Any block left unresolved is in a cycle: evaluate once with whatever is
    // cached so the scan always terminates.
    for (final b in prog.fbdBlocks) {
      if (done.contains(b.id)) {
        continue;
      }
      cache[b.id] = _evalBlock(p, b, inputsOf[b.id]!.map((s) => cache[s]).toList());
      done.add(b.id);
    }
  }
}
```

- [ ] **Step 4: Run tests → PASS (11 tests). Step 5: `flutter analyze` → No issues found!**

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/models/fbd_exec.dart mobile/test/fbd_exec_test.dart
git commit -m "feat(fbd-exec): pure dataflow FBD evaluator (logic, arithmetic, comparators, LIMIT, CONST)"
```

---

### Task 2: Scan wiring + migrate both diagrams + delete hardcoded logic

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Modify: `mobile/lib/data/default_projects.dart`

**Interfaces:**
- Consumes: `executeFbdPrograms`, `FbdRuntime` from Task 1.

**Same-commit rule:** FBD wiring and the deletion of the replaced hardcoded logic land together (no scan where both drive the same tag).

- [ ] **Step 1: Wire FBD into the scan**

In `workspace_shell.dart`: `import '../models/fbd_exec.dart';`; add field `final FbdRuntime _fbdRuntime = FbdRuntime();`. In `_executeScan`, insert the call AFTER `executeLdPrograms(...)` and BEFORE `executeSfcPrograms(...)`:

```dart
      executeFbdPrograms(_activeProject, scanSpeedMs, _fbdRuntime);
```

Add `_fbdRuntime.clear();` alongside the existing `_simRuntime...clear()` / `_ldRuntime.clear()` / `_sfcRuntime.clear()` on project switch. (Match the real scan-period variable name — `scanSpeedMs` — and the real runtime-clear site.)

- [ ] **Step 2: Migrate the HVAC diagram (`proj_fbd_hvac`)**

In `default_projects.dart`, replace `HvacControl_FBD`'s `fbdBlocks`/`fbdWires` with the executable form (input order matters — the first wire into a SUB/ADD/LT/GT is its left operand). Single shared `CONST 1.0` deadband:

```dart
        fbdBlocks: [
          FbdBlock(id: 'f_i1', type: 'TAG_INPUT', title: 'Occupied', tagBinding: 'Occupied', x: 50, y: 80),
          FbdBlock(id: 'f_i2', type: 'TAG_INPUT', title: 'Window Open', tagBinding: 'Window_Open', x: 50, y: 200),
          FbdBlock(id: 'f_n1', type: 'NOT', title: 'Window Closed', tagBinding: '', x: 240, y: 200),
          FbdBlock(id: 'f_a1', type: 'AND', title: 'HVAC Enable', tagBinding: '', x: 420, y: 130),
          FbdBlock(id: 'f_o1', type: 'TAG_OUTPUT', title: 'Fan Cmd', tagBinding: 'Fan_Cmd', x: 620, y: 80),
          FbdBlock(id: 'f_o2', type: 'TAG_OUTPUT', title: 'HVAC Active', tagBinding: 'Hvac_Active', x: 620, y: 200),
          FbdBlock(id: 'f_i3', type: 'TAG_INPUT', title: 'Room Temp', tagBinding: 'Room_Temp', x: 50, y: 360),
          FbdBlock(id: 'f_i4', type: 'TAG_INPUT', title: 'Setpoint', tagBinding: 'Setpoint', x: 50, y: 470),
          FbdBlock(id: 'f_c1', type: 'CONST', title: 'Deadband', tagBinding: '1.0', x: 50, y: 580),
          FbdBlock(id: 'f_s1', type: 'SUB', title: 'SP - 1', tagBinding: '', x: 240, y: 520),
          FbdBlock(id: 'f_lt', type: 'LT', title: 'Temp < SP-1', tagBinding: '', x: 420, y: 380),
          FbdBlock(id: 'f_a2', type: 'AND', title: 'Heat Enable', tagBinding: '', x: 600, y: 360),
          FbdBlock(id: 'f_o3', type: 'TAG_OUTPUT', title: 'Heat Cmd', tagBinding: 'Heat_Cmd', x: 790, y: 360),
          FbdBlock(id: 'f_a3', type: 'ADD', title: 'SP + 1', tagBinding: '', x: 240, y: 650),
          FbdBlock(id: 'f_gt', type: 'GT', title: 'Temp > SP+1', tagBinding: '', x: 420, y: 610),
          FbdBlock(id: 'f_a4', type: 'AND', title: 'Cool Enable', tagBinding: '', x: 600, y: 590),
          FbdBlock(id: 'f_o4', type: 'TAG_OUTPUT', title: 'Cool Cmd', tagBinding: 'Cool_Cmd', x: 790, y: 590),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'f_i2', toBlockId: 'f_n1'),
          FbdWire(fromBlockId: 'f_i1', toBlockId: 'f_a1'),
          FbdWire(fromBlockId: 'f_n1', toBlockId: 'f_a1'),
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_o1'),
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_o2'),
          // Heat: Room_Temp < (Setpoint - 1.0)
          FbdWire(fromBlockId: 'f_i4', toBlockId: 'f_s1'), // Setpoint (left)
          FbdWire(fromBlockId: 'f_c1', toBlockId: 'f_s1'), // 1.0 (right)
          FbdWire(fromBlockId: 'f_i3', toBlockId: 'f_lt'), // Room_Temp (left)
          FbdWire(fromBlockId: 'f_s1', toBlockId: 'f_lt'), // SP-1 (right)
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_a2'),
          FbdWire(fromBlockId: 'f_lt', toBlockId: 'f_a2'),
          FbdWire(fromBlockId: 'f_a2', toBlockId: 'f_o3'),
          // Cool: Room_Temp > (Setpoint + 1.0)
          FbdWire(fromBlockId: 'f_i4', toBlockId: 'f_a3'), // Setpoint (left)
          FbdWire(fromBlockId: 'f_c1', toBlockId: 'f_a3'), // 1.0 (right)
          FbdWire(fromBlockId: 'f_i3', toBlockId: 'f_gt'), // Room_Temp (left)
          FbdWire(fromBlockId: 'f_a3', toBlockId: 'f_gt'), // SP+1 (right)
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_a4'),
          FbdWire(fromBlockId: 'f_gt', toBlockId: 'f_a4'),
          FbdWire(fromBlockId: 'f_a4', toBlockId: 'f_o4'),
        ],
```

(Keep the surrounding `PlcProgram(...)` constructor shape exactly as in the file — only the two lists change.)

- [ ] **Step 3: Migrate the water-quality diagram (`proj_all_water`)**

Replace `WaterQuality_FBD`'s `fbdBlocks`/`fbdWires` with just the `Quality_OK` computation — **drop the `Pump_Motor → AND → Flow_PV` branch** (Flow_PV is sim-driven by `sim4`/`sim5`; the FBD must not write it):

```dart
        fbdBlocks: [
          FbdBlock(id: 'wf_i1', type: 'TAG_INPUT', title: 'Turbidity PV', tagBinding: 'Turbidity_PV', x: 50, y: 80),
          FbdBlock(id: 'wf_i2', type: 'TAG_INPUT', title: 'Turbidity SP', tagBinding: 'Turbidity_SP', x: 50, y: 190),
          FbdBlock(id: 'wf_lt', type: 'LT', title: 'Turbidity < SP', tagBinding: '', x: 260, y: 130),
          FbdBlock(id: 'wf_i3', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 320),
          FbdBlock(id: 'wf_c1', type: 'CONST', title: 'Min Level', tagBinding: '10.0', x: 50, y: 430),
          FbdBlock(id: 'wf_gt', type: 'GT', title: 'Level > 10', tagBinding: '', x: 260, y: 360),
          FbdBlock(id: 'wf_a1', type: 'AND', title: 'Quality OK', tagBinding: '', x: 460, y: 240),
          FbdBlock(id: 'wf_o1', type: 'TAG_OUTPUT', title: 'Quality OK', tagBinding: 'Quality_OK', x: 660, y: 240),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'wf_i1', toBlockId: 'wf_lt'), // Turbidity_PV (left)
          FbdWire(fromBlockId: 'wf_i2', toBlockId: 'wf_lt'), // Turbidity_SP (right)
          FbdWire(fromBlockId: 'wf_i3', toBlockId: 'wf_gt'), // Level_PV (left)
          FbdWire(fromBlockId: 'wf_c1', toBlockId: 'wf_gt'), // 10.0 (right)
          FbdWire(fromBlockId: 'wf_lt', toBlockId: 'wf_a1'),
          FbdWire(fromBlockId: 'wf_gt', toBlockId: 'wf_a1'),
          FbdWire(fromBlockId: 'wf_a1', toBlockId: 'wf_o1'),
        ],
```

- [ ] **Step 4: Delete the replaced hardcoded logic**

In `workspace_shell._evaluateActiveLogic`:
- Delete the entire `else if (id == 'proj_fbd_hvac') { ... }` branch (the `Hvac_Active`/`Fan_Cmd`/`Heat_Cmd`/`Cool_Cmd` writes). Leave a one-line comment noting HVAC is now executed by `HvacControl_FBD` (see `executeFbdPrograms`).
- In the `proj_all_water` branch, delete the `Quality_OK` FBD block (the `turbidity`/`turbSP`/`level`/`qualityOk` lines and the `_setTagBool('Quality_OK', ...)`). Leave a one-line comment noting `Quality_OK` is now executed by `WaterQuality_FBD`. KEEP the `Alarm_Active`/`System_Ready` ST-domain logic (WS4d) and any `pumpRun`/`estop` reads still used by that remaining logic (if `pumpRun`/`estop` become unused after the deletion, remove them too to keep analyze clean).

Verify no other code path still writes `Hvac_Active`/`Fan_Cmd`/`Heat_Cmd`/`Cool_Cmd`/`Quality_OK`.

Note: `proj_st_reactor` also has `Heat_Cmd`/`Cool_Cmd` tags, but those are a DIFFERENT project's tags written only in the `proj_st_reactor` branch — leave that branch untouched.

- [ ] **Step 5: Verify**

`flutter analyze` → No issues found! · `flutter test` → all pass · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz" lib` → no matches.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/data/default_projects.dart
git commit -m "feat(fbd-exec): run FBD each scan; migrate HVAC and water-quality to executed diagrams; drop Flow_PV double-drive"
```

---

### Task 3: FBD editor palette — new executable block types

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart`

**Interfaces:** none (UI only; the executor already handles these `type` strings).

- [ ] **Step 1: Add palette entries**

The palette is built from `_buildBlockPaletteItem(type, title, icon, color)` calls (around lines 130-140, near the existing `'TON'`/`'LIMIT'` entries) and blocks are added via `_addFbdBlock(type, title)`. Add entries for the new executable types, following the existing call style and using existing `Icons`/`Colors` constants (dark-theme-appropriate accents). Add:

```dart
                      _buildBlockPaletteItem('CONST', 'Constant Value', Icons.pin, Colors.limeAccent),
                      _buildBlockPaletteItem('GT', 'Greater Than (>)', Icons.chevron_right, Colors.lightBlueAccent),
                      _buildBlockPaletteItem('LT', 'Less Than (<)', Icons.chevron_left, Colors.lightBlueAccent),
                      _buildBlockPaletteItem('GE', 'Greater or Equal (>=)', Icons.keyboard_double_arrow_right, Colors.lightBlueAccent),
                      _buildBlockPaletteItem('LE', 'Less or Equal (<=)', Icons.keyboard_double_arrow_left, Colors.lightBlueAccent),
                      _buildBlockPaletteItem('EQ', 'Equal (=)', Icons.drag_handle, Colors.lightBlueAccent),
                      _buildBlockPaletteItem('NE', 'Not Equal (<>)', Icons.compare_arrows, Colors.lightBlueAccent),
                      _buildBlockPaletteItem('MUL', 'Multiply (x)', Icons.close, Colors.tealAccent),
                      _buildBlockPaletteItem('DIV', 'Divide (/)', Icons.percent, Colors.tealAccent),
```

(Match the actual argument order/signature of `_buildBlockPaletteItem` in the file — if it takes `(type, title, icon, color)` use that; if the icon/color are omitted for some entries, follow the file's real pattern. Do not invent a new signature.)

- [ ] **Step 2: CONST value editing**

`CONST` carries its literal in the block's `tagBinding`. Confirm the block inspector/edit affordance that sets `tagBinding` (used by TAG_INPUT/TAG_OUTPUT) is reachable for a `CONST` block too, so a user can type `10.0`/`TRUE`. If the tag-binding editor is gated to only TAG_INPUT/TAG_OUTPUT types, widen that gate to also allow `CONST` (labeling the field "Value" for CONST is a nice-to-have, not required). If it is already type-agnostic, no change needed — note which in the report.

- [ ] **Step 3: Verify**

`flutter analyze` → No issues found! · `flutter test` → all pass (no test regressions) · `flutter build web --release` → succeeds. If a widget test renders the FBD editor, confirm no RenderFlex overflow.

- [ ] **Step 4: Commit**

```bash
git add mobile/lib/screens/fbd_editor_screen.dart
git commit -m "feat(fbd-editor): add CONST, comparator, and MUL/DIV blocks to the palette"
```

---

### Task 4: End-to-end validation

**Files:**
- Create: `mobile/test/fbd_exec_integration_test.dart`

- [ ] **Step 1: Integration tests against the REAL default projects**

Replicate the shell's scan order (sim → LD → FBD → SFC) against the actual projects and assert parity with the old hardcoded formulas. Confirm the real accessors/signatures (`DefaultProjects.all()` / `applySimRules` / `executeLdPrograms` / `SimRuntime` / `LdExecRuntime`) by reading the model files; adjust the harness to match.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, FbdRuntime fbd,
    [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeFbdPrograms(p, dtMs, fbd);
}

bool _b(PlcProject p, String path) => readPath(p, path) == true;

void main() {
  test('HVAC diagram reproduces the hardcoded heat/cool/enable truth table', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_fbd_hvac');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();

    void setInputs(bool occ, bool win, double temp, double sp) {
      writePath(p, 'Occupied', occ);
      writePath(p, 'Window_Open', win);
      writePath(p, 'Room_Temp', temp);
      writePath(p, 'Setpoint', sp);
    }

    // Occupied, window shut, cold -> enable + heat, not cool.
    setInputs(true, false, 18.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isTrue);
    expect(_b(p, 'Fan_Cmd'), isTrue);
    expect(_b(p, 'Heat_Cmd'), isTrue); // 18 < 21-1
    expect(_b(p, 'Cool_Cmd'), isFalse);

    // Occupied, window shut, hot -> cool, not heat.
    setInputs(true, false, 24.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Cool_Cmd'), isTrue); // 24 > 21+1
    expect(_b(p, 'Heat_Cmd'), isFalse);

    // Window open -> everything disabled regardless of temp.
    setInputs(true, true, 18.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isFalse);
    expect(_b(p, 'Fan_Cmd'), isFalse);
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);

    // Unoccupied -> disabled.
    setInputs(false, false, 18.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isFalse);
    expect(_b(p, 'Heat_Cmd'), isFalse);

    // In-band temperature -> enabled, neither heat nor cool.
    setInputs(true, false, 21.0, 21.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Hvac_Active'), isTrue);
    expect(_b(p, 'Heat_Cmd'), isFalse);
    expect(_b(p, 'Cool_Cmd'), isFalse);
  });

  test('water Quality_OK tracks turb<SP && level>10; FBD leaves Flow_PV to sim', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final sim = SimRuntime();
    final ld = LdExecRuntime();
    final fbd = FbdRuntime();

    // Good quality: low turbidity, healthy level.
    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 50.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Quality_OK'), isTrue);

    // Bad turbidity -> not OK.
    writePath(p, 'Turbidity_PV', 20.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Quality_OK'), isFalse);

    // Turbidity fine but level too low -> not OK.
    writePath(p, 'Turbidity_PV', 2.0);
    writePath(p, 'Level_PV', 5.0);
    _scan(p, sim, ld, fbd);
    expect(_b(p, 'Quality_OK'), isFalse);

    // Flow_PV is driven by the sim rules, not the FBD: with the pump stopped
    // (no Start_PB), sim5 holds it at/toward 0 and the FBD never writes it.
    expect((readPath(p, 'Flow_PV') as num).toDouble(), lessThan(1.0));
  });
}
```

Adjust the asserted `Flow_PV` threshold to whatever `sim4`/`sim5` actually produce from the default initial state if it differs — the point is that FBD does not clobber it with a bool. If the pump-stopped sim genuinely leaves `Flow_PV` at its initial `0.0`, `lessThan(1.0)` holds.

- [ ] **Step 2: Full suite + analyze + build**

`flutter test` → all pass · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz" lib test` → no matches.

- [ ] **Step 3: Commit**

```bash
git add mobile/test/fbd_exec_integration_test.dart
git commit -m "test(fbd-exec): end-to-end HVAC truth table and water Quality_OK parity"
```

---

## Self-review notes

- **Spec coverage:** dataflow evaluator w/ topological order + wire-order inputs + never-throw/never-hang (Task 1) ✓; block set AND/OR/NOT/ADD/SUB/MUL/DIV/GT/LT/GE/LE/EQ/NE/LIMIT/CONST/TAG_INPUT/TAG_OUTPUT (Task 1) ✓; scan pipeline sim→LD→FBD→SFC→ST + runtime clear (Task 2) ✓; HVAC redraw reproducing enable/heat(`<sp-1`)/cool(`>sp+1`) + water redraw for Quality_OK dropping the Flow_PV branch (Task 2) ✓; hardcoded deletion same commit (Task 2) ✓; editor palette for the new types (Task 3) ✓; integration parity tests incl. Flow_PV-not-clobbered (Task 4) ✓.
- **Type consistency:** `executeFbdPrograms(p, dtMs, rt)`, `FbdRuntime`/`.clear()`, `_forceAwareWrite` used identically across tasks; block `type` strings match between executor (Task 1) and palette (Task 3) and migrated data (Task 2).
- **Known limitations (per spec):** stateful blocks (TON) not executed; deterministic wire-order ports (no reorder UI); cycles only guaranteed to terminate. All documented.
