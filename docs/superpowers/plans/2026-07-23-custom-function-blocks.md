# Custom Function Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-defined function blocks — a typed interface + ST body, instantiated as struct-tag state, usable and executed as a block in FBD and LD.

**Architecture:** An `FbDefinition` (interface `FbVar`s + ST source) on the project; each instance is a struct-typed tag (reuses the TIMER/COUNTER composite mechanism via `lookupComposite`); a shared `executeFbInstance` runs the FB's ST body through the existing ST engine with an instance **scope** (bare vars resolve to the instance struct, else global); FBD/LD block dispatch gains a fallback that recognizes FB-name block types.

**Tech Stack:** Dart/Flutter. Reuses `st_exec.dart`/`st_expr.dart` (adds a scope), `tag_resolver.dart` (`lookupComposite`/`readPath`/`writePath`/`defaultValueFor`), `fbd_exec.dart`/`fbd_pins.dart`, `ld_exec.dart`.

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic. Zero `flutter analyze` warnings. Run flutter from `mobile/`.
- **Additive / backward-compatible:** new `fb_definitions` on the project + additive `pin_bindings` on `LdNode`; instances are ordinary tags. Existing projects have no FBs; every built-in block and all LD/FBD/ST/SFC behavior is unchanged — the FB fallback fires ONLY for a block type that names an FB definition.
- Force-aware writes (`_forceAwareWrite`/`writePath`). Responsive (no overflow 320/360/1400). Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Deferred items live in `docs/DEFERRED.md` — do not re-scope them in (esp. the import mapping = sub-project 2).

## File Structure

- Modify `mobile/lib/models/project_model.dart` — `FbDefinition`/`FbVar`/`FbVarDir`, `PlcProject.fbDefinitions`, `LdNode.pinBindings` + serialization (Task 1).
- Modify `mobile/lib/models/tag_resolver.dart` — `lookupComposite` resolves FB types + `fbDefinitionFor` (Task 2).
- Modify `mobile/lib/models/st_exec.dart` — an optional instance scope on `_execBlock` (Task 3).
- Create `mobile/lib/models/fb_exec.dart` — `executeFbInstance` (Task 3).
- Modify `mobile/lib/models/fbd_pins.dart` + `fbd_exec.dart` — FB pin + eval fallback (Task 4).
- Modify `mobile/lib/models/ld_exec.dart` — FB block dispatch via `pinBindings` (Task 5).
- Modify `mobile/lib/screens/` (a new FB editor + FBD/LD palettes) (Task 6).
- Modify `mobile/lib/data/default_projects.dart` + `docs/` (Task 7).

---

### Task 1: Model — `FbDefinition`/`FbVar`, `fbDefinitions`, `LdNode.pinBindings`

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`LdNode` ~159-214; `PlcProject` ~890+)
- Test: `mobile/test/models/fb_model_test.dart`

**Interfaces — Produces:**
- `enum FbVarDir { input, output, internal }`
- `class FbVar { String name; String dataType; FbVarDir direction; dynamic initialValue; FbVar({required this.name, required this.dataType, this.direction = FbVarDir.internal, this.initialValue}); fromJson; toJson; }` (direction serialized as its `.name` string; JSON keys `name`,`data_type`,`direction`,`initial_value`).
- `class FbDefinition { String name; List<FbVar> vars; String stSource; FbDefinition({required this.name, List<FbVar>? vars, this.stSource = ''}) : vars = vars ?? []; fromJson; toJson; }` (JSON keys `name`,`vars`,`st_source`).
- `PlcProject.fbDefinitions` (`List<FbDefinition>`, default `[]`; JSON key `fb_definitions`).
- `LdNode.pinBindings` (`Map<String,String>`, default `{}`; JSON key `pin_bindings`; only written when non-empty).

