# L5X FBD Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Rockwell L5X FBD content executable end to end: a `<Routine Type="FBD">` parses into the neutral `GraphBody` and translates through the existing `translateFbdBody` into a real `FunctionBlockDiagram` program, and an AOI whose `Logic` routine is FBD compiles at import into an FBD-bodied `FbDefinition` that executes per instance through a new scoped FBD executor.

**Architecture:** `FbDefinition` gains `fbdBlocks`/`fbdWires`/`fbdNetworks` (a third body kind after ST and ladder, with precedence ladder > FBD > ST). `fbd_exec.dart`'s per-program body is extracted into a private `_runFbdBody` shared by `executeFbdPrograms` (unscoped, byte-identical) and a new `runScopedFbdBody` that applies an `LdScope` at the three tag-path sites and prefixes every stateful block's runtime key with `fb:<instancePath>|`. On the import side one new private builder, `_l5xFbdBody`, converts `<FBDContent><Sheet>` XML into the exact IR attribute keys the PLCopen parser emits (merging sheets, resolving `ICon`/`OCon` connector pairs into direct wires, and rewriting Rockwell type and pin mnemonics to IEC names), so `translateFbdBody` needs zero changes and feeds both the routine arm and the AOI arm.

**Tech Stack:** Dart 3 / Flutter (package `soft_plc_mobile` in `mobile/`), `flutter_test`, `package:xml` (parsers only). Pure-Dart models, executors and importers; no Flutter imports in `fbd_exec.dart` / `fb_exec.dart` / `ld_exec.dart`.

## Global Constraints

Copied from the spec's binding rules (`docs/superpowers/specs/2026-08-04-l5x-fbd-import-design.md`, "Global constraints", "North-star decisions", §8, §13). Every task below must hold all of them.

- **Spec is the single source of requirements:** `docs/superpowers/specs/2026-08-04-l5x-fbd-import-design.md`. Every section maps to a task in this plan (see the coverage table below).
- **Faithful-or-stub, never-throws, everywhere.** An FBD AOI whose body cannot translate degrades to the existing interface-only no-op plus a warning; an FBD routine that cannot translate keeps today's whole-POU stub. A parser that meets malformed XML emits a warning, never an exception. `parseL5x` still throws `FormatException` only for non-well-formed XML or a wrong root element (unchanged).
- **`translateFbdBody` needs ZERO changes.** `_l5xFbdBody` emits a **deliberately stricter subset** of the IR attribute keys `plcopen_parser.dart`'s `_graphBody` emits: `variable`, `typeName`, `instanceName`, plus unique negative synthetic ids for malformed ids. It never emits `hasNegatedPin` and never emits `negated` (Logix FBD has no pin inversion or element negation: `BNOT` is an explicit element), so the translator's negated-pin gate is unreachable from this parser by construction. `abOriginal` (Task 6) and `connectorName` (Tasks 4-5) are permitted EXTRA keys: `translateFbdBody` copies attributes through and only reads the keys it knows, so an unrecognized key is silently ignored, not an error.
- **PLCopen path stays byte-identical.** PLCopen `functionBlock` FBD POUs keep today's "graphical body (fbd) - not imported" warning verbatim; only L5X-parser-produced FBD AOIs enter the new `mapImportedFbs` arm, gated on `ImportedProject.dialect == ImportDialect.l5x`. The whole PLCopen import path, every ST- and ladder-bodied FB, and all existing L5X behaviour are unchanged.
- **Additive / backward-compatible JSON.** `FbDefinition` JSON keys are exactly `fbd_blocks` / `fbd_wires` / `fbd_networks` (the same key names `PlcProgram` already uses, so the element serializers are reused as-is). Each is emitted **only when non-empty**, so ST- and ladder-bodied FB JSON is byte-identical to today. `fromJson` defaults each to `[]`, so old projects (no `fbd_blocks` key) load unchanged.
- **Runtime state key prefix is exactly `'fb:<instancePath>|'`** (note the trailing pipe), producing keys like `fb:Pump1|AOI Ramp_n7`. Programs use the empty prefix, so program keys stay bare `b.id`. Do not invent another scheme. **Disjointness argument (state it this way, not via the sanitizer):** a program-produced block id can never contain `:` or `|`, so no prefixed key can collide with one. It is NOT true that block ids are fully sanitized identifiers: `_blockId` is `'${pouName}_n$localId'` and `pouName` for an AOI body is `'AOI Ramp'`, which carries a space. The space is harmless; only `:`/`|` matter.
- **Body precedence discriminator, single source of truth in `executeFbInstance`:** `ladderRungs.isNotEmpty` -> ladder; else `fbdBlocks.isNotEmpty` -> FBD; else ST.
- **Exact warning severities and assertable substrings** (tests assert these):
  | Condition | Severity | Substring |
  |---|---|---|
  | `<TextBox>` / `<Attachment>` dropped | `WarningSeverity.info` | `ignored` |
  | Unmatched `ICon`/`OCon` | `WarningSeverity.info` | `unmatched connector` |
  | `TONR`/`TOFR` best-effort mapping | `WarningSeverity.warning` | `verify` |
  | Wired `EnableIn`/`EnableOut` on a block endpoint | `WarningSeverity.info` | `EnableIn/EnableOut wired` |
  | Unnamed (blank `Name`) `ICon`/`OCon` | `WarningSeverity.info` | `unmatched connector` + `(unnamed)` |
  | AOI FBD body, 0 networks translated, body had nodes | `WarningSeverity.warning` | the AOI name |
  | Nested-instance var name collides with a differently-typed var (R3) | `WarningSeverity.info` | `may not resolve` |
  | Dotted/member operand on an `IRef`/`ORef` (`Timer1.DN`) | `WarningSeverity.warning` (from `translateFbdBody`) | `not translated` + `compound` |
  | Multiple wires into one input pin | `WarningSeverity.warning` (from `translateFbdBody`) | `not translated` + `same input pin` |
- **Stub reason keys** are the existing `stubReasons` keys only: `unsupported-element` (unmatched or unnamed connector, `JSR`/`SBR`/`Ret` and other unknown elements, malformed id, dangling-wire placeholder), `unsupported-block` (unmapped AB block), `unresolved-pin` (unmapped pin, wired `EnableIn`/`EnableOut`, multiple wires into one input pin), `complex-expression` (dotted/member operand). No new `ImportReport` field, no preview-UI change.
- **Pure Dart, in-app (ADR-010). Deterministic.** The `xml` package stays confined to `lib/import/*_parser.dart`; `fbd_exec.dart`, `fb_exec.dart` and `ld_exec.dart` stay Flutter-free.
- **Zero `flutter analyze` warnings.** Flutter is NOT on PATH: use `/c/flutter/bin/flutter`, and run every `flutter` command from `mobile/`.
- **Every task ends green:** the task's own tests, the **full suite** (`/c/flutter/bin/flutter test`) and `/c/flutter/bin/flutter analyze` all pass before the commit step.
- **TDD:** write the failing test first, run it and watch it fail for the expected reason, then implement.
- **No em dashes in `knowledge/**` prose** (`.git/sdd/kb-conventions.md:99`: "No em dashes anywhere. Plain hyphens only."). This applies to the knowledge-base files touched in Task 9 and to this plan's own prose. It does **not** apply to `docs/**`, which keeps its existing house style (em dashes are used throughout `docs/import/L5X.md`, `docs/DEFERRED.md` and the `docs/iec61131/` files), and it does **not** apply to Dart code: the five new warning strings and every new doc-comment follow the codebase's existing em-dash style, and code quoted verbatim from live files keeps its original punctuation.

## Recorded resolutions

Five points the spec leaves open, resolved here. Implement them as written; do not re-litigate them mid-task.

1. **A wire endpoint that names no assigned node is NOT dropped.** Pass 1 records `assignedByRawId[rawId] = assignedLocalId` for every element whose `ID` parsed as a non-negative int (including one that got a synthetic negative id for being out of range). Pass 2 resolves each endpoint through that map; an endpoint that still does not resolve (absent, unparseable, negative, or naming no element on the sheet) gets a fresh `danglingWire` placeholder node with a synthetic negative id, and the wire points at it. Dropping the wire instead would silently delete a data path and let the consumer's component translate as if the input were simply unwired; the placeholder makes that component stub (`unsupported-element`) with a named reason. (Revised from the first draft of this plan, which dropped such wires.)
2. **Sheet ordering when `<Sheet Number>` is absent.** The sheet's sort key is `previousSheetKey + 0.5` with a stable sort, so an unnumbered sheet lands immediately after its document-order predecessor. Sheets numbered `2`, none, `1` therefore process as `1`, `2`, unnumbered.
3. **Scope of the wired-`EnableIn`/`EnableOut` heads-up.** It fires whenever a wire endpoint is any recorded FBD block node (`Block`, `Function` or `AddOnInstruction`) and the pin is literally `EnableIn`/`EnableOut`. Restricting it to aliased built-ins would miss the most common real case, an `<AddOnInstruction>` call whose `EnableIn` is wired: for an FBD-Logic AOI, `EnableIn`/`EnableOut` are INTERNAL vars and therefore not pins, so that wire stubs the network exactly like an aliased built-in's would.
4. **Em dashes.** REVISED per review: the no-em-dash rule is a `knowledge/**` convention (`.git/sdd/kb-conventions.md:99`), not a repo-wide one. `docs/**` keeps its house style and the new Dart warning strings keep theirs. See the Global Constraints bullet above.
5. **`<Function>` carries no `instanceName`.** The spec's §4 table gives `<Function Type=>` a `typeName` only, and Logix `<Function>` elements are the stateless ones (`BAND`/`BOR`/`BNOT`), so only `<Block>` and `<AddOnInstruction>` emit `instanceName`. Both still record their raw type for pin aliasing and the `EnableIn` heads-up.

## Spec coverage

| Spec section | Task |
|---|---|
| §1 Model: FBD body on `FbDefinition` | 1 |
| §2 Scoped FBD executor | 2 |
| §3 Dispatch + runtime plumbing | 3 |
| §4 L5X FBD parser core + `_l5xRoutines` arm | 4 |
| §5 Multi-sheet merge + connector resolution | 5 |
| §6 Mnemonic + pin aliasing | 6 |
| §7 AOI FBD logic -> FBD-bodied `FbDefinition` | 7 |
| §8 Error handling | 4, 5, 6, 7 (each row lands in the owning task's tests) |
| §9 Testing | every task; composed e2e in 8 |
| §10 Docs | 9 |
| §11 Deferred rows | 9 |
| §12 Resolutions R1-R5 | R1 -> 6, R2 -> 7, R3 -> 7, R4 -> 5, R5 -> 5 |
| §13 Execution shape | this plan's task order |

## File structure

| File | Responsibility | Task |
|---|---|---|
| `mobile/lib/models/project_model.dart` | `FbDefinition.fbdBlocks/fbdWires/fbdNetworks` + JSON | 1 |
| `mobile/lib/models/tag_resolver.dart` | `renameFbDefinition` third `FbdBlock` root | 1 |
| `mobile/lib/models/fbd_exec.dart` | `_runFbdBody` extraction, `runScopedFbdBody`, scoped `_evalBlock`, state-key prefix | 2, 3 |
| `mobile/lib/models/fb_exec.dart` | Three-way body dispatch, `_reassertEnableIn`, `fbdRt` | 3 |
| `mobile/lib/models/ld_exec.dart` | `fbdRt` threading through `executeLdPrograms`/`executeRung`/`runScopedLdBody` | 3 |
| `mobile/lib/screens/scan_tick.dart` | Passes the shell's `FbdRuntime` into the LD engine | 3 |
| `mobile/lib/import/l5x_parser.dart` | `_l5xFbdBody`, routine FBD arm, sheet merge, connectors, aliases, AOI FBD arm | 4, 5, 6, 7 |
| `mobile/lib/import/import_ir.dart` | `ImportedProject.dialect` | 7 |
| `mobile/lib/import/fb_import.dart` | `dialect` param, FBD arm, R3 instance vars, FBD counters | 7 |
| `mobile/lib/import/ir_to_project.dart` | Passes `ir.dialect`, seeds the FBD counters from `FbImportResult` | 7 |
| `mobile/test/models/fb_model_test.dart` | Round-trip + rename tests | 1 |
| `mobile/test/models/fb_fbd_body_exec_test.dart` | Scoped-executor units (new file) | 2 |
| `mobile/test/models/fb_exec_test.dart`, `mobile/test/fb_fbd_exec_test.dart` | Dispatch/threading units | 3 |
| `mobile/test/import/l5x_parser_fbd_test.dart` | Parser units (new file) | 4, 5, 6 |
| `mobile/test/import/l5x_parser_test.dart` | Rewritten FBD-AOI test | 7 |
| `mobile/test/import/fb_import_fbd_test.dart` | Mapper units (new file) | 7 |
| `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart` | Composed e2e (new file) | 8 |
| `docs/iec61131/FUNCTION_BLOCKS.md`, `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md`, `docs/import/L5X.md`, `docs/DEFERRED.md` | Feature docs | 9 |
| `knowledge/industry/plc-formats/rockwell-l5x.md`, `knowledge/industry/plc-formats/index.md`, `knowledge/industry/iec61131/custom-function-blocks.md`, `knowledge/industry/iec61131/function-block-diagram.md`, `knowledge/app/scan-engine.md`, `knowledge/canonical-manifest.json` | Knowledge base | 9 |

---

### Task 1: Model - FBD body on `FbDefinition`

**Model:** sonnet · **Effort:** medium

Implements spec §1.

**Files:**
- Modify: `mobile/lib/models/project_model.dart:217-263` (`FbDefinition`)
- Modify: `mobile/lib/models/tag_resolver.dart:117-167` (`renameFbDefinition`)
- Test: `mobile/test/models/fb_model_test.dart` (existing file, append tests)

**Interfaces:**
- Consumes: `FbdBlock`, `FbdWire`, `FbdNetwork` (same file, lines 394-483) and their existing `toJson()` / `fromJson(Map<String, dynamic>)` pairs.
- Produces: `FbDefinition({required String name, List<FbVar>? vars, String stSource = '', List<LdRung>? ladderRungs, List<FbdBlock>? fbdBlocks, List<FbdWire>? fbdWires, List<FbdNetwork>? fbdNetworks})` with non-null fields `List<FbdBlock> fbdBlocks`, `List<FbdWire> fbdWires`, `List<FbdNetwork> fbdNetworks` (each defaults `[]`). JSON keys `'fbd_blocks'`, `'fbd_wires'`, `'fbd_networks'`, each emitted only when non-empty.
- Produces: `void renameFbDefinition(PlcProject p, String oldName, String newName)` (signature unchanged) now also retargets `def.fbdBlocks[].type`.

- [ ] **Step 1: Write the failing tests**

Append to `mobile/test/models/fb_model_test.dart`, inside the existing `void main() {`, after the last test:

```dart
  test('an FBD-bodied FbDefinition round-trips blocks, wires and networks', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'n0', type: 'TAG_INPUT', title: 'In', tagBinding: 'In', x: 10, y: 20),
      FbdBlock(id: 'n1', type: 'TON', title: 'TON', x: 110, y: 20),
      FbdBlock(id: 'n2', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out', x: 210, y: 20, network: 1),
    ], fbdWires: [
      FbdWire(fromBlockId: 'n0', fromPin: 'OUT', toBlockId: 'n1', toPin: 'IN'),
      FbdWire(fromBlockId: 'n1', fromPin: 'Q', toBlockId: 'n2', toPin: 'IN'),
    ], fbdNetworks: [
      FbdNetwork(comment: 'net one'),
      FbdNetwork(comment: 'net two'),
    ]);

    final rt = FbDefinition.fromJson(fb.toJson());
    expect(rt.fbdBlocks.map((b) => b.id), ['n0', 'n1', 'n2']);
    expect(rt.fbdBlocks[0].tagBinding, 'In');
    expect(rt.fbdBlocks[0].x, 10);
    expect(rt.fbdBlocks[2].network, 1);
    expect(rt.fbdWires, hasLength(2));
    expect(rt.fbdWires[1].fromPin, 'Q');
    expect(rt.fbdWires[1].toPin, 'IN');
    expect(rt.fbdNetworks.map((n) => n.comment), ['net one', 'net two']);
    expect(rt.ladderRungs, isEmpty);
    expect(rt.stSource, ''); // FBD-bodied FBs carry no ST source
  });

  test('ST- and ladder-bodied FbDefinitions serialize with NO fbd_* keys', () {
    final st = FbDefinition(name: 'Scaler', stSource: 'Out := In * 2.0;', vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
    ]);
    expect(st.toJson().keys.toList(), ['name', 'vars', 'st_source']);

    final ld = FbDefinition(name: 'Latch', ladderRungs: [
      LdRung(rungIndex: 0, nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [LdWire(fromId: 'L', toId: 'R')]),
    ]);
    final ldJson = ld.toJson();
    expect(ldJson.containsKey('fbd_blocks'), isFalse);
    expect(ldJson.containsKey('fbd_wires'), isFalse);
    expect(ldJson.containsKey('fbd_networks'), isFalse);
    expect(ldJson.keys.toList(), ['name', 'vars', 'st_source', 'ladder_rungs']);
  });

  test('legacy JSON without fbd_* keys loads with an empty FBD body', () {
    final rt = FbDefinition.fromJson({
      'name': 'Old',
      'vars': [
        {'name': 'In', 'data_type': 'BOOL', 'direction': 'input', 'initial_value': null},
      ],
      'st_source': 'Out := In;',
    });
    expect(rt.fbdBlocks, isEmpty);
    expect(rt.fbdWires, isEmpty);
    expect(rt.fbdNetworks, isEmpty);
    expect(rt.stSource, 'Out := In;');
  });

  test('renameFbDefinition retargets call blocks inside an FB FBD body (third root)', () {
    final inner = FbDefinition(name: 'B', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);
    final outer = FbDefinition(name: 'A', vars: [
      FbVar(name: 'Nested', dataType: 'B', direction: FbVarDir.internal),
    ], fbdBlocks: [
      FbdBlock(id: 'a0', type: 'B', title: 'B', tagBinding: 'Nested'),
    ]);
    final p = PlcProject(
        id: 'p', name: 'P', controllerName: 'C',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);

    renameFbDefinition(p, 'B', 'B_1');

    expect(outer.fbdBlocks.single.type, 'B_1');
    expect(outer.fbdBlocks.single.tagBinding, 'Nested'); // the var name is untouched
    expect(outer.vars.single.dataType, 'B_1');
    expect(inner.name, 'B_1');
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`: `/c/flutter/bin/flutter test test/models/fb_model_test.dart`

Expected: FAIL with a compile error, `The named parameter 'fbdBlocks' isn't defined` / `The getter 'fbdBlocks' isn't defined for the class 'FbDefinition'`.

- [ ] **Step 3: Add the fields, constructor params and JSON**

In `mobile/lib/models/project_model.dart`, replace the `FbDefinition` class body (lines 217-263) with:

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
  ///
  /// NOTE: these rungs are a SECOND `LdNode` root in the project graph
  /// (`PlcProgram.rungs` is the first). Any project-wide traversal over ladder
  /// nodes — renames, reference scans, validation — must visit BOTH roots; see
  /// `renameFbDefinition` in `tag_resolver.dart`.
  List<LdRung> ladderRungs;

  /// Native FBD body. Non-empty => this FB is FBD-BODIED: [stSource] is
  /// ignored and these blocks/wires run scoped to the instance (see
  /// `fb_exec.dart` and `fbd_exec.dart`'s `runScopedFbdBody`). Empty (the
  /// default) => unchanged behaviour.
  ///
  /// BODY PRECEDENCE (single source of truth: `executeFbInstance`):
  /// `ladderRungs.isNotEmpty` -> ladder; else `fbdBlocks.isNotEmpty` -> FBD;
  /// else ST.
  ///
  /// NOTE: these blocks are a THIRD `FbdBlock` root in the project graph
  /// (`PlcProgram.fbdBlocks` is the first, `ladderRungs` the second for LD
  /// nodes). Any project-wide traversal — renames, reference scans,
  /// validation — must visit all three; see `renameFbDefinition`.
  ///
  /// [fbdNetworks] carries header/comment metadata only: execution partitions
  /// on `FbdBlock.network` and sorts the distinct indices, so unlike
  /// `PlcProgram` there is no constructor-level `_normalizeFbdNetworks` here
  /// (the import translator appends exactly one network per component, so the
  /// lists are consistent by construction).
  List<FbdBlock> fbdBlocks;
  List<FbdWire> fbdWires;
  List<FbdNetwork> fbdNetworks;

  FbDefinition({
    required this.name,
    List<FbVar>? vars,
    this.stSource = '',
    List<LdRung>? ladderRungs,
    List<FbdBlock>? fbdBlocks,
    List<FbdWire>? fbdWires,
    List<FbdNetwork>? fbdNetworks,
  })  : vars = vars ?? [],
        ladderRungs = ladderRungs ?? [],
        fbdBlocks = fbdBlocks ?? [],
        fbdWires = fbdWires ?? [],
        fbdNetworks = fbdNetworks ?? [];

  factory FbDefinition.fromJson(Map<String, dynamic> json) {
    return FbDefinition(
      name: json['name'] ?? '',
      vars: (json['vars'] as List? ?? []).map((v) => FbVar.fromJson(v)).toList(),
      stSource: json['st_source'] ?? '',
      ladderRungs: (json['ladder_rungs'] as List? ?? [])
          .map((r) => LdRung.fromJson(r))
          .toList(),
      fbdBlocks: (json['fbd_blocks'] as List? ?? [])
          .map((b) => FbdBlock.fromJson(b))
          .toList(),
      fbdWires: (json['fbd_wires'] as List? ?? [])
          .map((w) => FbdWire.fromJson(w))
          .toList(),
      fbdNetworks: (json['fbd_networks'] as List? ?? [])
          .map((n) => FbdNetwork.fromJson(n))
          .toList(),
    );
  }

  // `ladder_rungs` / `fbd_blocks` / `fbd_wires` / `fbd_networks` are emitted
  // ONLY when non-empty so an ST-bodied (or ladder-bodied) FB's JSON is
  // byte-identical to what shipped before each feature (old projects reload
  // unchanged, and diffs of existing projects stay clean). The key names are
  // the SAME ones `PlcProgram` uses, so the element serializers are reused.
  Map<String, dynamic> toJson() => {
    'name': name,
    'vars': vars.map((v) => v.toJson()).toList(),
    'st_source': stSource,
    if (ladderRungs.isNotEmpty)
      'ladder_rungs': ladderRungs.map((r) => r.toJson()).toList(),
    if (fbdBlocks.isNotEmpty)
      'fbd_blocks': fbdBlocks.map((b) => b.toJson()).toList(),
    if (fbdWires.isNotEmpty)
      'fbd_wires': fbdWires.map((w) => w.toJson()).toList(),
    if (fbdNetworks.isNotEmpty)
      'fbd_networks': fbdNetworks.map((n) => n.toJson()).toList(),
  };
}
```

- [ ] **Step 4: Teach `renameFbDefinition` about the third root**

In `mobile/lib/models/tag_resolver.dart`, inside `renameFbDefinition`'s `for (final def in p.fbDefinitions)` loop (lines 148-161), add the `fbdBlocks` loop immediately after the `def.ladderRungs` loop and before the `def.vars` loop:

```dart
    for (final b in def.fbdBlocks) {
      // THIRD FbdBlock root (PlcProgram.fbdBlocks is the first): a custom-FB
      // call block inside an FB's own FBD body. A missed rename would leave
      // `fbDefinitionFor` unable to resolve the callee, silently turning a
      // nested AOI call into an unknown (never-executed) block type.
      if (b.type == oldName) {
        b.type = newName;
      }
    }
