# Import Mapping — Custom Function Blocks (sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import PLCopen ST-bodied `functionBlock` POUs as native `FbDefinition`s and route LD custom-FB call blocks to FB instances (`pinBindings` + instance tag) instead of the `unsupported-block` stub.

**Architecture:** A new pure helper turns `functionBlock` POUs into `FbDefinition`s + a `name→def` registry + a `oldName→finalName` rename map (`lib/import/fb_import.dart`). `translateLdBody` accepts that registry so a block whose `typeName` names an FB translates to an FB-call `LdNode`. `mapImportedProject` orchestrates: structs → global vars → **FB defs** → programs (LD gets the registry) → merge FB instance tags.

**Tech Stack:** Dart / Flutter (app in `mobile/`; run flutter from there — it is at `/c/flutter/bin/flutter`, not on PATH). Pure model/import code, no Flutter widgets except the import preview screen (Task 4).

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never throws** — every untranslatable POU/rung/pin degrades to a stub + warning.
- Zero `flutter analyze` warnings.
- **Additive / backward-compatible:** a project with no function blocks imports byte-identically to today; the FB pass + LD registry fire only when FBs / FB-call blocks are present. Existing import tests stay green.
- ST-bodied FBs only: a graphical-bodied `functionBlock` POU is NOT imported (warning) and is never emitted as a program.
- Follow the importer's name discipline: sanitize identifiers, dedup, avoid `kSystemTagName` (`'System'`), warn on every rename, and propagate a rename to every reference.
- Deferred items are tracked in `docs/DEFERRED.md`.

---

### Task 1: `mapImportedFbs` — functionBlock POUs → FbDefinitions

**Files:**
- Create: `mobile/lib/import/fb_import.dart`
- Test: `mobile/test/import/fb_import_test.dart`

**Interfaces:**
- Consumes: `ImportedPou`/`PouKind`/`PouBody`/`TextBody`/`GraphBody`/`ImportedVar`/`VarScope`/`ImportWarning`/`WarningSeverity`/`PouLanguage` (`import_ir.dart`); `FbDefinition`/`FbVar`/`FbVarDir`/`PlcProject`/`PlcStructDef` (`models/project_model.dart`); `fbNameValidationError` (`models/fb_name_validation.dart`); `normalizeType`, `coerceInitialValue` (`import/type_normalize.dart`); `kSystemTagName` (`models/system_tags.dart`).
- Produces:
  - `class FbImportResult { final List<FbDefinition> defs; final Map<String, FbDefinition> registry; final Map<String, String> renameMap; }` — `registry` keyed by FINAL name; `renameMap` maps each imported FB POU's ORIGINAL name → its final (possibly renamed) name (only ST-bodied FBs that produced a def appear).
  - `FbImportResult mapImportedFbs(List<ImportedPou> pous, {required List<PlcStructDef> structs, required Set<String> dutNames, required List<ImportWarning> warnings})`.

**Var-scope → direction rule:** `input`→`FbVarDir.input`; `output`→`FbVarDir.output`; `inOut`→`FbVarDir.input` **and** append an info warning; everything else (`local`/`temp`/`external`/`global`)→`FbVarDir.internal`.