- [ ] **Step 1: Write the failing test** (`mobile/test/models/fb_model_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('FbDefinition + FbVar round-trip', () {
    final fb = FbDefinition(name: 'Scaler', stSource: 'Out := In * Gain;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 2.0),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      FbVar(name: 'Count', dataType: 'INT32', direction: FbVarDir.internal),
    ]);
    final rt = FbDefinition.fromJson(fb.toJson());
    expect(rt.name, 'Scaler');
    expect(rt.stSource, 'Out := In * Gain;');
    expect(rt.vars.map((v) => v.name), ['In', 'Gain', 'Out', 'Count']);
    expect(rt.vars[1].direction, FbVarDir.input);
    expect(rt.vars[1].initialValue, 2.0);
    expect(rt.vars.firstWhere((v) => v.name == 'Out').direction, FbVarDir.output);
  });

  test('project carries fbDefinitions; legacy project has none', () {
    final p = PlcProject(id: 'p', name: 'P', controllerName: 'C',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [FbDefinition(name: 'X')]);
    expect(PlcProject.fromJson(p.toJson()).fbDefinitions.single.name, 'X');
    final legacy = PlcProject.fromJson({'id': 'q', 'name': 'Q', 'controller': {}});
    expect(legacy.fbDefinitions, isEmpty);
  });

  test('LdNode.pinBindings is additive and round-trips', () {
    final n = LdNode(id: 'n1', kind: LdKind.block, blockType: 'Scaler', variable: 'S1',
        pinBindings: {'In': 'PV', 'Out': 'CV'});
    expect(LdNode.fromJson(n.toJson()).pinBindings, {'In': 'PV', 'Out': 'CV'});
    expect(LdNode(id: 'n2', kind: LdKind.contact).pinBindings, isEmpty);
  });
}
```

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement** the classes + fields. `FbVarDir.fromJson`: `FbVarDir.values.firstWhere((d) => d.name == json['direction'], orElse: () => FbVarDir.internal)`. Add `fbDefinitions` to the `PlcProject` constructor (`List<FbDefinition>? fbDefinitions` → `?? []`), `fromJson` (`(json['fb_definitions'] as List? ?? []).map(FbDefinition.fromJson).toList()`), and `toJson`. Add `pinBindings` to `LdNode` (constructor `Map<String,String>? pinBindings` → `?? {}`; `fromJson` `Map<String,String>.from(json['pin_bindings'] ?? {})`; `toJson` writes `pin_bindings` only when non-empty). Match the file's existing serialization idioms.

- [ ] **Step 4: Run — expect PASS.** `flutter analyze` zero. Full suite (baseline 2557) — record count; serialization/persistence tests must stay green (additive).

- [ ] **Step 5: Commit** — `git add mobile/lib/models/project_model.dart mobile/test/models/fb_model_test.dart` / `feat(fb): FbDefinition + FbVar model + fbDefinitions + LdNode.pinBindings`.

---

### Task 2: `lookupComposite` resolves FB types (instance = struct tag)

**Files:**
- Modify: `mobile/lib/models/tag_resolver.dart` (`lookupComposite` ~103-115)
- Test: `mobile/test/models/fb_instance_tag_test.dart`

**Interfaces:**
- Consumes: `FbDefinition`/`FbVar` (Task 1); `PlcStructDef`/`StructFieldDef`.
- Produces: `FbDefinition? fbDefinitionFor(PlcProject p, String name)` (returns the matching FB def or null); `lookupComposite` also resolves an FB name → a synthesized `PlcStructDef` (fields = the FB's vars, in order). So an FB-typed tag gets `defaultValueFor`/`readPath`/`writePath` automatically.

- [ ] **Step 1: Write the failing test** (`mobile/test/models/fb_instance_tag_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj(FbDefinition fb, {List<PlcTag> tags = const []}) => PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [...tags], structDefs: [], programs: [], tasks: [], hmis: [],
    fbDefinitions: [fb]);

void main() {
  final fb = FbDefinition(name: 'Scaler', vars: [
    FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
    FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 2.0),
    FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
  ]);

  test('lookupComposite resolves an FB name to a struct of its vars', () {
    final comp = lookupComposite(_proj(fb), 'Scaler');
    expect(comp, isNotNull);
    expect(comp!.fields.map((f) => f.name), ['In', 'Gain', 'Out']);
  });

  test('an FB instance is a struct tag with defaults + path I/O', () {
    final p = _proj(fb, tags: [
      PlcTag(name: 'S1', path: 'S1', dataType: 'Scaler',
          value: defaultValueFor(_proj(fb), 'Scaler', 0)),
    ]);
    // default from FbVar.initialValue
    expect(readPath(p, 'S1.Gain'), 2.0);
    writePath(p, 'S1.In', 5.0);
    expect(readPath(p, 'S1.In'), 5.0);
  });

  test('fbDefinitionFor finds/misses', () {
    expect(fbDefinitionFor(_proj(fb), 'Scaler')?.name, 'Scaler');
    expect(fbDefinitionFor(_proj(fb), 'Nope'), isNull);
  });
}
```

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.** Add `fbDefinitionFor`:

```dart
FbDefinition? fbDefinitionFor(PlcProject p, String name) {
  for (final fb in p.fbDefinitions) {
    if (fb.name == name) return fb;
  }
  return null;
}
```

Extend `lookupComposite` — after the structDefs and builtins loops, before `return null`:

```dart
  final fb = fbDefinitionFor(p, typeName);
  if (fb != null) {
    return PlcStructDef(
      name: fb.name,
      fields: [
        for (final v in fb.vars)
          StructFieldDef(name: v.name, dataType: v.dataType, arrayLength: 0, defaultValue: v.initialValue),
      ],
    );
  }
```

(Confirm the exact `StructFieldDef` constructor param names against `project_model.dart` and match them.) A name collision between an FB and a struct/builtin resolves to the struct/builtin (checked first) — acceptable; the FB editor should prevent such names, but no special handling here.

- [ ] **Step 4: Run — expect PASS.** `flutter analyze` zero. Full suite — record count; existing composite/tag_resolver tests green (FB path only adds a new resolution branch).

- [ ] **Step 5: Commit** — `feat(fb): resolve FB instances as struct-typed tags via lookupComposite`.

---

### Task 3: Scoped ST execution + `executeFbInstance`

**Files:**
- Modify: `mobile/lib/models/st_exec.dart` (`_execBlock` ~258-281; add a scope type)
- Create: `mobile/lib/models/fb_exec.dart`
- Test: `mobile/test/models/fb_exec_test.dart`

**Interfaces:**
- Consumes: `evalExpr`/`evalStCondition` (`st_expr.dart`, both take `{Map<String,dynamic> extraVars}`); `readPath`/`writePath` (`tag_resolver.dart`); `FbDefinition` (Task 1).
- Produces: in `st_exec.dart`, `class StScope { final String instancePath; final Set<String> localVars; StScope(this.instancePath, this.localVars); }` and a public `void runScopedStBody(PlcProject p, String src, StScope scope)`; in `fb_exec.dart`, `Map<String,dynamic> executeFbInstance(PlcProject p, FbDefinition fb, String instanceName, Map<String,dynamic> inputs)`.

**Context:** `_execBlock` assignments do `evalExpr(p, rhs)` (reads global) then `_forceAwareWrite(p, s.path, v)` (writes global). Scoping = (a) reads: give `evalExpr`/`evalStCondition` an `extraVars` map of the instance's fields so a bare `x` resolves to `Inst.x`'s live value; (b) writes: if the assignment target's root is a scope localVar, rewrite the path to `Inst.<path>`.

- [ ] **Step 1: Write the failing test** (`mobile/test/models/fb_exec_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/models/fb_exec.dart';

FbDefinition _accumFb() => FbDefinition(name: 'Accum', stSource: 'Sum := Sum + In; Out := Sum;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Sum', dataType: 'FLOAT64', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);

PlcProject _proj(FbDefinition fb, {List<PlcTag>? tags}) => PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: tags ?? [], structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb]);

void main() {
  test('executeFbInstance runs scoped body; internal state persists across calls', () {
    final fb = _accumFb();
    final p = _proj(fb, tags: [PlcTag(name: 'A1', path: 'A1', dataType: 'Accum', value: defaultValueFor(_proj(fb), 'Accum', 0))]);
    var out = executeFbInstance(p, fb, 'A1', {'In': 3.0});
    expect(out['Out'], 3.0);
    out = executeFbInstance(p, fb, 'A1', {'In': 4.0});
    expect(out['Out'], 7.0); // Sum persisted in the A1 struct
    expect(readPath(p, 'A1.Sum'), 7.0);
  });

  test('two instances keep independent state', () {
    final fb = _accumFb();
    final p = _proj(fb, tags: [
      PlcTag(name: 'A1', path: 'A1', dataType: 'Accum', value: defaultValueFor(_proj(fb), 'Accum', 0)),
      PlcTag(name: 'A2', path: 'A2', dataType: 'Accum', value: defaultValueFor(_proj(fb), 'Accum', 0)),
    ]);
    executeFbInstance(p, fb, 'A1', {'In': 5.0});
    final o2 = executeFbInstance(p, fb, 'A2', {'In': 9.0});
    expect(o2['Out'], 9.0);
    expect(readPath(p, 'A1.Sum'), 5.0);
  });

  test('a body reference not in the FB vars falls through to a global tag', () {
    final fb = FbDefinition(name: 'Gue', stSource: 'Out := In + Bias;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
    ]);
    final p = _proj(fb, tags: [
      PlcTag(name: 'G1', path: 'G1', dataType: 'Gue', value: defaultValueFor(_proj(fb), 'Gue', 0)),
      PlcTag(name: 'Bias', path: 'Bias', dataType: 'FLOAT64', value: 100.0),
    ]);
    final out = executeFbInstance(p, fb, 'G1', {'In': 1.0});
    expect(out['Out'], 101.0); // Bias read from the global tag
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`executeFbInstance`/`runScopedStBody` undefined). **Step 3: Implement.**

In `st_exec.dart`: add `StScope` and thread an optional scope through `_execBlock` (keep `executeStPrograms` calling with `null`). Replace `_execBlock`'s signature and body:

```dart
class StScope {
  final String instancePath;      // e.g. 'A1'
  final Set<String> localVars;    // the FB var names
  StScope(this.instancePath, this.localVars);
  Map<String, dynamic> readVars(PlcProject p) =>
      {for (final v in localVars) v: readPath(p, '$instancePath.$v')};
  String rewrite(String path) {
    final root = path.split('.').first.split('[').first;
    return localVars.contains(root) ? '$instancePath.$path' : path;
  }
}

// Reads rebuild `scope.readVars(p)` at every evalExpr/evalStCondition call so a
// just-written var (e.g. `Sum := Sum + In` then a later read of Sum) is live.
void _execBlock(PlcProject p, String src, List<_Stmt> stmts, Set<String>? readOnly, [StScope? scope]) {
  Map<String, dynamic> vars() => scope == null ? const {} : scope.readVars(p);
  for (final s in stmts) {
    if (s is _Assign) {
      final v = evalExpr(p, src.substring(s.rhsStart, s.rhsEnd), extraVars: vars());
      if (v != null) {
        final target = scope?.rewrite(s.path) ?? s.path;
        if (readOnly == null || !readOnly.contains(target)) {
          _forceAwareWrite(p, target, v);
        }
      }
    } else if (s is _If) {
      bool taken = false;
      for (final b in s.branches) {
        if (evalStCondition(p, src.substring(b.condStart, b.condEnd), extraVars: vars())) {
          _execBlock(p, src, b.body, readOnly, scope);
          taken = true;
          break;
        }
      }
      if (!taken && s.elseBody != null) {
        _execBlock(p, src, s.elseBody!, readOnly, scope);
      }
    }
  }
}
```

Add the public runner + keep `executeStPrograms` unchanged (it calls `_execBlock(p, src, stmts, readOnly)`):

```dart
void runScopedStBody(PlcProject p, String src, StScope scope) {
  final clean = stripStComments(src);
  final toks = _tokenize(clean);
  if (toks.isEmpty) return;
  _execBlock(p, clean, _Parser(toks).parseBlock(), null, scope);
}
```

Create `fb_exec.dart`:

```dart
import 'project_model.dart';
import 'st_exec.dart';
import 'tag_resolver.dart';

/// Runs one FB instance for a single scan: writes [inputs] into the instance
/// struct, executes the FB's ST body scoped to that instance (bare vars resolve
/// to `<instanceName>.<var>`, else global), and returns the output-var values.
/// Pure/deterministic; never throws.
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs) {
  // 1. Write inputs into the instance struct.
  for (final v in fb.vars) {
    if (v.direction == FbVarDir.input && inputs.containsKey(v.name)) {
      writePath(p, '$instanceName.${v.name}', inputs[v.name]);
    }
  }
  // 2. Run the scoped body.
  runScopedStBody(p, fb.stSource, StScope(instanceName, {for (final v in fb.vars) v.name}));
  // 3. Read outputs out.
  return {
    for (final v in fb.vars)
      if (v.direction == FbVarDir.output) v.name: readPath(p, '$instanceName.${v.name}'),
  };
}
```

- [ ] **Step 4: Run — expect PASS** (all 3 tests). `flutter analyze` zero. Full suite — record count; existing `st_exec_integration_test` MUST stay green (the null-scope path is byte-identical to before).

- [ ] **Step 5: Commit** — `git add mobile/lib/models/st_exec.dart mobile/lib/models/fb_exec.dart mobile/test/models/fb_exec_test.dart` / `feat(fb): scoped ST execution + executeFbInstance`.

---

### Task 4: FBD FB blocks — pin + eval fallback

**Files:**
- Modify: `mobile/lib/models/fbd_pins.dart` (`fbdInputPins` ~9, `fbdOutputPins` ~61)
- Modify: `mobile/lib/models/fbd_exec.dart` (`_evalBlock` switch ~166-457; needs the project + FB lookup)
- Test: `mobile/test/fb_fbd_exec_test.dart`

**Interfaces:**
- Consumes: `fbDefinitionFor` (Task 2); `executeFbInstance` (Task 3); `FbdBlock` (`type` = FB name, `tagBinding` = instance name).
- Produces: FBD blocks whose `type` names an FB resolve pins from the FB interface and execute via `executeFbInstance`.

**Context:** `fbdInputPins(type,{inputCount})`/`fbdOutputPins(type)` are closed switches returning `[]` for unknown types — but they don't take the project, so they can't see FB defs. The executor DOES have the project. Approach: add optional `List<FbVar>? fbVars` params so the *executor* (which has `p`) can pass the FB's vars, while the editor passes them from the project too. Simpler: add project-aware wrappers used at the call sites.

- [ ] **Step 1: Write the failing test** (`mobile/test/fb_fbd_exec_test.dart`): build a project with a `Scaler` FB (`In`,`Gain`(init 2)→`Out = In*Gain`), one FBD program with a `TAG_INPUT`(reads tag `PV`)→FB block `Scaler` (instance `S1`, input pin `In` wired) →`TAG_OUTPUT`(writes `CV`); run `executeFbdPrograms`; assert `CV == PV*2`. Also two FB instances in one program stay independent. (Resolve exact pin names: an FB's input pins are its input-var names in order; output pins its output-var names.)

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.**
  - In `fbd_pins.dart`, add project/FB-aware helpers: `List<String> fbdInputPinsFor(PlcProject p, FbdBlock b)` = if `fbDefinitionFor(p,b.type)!=null` → its input-var names, else `fbdInputPins(b.type, inputCount: b.inputCount)`; likewise `fbdOutputPinsFor`. Update the executor's pin lookups (`fbd_exec.dart:512`, `:525`, and wherever `fbdOutputPins`/`fbdInputPins` are called in exec) to the `…For` variants. (The editor keeps using the plain ones for built-ins + the new ones for FB blocks — Task 6.)
  - In `_evalBlock`, add a branch at the top of the `switch` default (or before it): `final fb = fbDefinitionFor(p, b.type); if (fb != null) { final inputMap = {for (var i = 0; i < fb-inputs.length; i++) inputName[i]: inputs[i]}; return executeFbInstance(p, fb, b.tagBinding, inputMap); }`. Map the positional `inputs` list (registry order) to input-var names. The returned output-var map IS the pin→value map (output pin names == output var names). Provide the complete branch.

- [ ] **Step 4: Run — expect PASS.** `flutter analyze` zero. Full suite — record count; existing `fbd_exec_integration_test` green (no FB blocks → fallback never fires).

- [ ] **Step 5: Commit** — `feat(fb): execute FB blocks in FBD (pin + eval fallback)`.

---

### Task 5: LD FB blocks — execute via `pinBindings`

**Files:**
- Modify: `mobile/lib/models/ld_exec.dart` (`executeRung` block dispatch ~165-380)
- Test: `mobile/test/fb_ld_exec_test.dart`

**Interfaces:**
- Consumes: `fbDefinitionFor` (Task 2); `executeFbInstance` (Task 3); `LdNode` (`blockType` = FB name, `variable` = instance name, `pinBindings` = varName→tag).
- Produces: LD block nodes whose `blockType` names an FB read inputs from the pin-bound tags, execute the FB, and write outputs to the pin-bound tags.

**Context:** `executeRung`'s block handling is an if-chain on `n.blockType` (`ld_exec.dart:171-379`); unknown types are skipped. Add an FB branch. An LD FB block's power passes through unchanged (it's a data block: `inP` in → `inP` out, like compare/math). Inputs/outputs bind via `n.pinBindings`.

- [ ] **Step 1: Write the failing test** (`mobile/test/fb_ld_exec_test.dart`): project with the `Scaler` FB; one LD rung `L —[block Scaler, variable=S1, pinBindings={In: PV, Out: CV}]— (coil)`; tags `PV=5`, `CV=0`, `S1` instance. Run the rung (via `executeRung`/`executeLdPrograms`, harness like `test/ld_exec_test.dart`); assert `CV == 10`. Power passes through (the block is not a break in the rung).

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.** In the block dispatch, before the "unknown type skipped" fallthrough, add:

```dart
final fb = fbDefinitionFor(p, n.blockType);
if (fb != null) {
  final inputs = <String, dynamic>{};
  for (final v in fb.vars) {
    if (v.direction == FbVarDir.input) {
      final tag = n.pinBindings[v.name];
      if (tag != null && tag.isNotEmpty) inputs[v.name] = readPath(p, tag);
    }
  }
  final outputs = executeFbInstance(p, fb, n.variable, inputs);
  outputs.forEach((name, value) {
    final tag = n.pinBindings[name];
    if (tag != null && tag.isNotEmpty && value != null) write(tag, value); // use the rung's force-aware write closure
  });
  // power passes through the data block:
  // (leave inP flowing to the node's output exactly as compare/math data blocks do)
}
```

(Match the real force-aware write mechanism `executeRung` uses — the `write(path, value)` closure at `ld_exec.dart:66-78`/the `void Function(String,dynamic) write` param — and the power-flow convention for a data block. Provide the complete branch consistent with the surrounding compare/math handling.)

- [ ] **Step 4: Run — expect PASS.** `flutter analyze` zero. Full suite — record count; existing LD tests green.

- [ ] **Step 5: Commit** — `feat(fb): execute FB blocks in LD via pin-bindings`.

---

### Task 6: FB editor + palettes (define & use)

**Files:**
- Create: `mobile/lib/screens/fb_editor_screen.dart` (interface list + embedded ST editor)
- Modify: `mobile/lib/screens/workspace_shell.dart` (a "Function Blocks" nav/section + routing), `mobile/lib/screens/fbd_editor_screen.dart` (palette lists FB defs), `mobile/lib/screens/ld_editor_screen.dart` (block picker "Function Blocks" group)
- Test: `mobile/test/fb_editor_test.dart`

**Deliverable contract (build widgets to satisfy this; reuse the existing ST editor for the body and follow the struct-def CRUD pattern from Memory Manager / `sfc`/`fbd` editors):**
- **FB editor** (`Key('fb_editor')`): create/rename an FB; an interface list where each row edits a var's name / dataType / direction (input|output|internal) / initial value, with add + delete (`Key('fb_add_var')`); an embedded ST body editor bound to `fbDefinition.stSource`. Reached from a "Function Blocks" entry in the shell (near program/struct management). Creating/editing routes through the project-update/autosave path.
- **FBD palette:** append the project's FB definitions as selectable blocks (dynamic entries after the built-ins). Selecting one calls the existing add-block path with `type = fb.name` and auto-creates a uniquely-named instance tag (`dataType = fb.name`, `value = defaultValueFor(project, fb.name, 0)`) bound via `tagBinding`.
- **LD block picker:** add a "Function Blocks" group listing FB definitions; selecting one creates an FB-call block node (`blockType = fb.name`, `variable` = auto instance name, empty `pinBindings` the user fills via the block config) + the instance tag.
- Instance tags are ordinary tags (already inspectable/renamable/force-able).

- [ ] **Step 1: Write failing widget tests** (`mobile/test/fb_editor_test.dart`) at 1400×1000: pump the FB editor with a project + an FbDefinition; add a var (`fb_add_var`), set its name/type/direction, confirm it lands in `fbDefinition.vars`; edit the ST body and confirm `stSource` updates; assert a 320-width pump has no overflow. Plus: pump the FBD editor and assert an FB definition appears as a palette entry and selecting it adds an `FbdBlock` with `type == fb.name` and a new instance tag in `project.tags`. Run → FAIL.
- [ ] **Step 2: Implement** the FB editor + the two palette integrations + the shell nav entry. Run tests → PASS.
- [ ] **Step 3:** `flutter analyze` zero; full suite — existing fbd/ld editor + shell tests green. Record count.
- [ ] **Step 4: Commit** — `feat(fb): FB definition editor + FBD/LD palettes`.

---

### Task 7: Demo FB + validation & docs

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (add a demo FB + use it in a demo)
- Modify: `docs/` (an FB note; confirm `docs/DEFERRED.md` FB section accurate)
- Test: adjust any default-project-shape test

- [ ] **Step 1:** Add one demo `FbDefinition` (e.g. a `Scaler` or a simple `Hysteresis` FB with internal state) to a demo project and instantiate it in that project's FBD program, proving native authoring + execution in a shipped demo. Keep the demo's behavior sensible.
- [ ] **Step 2:** Full validation: `cd mobile && flutter analyze` (zero), `cd mobile && flutter test` (ALL pass — record count), `cd mobile && flutter build web --release` (succeeds).
- [ ] **Step 3:** Docs: a short "Custom function blocks" note (define an FB → use it in FBD/LD → per-instance state). Confirm `docs/DEFERRED.md`'s Custom-FB rows are accurate (import mapping = sub-project 2, graphical bodies, nesting remain deferred — strike nothing).
- [ ] **Step 4: Commit** — `feat(fb): demo function block + docs; validation`.

---

## Self-Review

**Spec coverage:** §1 model → Task 1. §1 instance-as-struct-tag → Task 2. §2 scoped-ST execution → Task 3. §3 FBD usage → Task 4; LD usage (pin-bindings) → Task 5. §4 editor + palettes → Task 6. §5 backward-compat asserted in Tasks 1-5 (fallback fires only for FB names; null-scope ST path unchanged); testing folded per task; demo + docs → Task 7; deferred → `docs/DEFERRED.md` (Task 7 confirms). All spec sections map to a task.

**Placeholder scan:** Tasks 1-5 carry complete code + concrete tests. Task 4/5's exact call-site edits reference the real files (`fbd_exec.dart` pin lookups; `ld_exec.dart` block if-chain + the force-aware `write` closure) and instruct matching the surrounding data-block convention — the established "follow the existing pattern; tests are the oracle" approach — not vague placeholders. Task 6 (UI) gives an exact widget-key contract + the reuse targets (ST editor, struct-def CRUD pattern) + widget tests. The one deliberate note in Task 3 Step 3 (delete the unused `final extra` line) is an explicit correction, not a placeholder.

**Type consistency:** `FbDefinition`/`FbVar`/`FbVarDir`/`fbDefinitions`/`LdNode.pinBindings` (Task 1) are consumed unchanged in Tasks 2-6. `fbDefinitionFor`/`lookupComposite` FB resolution (Task 2) feed Tasks 3-5. `executeFbInstance(p, fb, instanceName, inputs)→outputs` + `runScopedStBody`/`StScope` (Task 3) match the FBD (Task 4) and LD (Task 5) call sites. `fbdInputPinsFor`/`fbdOutputPinsFor` (Task 4) are introduced and consumed within Tasks 4/6.