```

Also update the comment directly above that loop (lines 143-147) so it names all three roots:

```dart
  // FB bodies hold a SECOND LdNode root and a THIRD FbdBlock root (programs
  // are the first for both). A missed ladder-body call node would stop
  // matching an FB definition and fall through executeRung's unconditional
  // TON/TOF fallback, silently turning a renamed-away nested AOI call into a
  // timer; a missed FBD-body call block would stop resolving entirely. A
  // missed FbVar.dataType would leave the nested instance member typed as a
  // now-nonexistent composite.
```

And update the function's PUBLIC doc-comment (`mobile/lib/models/tag_resolver.dart:103-116`), whose root enumeration currently stops at the ladder body. Replace its first sentence with:

```dart
/// Renames function block definition [oldName] to [newName] everywhere it is
/// referenced: the FB's own name, every FBD block of that type
/// (`FbdBlock.type`) in a PROGRAM and in another FB's FBD body
/// (`FbDefinition.fbdBlocks` — the third `FbdBlock` root), every LD block
/// instance of that type (`LdNode.blockType`) in a PROGRAM's rungs AND in
/// another FB's ladder body (`FbDefinition.ladderRungs` — the second `LdNode`
/// root), every instance tag's data type (`PlcTag.dataType`), and every
/// FB-typed FB var (`FbVar.dataType`, i.e. a nested instance member) —
/// mirroring [renameStructDef]'s exact traversal/immutability idiom (in-place
/// field mutation, not copyWith, so autosave/serialization sees the same object
/// graph). No-op if the names are equal or no such FB definition exists.
```

- [ ] **Step 5: Run the tests to verify they pass**

From `mobile/`: `/c/flutter/bin/flutter test test/models/fb_model_test.dart`

Expected: all tests pass (`All tests passed!`).

- [ ] **Step 6: Verify the whole suite and the analyzer**

From `mobile/`:
- `/c/flutter/bin/flutter test` -> expect `All tests passed!` (in particular `test/serialization_roundtrip_test.dart` and `test/project_repository_test.dart` stay green: no existing JSON changed).
- `/c/flutter/bin/flutter analyze` -> expect `No issues found!`.

- [ ] **Step 7: Commit**

```
git add -A && git commit -m "feat(fb): FBD body fields on FbDefinition + rename third root"
```

---

### Task 2: Scoped FBD executor (`_runFbdBody` + `runScopedFbdBody`)

**Model:** opus · **Effort:** high

Implements spec §2. This is the runtime-correctness core: one shared body runner, three scoped tag-path sites, and a per-instance state key. `executeFbdPrograms` must stay byte-identical for programs.

**Files:**
- Modify: `mobile/lib/models/fbd_exec.dart` (`_evalBlock` signature + 3 sites; `executeFbdPrograms` -> `_runFbdBody` extraction; new `runScopedFbdBody`)
- Test: `mobile/test/models/fb_fbd_body_exec_test.dart` (new file)

**Interfaces:**
- Consumes: `LdScope(String instancePath, Set<String> localVars)` with `String rewrite(String path)` from `models/ld_exec.dart` (already imported by `fbd_exec.dart`), `LdExecRuntime` (same file), `FbdMonitor` (`models/fbd_monitor.dart`), `fbdInputPinsFor`/`fbdOutputPinsFor` (`models/fbd_pins.dart`).
- Produces (private): `void _runFbdBody(PlcProject p, List<FbdBlock> blocks, List<FbdWire> wires, int dtMs, FbdRuntime rt, {Set<String>? readOnly, LdExecRuntime? ldRt, FbdMonitor? monitor, String monitorProgName = '', LdScope? scope, String stateKeyPrefix = ''})`.
- Produces (public): `void runScopedFbdBody(PlcProject p, List<FbdBlock> blocks, List<FbdWire> wires, LdScope scope, int dtMs, FbdRuntime rt, {Set<String>? readOnly, LdExecRuntime? ldRt})`.
- Produces (private, changed): `Map<String, dynamic> _evalBlock(PlcProject p, FbdBlock b, List<dynamic> inputs, int dtMs, FbdRuntime rt, Set<String>? readOnly, LdExecRuntime? ldRt, String stateKey, LdScope? scope)`.
- Unchanged: `void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt, {Set<String>? only, Set<String>? readOnly, FbdMonitor? monitor, LdExecRuntime? ldRt})`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/models/fb_fbd_body_exec_test.dart`:

```dart
// Scoped FBD executor units: an FB's FBD body runs against ONE instance's
// struct (LdScope rewriting) with per-instance stateful-block state
// ('fb:<instancePath>|<blockId>' keys). Never touches same-named globals.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

/// FB interface used by every fixture below: In (BOOL in), Out (BOOL out).
FbDefinition _rampFb() => FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ]);

/// TAG_INPUT('In') -> TON(PT = CONST 1000) -> TAG_OUTPUT('Out').
List<FbdBlock> _tonBlocks() => [
      FbdBlock(id: 'b_in', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'b_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'b_ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'b_out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ];

List<FbdWire> _tonWires() => [
      FbdWire(fromBlockId: 'b_in', fromPin: 'OUT', toBlockId: 'b_ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'b_pt', fromPin: 'OUT', toBlockId: 'b_ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'b_ton', fromPin: 'Q', toBlockId: 'b_out', toPin: 'IN'),
    ];

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

/// Project with FB `Ramp`, instance tags [instances], and same-named GLOBAL
/// `In`/`Out` BOOLs that a correctly-scoped body must never touch.
PlcProject _proj(FbDefinition fb, List<String> instances) {
  final defaults = PlcProject(
      id: 'd', name: 'd', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
      fbDefinitions: [fb]);
  return PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [
      _tag('In', 'BOOL', false),
      _tag('Out', 'BOOL', false),
      for (final i in instances)
        _tag(i, fb.name, defaultValueFor(defaults, fb.name, 0)),
    ],
    structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: [fb],
  );
}

void main() {
  test('TAG_INPUT/TAG_OUTPUT bind to <instance>.<var>, never same-named globals', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    final scope = LdScope('R1', {'In', 'Out'});
    writePath(p, 'R1.In', true);

    final rt = FbdRuntime();
    runScopedFbdBody(p, _tonBlocks(), _tonWires(), scope, 500, rt);
    expect(readPath(p, 'R1.Out'), isFalse); // ET 500 < PT 1000
    runScopedFbdBody(p, _tonBlocks(), _tonWires(), scope, 500, rt);
    expect(readPath(p, 'R1.Out'), isTrue); // ET 1000 >= PT 1000

    // The same-named globals were never read (global In stayed false yet the
    // instance timed) and never written.
    expect(readPath(p, 'In'), isFalse);
    expect(readPath(p, 'Out'), isFalse);
  });

  test('a non-var binding still resolves to the global', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    p.tags.add(_tag('Global_Out', 'BOOL', false));
    final blocks = _tonBlocks()
      ..removeWhere((b) => b.id == 'b_out')
      ..add(FbdBlock(
          id: 'b_out', type: 'TAG_OUTPUT', title: 'G', tagBinding: 'Global_Out'));
    writePath(p, 'R1.In', true);

    final rt = FbdRuntime();
    runScopedFbdBody(p, blocks, _tonWires(), LdScope('R1', {'In', 'Out'}), 2000, rt);
    expect(readPath(p, 'Global_Out'), isTrue); // not a var name -> global
  });

  test('CONST is NOT rewritten by the scope', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    writePath(p, 'R1.In', true);
    // Deliberately hostile scope: '1000' is listed as a local var name. If the
    // CONST branch rewrote its tagBinding it would become 'R1.1000', parse to
    // null, and the TON would see PT = 0 (Q true on the FIRST scan).
    final scope = LdScope('R1', {'In', 'Out', '1000'});
    runScopedFbdBody(p, _tonBlocks(), _tonWires(), scope, 500, FbdRuntime());
    expect(readPath(p, 'R1.Out'), isFalse);
  });

  test('two instances keep independent stateful-block state', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1', 'R2']);
    final rt = FbdRuntime();
    final blocks = _tonBlocks();
    final wires = _tonWires();
    writePath(p, 'R1.In', true);
    writePath(p, 'R2.In', true);

    // R1 gets two scans, R2 only one: same block ids, disjoint state keys.
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 500, rt);
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 500, rt);
    runScopedFbdBody(p, blocks, wires, LdScope('R2', {'In', 'Out'}), 500, rt);

    expect(readPath(p, 'R1.Out'), isTrue);
    expect(readPath(p, 'R2.Out'), isFalse);
  });

  test('R_TRIG state is per instance too', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1', 'R2']);
    final blocks = [
      FbdBlock(id: 'e_in', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'e_trig', type: 'R_TRIG', title: 'R_TRIG'),
      FbdBlock(id: 'e_out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ];
    final wires = [
      FbdWire(fromBlockId: 'e_in', fromPin: 'OUT', toBlockId: 'e_trig', toPin: 'CLK'),
      FbdWire(fromBlockId: 'e_trig', fromPin: 'Q', toBlockId: 'e_out', toPin: 'IN'),
    ];
    final rt = FbdRuntime();
    writePath(p, 'R1.In', true);
    writePath(p, 'R2.In', true);

    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R1.Out'), isTrue); // first rising edge for R1
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R1.Out'), isFalse); // no second edge for R1
    runScopedFbdBody(p, blocks, wires, LdScope('R2', {'In', 'Out'}), 100, rt);
    expect(readPath(p, 'R2.Out'), isTrue); // R2's own first edge
  });

  test('readOnly gates a global body output but never an instance member', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    p.tags.add(_tag('Gen', 'BOOL', false));
    final blocks = [
      FbdBlock(id: 'c1', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
      FbdBlock(id: 'o_inst', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
      FbdBlock(id: 'o_glob', type: 'TAG_OUTPUT', title: 'Gen', tagBinding: 'Gen'),
    ];
    final wires = [
      FbdWire(fromBlockId: 'c1', fromPin: 'OUT', toBlockId: 'o_inst', toPin: 'IN'),
      FbdWire(fromBlockId: 'c1', fromPin: 'OUT', toBlockId: 'o_glob', toPin: 'IN'),
    ];

    // 'Out' names a var, so the gate must be evaluated on the REWRITTEN path
    // ('R1.Out'), which no readOnly entry names.
    runScopedFbdBody(p, blocks, wires, LdScope('R1', {'In', 'Out'}), 100,
        FbdRuntime(), readOnly: {'Gen', 'Out'});

    expect(readPath(p, 'R1.Out'), isTrue);
    expect(readPath(p, 'Gen'), isFalse); // read-only global untouched
  });

  test('an empty body is a no-op and never throws', () {
    final fb = _rampFb();
    final p = _proj(fb, ['R1']);
    runScopedFbdBody(p, const [], const [], LdScope('R1', {'In', 'Out'}), 100,
        FbdRuntime());
    expect(readPath(p, 'R1.Out'), isFalse);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`: `/c/flutter/bin/flutter test test/models/fb_fbd_body_exec_test.dart`

Expected: FAIL with `The function 'runScopedFbdBody' isn't defined`.

- [ ] **Step 3: Update `FbdRuntime`'s class doc-comment**

`FbdRuntime`'s doc (`mobile/lib/models/fbd_exec.dart:8-10`) currently says its maps are keyed by block id alone, which stops being the whole truth in this task. Replace it with:

```dart
/// Per-block state for stateful FBD blocks (TON/TOF, PID, counters, edge
/// detectors, TP). Keyed by `'<stateKeyPrefix><blockId>'`: program execution
/// uses an EMPTY prefix, so the key is the bare block id (unique within a
/// project's FBD programs, unchanged); a scoped FB body uses
/// `'fb:<instancePath>|'`, so two instances of the same FBD-bodied FB never
/// share timer/counter/edge state even though they share one set of body block
/// ids (see `runScopedFbdBody`). Cleared on project switch.
```

The per-field comments below it ("keyed by block id") should say "keyed by state key" for the same reason.

- [ ] **Step 4: Give `_evalBlock` a state key and a scope**

In `mobile/lib/models/fbd_exec.dart`, change the `_evalBlock` doc-comment tail and signature (lines 159-179) to:

```dart
/// [ldRt] flows through to the custom-FB branch (`executeFbInstance`), so a
/// ladder-bodied FB instance's timers/counters/edges share the caller's
/// runtime instead of an ephemeral per-call one.
/// [stateKey] is the key under which this block's stateful data lives in [rt]
/// (`_elapsedMs`/`_pid`/`_counters`/`_prevClk`/`_pulse`). Program execution
/// passes the bare `b.id` (unchanged); a scoped FB body passes
/// `'fb:<instancePath>|<blockId>'`, which is disjoint by construction because
/// sanitized tag/instance names can contain neither ':' nor '|'.
/// [scope] rewrites the THREE tag paths a block can reach (TAG_INPUT read,
/// TAG_OUTPUT write + its readOnly gate, custom-FB instance path) into the
/// instance's namespace. `scope == null` (program execution) is the identity.
/// A CONST's `tagBinding` is a LITERAL, not a path, and is never rewritten.
/// Never throws.
Map<String, dynamic> _evalBlock(
  PlcProject p,
  FbdBlock b,
  List<dynamic> inputs,
  int dtMs,
  FbdRuntime rt,
  Set<String>? readOnly,
  LdExecRuntime? ldRt,
  String stateKey,
  LdScope? scope,
) {
  String sp(String path) => scope == null ? path : scope.rewrite(path);
```

- [ ] **Step 5: Apply the scope at the three tag-path sites**

Still in `_evalBlock`:

1. Custom-FB branch (line ~206) - rewrite the instance path:

```dart
    return executeFbInstance(p, fb, sp(b.tagBinding), inputMap,
        dtMs: dtMs, ldRt: ldRt, readOnly: readOnly);
```

2. `TAG_INPUT` (line ~211):

```dart
    case 'TAG_INPUT':
      return {'OUT': b.tagBinding.isEmpty ? null : readPath(p, sp(b.tagBinding))};
```

3. `TAG_OUTPUT` (lines ~479-489) - gate and write on the REWRITTEN path:

```dart
    case 'TAG_OUTPUT':
      if (inputs.isEmpty) {
        return {};
      }
      final v = inputs.first;
      if (v != null && b.tagBinding.isNotEmpty) {
        // The readOnly gate is applied to the REWRITTEN path, so an instance
        // member ('Inst.Out') is never gated while a global coil target still
        // is — the same semantics the ladder scoped executor uses.
        final target = sp(b.tagBinding);
        if (readOnly == null || !readOnly.contains(target)) {
          _forceAwareWrite(p, target, v);
        }
      }
      return {};
```

- [ ] **Step 6: Replace every `rt._xxx[b.id]` with `rt._xxx[stateKey]`**

Still in `_evalBlock`, the stateful branches. There are exactly nine lookups to change:

| Line (pre-edit) | Branch | Change |
|---|---|---|
| ~292 | `TON`/`TOF` | `num et = rt._elapsedMs[stateKey] ?? 0;` |
| ~318 | `TON`/`TOF` | `rt._elapsedMs[stateKey] = et;` |
| ~332 | `PID` | `final state = rt._pid[stateKey] ?? [0.0, 0.0];` |
| ~351 | `PID` | `rt._pid[stateKey] = [integ, e];` |
| ~361, ~370 | `CTU` | `rt._counters[stateKey] ?? [0, 0, 0]` / `rt._counters[stateKey] = [cv, cu ? 1 : 0, state[2]];` |
| ~381, ~393 | `CTD` | `rt._counters[stateKey] ?? [0, 0, 0]` / `rt._counters[stateKey] = [cv, state[1], cd ? 1 : 0];` |
| ~406, ~427 | `CTUD` | `rt._counters[stateKey] ?? [0, 0, 0]` / `rt._counters[stateKey] = [cv, cu ? 1 : 0, cd ? 1 : 0];` |
| ~435, ~437 | `R_TRIG` | `rt._prevClk[stateKey] ?? false` / `rt._prevClk[stateKey] = clk;` |
| ~444, ~446 | `F_TRIG` | `rt._prevClk[stateKey] ?? false` / `rt._prevClk[stateKey] = clk;` |
| ~454, ~475 | `TP` | `rt._pulse[stateKey] ?? [0, 0, 0]` / `rt._pulse[stateKey] = [et, running, inVal ? 1 : 0];` |

Verify none are missed:

```
cd mobile && grep -n "rt\._\(elapsedMs\|pid\|counters\|prevClk\|pulse\)\[b\.id\]" lib/models/fbd_exec.dart
```

Expected: no output.

- [ ] **Step 7: Extract `_runFbdBody` and rewrite `executeFbdPrograms`**

In `mobile/lib/models/fbd_exec.dart`, replace the whole `executeFbdPrograms` function (lines 521-665, doc-comment included) with:

```dart
/// Executes ONE FBD body (a program's or an FB instance's): partitions
/// [blocks] by `network` and evaluates the networks in ascending index order
/// (IEC 61131-3 network-ordered execution), running the same dependency
/// (topological) worklist scoped to each network's blocks in turn — a block
/// after all blocks feeding any of its input pins — producing a
/// `Map<String,dynamic>` of output-pin values per block. An input pin's value
/// is resolved from the wire targeting `(block, pin)`, read from the source
/// block's named output in the cache. Arithmetic/comparator operand order
/// follows the registry's pin order (`IN1`, `IN2`, ... / `MN`, `IN`, `MX`), not
/// wire-insertion order. TON/TOF are executed statefully (per-block state in
/// [rt], keyed by `'$stateKeyPrefix<blockId>'`). TAG_OUTPUT writes its `IN`
/// force-aware, immediately, so a later network in the same body reads the
/// updated tag via its own TAG_INPUT (this is how data flows across networks —
/// wires never cross a network boundary). Cycles terminate deterministically
/// without hanging. Never throws. When [monitor] is supplied, every evaluated
/// block's output-pin values are recorded into it, keyed by
/// `monitor.keyFor(monitorProgName, block.id, pin)`.
///
/// [scope] + [stateKeyPrefix] are what make this reusable for an FB body:
/// with both at their defaults (`null` / `''`) behaviour is byte-identical to
/// the pre-extraction program path.
void _runFbdBody(
  PlcProject p,
  List<FbdBlock> blocks,
  List<FbdWire> wires,
  int dtMs,
  FbdRuntime rt, {
  Set<String>? readOnly,
  LdExecRuntime? ldRt,
  FbdMonitor? monitor,
  String monitorProgName = '',
  LdScope? scope,
  String stateKeyPrefix = '',
}) {
  if (blocks.isEmpty) {
    return;
  }
  final byId = <String, FbdBlock>{};
  for (final b in blocks) {
    byId[b.id] = b;
  }

  // Networks execute in ascending index order. Wires are intra-network
  // (a block's deps are always in its own network), so scoping is just
  // filtering `blocks` by network — the worklist below is otherwise
  // identical to the pre-network-aware single-pass version. A one-network
  // body (all blocks `network == 0`) runs exactly one pass.
  final netIndices = blocks.map((b) => b.network).toSet().toList()..sort();
  for (final net in netIndices) {
    final netBlocks = blocks.where((b) => b.network == net).toList();
    final netIds = netBlocks.map((b) => b.id).toSet();

    // For each block, the ordered list of (fromBlockId, fromPin) feeding
    // each of its input pins in registry order (null entry = unconnected
    // input).
    final inputWireFor = <String, List<FbdWire?>>{};
    for (final b in netBlocks) {
      final pins = fbdInputPinsFor(p, b);
      inputWireFor[b.id] = List<FbdWire?>.filled(pins.length, null);
    }
    for (final w in wires) {
      if (!netIds.contains(w.toBlockId) || !netIds.contains(w.fromBlockId)) {
        continue;
      }
      final toBlock = byId[w.toBlockId];
      final fromBlock = byId[w.fromBlockId];
      if (toBlock == null || fromBlock == null) {
        continue;
      }
      final toPin = _resolvedToPin(p, w, toBlock);
      if (toPin.isEmpty) {
        continue;
      }
      final pins = fbdInputPinsFor(p, toBlock);
      final idx = pins.indexOf(toPin);
      if (idx < 0) {
        continue;
      }
      inputWireFor[toBlock.id]![idx] = w;
    }

    // Dependency ids (source block ids) per block, for the topological pass.
    final depsOf = <String, List<String>>{};
    for (final b in netBlocks) {
      depsOf[b.id] = [
        for (final w in inputWireFor[b.id]!)
          if (w != null) w.fromBlockId,
      ];
    }

    final cache = <String, Map<String, dynamic>>{};
    final done = <String>{};

    dynamic resolveInput(FbdWire? w) {
      if (w == null) {
        return null;
      }
      final fromBlock = byId[w.fromBlockId];
      final fromPin = _resolvedFromPin(p, w, fromBlock);
      final outMap = cache[w.fromBlockId];
      if (outMap == null || fromPin.isEmpty) {
        return null;
      }
      return outMap[fromPin];
    }

    List<dynamic> orderedInputs(FbdBlock b) =>
        inputWireFor[b.id]!.map(resolveInput).toList();

    void recordMonitor(FbdBlock b) {
      if (monitor == null) {
        return;
      }
      final out = cache[b.id];
      if (out == null) {
        return;
      }
      out.forEach((pin, val) =>
          monitor.pinValue[monitor.keyFor(monitorProgName, b.id, pin)] = val);
    }

    Map<String, dynamic> evaluate(FbdBlock b) => _evalBlock(p, b,
        orderedInputs(b), dtMs, rt, readOnly, ldRt, '$stateKeyPrefix${b.id}',
        scope);

    // Evaluate blocks whose dependencies are all resolved; repeat until
    // stable (topological worklist).
    bool progressed = true;
    while (progressed) {
      progressed = false;
      for (final b in netBlocks) {
        if (done.contains(b.id)) {
          continue;
        }
        final deps = depsOf[b.id]!;
        if (!deps.every(done.contains)) {
          continue;
        }
        cache[b.id] = evaluate(b);
        recordMonitor(b);
        done.add(b.id);
        progressed = true;
      }
    }
    // Any block left unresolved is in a cycle: evaluate once with whatever
    // is cached so the scan always terminates.
    for (final b in netBlocks) {
      if (done.contains(b.id)) {
        continue;
      }
      cache[b.id] = evaluate(b);
      recordMonitor(b);
      done.add(b.id);
    }
  }
}

/// Executes every FunctionBlockDiagram program in [p] (see [_runFbdBody] for
/// the per-body semantics). Unscoped, empty state-key prefix: network
/// partitioning, the topological worklist, the cycle fallback, monitor keys
/// and runtime keys are byte-identical to before the scoped-body extraction.
void executeFbdPrograms(PlcProject p, int dtMs, FbdRuntime rt, {Set<String>? only, Set<String>? readOnly, FbdMonitor? monitor, LdExecRuntime? ldRt}) {
  for (final prog in p.programs) {
    if (prog.language != 'FunctionBlockDiagram' || prog.fbdBlocks.isEmpty) {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    _runFbdBody(p, prog.fbdBlocks, prog.fbdWires, dtMs, rt,
        readOnly: readOnly, ldRt: ldRt, monitor: monitor,
        monitorProgName: prog.name);
  }
}

/// Executes one FBD FB body scoped to a single instance: every tag path goes
/// through [scope] (bare references to the FB's own vars resolve against
/// `<instancePath>.<var>`, everything else falls through global) and every
/// stateful block's runtime state is keyed `'fb:<instancePath>|<blockId>'`, so
/// two instances of the same FBD-bodied FB have disjoint timer/counter/edge
/// state even though they share one set of body block ids. That prefix is also
/// disjoint from every program block id: a block id is `'<pouName>_n<localId>'`
/// (or an editor-assigned id) and can never contain ':' or '|', so no
/// prefixed key can collide with a program's. (Note the id is NOT a sanitized
/// identifier — an AOI body's pouName is e.g. `'AOI Ramp'`, with a space —
/// the argument rests only on ':' and '|' never occurring.)
/// Online monitoring is deliberately not wired up for FB bodies
/// (`monitor: null`) — see docs/DEFERRED.md. The FBD analog of
/// `runScopedLdBody` (ld_exec.dart). Never throws.
void runScopedFbdBody(PlcProject p, List<FbdBlock> blocks, List<FbdWire> wires,
    LdScope scope, int dtMs, FbdRuntime rt,
    {Set<String>? readOnly, LdExecRuntime? ldRt}) {
  _runFbdBody(p, blocks, wires, dtMs, rt,
      readOnly: readOnly,
      ldRt: ldRt,
      monitor: null,
      scope: scope,
      stateKeyPrefix: 'fb:${scope.instancePath}|');
}
```