- [ ] **Step 1: Write the failing test** (`mobile/test/import/fb_import_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fb_import.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

ImportedVar _v(String name, String type, VarScope scope, {dynamic init}) =>
    ImportedVar(name: name, baseType: type, scope: scope, initialValue: init);

ImportedPou _fbPou(String name, List<ImportedVar> vars, String st,
        {PouLanguage lang = PouLanguage.st}) =>
    ImportedPou(name: name, kind: PouKind.functionBlock, lang: lang,
        localVars: vars, body: TextBody(st));

void main() {
  test('ST functionBlock POU -> FbDefinition with vars, directions, body', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _fbPou('Scaler', [
        _v('In', 'REAL', VarScope.input),
        _v('Gain', 'REAL', VarScope.input, init: '2.0'),
        _v('Acc', 'REAL', VarScope.local),
        _v('Out', 'REAL', VarScope.output),
      ], 'Out := In * Gain;'),
    ], structs: [], dutNames: {}, warnings: warnings);

    expect(res.defs, hasLength(1));
    final fb = res.defs.single;
    expect(fb.name, 'Scaler');
    expect(fb.stSource, 'Out := In * Gain;');
    expect(fb.vars.map((v) => v.name).toList(), ['In', 'Gain', 'Acc', 'Out']);
    expect(fb.vars.map((v) => v.direction).toList(), [
      FbVarDir.input, FbVarDir.input, FbVarDir.internal, FbVarDir.output,
    ]);
    expect(fb.vars[0].dataType, 'FLOAT64'); // REAL normalized
    expect(fb.vars[1].initialValue, 2.0);   // coerced
    expect(res.registry.containsKey('Scaler'), isTrue);
    expect(res.renameMap['Scaler'], 'Scaler');
  });

  test('inOut var maps to input + info warning', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      _fbPou('Acc', [_v('Sum', 'INT', VarScope.inOut)], 'Sum := Sum + 1;'),
    ], structs: [], dutNames: {}, warnings: warnings);
    expect(res.defs.single.vars.single.direction, FbVarDir.input);
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.info && w.message.contains('VAR_IN_OUT')), isTrue);
  });

  test('graphical-bodied functionBlock POU is skipped with a warning', () {
    final warnings = <ImportWarning>[];
    final res = mapImportedFbs([
      ImportedPou(name: 'Mixer', kind: PouKind.functionBlock, lang: PouLanguage.fbd,
          localVars: const [], body: GraphBody(nodes: const [], connections: const [])),
    ], structs: [], dutNames: {}, warnings: warnings);
    expect(res.defs, isEmpty);
    expect(res.registry, isEmpty);
    expect(warnings.any((w) =>
        w.severity == WarningSeverity.warning && w.message.contains('graphical body')), isTrue);
  });

  test('FB name colliding with a reserved block type is renamed + warned', () {
    final warnings = <ImportWarning>[];
    // 'AND' is a reserved built-in block type (fbNameValidationError rejects it).
    final res = mapImportedFbs([
      _fbPou('AND', [_v('a', 'BOOL', VarScope.input), _v('q', 'BOOL', VarScope.output)],
          'q := a;'),
    ], structs: [], dutNames: {}, warnings: warnings);
    final fb = res.defs.single;
    expect(fb.name, isNot('AND'));
    expect(res.registry.containsKey(fb.name), isTrue);
    expect(res.renameMap['AND'], fb.name); // original -> final
    expect(warnings.any((w) => w.message.contains('renamed')), isTrue);
  });

  test('non-functionBlock POUs are ignored', () {
    final res = mapImportedFbs([
      ImportedPou(name: 'Main', kind: PouKind.program, lang: PouLanguage.st,
          localVars: const [], body: TextBody('X := 1;')),
    ], structs: [], dutNames: {}, warnings: []);
    expect(res.defs, isEmpty);
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`mapImportedFbs` undefined).
  Run: `cd mobile && /c/flutter/bin/flutter test test/import/fb_import_test.dart`

- [ ] **Step 3: Implement** `mobile/lib/import/fb_import.dart`:

```dart
import '../models/fb_name_validation.dart';
import '../models/project_model.dart';
import '../models/system_tags.dart';
import 'import_ir.dart';
import 'type_normalize.dart';

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

String _sanitize(String raw) {
  var s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (s.isEmpty) s = 'Fb';
  if (RegExp(r'^[0-9]').hasMatch(s)) s = '_$s';
  return s;
}

FbVarDir _dir(VarScope scope) => switch (scope) {
      VarScope.input => FbVarDir.input,
      VarScope.output => FbVarDir.output,
      VarScope.inOut => FbVarDir.input,
      _ => FbVarDir.internal,
    };

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

    // Vars.
    final vars = <FbVar>[];
    for (final v in pou.localVars) {
      if (v.scope == VarScope.inOut) {
        warnings.add(ImportWarning(severity: WarningSeverity.info,
            message: 'VAR_IN_OUT "${v.name}" on FB "${pou.name}" imported as an '
                'input (by-reference semantics unsupported).'));
      }
      final appType = normalizeType(v.baseType, knownDutNames: dutNames);
      vars.add(FbVar(
        name: v.name,
        dataType: appType,
        direction: _dir(v.scope),
        initialValue: coerceInitialValue(scratch, appType, v.arrayLength,
            v.initialValue == null ? null : '${v.initialValue}', warnings),
      ));
    }

    // Name sanitize + collision.
    var name = _sanitize(pou.name);
    if (name != pou.name) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Function block "${pou.name}" renamed to "$name" (identifier rules).'));
    }
    if (name == kSystemTagName || fbNameValidationError(scratch, name) != null) {
      final base = name;
      var i = 1;
      while (fbNameValidationError(scratch, '${base}_$i') != null ||
          '${base}_$i' == kSystemTagName) {
        i++;
      }
      final renamed = '${base}_$i';
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Function block "$name" renamed to "$renamed" (name collision/reserved).'));
      name = renamed;
    }

    final def = FbDefinition(name: name, vars: vars, stSource: body.source);
    defs.add(def); // scratch.fbDefinitions IS defs, so the next FB sees it
    registry[name] = def;
    renameMap[pou.name] = name;
  }
  return FbImportResult(defs, registry, renameMap);
}
```

Note: `PlcProject`'s constructor must accept `fbDefinitions`. Verify the param name/shape in `models/project_model.dart` and match it; if `fbDefinitions` isn't a named ctor param, set it after construction (`scratch.fbDefinitions.addAll(defs)` once, keeping the same growing-list identity).

- [ ] **Step 4: Run — expect PASS.** `cd mobile && /c/flutter/bin/flutter test test/import/fb_import_test.dart` then `/c/flutter/bin/flutter analyze lib/import/fb_import.dart test/import/fb_import_test.dart` → zero.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/import/fb_import.dart mobile/test/import/fb_import_test.dart
git commit -m "feat(import): map ST functionBlock POUs to FbDefinitions"
```