- [ ] **Step 8: Run the new tests**

From `mobile/`: `/c/flutter/bin/flutter test test/models/fb_fbd_body_exec_test.dart`

Expected: all 7 tests pass.

- [ ] **Step 9: Prove the program path is unchanged**

From `mobile/`:

```
/c/flutter/bin/flutter test test/fbd_exec_test.dart test/fbd_networks_exec_test.dart test/fbd_exec_integration_test.dart test/fb_fbd_exec_test.dart test/fbd_editor_online_test.dart test/scan_ld_monitor_test.dart
```

Expected: `All tests passed!` (these cover network ordering, the cycle fallback, monitor keys and custom-FB calls from FBD).

- [ ] **Step 10: Verify the whole suite and the analyzer**

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze`.
Expected: `All tests passed!` and `No issues found!`.

- [ ] **Step 11: Commit**

```
git add -A && git commit -m "feat(fbd): scoped FBD body executor (runScopedFbdBody)"
```

---

### Task 3: Dispatch + runtime plumbing

**Model:** opus · **Effort:** high

Implements spec §3. Three-way body dispatch in `executeFbInstance`, the shared `_reassertEnableIn` helper, and `FbdRuntime` threading in both directions so an FBD-bodied FB called from ladder (and a ladder-bodied FB called from FBD) keeps its state across scans.

**Files:**
- Modify: `mobile/lib/models/fb_exec.dart` (imports, `_reassertEnableIn`, `fbdRt` param, three-way branch)
- Modify: `mobile/lib/models/ld_exec.dart` (`executeLdPrograms`, `executeRung`, `runScopedLdBody` gain `FbdRuntime? fbdRt`)
- Modify: `mobile/lib/models/fbd_exec.dart` (custom-FB branch passes `fbdRt: rt`)
- Modify: `mobile/lib/screens/scan_tick.dart` (passes `rt.fbd` into the LD engine)
- Test: `mobile/test/models/fb_exec_test.dart` (append), `mobile/test/fb_fbd_exec_test.dart` (append), `mobile/test/fb_ld_exec_test.dart` (append)

**Interfaces:**
- Consumes: `runScopedFbdBody(PlcProject, List<FbdBlock>, List<FbdWire>, LdScope, int, FbdRuntime, {Set<String>? readOnly, LdExecRuntime? ldRt})` and `FbdRuntime` (Task 2).
- Produces: `Map<String, dynamic> executeFbInstance(PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs, {int dtMs = 0, LdExecRuntime? ldRt, FbdRuntime? fbdRt, Set<String>? readOnly})` - `fbdRt` is NEW and defaulted, so every existing caller compiles unchanged.
- Produces: `void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt, {Set<String>? only, Set<String>? readOnly, LdMonitor? monitor, FbdRuntime? fbdRt})`.
- Produces: `void executeRung(PlcProject p, String progName, LdRung rung, int dtMs, LdExecRuntime rt, void Function(String, dynamic) write, {LdMonitor? monitor, LdScope? scope, Set<String>? readOnly, FbdRuntime? fbdRt})`.
- Produces: `void runScopedLdBody(PlcProject p, List<LdRung> rungs, LdScope scope, int dtMs, LdExecRuntime rt, {Set<String>? readOnly, FbdRuntime? fbdRt})`.

- [ ] **Step 1: Write the failing dispatch tests**

Append to `mobile/test/models/fb_exec_test.dart`, inside `void main() {`, after the last test. Add `import 'package:soft_plc_mobile/models/fbd_exec.dart';` and `import 'package:soft_plc_mobile/models/ld_graph.dart';` to the file's imports if absent:

```dart
  // ---- three-way body precedence + FBD dispatch (L5X FBD import) ----

  PlcProject projFor(List<FbDefinition> fbs, List<String> instances,
      {List<PlcTag> extra = const []}) {
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: fbs);
    return PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        ...extra,
        for (final i in instances)
          PlcTag(name: i, path: i, dataType: fbs.first.name,
              value: defaultValueFor(defaults, fbs.first.name, 0),
              ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [], fbDefinitions: fbs,
    );
  }

  test('body precedence: ladder wins over FBD, FBD wins over ST', () {
    final both = FbDefinition(
      name: 'Both',
      stSource: 'StMark := TRUE;',
      vars: [
        FbVar(name: 'LdMark', dataType: 'BOOL', direction: FbVarDir.output),
        FbVar(name: 'FbdMark', dataType: 'BOOL', direction: FbVarDir.output),
        FbVar(name: 'StMark', dataType: 'BOOL', direction: FbVarDir.output),
      ],
      ladderRungs: [
        LdRung(rungIndex: 0, nodes: [
          LdNode(id: 'L', kind: LdKind.leftRail),
          LdNode(id: 'c', kind: LdKind.coil, variable: 'LdMark'),
          LdNode(id: 'R', kind: LdKind.rightRail),
        ], wires: [
          LdWire(fromId: 'L', toId: 'c'),
          LdWire(fromId: 'c', toId: 'R'),
        ]),
      ],
      fbdBlocks: [
        FbdBlock(id: 'k', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
        FbdBlock(id: 'o', type: 'TAG_OUTPUT', title: 'FbdMark', tagBinding: 'FbdMark'),
      ],
      fbdWires: [
        FbdWire(fromBlockId: 'k', fromPin: 'OUT', toBlockId: 'o', toPin: 'IN'),
      ],
    );
    final p = projFor([both], ['A1']);
    executeFbInstance(p, both, 'A1', {}, dtMs: 100, fbdRt: FbdRuntime());
    expect(readPath(p, 'A1.LdMark'), isTrue);
    expect(readPath(p, 'A1.FbdMark'), isFalse); // ladder wins
    expect(readPath(p, 'A1.StMark'), isFalse);

    // Same definition minus the ladder body: now FBD wins over ST.
    both.ladderRungs.clear();
    final p2 = projFor([both], ['A2']);
    executeFbInstance(p2, both, 'A2', {}, dtMs: 100, fbdRt: FbdRuntime());
    expect(readPath(p2, 'A2.FbdMark'), isTrue);
    expect(readPath(p2, 'A2.StMark'), isFalse);
  });

  test('EnableIn is re-asserted true before every FBD-body call', () {
    final fb = FbDefinition(name: 'Gated', vars: [
      FbVar(name: 'EnableIn', dataType: 'BOOL', direction: FbVarDir.internal,
          initialValue: true),
      FbVar(name: 'Seen', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      // Read EnableIn -> Seen, then deliberately clear EnableIn (the FBD
      // analog of an OTU(EnableIn) rung). List order fixes the evaluation
      // order: the read is resolved before the clear is written.
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'EnableIn', tagBinding: 'EnableIn'),
      FbdBlock(id: 'seen', type: 'TAG_OUTPUT', title: 'Seen', tagBinding: 'Seen'),
      FbdBlock(id: 'kf', type: 'CONST', title: 'CONST', tagBinding: 'FALSE'),
      FbdBlock(id: 'clr', type: 'TAG_OUTPUT', title: 'EnableIn', tagBinding: 'EnableIn'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'seen', toPin: 'IN'),
      FbdWire(fromBlockId: 'kf', fromPin: 'OUT', toBlockId: 'clr', toPin: 'IN'),
    ]);
    final p = projFor([fb], ['G1']);
    final rt = FbdRuntime();

    executeFbInstance(p, fb, 'G1', {}, dtMs: 100, fbdRt: rt);
    expect(readPath(p, 'G1.Seen'), isTrue);
    expect(readPath(p, 'G1.EnableIn'), isFalse); // body cleared it

    executeFbInstance(p, fb, 'G1', {}, dtMs: 100, fbdRt: rt);
    expect(readPath(p, 'G1.Seen'), isTrue); // re-asserted, not self-disabled
  });

  test('no fbdRt degrades ONLY stateful blocks (ephemeral fallback)', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Alive', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
      FbdBlock(id: 'kt', type: 'CONST', title: 'CONST', tagBinding: 'TRUE'),
      FbdBlock(id: 'al', type: 'TAG_OUTPUT', title: 'Alive', tagBinding: 'Alive'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'pt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'to', toPin: 'IN'),
      FbdWire(fromBlockId: 'kt', fromPin: 'OUT', toBlockId: 'al', toPin: 'IN'),
    ]);
    final p = projFor([fb], ['R1']);

    for (var i = 0; i < 4; i++) {
      executeFbInstance(p, fb, 'R1', {'In': true}, dtMs: 500);
    }
    expect(readPath(p, 'R1.Alive'), isTrue); // combinational still correct
    expect(readPath(p, 'R1.Out'), isFalse); // timer state lost every call
  });

  test('nested FBD AOI keeps per-instancePath state (Outer.Inner)', () {
    final inner = FbDefinition(name: 'Inner', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'i_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'i_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'i_ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'i_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'i_ti', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'i_pt', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'i_ton', fromPin: 'Q', toBlockId: 'i_to', toPin: 'IN'),
    ]);
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Nested', dataType: 'Inner', direction: FbVarDir.internal),
    ], fbdBlocks: [
      FbdBlock(id: 'o_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'o_fb', type: 'Inner', title: 'Inner', tagBinding: 'Nested'),
      FbdBlock(id: 'o_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'o_ti', fromPin: 'OUT', toBlockId: 'o_fb', toPin: 'In'),
      FbdWire(fromBlockId: 'o_fb', fromPin: 'Out', toBlockId: 'o_to', toPin: 'IN'),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        for (final i in ['O1', 'O2'])
          PlcTag(name: i, path: i, dataType: 'Outer',
              value: defaultValueFor(defaults, 'Outer', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
      fbDefinitions: [inner, outer],
    );
    final rt = FbdRuntime();

    // O1 runs twice (ET 1000 >= PT), O2 once.
    executeFbInstance(p, outer, 'O1', {'In': true}, dtMs: 500, fbdRt: rt);
    executeFbInstance(p, outer, 'O1', {'In': true}, dtMs: 500, fbdRt: rt);
    executeFbInstance(p, outer, 'O2', {'In': true}, dtMs: 500, fbdRt: rt);

    expect(readPath(p, 'O1.Nested.Out'), isTrue);
    expect(readPath(p, 'O1.Out'), isTrue);
    expect(readPath(p, 'O2.Nested.Out'), isFalse);
    expect(readPath(p, 'O2.Out'), isFalse);
  });
```

- [ ] **Step 2: Write the failing threading tests**

Append to `mobile/test/fb_ld_exec_test.dart`, inside `void main() {`. Add `import 'package:soft_plc_mobile/models/fbd_exec.dart';` if absent:

```dart
  test('an FBD-bodied FB called from a LADDER program keeps state across scans', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'pt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'to', toPin: 'IN'),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [fb]);

    LdRung callRung(int i, String inst, String src, String dst) =>
        LdRung(rungIndex: i, nodes: [
          LdNode(id: 'L$i', kind: LdKind.leftRail),
          LdNode(id: 'b$i', kind: LdKind.block, blockType: 'Ramp', variable: inst,
              pinBindings: {'In': src, 'Out': dst}),
          LdNode(id: 'R$i', kind: LdKind.rightRail),
        ], wires: [
          LdWire(fromId: 'L$i', toId: 'b$i'),
          LdWire(fromId: 'b$i', toId: 'R$i'),
        ]);

    final prog = PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [
      callRung(0, 'R1', 'Src1', 'Dst1'),
      callRung(1, 'R2', 'Src2', 'Dst2'),
    ]);
    PlcTag t(String n, dynamic v) =>
        PlcTag(name: n, path: n, dataType: 'BOOL', value: v, ioType: 'Internal');
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        t('Src1', true), t('Src2', false), t('Dst1', false), t('Dst2', false),
        for (final i in ['R1', 'R2'])
          PlcTag(name: i, path: i, dataType: 'Ramp',
              value: defaultValueFor(defaults, 'Ramp', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    final ldRt = LdExecRuntime();
    final fbdRt = FbdRuntime();
    executeLdPrograms(p, 500, ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'Dst1'), isFalse); // ET 500 < PT 1000
    executeLdPrograms(p, 500, ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'Dst1'), isTrue); // state survived the scan boundary
    expect(readPath(p, 'Dst2'), isFalse); // instance 2 never driven

    // Now drive instance 2: it starts its own timer from zero.
    writePath(p, 'Src2', true);
    executeLdPrograms(p, 500, ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'Dst2'), isFalse);
    executeLdPrograms(p, 500, ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'Dst2'), isTrue);
  });