---

### Task 2: LD FB-call routing in `translateLdBody`

**Files:**
- Modify: `mobile/lib/import/ld_translate.dart`
- Test: `mobile/test/import/ld_translate_test.dart` (append new tests)

**Interfaces:**
- Consumes: `FbImportResult`/`registry` (Task 1) — but to keep `ld_translate` dependency-light, `translateLdBody` takes **`Map<String, FbDefinition> fbRegistry`** (final-name→def) and **`Map<String, String> fbRenameMap`** (original→final) directly. `FbDefinition`/`FbVar`/`FbVarDir` (`models/project_model.dart`); `defaultValueFor` (`models/tag_resolver.dart`).
- Produces: `translateLdBody(GraphBody body, {required String pouName, Map<String, FbDefinition> fbRegistry = const {}, Map<String, String> fbRenameMap = const {}})` — a block whose `typeName` (after `fbRenameMap`) is a key of `fbRegistry` translates to `LdNode(kind: LdKind.block, blockType: <final FB name>, variable: <instance>, pinBindings: {<varName>: <tag/operand>})`, and its struct-typed instance tag is appended to `instanceTags`.

**Integration points (read the current code around each before editing):**

1. **Signature:** add the two optional named params to `translateLdBody` (defaults `const {}` keep all existing call sites and tests compiling). Thread `fbRegistry`/`fbRenameMap` down to `_translateComponent` and its helpers (new params, defaulting `const {}`).
2. **A block's *effective* type** is `fbRenameMap[typeName] ?? typeName`. Define a local `bool isFbCall(String typeName) => fbRegistry.containsKey(fbRenameMap[typeName] ?? typeName)`. Compute the effective name once per block.
3. **`isFoldedEdge`** (reduced-power view, ~line 272): an FB block folds ALL its pin edges out of the power graph so it sits as a bare data block. Add, before the existing `_dataSlotFor` check: if `tgtBlock` is an FB call → this input edge folds (data); if `srcBlock` is an FB call and the target is an `outVariable` → this output edge folds (destination write). (The FB is series-wired like a coil-less MOVE terminal — power passes through.)
4. **Terminal/`no-coil` gate (~line 306-312):** FB blocks are already counted as `blocks` (any `elementType == 'block'`), so a coil-less FB rung is a valid block rung — no change needed; verify.
5. **`_buildBlockNode`** (the function starting ~line 379 with the `if (!_kSupportedBlocks.contains(typeName))` throw): add an FB branch at the TOP, before the unsupported-block throw and before the timer/counter power-pin check:

```dart
final effective = fbRenameMap[typeName] ?? typeName;
final fb = fbRegistry[effective];
if (fb != null) {
  return _buildFbCallNode(comp, node, byId, fb, effective, instanceTags,
      usedInstanceNames, pouName, fbRegistry);
}
```

6. **New `_buildFbCallNode`:**

```dart
LdNode _buildFbCallNode(
  LdComponent comp,
  IrGraphNode node,
  Map<int, IrGraphNode> byId,
  FbDefinition fb,
  String fbName,
  List<PlcTag> instanceTags,
  Set<String> usedInstanceNames,
  String pouName,
  Map<String, FbDefinition> fbRegistry,
) {
  final inputNames = {
    for (final v in fb.vars) if (v.direction == FbVarDir.input) v.name
  };
  final outputNames = {
    for (final v in fb.vars) if (v.direction == FbVarDir.output) v.name
  };
  final pinBindings = <String, String>{};

  // Inputs: each incoming edge's toPin (formalParameter) is an input var name;
  // its source must resolve to a variable/literal (an inVariable's `variable`).
  for (final e in comp.edges) {
    if (e.toLocalId != node.localId) continue;
    final pin = e.toPin;
    if (pin == null || !inputNames.contains(pin)) {
      throw _StubException('unresolved-operand',
          'FB "$fbName" input pin "${pin ?? '?'}" not on its interface');
    }
    final src = byId[e.fromLocalId]?.attributes['variable'];
    if (src == null || src.isEmpty) {
      throw _StubException('unresolved-operand', 'unresolved FB input on $pin');
    }
    pinBindings[pin] = src;
  }

  // Outputs: each outgoing edge's fromPin is an output var name; the consumer
  // (an outVariable) supplies the destination tag. Unbound outputs are allowed.
  for (final e in comp.edges) {
    if (e.fromLocalId != node.localId) continue;
    final pin = e.fromPin;
    if (pin == null || !outputNames.contains(pin)) continue;
    final dest = byId[e.toLocalId]?.attributes['variable'];
    if (dest != null && dest.isNotEmpty) pinBindings[pin] = dest;
  }

  final instance = _instanceName(node, pouName, usedInstanceNames);
  // Instance tag default resolved against a scratch project that knows the FB.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
      fbDefinitions: fbRegistry.values.toList());
  instanceTags.add(PlcTag(
    name: instance, path: instance, dataType: fbName,
    value: defaultValueFor(scratch, fbName, 0), ioType: 'Internal'));

  return LdNode(id: '', kind: LdKind.block, blockType: fbName,
      variable: instance, pinBindings: pinBindings);
}
```

(Adapt names to the real `LdNode` constructor + the real `_instanceName`/`_StubException`/`PlcProject` shapes. `pinBindings` is an existing `LdNode` field — verify its exact name.)