```

Append to `mobile/test/fb_fbd_exec_test.dart`, inside `void main() {` (it already has the `_tag` helper):

```dart
  test('an FBD-bodied FB called from an FBD program keeps state across scans', () {
    final fb = FbDefinition(name: 'Ramp', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'ti', fromPin: 'OUT', toBlockId: 'ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'pt', fromPin: 'OUT', toBlockId: 'ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'ton', fromPin: 'Q', toBlockId: 'to', toPin: 'IN'),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [fb]);

    final prog = PlcProgram(name: 'F1', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll([
      FbdBlock(id: 'g_in', type: 'TAG_INPUT', title: 'Src', tagBinding: 'Src'),
      FbdBlock(id: 'g_fb', type: 'Ramp', title: 'Ramp', tagBinding: 'R1'),
      FbdBlock(id: 'g_out', type: 'TAG_OUTPUT', title: 'Dst', tagBinding: 'Dst'),
    ]);
    prog.fbdWires.addAll([
      FbdWire(fromBlockId: 'g_in', fromPin: 'OUT', toBlockId: 'g_fb', toPin: 'In'),
      FbdWire(fromBlockId: 'g_fb', fromPin: 'Out', toBlockId: 'g_out', toPin: 'IN'),
    ]);

    final p = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [
        _tag('Src', 'BOOL', true),
        _tag('Dst', 'BOOL', false),
        PlcTag(name: 'R1', path: 'R1', dataType: 'Ramp',
            value: defaultValueFor(defaults, 'Ramp', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [fb],
    );

    final rt = FbdRuntime();
    executeFbdPrograms(p, 500, rt);
    expect(readPath(p, 'Dst'), isFalse);
    executeFbdPrograms(p, 500, rt);
    expect(readPath(p, 'Dst'), isTrue); // fbdRt threaded into the FB body
  });
```

Append to `mobile/test/models/fb_exec_test.dart` as well (this one proves `runScopedLdBody` FORWARDS `fbdRt`, the only threading edge with no other coverage: a LADDER-bodied AOI whose rung calls an FBD-bodied AOI):

```dart
  test('a ladder-bodied AOI calling an FBD-bodied AOI keeps the inner timer state', () {
    final inner = FbDefinition(name: 'Inner', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ], fbdBlocks: [
      FbdBlock(id: 'i_ti', type: 'TAG_INPUT', title: 'In', tagBinding: 'In'),
      FbdBlock(id: 'i_pt', type: 'CONST', title: 'CONST', tagBinding: '1000'),
      FbdBlock(id: 'i_ton', type: 'TON', title: 'TON'),
      FbdBlock(id: 'i_to', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Out'),
    ], fbdWires: [
      FbdWire(fromBlockId: 'i_ti', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'IN'),
      FbdWire(fromBlockId: 'i_pt', fromPin: 'OUT', toBlockId: 'i_ton', toPin: 'PT'),
      FbdWire(fromBlockId: 'i_ton', fromPin: 'Q', toBlockId: 'i_to', toPin: 'IN'),
    ]);
    // LADDER body: left rail -> FB call block (type 'Inner', instance var
    // 'Nested') -> right rail.
    final outer = FbDefinition(name: 'Outer', vars: [
      FbVar(name: 'In', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
      FbVar(name: 'Nested', dataType: 'Inner', direction: FbVarDir.internal),
    ], ladderRungs: [
      LdRung(rungIndex: 0, nodes: [
        LdNode(id: 'L', kind: LdKind.leftRail),
        LdNode(id: 'b', kind: LdKind.block, blockType: 'Inner', variable: 'Nested',
            pinBindings: {'In': 'In', 'Out': 'Out'}),
        LdNode(id: 'R', kind: LdKind.rightRail),
      ], wires: [
        LdWire(fromId: 'L', toId: 'b'),
        LdWire(fromId: 'b', toId: 'R'),
      ]),
    ]);
    final defaults = PlcProject(
        id: 'd', name: 'd', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
        fbDefinitions: [inner, outer]);
    final p = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'O1', path: 'O1', dataType: 'Outer',
            value: defaultValueFor(defaults, 'Outer', 0), ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
      fbDefinitions: [inner, outer],
    );

    final ldRt = LdExecRuntime();
    final fbdRt = FbdRuntime();
    executeFbInstance(p, outer, 'O1', {'In': true},
        dtMs: 500, ldRt: ldRt, fbdRt: fbdRt);
    expect(readPath(p, 'O1.Out'), isFalse); // ET 500 < PT 1000
    executeFbInstance(p, outer, 'O1', {'In': true},
        dtMs: 500, ldRt: ldRt, fbdRt: fbdRt);
    // Only true if runScopedLdBody -> executeRung -> executeFbInstance carried
    // fbdRt all the way down; with a dropped fbdRt the inner TON restarts.
    expect(readPath(p, 'O1.Out'), isTrue);
  });
```

This test needs `import 'package:soft_plc_mobile/models/ld_exec.dart';` in `fb_exec_test.dart` for `LdExecRuntime`; add it if absent.

- [ ] **Step 3: Run the tests to verify they fail**

From `mobile/`:

```
/c/flutter/bin/flutter test test/models/fb_exec_test.dart test/fb_ld_exec_test.dart test/fb_fbd_exec_test.dart
```

Expected: FAIL - `No named parameter with the name 'fbdRt'` (in `executeFbInstance` and `executeLdPrograms`).

- [ ] **Step 4: Three-way dispatch in `fb_exec.dart`**

In `mobile/lib/models/fb_exec.dart`, add the import (after `import 'project_model.dart';`):

```dart
import 'fbd_exec.dart';
```

(Yes, this closes a library cycle with `fbd_exec.dart`'s existing `import 'fb_exec.dart';` at line 5. Dart permits it, neither library performs top-level circular initialization, and it is the same shape already shipped between `ld_exec.dart` and `fb_exec.dart`.)

Add the helper above `executeFbInstance`:

```dart
/// Rockwell re-evaluates an AOI's implicit EnableIn on EVERY call, so a
/// graphical body that clears it (an `OTU(EnableIn)` rung, or an FBD network
/// writing `EnableIn`) must not permanently self-disable. The import path
/// retains EnableIn as an INTERNAL BOOL var for RLL- and FBD-Logic AOIs (see
/// l5x_parser.dart), so that shape — and only that shape — is re-asserted true
/// here, just before the body runs. Data-driven on the var list rather than a
/// per-definition flag, so old JSON needs no new field. An EnableIn that is a
/// real interface pin (input/output) is caller-driven and left alone; the ST
/// path is untouched.
void _reassertEnableIn(PlcProject p, FbDefinition fb, String instanceName) {
  for (final v in fb.vars) {
    if (v.name == 'EnableIn' &&
        v.direction == FbVarDir.internal &&
        v.dataType == 'BOOL') {
      writePath(p, '$instanceName.EnableIn', true);
      return;
    }
  }
}
```

Replace the doc-comment's body-dispatch paragraph (lines 18-27) and the signature with:

```dart
/// Body dispatch (the single source of truth for body precedence): a non-empty
/// [FbDefinition.ladderRungs] runs the native ladder body via
/// `runScopedLdBody`; else a non-empty [FbDefinition.fbdBlocks] runs the
/// native FBD body via `runScopedFbdBody`; else the existing scoped-ST path
/// runs, unchanged. [dtMs] drives a graphical body's timers, [ldRt] carries a
/// ladder body's edge/pulse state and [fbdRt] an FBD body's
/// timer/counter/edge state. Both engine call sites thread their real scan
/// `dtMs` and runtimes down to here (the LD engine gains `fbdRt` from
/// `runScanTick`; the FBD engine passes its own `FbdRuntime`), so the
/// ephemeral `LdExecRuntime()` / `FbdRuntime()` fallbacks are unreachable in
/// the scan — they only catch direct/ad-hoc callers, where they degrade ONLY
/// stateful blocks (a body TON restarts each call; never throws).
Map<String, dynamic> executeFbInstance(
    PlcProject p, FbDefinition fb, String instanceName, Map<String, dynamic> inputs,
    {int dtMs = 0, LdExecRuntime? ldRt, FbdRuntime? fbdRt, Set<String>? readOnly}) {
```

Replace step 2 of the body (lines 54-77) with:

```dart
    // 2. Run the scoped body (precedence: ladder > FBD > ST).
    final varNames = {for (final v in fb.vars) v.name};
    if (fb.ladderRungs.isNotEmpty) {
      _reassertEnableIn(p, fb, instanceName);
      runScopedLdBody(p, fb.ladderRungs, LdScope(instanceName, varNames), dtMs,
          ldRt ?? LdExecRuntime(), readOnly: readOnly, fbdRt: fbdRt);
    } else if (fb.fbdBlocks.isNotEmpty) {
      _reassertEnableIn(p, fb, instanceName);
      runScopedFbdBody(p, fb.fbdBlocks, fb.fbdWires,
          LdScope(instanceName, varNames), dtMs, fbdRt ?? FbdRuntime(),
          readOnly: readOnly, ldRt: ldRt);
    } else {
      runScopedStBody(p, fb.stSource, StScope(instanceName, varNames));
    }
```

- [ ] **Step 5: Thread `FbdRuntime` through `ld_exec.dart`**

In `mobile/lib/models/ld_exec.dart`:

1. Add the import after `import 'fb_exec.dart';`:

```dart
import 'fbd_exec.dart';
```

2. `executeLdPrograms` (lines 93-110) - add the parameter and forward it:

```dart
void executeLdPrograms(PlcProject p, int dtMs, LdExecRuntime rt,
    {Set<String>? only, Set<String>? readOnly, LdMonitor? monitor,
    FbdRuntime? fbdRt}) {
  for (final prog in p.programs) {
    if (prog.language != 'LadderLogic') {
      continue;
    }
    if (only != null && !only.contains(prog.name)) {
      continue;
    }
    for (final rung in prog.rungs) {
      executeRung(p, prog.name, rung, dtMs, rt, (path, v) {
        if (readOnly == null || !readOnly.contains(path)) {
          _forceAwareWrite(p, path, v);
        }
      }, monitor: monitor, readOnly: readOnly, fbdRt: fbdRt);
    }
  }
}
```

3. `executeRung` (line 118) - add the parameter to the signature:

```dart
void executeRung(PlcProject p, String progName, LdRung rung, int dtMs,
    LdExecRuntime rt, void Function(String path, dynamic value) write,
    {LdMonitor? monitor, LdScope? scope, Set<String>? readOnly,
    FbdRuntime? fbdRt}) {
```

and at its custom-FB call site (line ~448):

```dart
            final outputs = executeFbInstance(p, fb, sp(n.variable), inputs,
                dtMs: dtMs, ldRt: rt, fbdRt: fbdRt, readOnly: readOnly);
```

4. `runScopedLdBody` (line 532) - add the parameter and forward it (a ladder AOI calling an FBD AOI):

```dart
void runScopedLdBody(PlcProject p, List<LdRung> rungs, LdScope scope, int dtMs,
    LdExecRuntime rt, {Set<String>? readOnly, FbdRuntime? fbdRt}) {
  final progKey = 'fb:${scope.instancePath}';
  for (final rung in rungs) {
    executeRung(p, progKey, rung, dtMs, rt, (path, v) {
      if (readOnly == null || !readOnly.contains(path)) {
        _forceAwareWrite(p, path, v);
      }
    }, scope: scope, readOnly: readOnly, fbdRt: fbdRt); // inherited by nested FB calls
  }
}
```

- [ ] **Step 6: Thread `FbdRuntime` from the FBD engine and the scan tick**

In `mobile/lib/models/fbd_exec.dart`, the custom-FB branch of `_evalBlock` (line ~206), replace the comment + call with:

```dart
    // A ladder-bodied FB needs the scan's dtMs (timers) and a persistent
    // LdExecRuntime (edge/pulse); an FBD-bodied FB needs this same FbdRuntime
    // so its own timers/counters/edges survive the scan boundary (its state
    // keys are 'fb:<instancePath>|'-prefixed, so they can never collide with
    // this body's own block keys). An ST-bodied FB ignores both. `readOnly`
    // gates the body's writes on globals, matching the gate this function's
    // own TAG_OUTPUT branch already applies.
    return executeFbInstance(p, fb, sp(b.tagBinding), inputMap,
        dtMs: dtMs, ldRt: ldRt, fbdRt: rt, readOnly: readOnly);
```

In `mobile/lib/screens/scan_tick.dart` (line 76), pass the shell's FBD runtime into the LD engine:

```dart
    // The SAME FbdRuntime the FBD engine uses: an FBD-bodied FB called from a
    // ladder rung keeps its timer/counter/edge state across scans.
    executeLdPrograms(p, dtMs, rt.ld, only: only, readOnly: readOnly,
        monitor: rt.ldMonitor, fbdRt: rt.fbd);
```

- [ ] **Step 7: Run the tests to verify they pass**

From `mobile/`:

```
/c/flutter/bin/flutter test test/models/fb_exec_test.dart test/fb_ld_exec_test.dart test/fb_fbd_exec_test.dart test/models/fb_fbd_body_exec_test.dart
```

Expected: `All tests passed!`.

- [ ] **Step 8: Verify the whole suite and the analyzer**

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze`.

Expected: `All tests passed!` and `No issues found!`. Pay particular attention to `test/models/fb_ladder_exec_test.dart`, `test/models/fb_ladder_engine_test.dart`, `test/ld_exec_test.dart`, `test/models/executor_readonly_test.dart` and `test/scan_scheduling_test.dart`: a ladder-bodied FB called from an FBD program must still work, and the LD path with `fbdRt: null` must be unchanged.

- [ ] **Step 9: Commit**

```
git add -A && git commit -m "feat(fb): FBD body dispatch + FbdRuntime threading"
```

---

### Task 4: L5X FBD parser core + `_l5xRoutines` FBD arm

**Model:** sonnet · **Effort:** medium

Implements spec §4 (element mapping, wires, ids, the ignore/keep split) plus the front-end arm. Multi-sheet merging, connector resolution and aliasing arrive in Tasks 5 and 6; this task parses every `<Sheet>` in document order with raw ids, which is already correct for the single-sheet case.

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (new `_l5xFbdBody`; FBD arm of `_l5xRoutines` at lines 315-322)
- Test: `mobile/test/import/l5x_parser_fbd_test.dart` (new file)

**Interfaces:**
- Consumes: `_children(XmlElement, String)` (same file, line 78); `IrGraphNode({required int localId, required String elementType, double x, double y, Map<String, String>? attributes})`; `IrConnection({required int toLocalId, String? toPin, required int fromLocalId, String? fromPin})`; `GraphBody({required List<IrGraphNode> nodes, required List<IrConnection> connections})` (all `import_ir.dart`).
- Produces: `GraphBody _l5xFbdBody(XmlElement routine, List<ImportWarning> warnings, String ownerLabel)` - `ownerLabel` is `'Routine "Prog_Main"'` or `'AOI "Foo"'`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/import/l5x_parser_fbd_test.dart`:

```dart
// L5X FBD parser units: <FBDContent><Sheet> XML -> the vendor-neutral
// GraphBody, using EXACTLY the attribute keys plcopen_parser.dart emits so
// translateFbdBody needs no changes.
//
// Corpus note: the local Rockwell corpus contains zero FBD content, so every
// fixture here is handcrafted schema-faithful L5X (the same precedent as the
// PLCopen FBD e2e).
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fbd_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

ImportedProject _parse(String fbdContent) => parseL5x('''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Prog"><Tags/><Routines>
    <Routine Name="Main" Type="FBD"><FBDContent>$fbdContent</FBDContent></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''');

GraphBody _graph(ImportedProject ir) =>
    ir.pous.firstWhere((p) => p.name == 'Prog_Main').body as GraphBody;

IrGraphNode _node(GraphBody g, int id) =>
    g.nodes.firstWhere((n) => n.localId == id);

PlcTag _tag(String n, dynamic v) =>
    PlcTag(name: n, path: n, dataType: 'INT32', value: v, ioType: 'Internal');

void main() {
  test('every element kind maps to the expected elementType + attributes', () {
    // Real-Logix element shapes: stateful instructions are <Block> with an
    // Operand (their backing tag); stateless bit functions are <Function>.
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand=" Speed " X="10" Y="20"/>
        <ORef ID="1" Operand="Alarm" X="30" Y="40"/>
        <Block ID="2" Type="TON" Operand="T1" X="50" Y="60"/>
        <Block ID="3" Type="ADD" Operand="Add_01" X="70" Y="80"/>
        <AddOnInstruction ID="4" Name="MyAoi" Operand="Inst1" X="90" Y="100"/>
        <Function ID="5" Type="BNOT" X="110" Y="120"/>
      </Sheet>'''));

    expect(g.nodes, hasLength(6));

    expect(_node(g, 0).elementType, 'inVariable');
    expect(_node(g, 0).attributes['variable'], 'Speed'); // trimmed
    expect(_node(g, 0).x, 10);
    expect(_node(g, 0).y, 20);

    expect(_node(g, 1).elementType, 'outVariable');
    expect(_node(g, 1).attributes['variable'], 'Alarm');

    expect(_node(g, 2).elementType, 'block');
    expect(_node(g, 2).attributes['typeName'], 'TON');
    expect(_node(g, 2).attributes['instanceName'], 'T1');

    expect(_node(g, 3).elementType, 'block');
    expect(_node(g, 3).attributes['typeName'], 'ADD');
    expect(_node(g, 3).attributes['instanceName'], 'Add_01');

    expect(_node(g, 4).elementType, 'block');
    expect(_node(g, 4).attributes['typeName'], 'MyAoi');
    expect(_node(g, 4).attributes['instanceName'], 'Inst1');

    // <Function> is stateless: no Operand, so no instanceName key at all.
    expect(_node(g, 5).elementType, 'block');
    expect(_node(g, 5).attributes.containsKey('instanceName'), isFalse);

    // hasNegatedPin/negated are NEVER emitted (Logix FBD has no pin inversion
    // or element negation; BNOT is an explicit element).
    expect(g.nodes.any((n) => n.attributes.containsKey('hasNegatedPin')), isFalse);
    expect(g.nodes.any((n) => n.attributes.containsKey('negated')), isFalse);
  });

  test('Wire maps to IrConnection; absent Params are null', () {
    // A real Logix wire out of an <IRef> carries no FromParam (the ref has a
    // single implicit output); a wire out of a block names its output pin.
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="A"/>
        <Function ID="1" Type="BNOT"/>
        <ORef ID="2" Operand="B"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
        <Wire FromID="1" FromParam="OUT" ToID="2"/>
      </Sheet>'''));

    expect(g.connections, hasLength(2));
    final w0 = g.connections[0];
    expect(w0.fromLocalId, 0);
    expect(w0.fromPin, isNull); // absent FromParam -> null
    expect(w0.toLocalId, 1);
    expect(w0.toPin, 'IN');
    final w1 = g.connections[1];
    expect(w1.fromPin, 'OUT');
    expect(w1.toPin, isNull); // absent ToParam -> null
  });

  test('FeedbackWire maps like Wire, translates, and EXECUTES without hanging', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <Block ID="1" Type="ADD" Operand="Add_01" X="100" Y="0"/>
        <ORef ID="2" Operand="Dst" X="200" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN1"/>
        <Wire FromID="1" FromParam="OUT" ToID="2" ToParam="IN"/>
        <FeedbackWire FromID="1" FromParam="OUT" ToID="1" ToParam="IN2"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.connections, hasLength(3));
    final fb = g.connections.last;
    expect(fb.fromLocalId, 1);
    expect(fb.fromPin, 'OUT');
    expect(fb.toLocalId, 1);
    expect(fb.toPin, 'IN2');

    // One weakly-connected component -> one real network.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);

    // The "never hangs" claim is only worth anything if it is EXECUTED: the
    // engine's dataflow-cycle fallback evaluates each unresolved block once
    // and returns. (The ADD's own feedback input is unresolved on that pass,
    // so it yields null and the ORef writes nothing; the point is the call
    // returns at all.)
    final prog = PlcProgram(name: 'Prog_Main', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll(tr.blocks);
    prog.fbdWires.addAll(tr.wires);
    final p = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [_tag('Src', 5), _tag('Dst', 0)],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [],
    );
    executeFbdPrograms(p, 100, FbdRuntime());
    expect(readPath(p, 'Dst'), 0);
  });

  test('an unrecognized element with an ID is KEPT and stubs its component', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src"/>
        <JSR ID="1" Routine="Sub"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(_node(g, 1).elementType, 'JSR'); // raw tag name, not dropped
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 1);
  });

  test('TextBox/Attachment are dropped with ONE info "ignored" warning', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src"/>
        <TextBox ID="7" Width="100"><Text>note</Text></TextBox>
        <TextBox ID="8" Width="100"><Text>note2</Text></TextBox>
        <Attachment FromID="7" ToID="0"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.map((n) => n.localId), [0]); // annotations are not nodes
    final ignored = ir.warnings
        .where((w) =>
            w.message.contains('ignored') &&
            w.message.contains('Routine "Prog_Main"'))
        .toList();
    expect(ignored, hasLength(1));
    expect(ignored.single.severity, WarningSeverity.info);
    expect(ignored.single.message, contains('3 element(s) ignored'));
    expect(ignored.single.message, contains('TextBox'));
    expect(ignored.single.message, contains('Attachment'));
  });

  test('malformed ids get DISTINCT negative ids; a dangling wire gets a placeholder', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef Operand="NoId"/>
        <IRef ID="abc" Operand="BadId"/>
        <IRef ID="-4" Operand="Negative"/>
        <IRef ID="0" Operand="Fine"/>
        <Wire FromID="abc" ToID="0" ToParam="IN"/>
      </Sheet>'''));

    // 3 malformed elements + 1 placeholder for the wire's unresolvable source.
    final negatives =
        g.nodes.where((n) => n.localId < 0).map((n) => n.localId).toList();
    expect(negatives, hasLength(4));
    expect(negatives.toSet(), hasLength(4)); // distinct, never a shared -1
    expect(g.nodes.where((n) => n.localId >= 0), hasLength(1));

    // The wire is KEPT (never silently dropped) and points at the placeholder.
    expect(g.connections, hasLength(1));
    final placeholder =
        g.nodes.firstWhere((n) => n.elementType == 'danglingWire');
    expect(g.connections.single.fromLocalId, placeholder.localId);
    expect(g.connections.single.toLocalId, 0);

    // So the CONSUMER's component stubs instead of translating as if its
    // input were merely unwired. 3 isolated malformed nodes + 1 component
    // {placeholder, Fine} = 4 stubbed components, 0 translated.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 4);
  });

  test('an absent/empty FBDContent yields an empty GraphBody, no warning, no throw', () {
    final ir = parseL5x('''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Prog"><Tags/><Routines>
    <Routine Name="Main" Type="FBD"/>
    <Routine Name="Empty" Type="FBD"><FBDContent/></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''');
    for (final n in ['Prog_Main', 'Prog_Empty']) {
      final pou = ir.pous.firstWhere((p) => p.name == n);
      expect(pou.lang, PouLanguage.fbd);
      final g = pou.body as GraphBody;
      expect(g.nodes, isEmpty);
      expect(g.connections, isEmpty);
      // Distinguishes the NEW path from the old one: the pre-feature FBD arm
      // emitted an equally-empty GraphBody but ALWAYS warned. Nothing here has
      // failed, so nothing warns at all.
      expect(ir.warnings.any((w) => w.message.contains(n)), isFalse);
    }
  });

  test('the old "graphical body not yet translated" FBD warning is gone', () {
    final ir = _parse('''
      <Sheet Number="1"><IRef ID="0" Operand="Src"/></Sheet>''');
    expect(
        ir.warnings.any((w) =>
            w.message.contains('Prog_Main') &&
            w.message.contains('not yet translated')),
        isFalse);
    final pou = ir.pous.firstWhere((p) => p.name == 'Prog_Main');
    expect(pou.lang, PouLanguage.fbd);
    expect(pou.kind, PouKind.program);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_fbd_test.dart`

Expected: FAIL - the element-kind test reports `g.nodes` empty (the FBD arm still emits `GraphBody(nodes: const [], connections: const [])`) and the last test fails on the still-emitted "not yet translated" warning.

- [ ] **Step 3: Add `_l5xFbdBody` to the parser**

In `mobile/lib/import/l5x_parser.dart`, add after the `_stLines` helper (line 174):

```dart
/// Upper bound on a usable L5X FBD element `ID`. Anything above it (or absent,
/// unparseable, or negative) is treated as malformed and gets a unique
/// negative synthetic id instead, reproducing `plcopen_parser.dart`'s
/// `_graphBody` contract: distinct negative ids keep
/// `weaklyConnectedComponents` from merging two unrelated malformed nodes, and
/// the FBD translator's `localId < 0` gate still stubs their component.
const int _kMaxL5xFbdId = 1 << 31;

/// L5X FBD elements that are pure annotations: they carry an `ID` (or link to
/// one) but never participate in dataflow, so they are dropped entirely rather
/// than kept as opaque stub nodes. Everything else unrecognized IS kept (see
/// `_l5xFbdBody`), so a `<JSR>`/`<SBR>`/`<Ret>` network stubs visibly instead
/// of silently disappearing.
const Set<String> _kL5xFbdAnnotationElements = {'TextBox', 'Attachment'};

/// Builds the vendor-neutral [GraphBody] for one L5X FBD routine body
/// (`<FBDContent><Sheet>...`), shared by the program-routine arm and the AOI
/// arm. [ownerLabel] is the human label used in warnings, e.g.
/// `'Routine "Prog_Main"'` or `'AOI "Pump"'`.
///
/// Emits EXACTLY the IR attribute keys `plcopen_parser.dart`'s `_graphBody`
/// emits (`variable`, `typeName`, `instanceName`), so `translateFbdBody` needs
/// no changes. `hasNegatedPin` is never emitted: Logix FBD has no pin
/// inversion (`BNOT` is an explicit element).
///
/// Two passes per sheet — nodes first, then wires — because pin aliasing needs
/// the endpoint node's type to be known, and because a wire endpoint is
/// resolved through the node pass's `assignedByRawId` map (an endpoint that
/// names no element gets a `danglingWire` placeholder node so the wire is
/// never silently dropped). Never throws: every attribute read is null-tolerant
/// and an absent/empty `<FBDContent>` yields an empty body.
GraphBody _l5xFbdBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel) {
  final nodes = <IrGraphNode>[];
  final conns = <IrConnection>[];
  // ROUTINE-WIDE (not per-sheet) synthetic-id counter: a malformed-id element
  // on sheet 1 and one on sheet 2 must still get distinct ids.
  var malformedId = -1;
  final ignoredKinds = <String>[];
  var ignoredCount = 0;

  for (final content in _children(routine, 'FBDContent')) {
    for (final sheet in _children(content, 'Sheet')) {
      // Raw `ID` -> the localId actually assigned to that element, so pass 2
      // can resolve a wire endpoint to a REAL node (including one that was
      // given a synthetic negative id for an out-of-range `ID`). Wire
      // endpoints are sheet-local, so this map is per sheet.
      final assignedByRawId = <int, int>{};

      // Pass 1 — nodes.
      for (final el in sheet.childElements) {
        final tag = el.name.local;
        if (tag == 'Wire' || tag == 'FeedbackWire') {
          continue; // pass 2
        }
        if (_kL5xFbdAnnotationElements.contains(tag)) {
          ignoredCount++;
          if (!ignoredKinds.contains(tag)) ignoredKinds.add(tag);
          continue;
        }
        final parsed = int.tryParse(el.getAttribute('ID') ?? '');
        final localId = (parsed == null || parsed < 0 || parsed > _kMaxL5xFbdId)
            ? malformedId--
            : parsed;
        if (parsed != null && parsed >= 0) {
          assignedByRawId[parsed] = localId;
        }
        final attrs = <String, String>{};
        final String elementType;
        switch (tag) {
          case 'IRef':
            {
              elementType = 'inVariable';
              attrs['variable'] = (el.getAttribute('Operand') ?? '').trim();
              break;
            }
          case 'ORef':
            {
              elementType = 'outVariable';
              attrs['variable'] = (el.getAttribute('Operand') ?? '').trim();
              break;
            }
          case 'Block':
            {
              elementType = 'block';
              attrs['typeName'] = (el.getAttribute('Type') ?? '').trim();
              final operand = (el.getAttribute('Operand') ?? '').trim();
              if (operand.isNotEmpty) attrs['instanceName'] = operand;
              break;
            }
          case 'Function':
            {
              elementType = 'block';
              attrs['typeName'] = (el.getAttribute('Type') ?? '').trim();
              break;
            }
          case 'AddOnInstruction':
            {
              // An AOI's `Name` is a user type name and is NEVER aliased.
              elementType = 'block';
              attrs['typeName'] = (el.getAttribute('Name') ?? '').trim();
              final operand = (el.getAttribute('Operand') ?? '').trim();
              if (operand.isNotEmpty) attrs['instanceName'] = operand;
              break;
            }
          case 'ICon':
          case 'OCon':
            {
              elementType = tag;
              attrs['connectorName'] = (el.getAttribute('Name') ?? '').trim();
              break;
            }
          default:
            {
              // Kept, NOT ignored: the raw element name is not one of the
              // translator's known elementType strings, so this node's whole
              // component stubs as `unsupported-element` instead of vanishing.
              elementType = tag;
              break;
            }
        }
        nodes.add(IrGraphNode(
          localId: localId,
          elementType: elementType,
          x: double.tryParse(el.getAttribute('X') ?? '') ?? 0,
          y: double.tryParse(el.getAttribute('Y') ?? '') ?? 0,
          attributes: attrs,
        ));
      }

      // Resolves one wire endpoint to a real node id. An endpoint that names
      // no element on this sheet (absent, unparseable, negative, or an id no
      // element carries) gets a fresh `danglingWire` PLACEHOLDER node instead
      // of dropping the wire: dropping it would silently delete a data path
      // and let the consumer's component translate as though that input were
      // simply unwired. The placeholder's negative id + unknown elementType
      // make the consumer's component stub (`unsupported-element`).
      int resolveEndpoint(String? raw) {
        final parsed = int.tryParse(raw ?? '');
        final hit = parsed == null ? null : assignedByRawId[parsed];
        if (hit != null) {
          return hit;
        }
        final id = malformedId--;
        nodes.add(IrGraphNode(localId: id, elementType: 'danglingWire'));
        return id;
      }

      // Pass 2 — wires. `<FeedbackWire>` (a wire closing a feedback loop)
      // carries the identical attribute set as `<Wire>` and maps the same way;
      // the cyclic graph it creates is handled by the executor's existing
      // dataflow-cycle fallback.
      for (final el in sheet.childElements) {
        final tag = el.name.local;
        if (tag != 'Wire' && tag != 'FeedbackWire') {
          continue;
        }
        conns.add(IrConnection(
          fromLocalId: resolveEndpoint(el.getAttribute('FromID')),
          fromPin: el.getAttribute('FromParam'),
          toLocalId: resolveEndpoint(el.getAttribute('ToID')),
          toPin: el.getAttribute('ToParam'),
        ));
      }
    }
  }

  if (ignoredCount > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $ignoredCount element(s) ignored '
            '(${ignoredKinds.join(', ')}).'));
  }
  return GraphBody(nodes: nodes, connections: conns);
}
```

- [ ] **Step 4: Wire the FBD arm of `_l5xRoutines`**

In `mobile/lib/import/l5x_parser.dart`, replace the `case 'FBD':` arm (lines 315-322) with:

```dart
            case 'FBD':
              // The structured <FBDContent> parses into a real GraphBody;
              // `ir_to_project`'s existing FBD arm translates it per network
              // (faithful-or-stub). A routine where NOTHING translates keeps
              // today's whole-POU stub via that arm's existing `else`.
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.fbd, localVars: const [],
                  body: _l5xFbdBody(r, warnings, 'Routine "$name"')));
              break;
```

Also update the `_l5xRoutines` doc-comment (lines 278-283) so it no longer claims FBD produces an empty body:

```dart
/// Maps each `<Routine>` in each `<Program>` to a program POU named
/// `Program_Routine`. ST inlines its lines; RLL captures each rung's neutral
/// text + comment into a `NeutralLadderBody`; FBD parses its structured
/// `<FBDContent>` into a `GraphBody` (translated per network by
/// `ir_to_project`); SFC still becomes an empty graphical body (the mapper's
/// existing whole-POU stub) + a count-carrying warning.
```

- [ ] **Step 5: Run the tests to verify they pass**

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_fbd_test.dart`

Expected: all 8 tests pass.

- [ ] **Step 6: Verify the whole suite and the analyzer**

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze`.

Expected: `All tests passed!` and `No issues found!`. If `test/import/l5x_parser_test.dart` or `test/import/import_l5x_e2e_test.dart` asserted the removed "graphical body not yet translated" warning for a PROGRAM FBD routine, update those assertions to the new behaviour. The AOI-side assertion at `l5x_parser_test.dart:163-184` belongs to Task 7 and must still pass unchanged here (AOIs are untouched until then).

- [ ] **Step 7: Commit**

```
git add -A && git commit -m "feat(l5x): parse FBD routine bodies into the neutral GraphBody"
```
---

### Task 5: Multi-sheet merge + connector resolution

**Model:** opus · **Effort:** high

Implements spec §5 and resolutions R4 (unmatched connectors stub via the element gate) and R5 (per-sheet y offsetting). Raised to opus/high on review: the merge touches id assignment, wire-endpoint resolution and connector splicing at once, and three of its edge cases (unnamed connectors, connector chaining, dangling endpoints) silently produce WRONG graphs rather than failing loudly if they are handled naively.

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (`_l5xFbdBody` restructured; new `_l5xFbdSheets` and `_resolveL5xFbdConnectors` helpers)
- Test: `mobile/test/import/l5x_parser_fbd_test.dart` (append)

**Interfaces:**
- Produces: `List<XmlElement> _l5xFbdSheets(XmlElement routine)` - the routine's `<Sheet>`s in ascending `Number` order, document order as the fallback key.
- Produces: `void _resolveL5xFbdConnectors(List<IrGraphNode> nodes, List<IrConnection> conns, Map<int, String> iconNames, Map<int, String> oconNames, List<ImportWarning> warnings, String ownerLabel)` - mutates `nodes`/`conns` in place.
- Unchanged: `GraphBody _l5xFbdBody(XmlElement routine, List<ImportWarning> warnings, String ownerLabel)` (same signature as Task 4).

- [ ] **Step 1: Write the failing tests**

Append to `mobile/test/import/l5x_parser_fbd_test.dart`, inside `void main() {`:

```dart
  test('two sheets with OVERLAPPING raw ids merge with disjoint localIds', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="A" X="0" Y="0"/>
        <ORef ID="1" Operand="B" X="100" Y="50"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="0" Operand="C" X="0" Y="0"/>
        <ORef ID="1" Operand="D" X="100" Y="10"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>'''));

    expect(g.nodes.map((n) => n.localId).toSet(), hasLength(4));
    // Sheet 1 keeps raw ids; sheet 2 is offset past the max assigned so far.
    expect(_node(g, 0).attributes['variable'], 'A');
    expect(_node(g, 2).attributes['variable'], 'C');
    expect(_node(g, 3).attributes['variable'], 'D');
    // Wires are sheet-local, so they follow their sheet's offset.
    expect(g.connections.map((c) => '${c.fromLocalId}->${c.toLocalId}'),
        ['0->1', '2->3']);
    // Sheet 2 sits BELOW sheet 1 (maxY 50 + 200), so network numbering reads
    // sheet by sheet instead of interleaving.
    expect(_node(g, 2).y, 250);
    expect(_node(g, 3).y, 260);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 2);
  });

  test('sheets are visited in ascending Number order, not document order', () {
    final g = _graph(_parse('''
      <Sheet Number="2">
        <IRef ID="0" Operand="Second" X="0" Y="0"/>
      </Sheet>
      <Sheet Number="1">
        <IRef ID="0" Operand="First" X="0" Y="0"/>
      </Sheet>'''));

    // The Number="1" sheet is processed first, so it keeps the raw id.
    expect(_node(g, 0).attributes['variable'], 'First');
    expect(_node(g, 1).attributes['variable'], 'Second');
  });

  test('an unnumbered sheet falls back to its document-order position', () {
    // Document order: Number="2", (none), Number="1". Keys: 2.0, 2.5, 1.0 ->
    // processed 1, 2, unnumbered (the unnumbered one sits just after the
    // neighbour it followed in the file).
    final g = _graph(_parse('''
      <Sheet Number="2">
        <IRef ID="0" Operand="Two" X="0" Y="0"/>
      </Sheet>
      <Sheet>
        <IRef ID="0" Operand="NoNumber" X="0" Y="0"/>
      </Sheet>
      <Sheet Number="1">
        <IRef ID="0" Operand="One" X="0" Y="0"/>
      </Sheet>'''));

    expect(_node(g, 0).attributes['variable'], 'One');
    expect(_node(g, 1).attributes['variable'], 'Two');
    expect(_node(g, 2).attributes['variable'], 'NoNumber');
  });

  test('the synthetic-id counter is ROUTINE-wide across sheets', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef Operand="BadOne"/>
        <IRef ID="0" Operand="Fine"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="oops" Operand="BadTwo"/>
        <IRef ID="0" Operand="AlsoFine"/>
      </Sheet>'''));

    final negatives =
        g.nodes.where((n) => n.localId < 0).map((n) => n.localId).toList();
    expect(negatives, hasLength(2));
    expect(negatives.toSet(), hasLength(2)); // distinct, not both -1

    // Each malformed element stubs its OWN component.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.stubReasons['unsupported-element'], 2);
  });

  test('a matched OCon/ICon pair becomes a direct wire and the nodes vanish', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <Function ID="1" Type="NOT" X="50" Y="0"/>
        <OCon ID="2" Name="Loop1" X="100" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
        <Wire FromID="1" FromParam="OUT" ToID="2"/>
      </Sheet>
      <Sheet Number="2">
        <ICon ID="0" Name="Loop1" X="0" Y="0"/>
        <ORef ID="1" Operand="Dst" X="50" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>'''));

    expect(g.nodes.any((n) => n.elementType == 'ICon'), isFalse);
    expect(g.nodes.any((n) => n.elementType == 'OCon'), isFalse);

    // Producer (NOT.OUT) is wired straight to the consumer (Dst.IN); both
    // connector wires are gone.
    final notId = g.nodes
        .firstWhere((n) => n.attributes['typeName'] == 'NOT')
        .localId;
    final dstId = g.nodes
        .firstWhere((n) => n.attributes['variable'] == 'Dst')
        .localId;
    final direct = g.connections
        .where((c) => c.fromLocalId == notId && c.toLocalId == dstId)
        .toList();
    expect(direct, hasLength(1));
    expect(direct.single.fromPin, 'OUT');
    expect(direct.single.toPin, 'IN');
    expect(g.connections, hasLength(2)); // Src->NOT plus the merged wire

    // Merged into ONE component -> one real network. (The IEC type name `NOT`
    // is deliberate: Task 6's alias table does not exist yet, so the fixture
    // must already name an IEC built-in to translate here.)
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);
  });

  test('UNNAMED connectors never match each other; both stub', () {
    // Two blank-Name connectors are NOT the same connector. Splicing them
    // would wire two unrelated networks together, so they must never enter the
    // match maps: the nodes stay and their components stub.
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <OCon ID="1" Name="" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>
      <Sheet Number="2">
        <ICon ID="0" X="0" Y="0"/>
        <ORef ID="1" Operand="Dst" X="50" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.any((n) => n.elementType == 'OCon'), isTrue);
    expect(g.nodes.any((n) => n.elementType == 'ICon'), isTrue);
    // No splice happened: Src is not wired to Dst.
    expect(
        g.connections.any((c) => c.fromLocalId == 0 && c.toLocalId == 3), isFalse);

    final w = ir.warnings
        .where((x) =>
            x.message.contains('unmatched connector') &&
            x.message.contains('(unnamed)'))
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.info);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 2);
  });

  test('connector CHAINING (an ICon feeding an OCon) routes to the unmatched path', () {
    // There is no producer/consumer pair to splice here, so both names take
    // the unmatched path and their components stub.
    final ir = _parse('''
      <Sheet Number="1">
        <ICon ID="0" Name="A" X="0" Y="0"/>
        <OCon ID="1" Name="B" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <OCon ID="1" Name="A" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.where((n) => n.elementType == 'ICon'), hasLength(1));
    expect(g.nodes.where((n) => n.elementType == 'OCon'), hasLength(2));
    final names = ir.warnings
        .where((x) => x.message.contains('unmatched connector'))
        .map((x) => x.message)
        .toList();
    expect(names, hasLength(2)); // one for "A", one for "B"
    expect(names.any((m) => m.contains('"A"')), isTrue);
    expect(names.any((m) => m.contains('"B"')), isTrue);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
  });

  test('an unmatched connector is KEPT, warns, and stubs its component', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <OCon ID="1" Name="Dangling" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.any((n) => n.elementType == 'OCon'), isTrue);
    final w = ir.warnings
        .where((x) => x.message.contains('unmatched connector'))
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.info);
    expect(w.single.message, contains('Routine "Prog_Main"'));
    expect(w.single.message, contains('Dangling'));

    // R4: the ELEMENT-kind gate fires (not the pin gate).
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 1);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_fbd_test.dart`

Expected: FAIL - the two-sheet test reports 2 distinct localIds instead of 4 (raw ids collide), and the connector tests fail because `ICon`/`OCon` nodes are still present.

- [ ] **Step 3: Add the sheet-ordering helper**

In `mobile/lib/import/l5x_parser.dart`, add above `_l5xFbdBody`:

```dart
/// The `<Sheet>` elements of an FBD routine body, in ascending `<Sheet
/// Number>` order. A sheet without a `Number` (the schema allows it, though
/// real exports always carry one) keeps its DOCUMENT-order position relative
/// to its neighbours: its sort key sits just after the previous sheet's. The
/// sort is stable, so equal keys keep document order too. This ordering drives
/// both offsetting passes in `_l5xFbdBody`, so network numbering and
/// y-offsetting always read in a predictable sheet sequence.
List<XmlElement> _l5xFbdSheets(XmlElement routine) {
  final sheets = <XmlElement>[];
  for (final content in _children(routine, 'FBDContent')) {
    sheets.addAll(_children(content, 'Sheet'));
  }
  final keys = <double>[];
  var prev = -1.0;
  for (final s in sheets) {
    final n = int.tryParse(s.getAttribute('Number') ?? '');
    final k = n != null ? n.toDouble() : prev + 0.5;
    keys.add(k);
    prev = k;
  }
  final order = List<int>.generate(sheets.length, (i) => i)
    ..sort((a, b) {
      final c = keys[a].compareTo(keys[b]);
      return c != 0 ? c : a.compareTo(b); // stable
    });
  return [for (final i in order) sheets[i]];
}
```

- [ ] **Step 4: Add the connector resolver**

Add below `_l5xFbdSheets`:

```dart
/// Resolves Logix `ICon`/`OCon` connector pairs into direct wires, ROUTINE-wide
/// (connector names link across sheets), mutating [nodes]/[conns] in place.
///
/// `oconIn[name]` are the PRODUCER wires (a real block's output flows INTO the
/// named output connector) and `iconOut[name]` the CONSUMER wires (the named
/// input connector flows OUT to a real block's input). For every name present
/// in both, the cross-product of direct wires is emitted, then those connector
/// nodes and their wires are dropped.
///
/// An UNMATCHED connector keeps its node (whose `elementType` is `ICon`/`OCon`,
/// which `_translateComponent`'s element-kind pre-flight does not recognize),
/// so the affected component stubs as `unsupported-element` rather than
/// silently losing a data path, plus one info warning per connector name.
///
/// Two shapes are deliberately routed to that unmatched path rather than
/// spliced:
///  * an UNNAMED connector (blank `Name`) never even reaches this function's
///    maps (the caller does not register it) — two blank names are not the
///    same connector, and splicing them would wire unrelated networks together;
///  * CHAINED connectors (a wire whose source is an `ICon` and whose target is
///    an `OCon`) have no real producer or consumer to splice, and splicing
///    would leave a wire referencing a dropped connector node.
/// Never throws.
void _resolveL5xFbdConnectors(
    List<IrGraphNode> nodes,
    List<IrConnection> conns,
    Map<int, String> iconNames,
    Map<int, String> oconNames,
    List<ImportWarning> warnings,
    String ownerLabel) {
  if (iconNames.isEmpty && oconNames.isEmpty) {
    return;
  }
  final producers = <String, List<IrConnection>>{};
  final consumers = <String, List<IrConnection>>{};
  final chained = <String>{};
  for (final c in conns) {
    final o = oconNames[c.toLocalId];
    final i = iconNames[c.fromLocalId];
    if (o != null && i != null) {
      // Connector-to-connector chaining: both names route to unmatched.
      chained.add(o);
      chained.add(i);
      continue;
    }
    if (o != null) (producers[o] ??= []).add(c);
    if (i != null) (consumers[i] ??= []).add(c);
  }

  final matched = <String>{};
  final direct = <IrConnection>[];
  for (final entry in producers.entries) {
    if (chained.contains(entry.key)) continue;
    final cons = consumers[entry.key];
    if (cons == null) continue;
    matched.add(entry.key);
    for (final p in entry.value) {
      for (final c in cons) {
        direct.add(IrConnection(
          fromLocalId: p.fromLocalId,
          fromPin: p.fromPin,
          toLocalId: c.toLocalId,
          toPin: c.toPin,
        ));
      }
    }
  }

  final dropIds = <int>{
    for (final e in iconNames.entries)
      if (matched.contains(e.value)) e.key,
    for (final e in oconNames.entries)
      if (matched.contains(e.value)) e.key,
  };
  nodes.removeWhere((n) => dropIds.contains(n.localId));
  conns.removeWhere((c) =>
      dropIds.contains(c.fromLocalId) || dropIds.contains(c.toLocalId));
  conns.addAll(direct);

  final unmatched = <String>{...iconNames.values, ...oconNames.values}
      .difference(matched)
      .toList()
    ..sort();
  for (final name in unmatched) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: unmatched connector "$name" — the affected '
            'network is not translated.'));
  }
}
```

- [ ] **Step 5: Restructure `_l5xFbdBody` for the merge**

Replace the body of `_l5xFbdBody` with the version below. Keep the Task 4 doc-comment verbatim and append the MULTI-SHEET paragraph to the end of it:

```dart
/// (Task 4 doc-comment stays verbatim above; append this paragraph to it.)
///
/// MULTI-SHEET: every `<Sheet>` of the routine merges into ONE `GraphBody`
/// (`_l5xFbdSheets` fixes the order). Later sheets get a localId offset
/// (`maxAssignedIdSoFar + 1`) so raw ids that repeat per sheet cannot collide,
/// and a y offset (`maxYSeenSoFar + 200`, computed on the ALREADY-offset y
/// values) so `weaklyConnectedComponents`' layout ordering numbers networks
/// sheet by sheet instead of interleaving them. Synthetic negative ids are
/// never offset. `ICon`/`OCon` pairs are resolved after the merge.
GraphBody _l5xFbdBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel) {
  final nodes = <IrGraphNode>[];
  final conns = <IrConnection>[];
  // ROUTINE-WIDE (not per-sheet) synthetic-id counter.
  var malformedId = -1;
  final ignoredKinds = <String>[];
  var ignoredCount = 0;
  // Connector nodes, collected routine-wide: assigned localId -> name. ONLY
  // named connectors are registered; an unnamed one can never be matched (two
  // blank names are not the same connector), so it must not enter these maps.
  final iconNames = <int, String>{};
  final oconNames = <int, String>{};
  var unnamedConnectors = 0;
  // Sheet-merge state.
  var idOffset = 0;
  var maxAssignedId = -1;
  var yBase = 0.0;
  // Nullable so the FIRST node's y seeds the running max instead of an assumed
  // 0.0 (a sheet whose coordinates are all negative would otherwise make the
  // next sheet's yBase overlap it).
  double? maxYSeen;
  var firstSheet = true;

  for (final sheet in _l5xFbdSheets(routine)) {
    if (!firstSheet) {
      idOffset = maxAssignedId + 1;
      yBase = (maxYSeen ?? 0) + 200;
    }
    firstSheet = false;
    // Raw `ID` -> the localId actually assigned, so pass 2 resolves a wire
    // endpoint to a REAL node. Per sheet, because wires are sheet-local.
    final assignedByRawId = <int, int>{};

    // Pass 1 — nodes.
    for (final el in sheet.childElements) {
      final tag = el.name.local;
      if (tag == 'Wire' || tag == 'FeedbackWire') {
        continue; // pass 2
      }
      if (_kL5xFbdAnnotationElements.contains(tag)) {
        ignoredCount++;
        if (!ignoredKinds.contains(tag)) ignoredKinds.add(tag);
        continue;
      }
      final parsed = int.tryParse(el.getAttribute('ID') ?? '');
      final int localId;
      if (parsed == null || parsed < 0 || parsed > _kMaxL5xFbdId) {
        localId = malformedId--; // never offset
      } else {
        localId = parsed + idOffset;
        if (localId > maxAssignedId) maxAssignedId = localId;
      }
      // Recorded even when the element got a SYNTHETIC id (out-of-range `ID`),
      // so a wire naming that raw id still resolves to the real (stubbing)
      // node rather than to a placeholder.
      if (parsed != null && parsed >= 0) {
        assignedByRawId[parsed] = localId;
      }
      final y = (double.tryParse(el.getAttribute('Y') ?? '') ?? 0) + yBase;
      if (maxYSeen == null || y > maxYSeen!) maxYSeen = y;

      final attrs = <String, String>{};
      final String elementType;
      switch (tag) {
        case 'IRef':
          {
            elementType = 'inVariable';
            attrs['variable'] = (el.getAttribute('Operand') ?? '').trim();
            break;
          }
        case 'ORef':
          {
            elementType = 'outVariable';
            attrs['variable'] = (el.getAttribute('Operand') ?? '').trim();
            break;
          }
        case 'Block':
          {
            elementType = 'block';
            attrs['typeName'] = (el.getAttribute('Type') ?? '').trim();
            final operand = (el.getAttribute('Operand') ?? '').trim();
            if (operand.isNotEmpty) attrs['instanceName'] = operand;
            break;
          }
        case 'Function':
          {
            elementType = 'block';
            attrs['typeName'] = (el.getAttribute('Type') ?? '').trim();
            break;
          }
        case 'AddOnInstruction':
          {
            // An AOI's `Name` is a user type name and is NEVER aliased.
            elementType = 'block';
            attrs['typeName'] = (el.getAttribute('Name') ?? '').trim();
            final operand = (el.getAttribute('Operand') ?? '').trim();
            if (operand.isNotEmpty) attrs['instanceName'] = operand;
            break;
          }
        case 'ICon':
        case 'OCon':
          {
            elementType = tag;
            final cname = (el.getAttribute('Name') ?? '').trim();
            attrs['connectorName'] = cname;
            if (cname.isEmpty) {
              // Unnamed: NOT registered, so it can never be spliced. The node
              // stays, so its component stubs (`unsupported-element`).
              unnamedConnectors++;
            } else if (tag == 'ICon') {
              iconNames[localId] = cname;
            } else {
              oconNames[localId] = cname;
            }
            break;
          }
        default:
          {
            // Kept, NOT ignored: the raw element name is not one of the
            // translator's known elementType strings, so this node's whole
            // component stubs as `unsupported-element` instead of vanishing.
            elementType = tag;
            break;
          }
      }
      nodes.add(IrGraphNode(
        localId: localId,
        elementType: elementType,
        x: double.tryParse(el.getAttribute('X') ?? '') ?? 0,
        y: y,
        attributes: attrs,
      ));
    }

    // Resolves one wire endpoint to a real node id (see Task 4): an endpoint
    // naming no element on this sheet gets a `danglingWire` PLACEHOLDER node
    // so the wire is never silently dropped and the consumer's component
    // stubs. Resolution goes through `assignedByRawId`, so the per-sheet
    // offset is applied exactly once and out-of-range ids land on the real
    // synthetic-id node.
    int resolveEndpoint(String? raw) {
      final parsed = int.tryParse(raw ?? '');
      final hit = parsed == null ? null : assignedByRawId[parsed];
      if (hit != null) {
        return hit;
      }
      final id = malformedId--;
      nodes.add(IrGraphNode(
          localId: id, elementType: 'danglingWire', y: yBase));
      return id;
    }

    // Pass 2 — wires. Wires live inside their own <Sheet>, so every reference
    // is sheet-local.
    for (final el in sheet.childElements) {
      final tag = el.name.local;
      if (tag != 'Wire' && tag != 'FeedbackWire') {
        continue;
      }
      conns.add(IrConnection(
        fromLocalId: resolveEndpoint(el.getAttribute('FromID')),
        fromPin: el.getAttribute('FromParam'),
        toLocalId: resolveEndpoint(el.getAttribute('ToID')),
        toPin: el.getAttribute('ToParam'),
      ));
    }
  }

  _resolveL5xFbdConnectors(
      nodes, conns, iconNames, oconNames, warnings, ownerLabel);

  if (unnamedConnectors > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $unnamedConnectors unmatched connector(s) '
            '(unnamed) — a connector with no Name can never be matched, so the '
            'affected networks are not translated.'));
  }

  if (ignoredCount > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $ignoredCount element(s) ignored '
            '(${ignoredKinds.join(', ')}).'));
  }
  return GraphBody(nodes: nodes, connections: conns);
}
```

- [ ] **Step 6: Run the tests to verify they pass**

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_fbd_test.dart`

Expected: all 16 tests pass (the Task 4 tests are single-sheet, so their raw ids and y values are unchanged).

- [ ] **Step 7: Verify the whole suite and the analyzer**

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze`.
Expected: `All tests passed!` and `No issues found!`.

- [ ] **Step 8: Commit**

```
git add -A && git commit -m "feat(l5x): merge FBD sheets and resolve ICon/OCon connectors"
```

---

### Task 6: Rockwell type + pin aliasing

**Model:** sonnet · **Effort:** medium

Implements spec §6 and resolution R1 (the alias table must map PIN names, not just type names, or every math/compare network would stub).

**Beyond the spec's §6 table (added on review):** `SEL` and `CTUD` get pin maps, and `OSRI`/`OSFI` get type + pin maps. `SEL` and `CTUD` are Rockwell FBD blocks whose type names are ALREADY in `kFbdBuiltinBlockTypes`, so they sail past the block allowlist and then die in `_assertPin` with `unresolved-pin` and **no inventory entry** - the worst failure mode available (a silently non-executing network with no type recorded in `unsupportedFbdBlockTypes`). `OSRI`/`OSFI` are the Logix one-shot instructions that correspond exactly to `R_TRIG`/`F_TRIG`. All four are best-effort like `TONR`/`TOFR`; any pin outside the map still passes through and still stubs.

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (alias tables, `_aliasL5xFbdPin`, node/wire passes in `_l5xFbdBody`)
- Test: `mobile/test/import/l5x_parser_fbd_test.dart` (append)

**Interfaces:**
- Produces: `const Map<String, String> _kL5xFbdTypeAliases`, `const Map<String, Map<String, String>> _kL5xFbdPinAliases`, `const Set<String> _kL5xFbdBitFunctions`.
- Produces: `String? _aliasL5xFbdPin(String? abType, String? pin)` (returns `pin` verbatim when there is no mapping, `null` when `pin` is null). There is deliberately NO `_isAliasedAbBlock` helper: the `EnableIn`/`EnableOut` heads-up fires for ANY recorded block endpoint (Recorded resolution 3), so no such predicate is needed and an unused private function would fail `flutter analyze`.

- [ ] **Step 1: Write the failing tests**

Append to `mobile/test/import/l5x_parser_fbd_test.dart`, inside `void main() {`:

```dart
  test('type + pin aliasing turns a Rockwell compare into a real IEC network', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Level" X="0" Y="0"/>
        <IRef ID="1" Operand="50" X="0" Y="40"/>
        <Block ID="2" Type="GRT" Operand="Grt_01" X="100" Y="0"/>
        <ORef ID="3" Operand="HiAlarm" X="200" Y="0"/>
        <Wire FromID="0" ToID="2" ToParam="SourceA"/>
        <Wire FromID="1" ToID="2" ToParam="SourceB"/>
        <Wire FromID="2" FromParam="Dest" ToID="3" ToParam="IN"/>
      </Sheet>'''));

    expect(_node(g, 2).attributes['typeName'], 'GT'); // GRT -> GT
    expect(g.connections[0].toPin, 'IN1'); // SourceA -> IN1
    expect(g.connections[1].toPin, 'IN2'); // SourceB -> IN2
    expect(g.connections[2].fromPin, 'OUT'); // Dest -> OUT

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);
  });

  test('BAND/BNOT (real <Function> elements) alias their type and In<k>/Out pins', () {
    // Bit functions are stateless, so real exports carry them as <Function>
    // elements with no Operand - the element kind this test deliberately uses.
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="A" X="0" Y="0"/>
        <IRef ID="1" Operand="B" X="0" Y="40"/>
        <Function ID="2" Type="BAND" X="100" Y="0"/>
        <Function ID="3" Type="BNOT" X="200" Y="0"/>
        <ORef ID="4" Operand="Out" X="300" Y="0"/>
        <Wire FromID="0" ToID="2" ToParam="In1"/>
        <Wire FromID="1" ToID="2" ToParam="In2"/>
        <Wire FromID="2" FromParam="Out" ToID="3" ToParam="In"/>
        <Wire FromID="3" FromParam="Out" ToID="4" ToParam="IN"/>
      </Sheet>'''));

    expect(_node(g, 2).attributes['typeName'], 'AND');
    expect(_node(g, 3).attributes['typeName'], 'NOT');
    expect(g.connections[0].toPin, 'IN1');
    expect(g.connections[1].toPin, 'IN2');
    expect(g.connections[2].fromPin, 'OUT');
    expect(g.connections[2].toPin, 'IN');

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
  });

  test('an AddOnInstruction Name is never aliased, though the same word IS on a Function', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <AddOnInstruction ID="0" Name="BAND" Operand="Inst1"/>
        <Function ID="1" Type="BAND"/>
      </Sheet>'''));
    // Discriminating pair: the identical word aliases on a <Function> and does
    // NOT on an <AddOnInstruction>, so this cannot pass vacuously.
    expect(_node(g, 0).attributes['typeName'], 'BAND');
    expect(_node(g, 1).attributes['typeName'], 'AND');
  });

  test('SEL/OSRI pins alias instead of dying uninventoried in _assertPin', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Pick" X="0" Y="0"/>
        <IRef ID="1" Operand="Lo" X="0" Y="40"/>
        <IRef ID="2" Operand="Hi" X="0" Y="80"/>
        <Block ID="3" Type="SEL" Operand="Sel_01" X="100" Y="0"/>
        <ORef ID="4" Operand="Picked" X="200" Y="0"/>
        <Wire FromID="0" ToID="3" ToParam="SelectorIn"/>
        <Wire FromID="1" ToID="3" ToParam="In1"/>
        <Wire FromID="2" ToID="3" ToParam="In2"/>
        <Wire FromID="3" FromParam="Out" ToID="4" ToParam="IN"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="0" Operand="Pulse" X="0" Y="0"/>
        <Block ID="1" Type="OSRI" Operand="Osr_01" X="100" Y="0"/>
        <ORef ID="2" Operand="Edge" X="200" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="InputBit"/>
        <Wire FromID="1" FromParam="OutputBit" ToID="2" ToParam="IN"/>
      </Sheet>'''));

    // SEL keeps its type (it IS an IEC built-in name) but its pins are
    // Rockwell's: SelectorIn -> G, In1 -> IN0 (selector false), In2 -> IN1,
    // Out -> OUT. Without the map these die in _assertPin UNINVENTORIED.
    expect(_node(g, 3).attributes['typeName'], 'SEL');
    expect(g.connections[0].toPin, 'G');
    expect(g.connections[1].toPin, 'IN0');
    expect(g.connections[2].toPin, 'IN1');
    expect(g.connections[3].fromPin, 'OUT');
    // OSRI -> R_TRIG with InputBit -> CLK, OutputBit -> Q.
    final osri = g.nodes.firstWhere((n) => n.attributes['abOriginal'] == 'OSRI');
    expect(osri.attributes['typeName'], 'R_TRIG');
    expect(g.connections[4].toPin, 'CLK');
    expect(g.connections[5].fromPin, 'Q');

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 2);
    expect(tr.stubbedNetworkCount, 0);
  });

  test('TONR maps to TON with abOriginal + a prominent verify warning', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Run" X="0" Y="0"/>
        <IRef ID="1" Operand="1000" X="0" Y="40"/>
        <Block ID="2" Type="TONR" Operand="T1" X="100" Y="0"/>
        <ORef ID="3" Operand="Done" X="200" Y="0"/>
        <Wire FromID="0" ToID="2" ToParam="TimerEnable"/>
        <Wire FromID="1" ToID="2" ToParam="PRE"/>
        <Wire FromID="2" FromParam="DN" ToID="3" ToParam="IN"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(_node(g, 2).attributes['typeName'], 'TON');
    expect(_node(g, 2).attributes['abOriginal'], 'TONR');
    expect(g.connections[0].toPin, 'IN'); // TimerEnable -> IN
    expect(g.connections[1].toPin, 'PT'); // PRE -> PT
    expect(g.connections[2].fromPin, 'Q'); // DN -> Q

    final verify =
        ir.warnings.where((w) => w.message.contains('verify')).toList();
    expect(verify, hasLength(1));
    expect(verify.single.severity, WarningSeverity.warning); // NOT info
    expect(verify.single.message, contains('Routine "Prog_Main"'));
    expect(verify.single.message, contains('TONR'));

    // translateFbdBody ignores the unknown `abOriginal` key.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
  });

  test('a wired TONR Reset pin stubs that network (unresolved-pin)', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Run" X="0" Y="0"/>
        <IRef ID="1" Operand="Rst" X="0" Y="40"/>
        <Block ID="2" Type="TONR" Operand="T1" X="100" Y="0"/>
        <Wire FromID="0" ToID="2" ToParam="TimerEnable"/>
        <Wire FromID="1" ToID="2" ToParam="Reset"/>
      </Sheet>'''));

    expect(g.connections[1].toPin, 'Reset'); // passes through verbatim
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unresolved-pin'], 1);
  });

  test('a WIRED EnableIn on a built-in warns and stubs; unwired costs nothing', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Gate" X="0" Y="0"/>
        <IRef ID="1" Operand="A" X="0" Y="40"/>
        <IRef ID="2" Operand="B" X="0" Y="80"/>
        <Function ID="3" Type="BAND" X="100" Y="0"/>
        <Wire FromID="0" ToID="3" ToParam="EnableIn"/>
        <Wire FromID="1" ToID="3" ToParam="In1"/>
        <Wire FromID="2" ToID="3" ToParam="In2"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.connections[0].toPin, 'EnableIn'); // left unaliased
    final w = ir.warnings
        .where((x) => x.message.contains('EnableIn/EnableOut wired'))
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.info);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unresolved-pin'], 1);

    // The unwired case (the common one) produces no node, warning or stub.
    final clean = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="A" X="0" Y="0"/>
        <IRef ID="1" Operand="B" X="0" Y="40"/>
        <Function ID="2" Type="BAND" X="100" Y="0"/>
        <ORef ID="3" Operand="Out" X="200" Y="0"/>
        <Wire FromID="0" ToID="2" ToParam="In1"/>
        <Wire FromID="1" ToID="2" ToParam="In2"/>
        <Wire FromID="2" FromParam="Out" ToID="3" ToParam="IN"/>
      </Sheet>''');
    expect(
        clean.warnings.any((x) => x.message.contains('EnableIn/EnableOut wired')),
        isFalse);
    expect(translateFbdBody(_graph(clean), pouName: 'Prog_Main')
        .translatedNetworkCount, 1);
  });

  test('a wired EnableIn on an AddOnInstruction call warns too (the common case)', () {
    // The most common real occurrence of a wired EnableIn is an AOI call, not
    // an aliased built-in: for an FBD-Logic AOI, EnableIn/EnableOut are
    // INTERNAL vars and therefore not pins, so the network stubs identically.
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Gate" X="0" Y="0"/>
        <AddOnInstruction ID="1" Name="Ramp" Operand="R1" X="100" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="EnableIn"/>
      </Sheet>''');
    final w = ir.warnings
        .where((x) => x.message.contains('EnableIn/EnableOut wired'))
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.info);
    expect(w.single.message, contains('Ramp'));
  });

  test('an unmapped Rockwell block stubs and is inventoried, while a mapped one aliases', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Raw" X="0" Y="0"/>
        <Block ID="1" Type="SCL" Operand="S1" X="100" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="In"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="0" Operand="A" X="0" Y="0"/>
        <IRef ID="1" Operand="B" X="0" Y="40"/>
        <Block ID="2" Type="GRT" Operand="Grt_02" X="100" Y="0"/>
        <ORef ID="3" Operand="Hi" X="200" Y="0"/>
        <Wire FromID="0" ToID="2" ToParam="SourceA"/>
        <Wire FromID="1" ToID="2" ToParam="SourceB"/>
        <Wire FromID="2" FromParam="Dest" ToID="3" ToParam="IN"/>
      </Sheet>'''));

    // Discriminating pair in ONE routine: the aliasable GRT is rewritten, the
    // unmapped SCL is not, so "unchanged" cannot pass vacuously.
    expect(_node(g, 1).attributes['typeName'], 'SCL');
    expect(g.nodes.any((n) => n.attributes['typeName'] == 'GT'), isTrue);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1); // the GRT network
    expect(tr.stubReasons['unsupported-block'], 1); // the SCL network
    expect(tr.unsupportedBlockTypes, contains('SCL'));
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_fbd_test.dart`

Expected: FAIL - `typeName` is still `'GRT'` and `toPin` still `'SourceA'`.

- [ ] **Step 3: Add the alias tables and helpers**

In `mobile/lib/import/l5x_parser.dart`, add above `_l5xFbdSheets`:

```dart
/// Rockwell FBD block/function mnemonics that alias onto an IEC built-in.
/// Applied to `<Block Type=>` / `<Function Type=>` only: an
/// `<AddOnInstruction Name=>` is a user type name and is never aliased.
/// `TONR`/`TOFR` are BEST-EFFORT (retentive accumulation and the `Reset` pin
/// are not modeled) and carry an extra verify warning.
const Map<String, String> _kL5xFbdTypeAliases = {
  'EQU': 'EQ',
  'NEQ': 'NE',
  'GEQ': 'GE',
  'LEQ': 'LE',
  'GRT': 'GT',
  'LES': 'LT',
  'BAND': 'AND',
  'BOR': 'OR',
  'BNOT': 'NOT',
  'TONR': 'TON',
  'TOFR': 'TOF',
  // Logix one-shots map exactly onto the IEC edge detectors.
  'OSRI': 'R_TRIG',
  'OSFI': 'F_TRIG',
};

/// Pin renames keyed by the ROCKWELL (pre-alias) type name. Rockwell FBD wires
/// carry `SourceA`/`SourceB`/`Dest` (math + compares) and `In<k>`/`Out` (bit
/// functions); `_assertPin` compares literally against the IEC registry
/// (`fbd_pins.dart`), so without these a type-only alias would make EVERY
/// math/compare network stub with `unresolved-pin` (spec resolution R1).
/// Math types are listed even though their TYPE is unchanged.
const Map<String, Map<String, String>> _kL5xFbdPinAliases = {
  'ADD': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'SUB': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'MUL': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'DIV': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'EQU': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'NEQ': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'GEQ': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'LEQ': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'GRT': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'LES': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'BNOT': {'In': 'IN', 'Out': 'OUT'},
  'TONR': {'TimerEnable': 'IN', 'PRE': 'PT', 'Preset': 'PT', 'DN': 'Q', 'ACC': 'ET'},
  'TOFR': {'TimerEnable': 'IN', 'PRE': 'PT', 'Preset': 'PT', 'DN': 'Q', 'ACC': 'ET'},
  // SEL and CTUD keep their IEC-identical TYPE names, so they pass
  // `kFbdBuiltinBlockTypes` and would otherwise die in `_assertPin` with
  // `unresolved-pin` and NO inventory entry. IEC SEL is
  // `OUT = G ? IN1 : IN0`; Logix SEL is `Out = SelectorIn ? In2 : In1`.
  'SEL': {'SelectorIn': 'G', 'In1': 'IN0', 'In2': 'IN1', 'Out': 'OUT'},
  // CTUD is BEST-EFFORT (like TONR/TOFR): the mapped pins are the ones whose
  // meaning is unambiguous; anything else passes through and stubs.
  'CTUD': {
    'CUEnable': 'CU',
    'CDEnable': 'CD',
    'Reset': 'R',
    'Load': 'LD',
    'PRE': 'PV',
    'ACC': 'CV',
    'DN': 'QU',
  },
  'OSRI': {'InputBit': 'CLK', 'OutputBit': 'Q'},
  'OSFI': {'InputBit': 'CLK', 'OutputBit': 'Q'},
};

/// Extensible bit functions whose pins are `In<k>`/`Out` (mapped by regex to
/// `IN<k>`/`OUT`).
const Set<String> _kL5xFbdBitFunctions = {'BAND', 'BOR'};

final RegExp _kL5xFbdBitFunctionPin = RegExp(r'^In(\d+)$');

/// Rewrites a Rockwell pin name to its IEC equivalent, given the endpoint
/// node's ROCKWELL type. Anything unmapped (including `EnableIn`/`EnableOut`)
/// passes through VERBATIM and, if it is not a real IEC pin, `_assertPin`
/// stubs that network — faithful-or-stub preserved.
String? _aliasL5xFbdPin(String? abType, String? pin) {
  if (pin == null || pin.isEmpty || abType == null) {
    return pin;
  }
  final mapped = _kL5xFbdPinAliases[abType]?[pin];
  if (mapped != null) {
    return mapped;
  }
  if (_kL5xFbdBitFunctions.contains(abType)) {
    if (pin == 'Out') return 'OUT';
    final m = _kL5xFbdBitFunctionPin.firstMatch(pin);
    if (m != null) return 'IN${m.group(1)}';
  }
  return pin;
}
```

- [ ] **Step 4: Apply the aliases in `_l5xFbdBody`**

In `_l5xFbdBody`, add three locals next to the other merge state:

```dart
  // Assigned localId -> the node's ROCKWELL type (pre-alias), so pass 2 can
  // alias each wire's pins by its endpoint's source type.
  final abTypeById = <int, String>{};
  final verifyWarned = <String>{};
  final enableWarned = <String>{};
```

Replace the `case 'Block':` and `case 'Function':` arms with (both share the aliasing; `Function` still emits no `instanceName`):

```dart
        case 'Block':
        case 'Function':
          {
            elementType = 'block';
            final abType = (el.getAttribute('Type') ?? '').trim();
            final aliased = _kL5xFbdTypeAliases[abType] ?? abType;
            attrs['typeName'] = aliased;
            abTypeById[localId] = abType;
            if (_kL5xFbdBestEffortTypes.contains(abType)) {
              // IR-only breadcrumb: translateFbdBody copies attributes through
              // and only reads the keys it knows, so an unknown key is
              // silently ignored (there is no native field to carry it).
              attrs['abOriginal'] = abType;
              if (verifyWarned.add(abType)) {
                warnings.add(ImportWarning(
                    severity: WarningSeverity.warning,
                    message: '$ownerLabel: Rockwell $abType mapped best-effort '
                        'to the IEC $aliased block — behaviour differs '
                        '(retentive/reset, extra pins); verify.'));
              }
            }
            if (tag == 'Block') {
              final operand = (el.getAttribute('Operand') ?? '').trim();
              if (operand.isNotEmpty) attrs['instanceName'] = operand;
            }
            break;
          }
```

Add the best-effort set next to the alias tables (Step 3):

```dart
/// Aliases whose IEC target is only an APPROXIMATION of the Rockwell block, so
/// each carries an `abOriginal` breadcrumb and a prominent verify warning.
/// (`TONR`/`TOFR` lose retentive accumulation and the `Reset` pin;
/// `OSRI`/`OSFI` lose Logix's separate storage/output bits.)
const Set<String> _kL5xFbdBestEffortTypes = {'TONR', 'TOFR', 'OSRI', 'OSFI'};
```

Record the raw type for `AddOnInstruction` nodes too, so the `EnableIn`/`EnableOut` heads-up below covers AOI calls (the most common real occurrence). In that case arm, after `attrs['typeName'] = ...`, add:

```dart
            abTypeById[localId] = attrs['typeName']!; // never aliased
```

In pass 2, replace the `conns.add(...)` with the aliasing version plus the `EnableIn`/`EnableOut` heads-up:

```dart
      final rawFromPin = el.getAttribute('FromParam');
      final rawToPin = el.getAttribute('ToParam');
      final fromId = resolveEndpoint(el.getAttribute('FromID'));
      final toId = resolveEndpoint(el.getAttribute('ToID'));

      // Logix `EnableIn`/`EnableOut` are a rung-condition concept with no pin
      // on the IEC block an aliased type maps to — and none on an imported AOI
      // either, where they are INTERNAL vars (see l5x_parser's AOI arm). A
      // WIRED one is left unaliased and follows the existing unmapped-pin path
      // (the network stubs with `unresolved-pin`); this heads-up just makes
      // that a named, diagnosable condition instead of a generic pin stub. An
      // UNWIRED one never reaches here. The gate is simply "the endpoint is a
      // block": narrowing it to aliased built-ins would miss the AOI case.
      for (final e in [
        MapEntry(abTypeById[fromId], rawFromPin),
        MapEntry(abTypeById[toId], rawToPin),
      ]) {
        final t = e.key;
        final pin = e.value;
        if (t == null || pin == null) continue;
        if (pin != 'EnableIn' && pin != 'EnableOut') continue;
        if (enableWarned.add('$t|$pin')) {
          warnings.add(ImportWarning(
              severity: WarningSeverity.info,
              message: '$ownerLabel: EnableIn/EnableOut wired on "$t" — the '
                  'block it maps to has no such pin, so that network is '
                  'not translated.'));
        }
      }

      conns.add(IrConnection(
        fromLocalId: fromId,
        fromPin: _aliasL5xFbdPin(abTypeById[fromId], rawFromPin),
        toLocalId: toId,
        toPin: _aliasL5xFbdPin(abTypeById[toId], rawToPin),
      ));
```

- [ ] **Step 5: Run the tests to verify they pass**

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_fbd_test.dart`

Expected: all 25 tests pass.

- [ ] **Step 6: Verify the whole suite and the analyzer**

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze`.
Expected: `All tests passed!` and `No issues found!`.

- [ ] **Step 7: Commit**

```
git add -A && git commit -m "feat(l5x): alias Rockwell FBD block types and pin names to IEC"
```

---

### Task 7: AOI FBD logic -> FBD-bodied `FbDefinition` (the join)

**Model:** opus · **Effort:** high

Implements spec §7 plus resolutions R2 (dialect marker) and R3 (nested-FB instance tags live inside the AOI struct). This is where the runtime half and the parser half join: the mapper compiles an AOI's FBD `Logic` at import and the scoped executor runs it per instance.

**Files:**
- Modify: `mobile/lib/import/l5x_parser.dart` (`_l5xAois`: `keepsEnableParams`, FBD body arm; `parseL5x` sets the dialect)
- Modify: `mobile/lib/import/import_ir.dart` (`ImportedProject.dialect`)
- Modify: `mobile/lib/import/fb_import.dart` (`dialect` param, FBD arm, R3 vars, FBD counters)
- Modify: `mobile/lib/import/ir_to_project.dart` (pass `ir.dialect`, seed the FBD counters)
- Test: `mobile/test/import/fb_import_fbd_test.dart` (new file), `mobile/test/import/l5x_parser_test.dart:163-184` (REWRITE the existing test)

**Interfaces:**
- Consumes: `GraphBody _l5xFbdBody(...)` (Tasks 4-6), `FbdTranslation translateFbdBody(GraphBody body, {required String pouName, Map<String, FbDefinition> fbRegistry, Map<String, String> fbRenameMap})` with fields `blocks`, `wires`, `networks`, `instanceTags`, `translatedNetworkCount`, `stubbedNetworkCount`, `unsupportedBlockTypes`, `stubReasons`, `warnings`.
- Produces: `class ImportedProject { ...; final ImportDialect dialect; ImportedProject({..., this.dialect = ImportDialect.plcOpen}); }`.
- Produces: `FbImportResult mapImportedFbs(List<ImportedPou> pous, {required List<PlcStructDef> structs, required Set<String> dutNames, required List<ImportWarning> warnings, ImportDialect dialect = ImportDialect.plcOpen})`.
- Produces: `FbImportResult` gains `int translatedFbdNetworkCount`, `int stubbedFbdNetworkCount`, `Set<String> unsupportedFbdBlockTypes`, `Map<String, int> fbdStubReasons` (all default-safe).

- [ ] **Step 1: Write the failing mapper tests**

Create `mobile/test/import/fb_import_fbd_test.dart`:

```dart
// mapImportedFbs' FBD arm: an L5X FBD-Logic AOI compiles at import into an
// FBD-bodied FbDefinition, against the FB registry built SO FAR. PLCopen FBD
// functionBlock POUs keep the old warning path (dialect gate, spec R2).
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fb_import.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

ImportedVar _v(String name, String type, VarScope scope) =>
    ImportedVar(name: name, baseType: type, scope: scope);

/// TAG_INPUT('In') -> NOT -> TAG_OUTPUT('Out') as neutral IR.
GraphBody _notBody() => GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'inVariable', x: 0, y: 0,
          attributes: {'variable': 'In'}),
      IrGraphNode(localId: 1, elementType: 'block', x: 50, y: 0,
          attributes: {'typeName': 'NOT'}),
      IrGraphNode(localId: 2, elementType: 'outVariable', x: 100, y: 0,
          attributes: {'variable': 'Out'}),
    ], connections: [
      IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'IN'),
      IrConnection(fromLocalId: 1, fromPin: 'OUT', toLocalId: 2, toPin: 'IN'),
    ]);

ImportedPou _fbdAoi(String name, GraphBody body, {List<ImportedVar>? vars}) =>
    ImportedPou(
      name: name,
      kind: PouKind.functionBlock,
      lang: PouLanguage.fbd,
      localVars: vars ??
          [
            _v('In', 'BOOL', VarScope.input),
            _v('Out', 'BOOL', VarScope.output),
          ],
      body: body,
    );

FbImportResult _map(List<ImportedPou> pous, List<ImportWarning> warnings,
        {ImportDialect dialect = ImportDialect.l5x}) =>
    mapImportedFbs(pous,
        structs: const [], dutNames: const {}, warnings: warnings,
        dialect: dialect);

void main() {
  test('an L5X FBD AOI becomes an FBD-bodied FbDefinition', () {
    final warnings = <ImportWarning>[];
    final res = _map([_fbdAoi('Inverter', _notBody())], warnings);

    final def = res.defs.single;
    expect(def.name, 'Inverter');
    expect(def.stSource, '');
    expect(def.ladderRungs, isEmpty);
    expect(def.fbdBlocks.map((b) => b.type), ['TAG_INPUT', 'NOT', 'TAG_OUTPUT']);
    expect(def.fbdWires, hasLength(2));
    expect(def.fbdNetworks, hasLength(1));
    expect(res.translatedFbdNetworkCount, 1);
    expect(res.stubbedFbdNetworkCount, 0);
    expect(warnings.any((w) => w.message.contains('not imported')), isFalse);
  });

  test('a PLCopen FBD functionBlock keeps the unchanged warning path', () {
    final warnings = <ImportWarning>[];
    final res = _map([_fbdAoi('PlcopenFb', _notBody())], warnings,
        dialect: ImportDialect.plcOpen);

    expect(res.defs, isEmpty);
    final w = warnings.single;
    expect(w.severity, WarningSeverity.warning);
    expect(w.message, contains('Function block "PlcopenFb" has a graphical body'));
    expect(w.message, contains('(fbd)'));
    expect(w.message, contains('not imported'));
    expect(w.message, contains('3 elements captured'));
  });

  test('zero translated networks -> interface-only + a warning naming the AOI', () {
    final warnings = <ImportWarning>[];
    final bad = GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'block', attributes: {'typeName': 'SCL'}),
    ], connections: const []);
    final res = _map([_fbdAoi('Scaler', bad)], warnings);

    final def = res.defs.single;
    expect(def.fbdBlocks, isEmpty);
    expect(def.vars.map((v) => v.name), ['In', 'Out']); // interface survives
    expect(
        warnings.any((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('Scaler') &&
            w.message.contains('logic not translated')),
        isTrue);
    expect(res.unsupportedFbdBlockTypes, contains('SCL'));
    expect(res.fbdStubReasons['unsupported-block'], 1);
  });

  test('a ZERO-NODE FBD body is silent (nothing to fail at)', () {
    final warnings = <ImportWarning>[];
    final res = _map([
      _fbdAoi('Empty', GraphBody(nodes: const [], connections: const [])),
    ], warnings);

    expect(res.defs.single.fbdBlocks, isEmpty);
    expect(warnings.any((w) => w.message.contains('Empty')), isFalse);
  });

  test('registry-so-far: an AOI defined EARLIER routes, a LATER one stubs', () {
    final warnings = <ImportWarning>[];
    GraphBody callBody(String type) => GraphBody(nodes: [
          IrGraphNode(localId: 0, elementType: 'inVariable',
              attributes: {'variable': 'In'}),
          IrGraphNode(localId: 1, elementType: 'block',
              attributes: {'typeName': type, 'instanceName': 'Nested'}),
          IrGraphNode(localId: 2, elementType: 'outVariable',
              attributes: {'variable': 'Out'}),
        ], connections: [
          IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
          IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
        ]);

    final res = _map([
      ImportedPou(name: 'Leaf', kind: PouKind.functionBlock,
          lang: PouLanguage.st,
          localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
          body: TextBody('Out := In;')),
      _fbdAoi('UsesEarlier', callBody('Leaf')),
      _fbdAoi('UsesLater', callBody('Future')),
      ImportedPou(name: 'Future', kind: PouKind.functionBlock,
          lang: PouLanguage.st,
          localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
          body: TextBody('Out := In;')),
    ], warnings);

    final earlier = res.defs.firstWhere((d) => d.name == 'UsesEarlier');
    expect(earlier.fbdBlocks.map((b) => b.type), contains('Leaf'));

    final later = res.defs.firstWhere((d) => d.name == 'UsesLater');
    expect(later.fbdBlocks, isEmpty); // forward reference stubs
    expect(res.unsupportedFbdBlockTypes, contains('Future'));
  });

  test('R3: a nested instance reuses a matching FbVar, else synthesizes one', () {
    GraphBody nested() => GraphBody(nodes: [
          IrGraphNode(localId: 0, elementType: 'inVariable',
              attributes: {'variable': 'In'}),
          IrGraphNode(localId: 1, elementType: 'block',
              attributes: {'typeName': 'Leaf', 'instanceName': 'Nested'}),
          IrGraphNode(localId: 2, elementType: 'outVariable',
              attributes: {'variable': 'Out'}),
        ], connections: [
          IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
          IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
        ]);
    final leaf = ImportedPou(name: 'Leaf', kind: PouKind.functionBlock,
        lang: PouLanguage.st,
        localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
        body: TextBody('Out := In;'));

    // (a) The AOI already declares a LocalTag typed as the nested AOI.
    final warnA = <ImportWarning>[];
    final resA = _map([
      leaf,
      _fbdAoi('OuterA', nested(), vars: [
        _v('In', 'BOOL', VarScope.input),
        _v('Out', 'BOOL', VarScope.output),
        _v('Nested', 'Leaf', VarScope.local),
      ]),
    ], warnA);
    final a = resA.defs.firstWhere((d) => d.name == 'OuterA');
    expect(a.vars.where((v) => v.name == 'Nested'), hasLength(1)); // no dupe
    expect(a.vars.firstWhere((v) => v.name == 'Nested').dataType, 'Leaf');

    // (b) No such var: one is synthesized as an INTERNAL var so the nested
    // instance lives inside the AOI struct (per-instance state).
    final warnB = <ImportWarning>[];
    final resB = _map([leaf, _fbdAoi('OuterB', nested())], warnB);
    final b = resB.defs.firstWhere((d) => d.name == 'OuterB');
    final syn = b.vars.firstWhere((v) => v.name == 'Nested');
    expect(syn.dataType, 'Leaf');
    expect(syn.direction, FbVarDir.internal);
    expect(syn.initialValue, isA<Map>());
  });

  test('R3: a synthesized nested-instance name is sanitized and retargeted', () {
    final leaf = ImportedPou(name: 'Leaf', kind: PouKind.functionBlock,
        lang: PouLanguage.st,
        localVars: [_v('In', 'BOOL', VarScope.input), _v('Out', 'BOOL', VarScope.output)],
        body: TextBody('Out := In;'));
    // A Logix Operand is not bound by this app's identifier rules.
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 0, elementType: 'inVariable',
          attributes: {'variable': 'In'}),
      IrGraphNode(localId: 1, elementType: 'block',
          attributes: {'typeName': 'Leaf', 'instanceName': 'Pump-1'}),
      IrGraphNode(localId: 2, elementType: 'outVariable',
          attributes: {'variable': 'Out'}),
    ], connections: [
      IrConnection(fromLocalId: 0, fromPin: 'OUT', toLocalId: 1, toPin: 'In'),
      IrConnection(fromLocalId: 1, fromPin: 'Out', toLocalId: 2, toPin: 'IN'),
    ]);

    final warnings = <ImportWarning>[];
    final res = _map([leaf, _fbdAoi('Outer', body)], warnings);
    final outer = res.defs.firstWhere((d) => d.name == 'Outer');

    // NOTE: translateFbdBody's own `_fbInstanceName` rejects 'Pump-1' as an
    // identifier and falls back to '<pouName>_fb<localId>'; whichever name
    // arrives, the var and the block binding must AGREE and must be a legal
    // identifier, or the nested instance is unaddressable at runtime.
    final callBlock = outer.fbdBlocks.firstWhere((b) => b.type == 'Leaf');
    expect(RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(callBlock.tagBinding),
        isTrue);
    expect(outer.vars.map((v) => v.name), contains(callBlock.tagBinding));
    expect(
        outer.vars.firstWhere((v) => v.name == callBlock.tagBinding).dataType,
        'Leaf');
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

From `mobile/`: `/c/flutter/bin/flutter test test/import/fb_import_fbd_test.dart`

Expected: FAIL - `No named parameter with the name 'dialect'`.

- [ ] **Step 3: Add the dialect marker to the IR**

In `mobile/lib/import/import_ir.dart`, replace the `ImportedProject` class:

```dart
class ImportedProject {
  final String name;
  final List<ImportedType> types;
  final List<ImportedVar> globalVars;
  final List<ImportedPou> pous;
  final List<ImportWarning> warnings;

  /// Which vendor parser produced this IR. Language mappers use it where a
  /// dialect-specific rule applies — today only `mapImportedFbs`' FBD-bodied
  /// AOI arm, which must NOT change the PLCopen path (a PLCopen `functionBlock`
  /// FBD POU is otherwise indistinguishable from an L5X FBD AOI by
  /// kind/lang/body type alone). Defaults to `plcOpen`, so every existing
  /// construction site compiles unchanged.
  final ImportDialect dialect;

  ImportedProject({required this.name, required this.types,
      required this.globalVars, required this.pous, required this.warnings,
      this.dialect = ImportDialect.plcOpen});
}
```

In `mobile/lib/import/l5x_parser.dart`, `parseL5x`'s return (line 64):

```dart
  return ImportedProject(
      name: name, types: types, globalVars: globalVars, pous: pous,
      warnings: warnings, dialect: ImportDialect.l5x);
```

- [ ] **Step 4: Add the FBD arm to `mapImportedFbs`**

In `mobile/lib/import/fb_import.dart`:

1. Add the import:

```dart
import 'fbd_translate.dart';
```

2. Extend `FbImportResult` (fields, doc, constructor):

```dart
/// (The existing FbImportResult doc-comment stays verbatim; append this
/// paragraph to it.)
///
/// The `*Fbd*` counters cover FBD-bodied FB (Rockwell FBD-Logic AOI) bodies
/// translated here. `mapImportedProject` folds them into the EXISTING FBD
/// report fields — AOI-body networks are FBD networks, so no new preview UI is
/// needed.
class FbImportResult {
  final List<FbDefinition> defs;
  final Map<String, FbDefinition> registry;
  final Map<String, String> renameMap;
  final int translatedRllRungCount;
  final int stubbedRllRungCount;
  final Set<String> unsupportedRllInstructions;
  final Map<String, int> rllStubReasons;
  final int translatedFbdNetworkCount;
  final int stubbedFbdNetworkCount;
  final Set<String> unsupportedFbdBlockTypes;
  final Map<String, int> fbdStubReasons;
  FbImportResult(
    this.defs,
    this.registry,
    this.renameMap, {
    this.translatedRllRungCount = 0,
    this.stubbedRllRungCount = 0,
    this.unsupportedRllInstructions = const {},
    this.rllStubReasons = const {},
    this.translatedFbdNetworkCount = 0,
    this.stubbedFbdNetworkCount = 0,
    this.unsupportedFbdBlockTypes = const {},
    this.fbdStubReasons = const {},
  });
}
```

3. Signature + accumulators + entry gate. Replace the `mapImportedFbs` doc-comment, signature and the guard (lines 49-87) with:

```dart
/// Maps the ST-bodied, LADDER-bodied and (L5X only) FBD-bodied `functionBlock`
/// POUs of [pous] to `FbDefinition`s. A `TextBody` becomes the FB's
/// `stSource`; a `NeutralLadderBody` (a Rockwell RLL-Logic AOI) is compiled by
/// [compileRllRungs] into the FB's native `ladderRungs`; a `GraphBody` on an
/// `fbd` POU is translated by [translateFbdBody] into the FB's native
/// `fbdBlocks`/`fbdWires`/`fbdNetworks` — but ONLY when [dialect] is
/// `ImportDialect.l5x`. A PLCopen FBD `functionBlock` keeps the existing
/// "graphical body — not imported" warning byte-for-byte, pending
/// PLCopen-specific validation (see docs/DEFERRED.md). Other graphical bodies
/// are still skipped with that warning. Names are sanitized and
/// collision-resolved against [structs] + the FBs built so far (via
/// `fbNameValidationError`), avoiding reserved block types, builtin
/// composites, struct names, and `kSystemTagName`. Pure; never throws.
FbImportResult mapImportedFbs(
  List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
  ImportDialect dialect = ImportDialect.plcOpen,
}) {
  final defs = <FbDefinition>[];
  final registry = <String, FbDefinition>{};
  final renameMap = <String, String>{};
  var translatedRllRungCount = 0;
  var stubbedRllRungCount = 0;
  final unsupportedRllInstructions = <String>{};
  final rllStubReasons = <String, int>{};
  var translatedFbdNetworkCount = 0;
  var stubbedFbdNetworkCount = 0;
  final unsupportedFbdBlockTypes = <String>{};
  final fbdStubReasons = <String, int>{};
  // Growing scratch: structs known + FBs built so far, so name collisions
  // against earlier-imported FBs are caught. fbDefinitions is a mutable list.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], tags: [],
      structDefs: structs, fbDefinitions: defs);

  for (final pou in pous) {
    if (pou.kind != PouKind.functionBlock) continue;
    final body = pou.body;
    // Only an L5X-parser-produced FBD AOI enters the FBD arm below.
    final isFbdAoiBody = body is GraphBody &&
        pou.lang == PouLanguage.fbd &&
        dialect == ImportDialect.l5x;
    if (body is! TextBody && body is! NeutralLadderBody && !isFbdAoiBody) {
      final n = body is GraphBody ? body.nodes.length : 0;
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'Function block "${pou.name}" has a graphical body '
              '(${pou.lang.name}) — not imported (ST-bodied FBs only). '
              '$n elements captured.'));
      continue;
    }
```

4. Body construction. Replace the `final FbDefinition def; if (body is NeutralLadderBody) { ... } else { ... }` chain's `else` (line 171-174) so the FBD arm sits between them:

```dart
    } else if (body is GraphBody) {
      // Reachable only when `isFbdAoiBody` (the guard above rejects every
      // other GraphBody). Translated against the registry/renameMap built SO
      // FAR: an AOI sheet calling an AOI defined EARLIER routes to a real
      // FB-instance block; one defined later stubs (`unsupported-block`,
      // inventoried) — the same documented ordering limit the ladder arm has.
      final tr = translateFbdBody(body, pouName: 'AOI $name',
          fbRegistry: registry, fbRenameMap: renameMap);
      warnings.addAll(tr.warnings);
      translatedFbdNetworkCount += tr.translatedNetworkCount;
      stubbedFbdNetworkCount += tr.stubbedNetworkCount;
      unsupportedFbdBlockTypes.addAll(tr.unsupportedBlockTypes);
      tr.stubReasons.forEach((k, v) =>
          fbdStubReasons[k] = (fbdStubReasons[k] ?? 0) + v);
      if (tr.translatedNetworkCount > 0) {
        // Nested-FB instance tags (spec R3): `tr.instanceTags` are PROJECT
        // tags this mapper cannot add, and a shared global instance would make
        // every AOI instance share nested state. Consume them locally instead:
        // reuse a same-named FbVar when the AOI already declares one (its
        // LocalTag typed as the nested AOI), else synthesize an internal var.
        // Either way the nested instance lives INSIDE the AOI struct, so
        // LdScope rewrites the call block's tagBinding to
        // `<instance>.<localTag>` and each instance gets its own nested state.
        for (final it in tr.instanceTags) {
          final original = it.name;
          // The instance name came from the L5X `Operand` attribute, which is
          // NOT constrained to this app's identifier rules. Every other import
          // path sanitizes before creating a member (`_sanitize` here, and
          // `_sanitizeIdentifier` in ir_to_project for project tags), so this
          // one must too: an unsanitized member name would be unaddressable by
          // `readPath`/`writePath` and by the FB editor.
          var vname = _sanitize(original);
          if (vname != original) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Function block "$name": nested instance "$original" '
                    'renamed to "$vname" (identifier rules).'));
          }
          FbVar? existing;
          for (final v in vars) {
            if (v.name == vname) {
              existing = v;
              break;
            }
          }
          if (existing != null && existing.dataType != it.dataType) {
            // The name collides with an UNRELATED var of another type (often a
            // consequence of the sanitize above). Dedupe rather than reuse it:
            // reusing would point the call block at a member of the wrong type.
            final base = vname;
            var i = 2;
            while (vars.any((v) => v.name == '${base}_$i')) {
              i++;
            }
            vname = '${base}_$i';
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Function block "$name": local "$base" is typed '
                    '"${existing.dataType}" but backs a "${it.dataType}" call '
                    'block — the nested instance was given its own local '
                    '"$vname" (a reference to "$base" may not resolve).'));
            existing = null;
          }
          if (existing == null) {
            vars.add(FbVar(name: vname, dataType: it.dataType,
                direction: FbVarDir.internal, initialValue: it.value));
          }
          if (vname != original) {
            // Retarget the call block(s) that named the instance, mirroring
            // ir_to_project's instance-tag retarget loop. Only blocks whose
            // TYPE is a registered FB may be retargeted: a TAG_INPUT/CONST
            // binding that coincidentally matches must not be.
            for (final b in tr.blocks) {
              if (registry.containsKey(b.type) && b.tagBinding == original) {
                b.tagBinding = vname;
              }
            }
          }
        }
        def = FbDefinition(name: name, vars: vars, fbdBlocks: tr.blocks,
            fbdWires: tr.wires, fbdNetworks: tr.networks);
      } else {
        // Nothing translated -> today's interface-only no-op. An AOI whose
        // FBDContent is empty/absent has NOTHING to fail at, so it gets no
        // noise — only a real translation failure warns (mirrors the ladder
        // arm's `body.rungs.isNotEmpty` guard).
        if (body.nodes.isNotEmpty) {
          warnings.add(ImportWarning(severity: WarningSeverity.warning,
              message: 'Function block "$name": none of its FBD networks '
                  'translated — interface imported, logic not translated (the '
                  'instance is a no-op).'));
        }
        def = FbDefinition(name: name, vars: vars);
      }
    } else {
      def = FbDefinition(name: name, vars: vars,
          stSource: body is TextBody ? body.source : '');
    }
```

5. Return the new counters:

```dart
  return FbImportResult(defs, registry, renameMap,
      translatedRllRungCount: translatedRllRungCount,
      stubbedRllRungCount: stubbedRllRungCount,
      unsupportedRllInstructions: unsupportedRllInstructions,
      rllStubReasons: rllStubReasons,
      translatedFbdNetworkCount: translatedFbdNetworkCount,
      stubbedFbdNetworkCount: stubbedFbdNetworkCount,
      unsupportedFbdBlockTypes: unsupportedFbdBlockTypes,
      fbdStubReasons: fbdStubReasons);
```

- [ ] **Step 5: Fold the counters in `ir_to_project.dart`**

Pass the dialect (line 127):

```dart
  final fbRes = mapImportedFbs(ir.pous, structs: structs, dutNames: dutNames,
      warnings: warnings, dialect: ir.dialect);
```

Seed the FBD accumulators (lines 189-192):

```dart
  // AOI FBD bodies translated by `mapImportedFbs` are FBD networks too — seed
  // the FBD counters with them so the preview's EXISTING FBD fields cover both
  // program routines and AOI bodies (no new report fields, no new preview UI).
  var translatedFbdNetworkCount = fbRes.translatedFbdNetworkCount;
  var stubbedFbdNetworkCount = fbRes.stubbedFbdNetworkCount;
  final unsupportedFbdBlockTypes = <String>{...fbRes.unsupportedFbdBlockTypes};
  final fbdStubReasons = <String, int>{...fbRes.fbdStubReasons};
```

- [ ] **Step 6: Run the mapper tests**

From `mobile/`: `/c/flutter/bin/flutter test test/import/fb_import_fbd_test.dart`

Expected: all 7 tests pass.

- [ ] **Step 7: Write the failing parser test (rewrite the existing one)**

In `mobile/test/import/l5x_parser_test.dart`, REPLACE the test at lines 163-184 (`'an FBD-logic AOI still imports interface-only with a warning (unchanged)'`) with:

```dart
  test('an FBD-logic AOI imports a GraphBody body and keeps EnableIn/EnableOut', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="GraphAoi">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="X" DataType="BOOL" Usage="Input" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="X" X="0" Y="0"/>
          <Block ID="1" Type="BNOT" X="50" Y="0"/>
          <ORef ID="2" Operand="EnableOut" X="100" Y="0"/>
          <Wire FromID="0" FromParam="OUT" ToID="1" ToParam="In"/>
          <Wire FromID="1" FromParam="Out" ToID="2" ToParam="IN"/>
        </Sheet>
      </FBDContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final pou = ir.pous.single;
    expect(pou.lang, PouLanguage.fbd);
    expect(pou.body, isA<GraphBody>());
    expect((pou.body as GraphBody).nodes, hasLength(3));
    // EnableIn/EnableOut are retained as internal BOOLs (parameter-loop order).
    expect(pou.localVars.map((v) => v.name), ['EnableIn', 'EnableOut', 'X']);
    expect(pou.localVars[0].scope, VarScope.local);
    expect(pou.localVars[0].initialValue, true);
    expect(pou.localVars[1].initialValue, false);
    expect(ir.warnings.any((w) =>
        w.message.contains('GraphAoi') && w.message.contains('not yet translated')),
        isFalse);
    expect(ir.dialect, ImportDialect.l5x);
  });
```

From `mobile/`: `/c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: FAIL - `pou.lang` is `PouLanguage.st` and `localVars` is `['X']`.

- [ ] **Step 8: Teach `_l5xAois` about FBD logic**

In `mobile/lib/import/l5x_parser.dart`, `_l5xAois`:

1. Replace lines 202-203 (the `logicType`/`isRll` pair) with:

```dart
      final logicType = logic?.getAttribute('Type');
      final isRll = logicType == 'RLL';
      final isFbd = logicType == 'FBD';
      // Rockwell re-evaluates EnableIn on every call, and both graphical
      // logic languages routinely reference EnableIn/EnableOut, so both keep
      // them as internal vars. ST/SFC-logic AOIs keep the historic skip.
      final keepsEnableParams = isRll || isFbd;
```

2. In the parameter loop (line 211):

```dart
          if (pn == 'EnableIn' || pn == 'EnableOut') {
            if (!keepsEnableParams) continue; // ST/SFC AOIs: historic skip
```

3. In the body switch (lines 248-269), add the FBD arm:

```dart
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
        } else if (isFbd) {
          // Same sheet parse _l5xRoutines uses; the mapper compiles it via
          // translateFbdBody into the FB's native FBD body.
          body = _l5xFbdBody(logic, warnings, 'AOI "$name"');
          lang = PouLanguage.fbd;
        } else {
          warnings.add(ImportWarning(severity: WarningSeverity.info,
              message: 'AOI "$name" logic is ${logicType ?? '?'} — interface '
                  'imported, logic not yet translated.'));
        }
      }
```

4. Update the `_l5xAois` doc-comment (lines 183-184):

```dart
/// Maps `<AddOnInstructionDefinition>`s to functionBlock POUs. `mapImportedFbs`
/// turns these into FbDefinitions (AOI-typed tags then resolve): ST logic
/// becomes the FB's ST source, RLL logic a `NeutralLadderBody` compiled to a
/// ladder body, FBD logic a `GraphBody` translated to an FBD body. SFC logic
/// is still interface-only.
```

- [ ] **Step 9: Run the tests to verify they pass**

From `mobile/`:

```
/c/flutter/bin/flutter test test/import/l5x_parser_test.dart test/import/fb_import_fbd_test.dart test/import/l5x_parser_fbd_test.dart
```

Expected: `All tests passed!`.

- [ ] **Step 10: Verify the whole suite and the analyzer**

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze`.

Expected: `All tests passed!` and `No issues found!`. Watch `test/import/fb_import_test.dart`, `test/import/import_fbd_e2e_test.dart` and `test/import/import_xml_flow_test.dart`: the PLCopen path must be untouched (its POUs still hit the "not imported" warning, since `ImportedProject.dialect` defaults to `plcOpen` and `parsePlcOpen` never sets it).

- [ ] **Step 11: Commit**

```
git add -A && git commit -m "feat(l5x): compile FBD-Logic AOIs into FBD-bodied FbDefinitions"
```
---

### Task 8: Composed e2e + backward-compat sweep

**Model:** sonnet · **Effort:** medium

Implements spec §9's "Composed e2e" and the backward-compat sweep. One handcrafted L5X exercises the whole feature: a two-sheet FBD program routine with an aliased compare and a connector pair, an FBD-Logic AOI (EnableIn-gated, containing a `TONR`), two AOI-typed controller tags, and a ladder routine calling both instances.

**Files:**
- Test: `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart` (new file)

**Interfaces:**
- Consumes: `ImportedProject parseL5x(String xml)`; `ImportResult mapImportedProject(ImportedProject ir, {required String projectName, required String projectId})` with `.project` and `.report`; `executeLdPrograms(..., {FbdRuntime? fbdRt})`; `executeFbdPrograms(..., {LdExecRuntime? ldRt})`; `readPath`/`writePath`.

- [ ] **Step 1: Write the e2e test**

Create `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart`:

```dart
// End-to-end: a handcrafted L5X whose program FBD routine (two sheets, an
// aliased compare, a connector pair) becomes a real FunctionBlockDiagram
// program, and whose AOI FBD `Logic` routine becomes an FBD-bodied
// FbDefinition that EXECUTES per instance — two instances stay independent.
// Pipeline: parseL5x -> mapImportedProject -> executeLdPrograms +
// executeFbdPrograms.
//
// Corpus note: the available Rockwell corpus contains zero FBD content, so
// this feature is provable only against handcrafted, schema-faithful fixtures
// (the same precedent as import_fbd_e2e_test.dart and the AOI-ladder e2e).
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Ramp">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Out" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="EnableIn" X="0" Y="0"/>
          <IRef ID="1" Operand="In" X="0" Y="40"/>
          <Function ID="2" Type="BAND" X="100" Y="0"/>
          <IRef ID="3" Operand="1000" X="100" Y="80"/>
          <Block ID="4" Type="TONR" Operand="T1" X="200" Y="0"/>
          <ORef ID="5" Operand="Out" X="300" Y="0"/>
          <Wire FromID="0" ToID="2" ToParam="In1"/>
          <Wire FromID="1" ToID="2" ToParam="In2"/>
          <Wire FromID="2" FromParam="Out" ToID="4" ToParam="TimerEnable"/>
          <Wire FromID="3" ToID="4" ToParam="PRE"/>
          <Wire FromID="4" FromParam="DN" ToID="5" ToParam="IN"/>
        </Sheet>
      </FBDContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags>
    <Tag Name="R1" DataType="Ramp"/>
    <Tag Name="R2" DataType="Ramp"/>
    <Tag Name="Src1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Src2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Level" DataType="DINT"><Data Format="Decorated"><DataValue Value="10"/></Data></Tag>
    <Tag Name="HiAlarm" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Fbd" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="Level" X="0" Y="0"/>
          <IRef ID="1" Operand="50" X="0" Y="40"/>
          <Block ID="2" Type="GRT" Operand="Grt_01" X="100" Y="0"/>
          <OCon ID="3" Name="Hi" X="200" Y="0"/>
          <Wire FromID="0" ToID="2" ToParam="SourceA"/>
          <Wire FromID="1" ToID="2" ToParam="SourceB"/>
          <Wire FromID="2" FromParam="Dest" ToID="3"/>
        </Sheet>
        <Sheet Number="2">
          <ICon ID="0" Name="Hi" X="0" Y="0"/>
          <ORef ID="1" Operand="HiAlarm" X="100" Y="0"/>
          <Wire FromID="0" ToID="1" ToParam="IN"/>
        </Sheet>
      </FBDContent></Routine>
      <Routine Name="Ladder" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Ramp(R1,Src1,Dst1);]]></Text></Rung>
        <Rung Number="1"><Text><![CDATA[Ramp(R2,Src2,Dst2);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';

void main() {
  test('L5X FBD routines translate and FBD-Logic AOIs execute per instance', () {
    final ir = parseL5x(_kXml);
    expect(ir.dialect, ImportDialect.l5x);

    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_fbd_e2e');
    final p = res.project;

    // ---- the AOI became an FBD-bodied FbDefinition ----
    final fb = p.fbDefinitions.singleWhere((f) => f.name == 'Ramp');
    expect(fb.stSource, '');
    expect(fb.ladderRungs, isEmpty);
    expect(fb.fbdBlocks, isNotEmpty);
    expect(fb.fbdNetworks, hasLength(1));
    expect(fb.vars.map((v) => v.name), ['EnableIn', 'EnableOut', 'In', 'Out']);
    expect(fb.vars.firstWhere((v) => v.name == 'EnableIn').direction,
        FbVarDir.internal);
    // BAND -> AND, TONR -> TON (with the prominent verify warning).
    expect(fb.fbdBlocks.map((b) => b.type), contains('AND'));
    expect(fb.fbdBlocks.map((b) => b.type), contains('TON'));
    expect(
        res.report.warnings.any((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('AOI "Ramp"') &&
            w.message.contains('verify')),
        isTrue);

    // ---- both AOI-typed controller tags resolved to the FB's shape ----
    expect(readPath(p, 'R1.EnableIn'), isTrue);
    expect(readPath(p, 'R2.EnableIn'), isTrue);

    // ---- the program FBD routine became a real FBD program ----
    final fbdProg = p.programs.firstWhere((pr) => pr.name == 'Main_Fbd');
    expect(fbdProg.language, 'FunctionBlockDiagram');
    // The two sheets merged into ONE network via the Hi connector pair.
    expect(fbdProg.fbdBlocks.map((b) => b.network).toSet(), {0});
    expect(fbdProg.fbdBlocks.map((b) => b.type), contains('GT')); // GRT -> GT
    expect(fbdProg.fbdBlocks.any((b) => b.type == 'TAG_OUTPUT' && b.tagBinding == 'HiAlarm'),
        isTrue);

    // 1 AOI-body network + 1 program network, both counted as FBD.
    expect(res.report.translatedFbdNetworkCount, 2);
    expect(res.report.stubbedFbdNetworkCount, 0);

    final ladder = p.programs.firstWhere((pr) => pr.name == 'Main_Ladder');
    expect(ladder.language, 'LadderLogic');
    expect(ladder.rungs, hasLength(2));

    // ---- scan ----
    final ldRt = LdExecRuntime();
    final fbdRt = FbdRuntime();
    void scan() {
      executeLdPrograms(p, 500, ldRt, fbdRt: fbdRt);
      executeFbdPrograms(p, 500, fbdRt, ldRt: ldRt);
    }

    // The FBD program computes: Level (10) is not > 50.
    scan();
    expect(readPath(p, 'HiAlarm'), isFalse);
    writePath(p, 'Level', 80);
    scan();
    expect(readPath(p, 'HiAlarm'), isTrue);

    // Instance 1 only: its EnableIn-gated TON accumulates independently.
    expect(readPath(p, 'Dst1'), isFalse);
    writePath(p, 'Src1', true);
    scan(); // ET 500 < PT 1000
    expect(readPath(p, 'Dst1'), isFalse);
    scan(); // ET 1000 >= PT
    expect(readPath(p, 'Dst1'), isTrue);
    expect(readPath(p, 'Dst2'), isFalse); // instance 2 untouched

    // Instance 2 starts its own timer from zero: state is per instance.
    writePath(p, 'Src2', true);
    scan();
    expect(readPath(p, 'Dst2'), isFalse);
    scan();
    expect(readPath(p, 'Dst2'), isTrue);
    expect(readPath(p, 'Dst1'), isTrue); // still latched on
  });

  test('an FBD routine where NOTHING translates keeps the whole-POU stub', () {
    // The faithful-or-stub floor, end to end: a routine made only of unmapped
    // Rockwell blocks must fall into `ir_to_project`'s EXISTING else arm (an
    // empty LadderLogic-style stub program + a warning + graphicalStubCount),
    // not into a half-built FBD program.
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Tags>
    <Tag Name="Raw" DataType="REAL"><Data Format="Decorated"><DataValue Value="1.0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Fbd" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="Raw" X="0" Y="0"/>
          <Block ID="1" Type="SCL" Operand="S1" X="100" Y="0"/>
          <Wire FromID="0" ToID="1" ToParam="In"/>
        </Sheet>
      </FBDContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';
    final res = mapImportedProject(parseL5x(xml),
        projectName: 'P', projectId: 'l5x_fbd_stub');
    final prog = res.project.programs.firstWhere((pr) => pr.name == 'Main_Fbd');

    expect(prog.fbdBlocks, isEmpty);
    expect(res.report.translatedFbdNetworkCount, 0);
    expect(res.report.stubbedFbdNetworkCount, 1);
    expect(res.report.unsupportedFbdBlockTypes, contains('SCL'));
    expect(
        res.report.warnings.any((w) =>
            w.message.contains('Main_Fbd') &&
            w.message.contains('not yet translated')),
        isTrue);
  });
}
```

- [ ] **Step 2: Run the e2e**

From `mobile/`: `/c/flutter/bin/flutter test test/import/import_l5x_aoi_fbd_e2e_test.dart`

Expected: both tests PASS. If it fails, fix the implementation (not the assertions) unless an assertion contradicts the spec. Two likely diagnostics:
- `translatedFbdNetworkCount` is 3 instead of 2 -> the connector pair did not merge (check `_resolveL5xFbdConnectors` and the sheet-2 id offset).
- `Dst1` never turns true -> either the ladder engine is not receiving `fbdRt` (Task 3, `scan_tick`/`executeLdPrograms`) or the `TONR` pin aliasing did not produce `IN`/`PT`/`Q` (Task 6).

- [ ] **Step 3: Backward-compat sweep**

From `mobile/`:

```
/c/flutter/bin/flutter test
/c/flutter/bin/flutter analyze
```

Expected: `All tests passed!` and `No issues found!`. Specifically confirm these stay green:
- PLCopen import: `test/import/import_fbd_e2e_test.dart`, `test/import/plcopen_parser_test.dart`, `test/import/fb_import_test.dart`, `test/import/import_xml_flow_test.dart`.
- L5X foundation/RLL/AOI-ladder: `test/import/import_l5x_e2e_test.dart`, `test/import/import_l5x_rll_e2e_test.dart`, `test/import/import_l5x_aoi_ladder_e2e_test.dart`, `test/import/l5x_parser_test.dart`.
- Serialization: `test/serialization_roundtrip_test.dart`, `test/project_repository_test.dart`, `test/models/fb_model_test.dart`.
- Corpus: `test/import/corpus_import_test.dart` (skips when the corpus folder is absent, which is the CI case).

- [ ] **Step 4: Commit**

```
git add -A && git commit -m "test(l5x): end-to-end FBD routine + FBD-Logic AOI execution"
```

---

### Task 9: Docs

**Model:** sonnet · **Effort:** medium

Implements spec §10 and §11. No code changes; prose only. Follow the plan-wide constraint: no em dashes in authored prose (use ASCII hyphens, commas or parentheses), matching the existing `knowledge/**` style.

**Files:**
- Modify: `docs/iec61131/FUNCTION_BLOCKS.md` (new FBD-bodied section + the stale lines 106-111)
- Modify: `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md` (section heading + L5X subsection)
- Modify: `docs/import/L5X.md`
- Modify: `docs/DEFERRED.md` (the two struck rows, the new rows, and the stale line 42)
- Modify: `knowledge/industry/plc-formats/rockwell-l5x.md`
- Modify: `knowledge/industry/plc-formats/index.md`
- Modify: `knowledge/industry/iec61131/custom-function-blocks.md`
- Modify: `knowledge/industry/iec61131/function-block-diagram.md`
- Modify: `knowledge/app/scan-engine.md`
- Modify: `knowledge/canonical-manifest.json`

**Interfaces:** none (documentation only). Every factual claim below must match the code as implemented in Tasks 1-8; re-read the relevant file before writing the claim.

**Style:** `knowledge/**` prose takes plain hyphens, never em dashes (`.git/sdd/kb-conventions.md:99`), and each touched knowledge file bumps its frontmatter `version:` with the manifest kept in sync. `docs/**` keeps its existing house style (em dashes included); do not reflow it.

- [ ] **Step 1: `docs/iec61131/FUNCTION_BLOCKS.md` - FBD-bodied FBs**

Add a section next to the existing ladder-body material covering:
- What an FBD-bodied `FbDefinition` is: non-empty `fbdBlocks`/`fbdWires`/`fbdNetworks`, produced today only by the L5X import of an FBD-Logic AOI.
- The three-way body precedence, quoted exactly: `ladderRungs.isNotEmpty` -> ladder, else `fbdBlocks.isNotEmpty` -> FBD, else ST. Point at `executeFbInstance` (`mobile/lib/models/fb_exec.dart`) as the single source of truth.
- Per-instance scoping: `LdScope` rewrites a body tag path whose root segment is one of the FB's var names to `<instancePath>.<path>`; `CONST` literals are never rewritten.
- Stateful-block state keys: `fb:<instancePath>|<blockId>`, disjoint from program block ids because sanitized names can contain neither `:` nor `|`. Nested instances use the dotted path (`Outer.Inner`).
- `EnableIn` is re-asserted true before every graphical-body call.
- The FB editor does not view or edit FBD bodies yet (it shows the empty ST source), and FB bodies have no online monitoring.

Then fix the now-false claim at `docs/iec61131/FUNCTION_BLOCKS.md:106-111`: "Graphical-bodied FBs, FB-calling-FB nesting, ST bodies beyond the app's subset, and IEC *functions* (stateless POUs) all remain out of scope". Ladder bodies already shipped and FBD bodies ship here, so graphical-bodied FBs must come out of that out-of-scope list (leave the other three items, and keep the pointer to `docs/DEFERRED.md`); note instead that graphical bodies are import-produced and not yet editable.

- [ ] **Step 2: `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md` - the L5X support matrix**

First retitle the section heading at line 5, which currently names only one dialect: `## FBD import (PLCopen → native FunctionBlockDiagram)` becomes `## FBD import (PLCopen and Rockwell L5X → native FunctionBlockDiagram)`.

Then extend that section with an L5X subsection stating:
- Element mapping table: `IRef` -> inVariable, `ORef` -> outVariable, `Block`/`Function` -> block (type aliased), `AddOnInstruction` -> block (name never aliased), `Wire`/`FeedbackWire` -> connection, `ICon`/`OCon` resolved at parse time, `TextBox`/`Attachment` ignored (one info warning), anything else with an `ID` kept as an opaque node so its network stubs visibly (`JSR`/`SBR`/`Ret`).
- Type alias table: EQU/NEQ/GEQ/LEQ/GRT/LES/BAND/BOR/BNOT plus best-effort TONR/TOFR and OSRI/OSFI (each with the verify warning).
- Pin alias table: `SourceA`/`SourceB`/`Dest` for math and compares, `In<k>`/`Out` for BAND/BOR, `In`/`Out` for BNOT, `TimerEnable`/`PRE`/`DN`/`ACC` for TONR/TOFR, `SelectorIn`/`In1`/`In2`/`Out` for SEL, the CUEnable/CDEnable/Reset/Load/PRE/ACC/DN set for CTUD, and `InputBit`/`OutputBit` for OSRI/OSFI. Unmapped pins pass through and stub.
- Multi-sheet: all sheets merge into one body, ascending `<Sheet Number>`, later sheets offset in localId and y so network numbering reads sheet by sheet.
- What stubs: unmapped blocks (`SCL`, `PIDE`, `MOV`, `MOD`, `ESEL`), unmapped pins, wired `EnableIn`/`EnableOut`, unmatched connectors, malformed ids, multiple wires into one input pin, dotted operands.

- [ ] **Step 3: `docs/import/L5X.md` - two new sections**

- Add "FBD routines translate": a `<Routine Type="FBD">` becomes a real `FunctionBlockDiagram` program, per-network faithful-or-stub, with the support matrix summarized and a pointer to `docs/iec61131/FUNCTION_BLOCK_DIAGRAM.md`.
- Add "FBD-Logic AOIs execute": the AOI's `Logic` routine is translated at import into an FBD-bodied `FbDefinition` and runs per instance; `EnableIn`/`EnableOut` are retained as internal BOOLs (EnableIn initial `true`, EnableOut `false`) exactly as for RLL-Logic AOIs, and EnableIn is re-asserted before each call. Note the AOI-in-AOI forward-reference limit (callee must precede caller).
- Remove FBD from "What's captured but not yet translated" (SFC stays). Update the "Deferred (not in this release)" list to match `docs/DEFERRED.md`'s §11 rows.
- Cite `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart` as the proof.

- [ ] **Step 4: `docs/DEFERRED.md` - strike two rows, add the new ones**

Replace the "FBD-bodied AOI logic" row (~line 110) with:

```
| ~~FBD-bodied AOI logic~~ | ~~later~~ | **Shipped** (2026-08-07, L5X sub-project 4): an AOI whose `Logic` routine is FBD imports as an **FBD-bodied** `FbDefinition` (`FbDefinition.fbdBlocks`/`fbdWires`/`fbdNetworks`) compiled at import by `translateFbdBody`, and executes per instance via the scoped FBD executor (`runScopedFbdBody` + `LdScope`, `'fb:<instancePath>|<blockId>'` runtime keys). `EnableIn`/`EnableOut` are retained as internal vars for FBD-logic AOIs. Proven end-to-end in `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart`. |
```

Replace the "L5X FBD routine translation" row (~line 115) with:

```
| ~~L5X FBD routine translation~~ | ~~later~~ | **Shipped** (2026-08-07, L5X sub-project 4): a `<Routine Type="FBD">`'s `<FBDContent><Sheet>` parses into the neutral `GraphBody` (multi-sheet merge, `ICon`/`OCon` connector resolution, Rockwell type + pin aliasing) and translates through the existing `translateFbdBody` into a real, executing `FunctionBlockDiagram` program, faithful-or-stub per network. See `docs/import/L5X.md`'s "FBD routines translate". |
```

Add the §11 deferred rows (keep the existing AOI-auxiliary-routines and AOI-in-AOI rows, which already cover their entries):

```
| AB FBD block synthesis | later | `SCL`, `PIDE`, `MOV`, `MOD`, `ESEL` and other unmapped Rockwell FBD blocks stub their network and are inventoried in `unsupportedFbdBlockTypes`; no synthesis onto native equivalents (e.g. `MOV` as a pass-through wire, `PIDE` -> `PID`). |
| `TONR`/`TOFR` fidelity | later | Mapped best-effort to `TON`/`TOF` with a prominent verify warning; retentive accumulation and the `Reset` pin are not modeled (a wired `Reset` stubs that network). `abOriginal` survives only in the IR and the warning; there is no native field to carry it. |
| `<TextBox>`/`<Attachment>` FBD annotations | later | Dropped at parse (counted in one info warning per routine), not imported as documentation. |
| `EnableIn`/`EnableOut` pass-through on aliased built-ins | later | A *wired* `EnableIn`/`EnableOut` pin on a Rockwell block aliased to an IEC built-in stubs its network (`unresolved-pin`) plus an info heads-up warning; no IEC-side enable/condition semantics are synthesized. The unwired case (the common one) is unaffected. |
| FB editor support for FBD bodies | later | An FBD-bodied `FbDefinition` shows its (empty) ST source; there is no view/edit UI for `fbdBlocks`. Same consequence as the ladder-body row: renaming or deleting an FB var silently reroutes body references. |
| FB-body online monitoring | later | Scoped ladder and FBD bodies pass `monitor: null`, so imported AOI bodies have no live pin/element values. |
| PLCopen FBD-bodied `functionBlock` POUs | later | The executor supports them; only the `ImportedProject.dialect` gate withholds them, pending PLCopen-specific validation. They keep the existing "graphical body - not imported" warning. |
| Dotted/member operands in FBD refs | later | An `IRef`/`ORef` naming `Timer1.DN` stubs (`complex-expression`), shared with the PLCopen FBD translator's `_isIdentifier` limit. |
| Backing-tag fidelity for FBD `Block` elements | later | A `<Block Type="TONR" Operand="T1">`'s state lives in the translator-managed `FbdRuntime`, not in the `T1` TIMER tag. |
```

Confirm the existing "FB editor support for ladder bodies", "AOI auxiliary routines", "AOI-in-AOI forward references" and "L5X SFC routine translation" rows are still accurate and left in place.

Also fix the now-false row at `docs/DEFERRED.md:42`, "Graphical-bodied FBs (LD/FBD body) | later | v1 FBs have an ST body; ... Import mapping explicitly skips these with a warning (`mapImportedFbs`) - not imported." Both halves shipped (LD in sub-project 3, FBD here). Strike it the same way as the other two rows, citing `FbDefinition.ladderRungs`/`fbdBlocks` and the two e2e tests, and note the one part that is still true: a PLCopen FBD `functionBlock` is still skipped with that warning (the dialect gate).

- [ ] **Step 5: `knowledge/industry/plc-formats/rockwell-l5x.md` - the real update**

This file's central claim ("FBD and SFC in L5X - confirmed still fully unshipped") is now stale for FBD. Update, per `knowledge/governance.md`'s conventions:

1. Frontmatter `summary:` - replace the tail "and the confirmed still-unshipped state of L5X FBD and SFC routine translation" with wording that says FBD routine and FBD-Logic AOI translation now ship and only SFC remains unshipped.
2. Frontmatter `version:` - bump from `"2026-08"` (per governance; use the current month or the governance-specified increment), and update the "**Current as of:**" blockquote at line 19 to match the new version, since it makes the same freshness claim in prose.
3. The "**Read this before:**" callout - re-point it at the shipped FBD behaviour, keeping the SFC caveat.
4. **§5 in full** (line 126) - retitle from "FBD and SFC in L5X - confirmed still fully unshipped" to something like "FBD ships, SFC does not", and rewrite the body:
   - Delete the claim that `fbdBlocks`/`fbdWires`/`fbdNetworks` "does not exist on [`FbDefinition`] today" (Task 1 added all three).
   - Delete or rewrite the "Design-rationale note, not behavioral authority" paragraph that points at the (now shipped) spec.
   - Describe what actually ships: the `<FBDContent><Sheet>` parse, sheet merge, connector resolution, type and pin aliasing, faithful-or-stub per network, the FBD-bodied `FbDefinition` and the scoped executor with `fb:<instancePath>|` keys.
   - Keep the SFC half factually unchanged (still unshipped).
5. §5's support-matrix table - update the `FBD routine` row (was "Whole-POU stub, always empty") and the `` `FBD`-Logic AOI `` row (was "Interface-only import, logic not translated") to describe real translation and execution. The `SFC` rows stay as they are.
6. "What this means practically" Q&A entries 1 and 2 - both currently describe the FBD gap as expected/current behaviour:
   - "I imported an L5X file with FBD routines - why did they come in empty, when PLCopen FBD imports for real?" - rewrite the question and answer for the shipped behaviour (what translates, what stubs and why).
   - "My AOI's RLL logic runs, but its FBD logic doesn't - is that inconsistent?" - rewrite: both run now; SFC-logic AOIs are still interface-only.

- [ ] **Step 6: Fix the other knowledge files that this feature falsifies**

These are not a style sweep: each line below asserts something the shipped code now contradicts. Work the checklist, then run the two greps at the end to catch anything missed.

`knowledge/industry/iec61131/custom-function-blocks.md` (the worst-affected file; bump `version:`):
- [ ] line 7 (frontmatter `summary:`) - "the ST-bodied/ladder-bodied body discriminator" must become the three-way ST/ladder/FBD discriminator.
- [ ] line 29 (the headline rule) - "A custom FB body is ST-bodied or ladder-bodied (never FBD-bodied)" is now false.
- [ ] lines 34-36 - the `FbDefinition` field list must include `fbdBlocks`/`fbdWires`/`fbdNetworks`; the discriminator sentence must become the three-way precedence; and "**There is no FBD-bodied custom FB in this engine** - FBD *calls* FBs ..., it does not host FB bodies" must be replaced (FBD both calls FBs and now hosts bodies).
- [ ] line 66 (body dispatch) - "the three-way precedence, ladder wins over ST since FBD-bodied FBs don't exist" must become ladder > FBD > ST, adding the `runScopedFbdBody` arm and its `FbdRuntime` ephemeral fallback alongside the `LdExecRuntime` one.
- [ ] line 72 - `EnableIn` re-assertion is no longer "(ladder-bodied FBs only)": it now covers both graphical bodies via `_reassertEnableIn`.
- [ ] lines 108-110 - the edge/pulse isolation paragraph documents only `'fb:<instancePath>'`; add the FBD body's `'fb:<instancePath>|<blockId>'` state key and state the disjointness argument correctly (no `:` or `|` in a block id, NOT "sanitized identifiers" - an AOI body's block id is `AOI Ramp_n7`, with a space).

`knowledge/app/scan-engine.md` (bump `version:`):
- [ ] line 118 - the FBD row's key column says "block id (`FbdBlock.id`, unique within a project's FBD programs)". Add the FB-body prefix case.

`knowledge/industry/iec61131/function-block-diagram.md` (bump `version:`):
- [ ] line 59 - "Every stateful FBD block keys its state off `b.id` into `FbdRuntime`'s maps" is now the program case only.
- [ ] line 110 - "State persists per `b.id` across scans" (PID) has the same problem.

`knowledge/industry/plc-formats/index.md`:
- [ ] line 51 - the Rockwell L5X row still advertises "the confirmed still-fully-unshipped state of L5X FBD and SFC routine translation". Reword to match the file's new summary (FBD ships, SFC does not).

`knowledge/canonical-manifest.json`:
- [ ] the manifest mirrors each file's frontmatter, so every `version:` and `summary:` changed above must be updated in the matching unit entry (`knowledge:industry/plc-formats/rockwell-l5x`, `knowledge:industry/iec61131/custom-function-blocks`, `knowledge:industry/iec61131/function-block-diagram`, `knowledge:app/scan-engine`). Nothing else in the manifest changes: no files are added or removed.

Then, from the repo root:

```
grep -rn -i "fbd" knowledge/ | grep -i "unshipped\|not translated\|not imported\|stub\|empty"
grep -rn "b\.id\|ladderRungs\|ladder-bodied\|ST-bodied" knowledge/
```

Review every hit from both. Update anything that now states something false; leave accurate statements alone and do not rewrite files for style.

- [ ] **Step 7: Verify**

From the repo root, confirm no doc still advertises the old behaviour:

```
grep -rn "FBD" docs/import/L5X.md | grep -i "not yet translated"
grep -rn "still fully unshipped" knowledge/industry/plc-formats/rockwell-l5x.md
grep -rn "never FBD-bodied\|no FBD-bodied custom FB" knowledge/
grep -rn "still-fully-unshipped" knowledge/industry/plc-formats/index.md
```

Expected: no output from any of them.

From `mobile/`: `/c/flutter/bin/flutter test` then `/c/flutter/bin/flutter analyze` one last time.
Expected: `All tests passed!` and `No issues found!`.

- [ ] **Step 8: Commit**

```
git add -A && git commit -m "docs: L5X FBD routines + FBD-bodied AOI execution"
```

---

## Done criteria

- All nine tasks committed, full suite green, `flutter analyze` clean.
- `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart` proves the composed pipeline.
- The PLCopen import path, every ST- and ladder-bodied FB, and all pre-existing L5X behaviour are unchanged; ST/ladder FB JSON is byte-identical.
- `docs/DEFERRED.md` no longer lists "FBD-bodied AOI logic", "L5X FBD routine translation" or "Graphical-bodied FBs" as open, and no `knowledge/**` file still claims L5X FBD is unshipped or that FBD-bodied custom FBs do not exist (`knowledge/canonical-manifest.json` matches the updated frontmatter).