- [ ] **Step 1: Write the failing tests** (append to `mobile/test/import/ld_translate_test.dart`). Study the file's existing helpers for building a `GraphBody` (block + inVariable/outVariable + rail wiring) and reuse them; the shapes below are the assertions the implementation must satisfy.

```dart
// A rung: leftRail -> FB(Scaler, instance 'S1') -> rightRail, In<-PV, Gain<-'2.0',
// Out->CV. Build with the file's existing GraphBody test helpers.
test('LD custom-FB call block -> FB-call node with pinBindings + instance tag', () {
  final fb = FbDefinition(name: 'Scaler', vars: [
    FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
    FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input),
    FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
  ], stSource: 'Out := In * Gain;');
  final body = /* GraphBody: block typeName='Scaler' instanceName='S1',
     inVariable 'PV'->In, inVariable '2.0'->Gain, Out->outVariable 'CV',
     rails wired */;
  final tr = translateLdBody(body, pouName: 'P', fbRegistry: {'Scaler': fb});

  expect(tr.translatedRungCount, 1);
  final block = tr.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
  expect(block.blockType, 'Scaler');
  expect(block.variable, 'S1');
  expect(block.pinBindings['In'], 'PV');
  expect(block.pinBindings['Gain'], '2.0');
  expect(block.pinBindings['Out'], 'CV');
  final inst = tr.instanceTags.firstWhere((t) => t.name == 'S1');
  expect(inst.dataType, 'Scaler');
  expect(inst.value, isA<Map>()); // struct default
  expect(tr.unsupportedBlockTypes, isNot(contains('Scaler')));
});

test('unresolved FB input pin stubs the rung', () {
  final fb = FbDefinition(name: 'Scaler', vars: [
    FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
    FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
  ], stSource: 'Out := In;');
  final body = /* GraphBody: FB with In wired from a source lacking `variable` */;
  final tr = translateLdBody(body, pouName: 'P', fbRegistry: {'Scaler': fb});
  expect(tr.translatedRungCount, 0);
  expect(tr.stubbedRungCount, 1);
});

test('renamed FB: block typeName routed through fbRenameMap', () {
  final fb = FbDefinition(name: 'AND_1', vars: [
    FbVar(name: 'a', dataType: 'BOOL', direction: FbVarDir.input),
    FbVar(name: 'q', dataType: 'BOOL', direction: FbVarDir.output),
  ], stSource: 'q := a;');
  final body = /* GraphBody: block typeName='AND' (original) instanceName='I1',
     a<-X, q->Y */;
  final tr = translateLdBody(body, pouName: 'P',
      fbRegistry: {'AND_1': fb}, fbRenameMap: {'AND': 'AND_1'});
  final block = tr.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
  expect(block.blockType, 'AND_1');
});
```

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && /c/flutter/bin/flutter test test/import/ld_translate_test.dart`
- [ ] **Step 3: Implement** the integration points above.
- [ ] **Step 4: Run — expect PASS** (new + all existing `ld_translate_test` + `ld_translate_exec_test`). `flutter analyze` zero.
- [ ] **Step 5: Commit** — `feat(import): route LD custom-FB call blocks to FB instances`.

---

### Task 3: Mapper integration (`ir_to_project.dart`)

**Files:**
- Modify: `mobile/lib/import/ir_to_project.dart`
- Test: `mobile/test/import/ir_to_project_test.dart` (append)

**Interfaces:**
- Consumes: `mapImportedFbs`/`FbImportResult` (Task 1); `translateLdBody(..., fbRegistry, fbRenameMap)` (Task 2); `isInstanceBackedLdBlock` (`ld_translate.dart`).
- Produces: `mapImportedProject` now (a) skips `functionBlock` POUs in the POU→program loop, (b) sets `project.fbDefinitions`, (c) threads the FB registry/renameMap into every LD `translateLdBody` call, (d) treats an FB-name blockType as instance-backed for the instance-rename retarget, (e) `ImportReport` gains `final int importedFbCount;` (default 0).

**Changes:**
1. After the global-vars→tags block and before the POU loop, call:
   `final fbRes = mapImportedFbs(ir.pous, structs: structs, dutNames: dutNames, warnings: warnings);`
2. In the POU loop, `if (pou.kind == PouKind.functionBlock) continue;` at the top (they became defs; do NOT emit them as programs — this also fixes today's bug where an ST FB POU wrongly became a program).
3. The LD branch: `final tr = translateLdBody(body, pouName: pou.name, fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);`
4. The existing instance-tag rename-retarget loop guards on `isInstanceBackedLdBlock(node.blockType)`. FB-call nodes are instance-backed too. Widen the guard: `(isInstanceBackedLdBlock(node.blockType) || fbRes.registry.containsKey(node.blockType))`.
5. Assemble `PlcProject(..., fbDefinitions: fbRes.defs, ...)`.
6. `ImportReport`: add `final int importedFbCount;` (ctor `this.importedFbCount = 0`), pass `importedFbCount: fbRes.defs.length`.

- [ ] **Step 1: Write the failing test** (`mobile/test/import/ir_to_project_test.dart`)

```dart
test('import maps an ST functionBlock POU to an FbDefinition (not a program)', () {
  final ir = ImportedProject(name: 'P', types: [], globalVars: [], warnings: [], pous: [
    ImportedPou(name: 'Scaler', kind: PouKind.functionBlock, lang: PouLanguage.st,
        localVars: [
          ImportedVar(name: 'In', baseType: 'REAL', scope: VarScope.input),
          ImportedVar(name: 'Out', baseType: 'REAL', scope: VarScope.output),
        ], body: TextBody('Out := In;')),
  ]);
  final res = mapImportedProject(ir, projectName: 'P', projectId: 'p');
  expect(res.project.fbDefinitions.map((f) => f.name), contains('Scaler'));
  expect(res.project.programs.where((p) => p.name == 'Scaler'), isEmpty);
  expect(res.report.importedFbCount, 1);
});
```

(If the file lacks an obvious `mapImportedProject` helper import, mirror the existing tests in the file for setup.)

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && /c/flutter/bin/flutter test test/import/ir_to_project_test.dart`
- [ ] **Step 3: Implement** the 6 changes.
- [ ] **Step 4: Run — expect PASS** (new + all existing `ir_to_project_test`, `corpus_import_test`, `import_xml_flow_test`). `flutter analyze` zero.
- [ ] **Step 5: Commit** — `feat(import): FB defs + registry into project mapping`.

---

### Task 4: End-to-end XML fixture, preview count, docs

**Files:**
- Test: `mobile/test/import/import_fb_e2e_test.dart` (create)
- Modify: `mobile/lib/screens/import_xml_preview.dart` (surface `importedFbCount`)
- Modify: `docs/DEFERRED.md`; `docs/` FB/import note if one exists.

**Interfaces:**
- Consumes: the full parse→map pipeline. Find the public entry the existing `import_xml_flow_test.dart` uses (e.g. `parsePlcopen(...)` → `mapImportedProject(...)`, or a single `importPlcopenXml(...)`); reuse it verbatim.

- [ ] **Step 1: Write the failing end-to-end test** (`mobile/test/import/import_fb_e2e_test.dart`). Use a small handcrafted PLCopen TC6 XML **string constant** (spec-faithful — write it to exercise a real FB call, not to match the importer), with: one `<pou name="Scaler" pouType="functionBlock">` (ST body `Out := In * Gain;`, interface In/Gain inputs + Out output) and one `<pou name="Main" pouType="program">` in LD that instantiates `Scaler` (`instanceName="S1"`) wired `In<-PV`, `Gain` from a literal `2.0`, `Out->CV`, with global vars `PV`,`CV`. Assertions:

```dart
// pipeline: parse XML -> ImportedProject -> mapImportedProject
final res = /* run the same entry point import_xml_flow_test uses on _kFbXml */;
final p = res.project;
// FB imported
expect(p.fbDefinitions.map((f) => f.name), contains('Scaler'));
// Main is a real LD program (not a stub) with an FB-call node
final main = p.programs.firstWhere((pr) => pr.name == 'Main');
expect(main.language, 'LadderLogic');
final fbNode = main.rungs.expand((r) => r.nodes)
    .firstWhere((n) => n.kind == LdKind.block && n.blockType == 'Scaler');
expect(fbNode.pinBindings['In'], 'PV');
// instance tag exists
expect(p.tags.any((t) => t.name == 'S1' && t.dataType == 'Scaler'), isTrue);
// and it RUNS: set PV, execute the LD program(s), CV == PV*2
writePath(p, 'PV', 21.0);
executeLdPrograms(p, /* the args ld_translate_exec_test uses */);
expect(readPath(p, 'CV'), 42.0);
```

Study `ld_translate_exec_test.dart` for the exact `executeLdPrograms`/scan invocation + imports (`tag_resolver` `writePath`/`readPath`, `ld_exec`).

- [ ] **Step 2: Run — expect FAIL** (until the pipeline wires through; if Tasks 1-3 are already merged it may pass the structural asserts but confirm the execution assert).
- [ ] **Step 3: Surface the count** in `import_xml_preview.dart`: wherever `report.stProgramCount`/`graphicalStubCount` are shown, add a line for `report.importedFbCount` (e.g. `'Function blocks: ${report.importedFbCount}'`) when `> 0`. Match the existing widget/style.
- [ ] **Step 4: Run — expect PASS.** Full suite: `cd mobile && /c/flutter/bin/flutter test` (record count) + `/c/flutter/bin/flutter analyze` zero.
- [ ] **Step 5: Docs + DEFERRED.**
  - In `docs/DEFERRED.md`, under "Custom (user-defined) function blocks", **strike through** the `Import mapping → FB defs/instances` row noting it shipped in this PR; and under "FBD & SFC graphical translators" (or a new note) record that **FBD custom-FB call routing** is deferred until the FBD import translator exists. Add rows for IEC `VAR_IN_OUT` (mapped to input) and graphical-bodied imported FBs if not already covered.
  - If an import feature doc exists (glob `docs/` for import notes), add a short "Custom function blocks" line: ST-bodied `functionBlock` POUs import as native FBs; LD calls to them route to instances; graphical FB bodies / FBD calls deferred.
- [ ] **Step 6: Commit** — `feat(import): FB import e2e + preview count + docs`.

---

## Self-Review

**Spec coverage:** §1 FB mapping → Task 1. §2 LD routing → Task 2. §3 orchestration/report → Task 3. §4 error handling → covered across Tasks 1-2 (graphical skip, collision rename, inOut warning, unresolved-pin stub) with tests. §5 testing → each task's tests + Task 4 e2e. Deferred → Task 4 Step 5.

**Placeholder scan:** Test bodies that build a `GraphBody` are marked `/* ... */` deliberately — they require the target file's existing GraphBody test helpers, which the implementer reads in-file (the assertions, which ARE the contract, are complete). Implementation code for the pure helper (Task 1) and `_buildFbCallNode` (Task 2) is complete; the surrounding wire-in points are named with exact line references to adapt to the real signatures.

**Type consistency:** `FbImportResult{defs, registry, renameMap}`, `mapImportedFbs(...)`, and `translateLdBody(..., fbRegistry, fbRenameMap)` are used identically in Tasks 1→2→3. `importedFbCount` consistent across Task 3/4. `pinBindings`/`blockType`/`variable` are existing `LdNode` fields (Task 2 verifies exact names against `project_model.dart`).
