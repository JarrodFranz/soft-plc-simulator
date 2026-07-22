# LD Graphical Translator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate imported PLCopen Ladder Diagram POUs (currently empty stubs) into real, editable *and executable* `LadderLogic` programs in the app's native `LdRung` model.

**Architecture:** A new pure module `mobile/lib/import/ld_translate.dart` consumes the captured `GraphBody` IR and produces `LdRung`s. It segments the ladder into rungs (connected components after removing power rails), then maps each component either to a faithful rung (via the existing `buildRung`/`colAssignment` layout helpers) or, when any element/topology is unsupported, to a commented placeholder rung plus a warning. The mapper (`ir_to_project.dart`) calls it in place of the LD stub.

**Tech Stack:** Dart (pure, no Flutter in the translator). Reuses `mobile/lib/models/ld_graph.dart` (`buildRung`, `BranchSpec`, `colAssignment`) and is verified against `mobile/lib/models/ld_exec.dart` (`executeLdPrograms`, `LdExecRuntime`).

## Global Constraints

- Pure Dart, in-app only (ADR-010). The translator is pure, deterministic, and **never throws** — an unhandled rung becomes a placeholder, never an exception. No clock, no RNG.
- Additive / backward-compatible: only the LD branch of the mapper changes; FBD/SFC keep stubbing untouched; the `GraphBody`/`IrConnection` IR is unchanged. New `ImportReport` fields are **optional with defaults** (existing construction sites must keep compiling).
- Per-rung correctness-first: translate a rung fully-faithfully or make it a placeholder + warning. Never emit silently-wrong logic.
- Coverage: contacts (normal/negated/rising/falling), coils (normal/negated/set/reset), power rails, single-level parallel branches, and blocks `TON/TOF/TP`, `CTU/CTD/CTUD`, `GT/LT/GE/LE/EQ/NE`, `ADD/SUB/MUL/DIV/MOVE`. Anything else stubs the rung.
- Behavioral fidelity is the bar: a translated rung run by `executeLdPrograms` must produce the same logic as the source.
- Zero `flutter analyze` warnings. Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Run flutter from the `mobile/` subdirectory.

## File Structure

- Create `mobile/lib/import/ld_translate.dart` — the pure translator (all tasks 1-4 build it up).
- Create `mobile/test/import/ld_translate_test.dart` — pure unit tests (structure).
- Create `mobile/test/import/ld_translate_exec_test.dart` — behavioral tests (run translated rungs through `executeLdPrograms`).
- Modify `mobile/lib/import/ir_to_project.dart` — `ImportReport` fields (Task 1) + LD hook (Task 5).
- Modify `mobile/test/import/import_xml_flow_test.dart` and `mobile/test/fixtures/plcopen/basic.xml` expectations (Task 5).
- Modify `mobile/lib/screens/import_xml_preview.dart` — surface the unsupported-block inventory (Task 6).
- Modify `docs/import/plcopen.md` — document LD translation (Task 5).

---

### Task 1: Foundation — `ImportReport` fields, `LdTranslation` type, IEC duration parser

**Files:**
- Modify: `mobile/lib/import/ir_to_project.dart` (the `ImportReport` class, lines 7-16)
- Create: `mobile/lib/import/ld_translate.dart`
- Test: `mobile/test/import/ld_translate_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `ImportReport` gains four optional fields: `int stubbedRungCount` (default 0), `int translatedRungCount` (default 0), `Set<String> unsupportedLdBlockTypes` (default `const {}`), `Map<String,int> ldStubReasons` (default `const {}`).
  - `class LdTranslation { final List<LdRung> rungs; final List<ImportWarning> warnings; final int translatedRungCount; final int stubbedRungCount; final Set<String> unsupportedBlockTypes; final Map<String,int> stubReasons; final List<PlcTag> instanceTags; LdTranslation({...}); }`
  - `int? parseIecDuration(String literal)` — parses an IEC time literal to milliseconds.

- [ ] **Step 1: Write the failing test** (`mobile/test/import/ld_translate_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';

void main() {
  group('parseIecDuration', () {
    test('parses seconds, ms, minutes, compound, and TIME# prefix', () {
      expect(parseIecDuration('T#5s'), 5000);
      expect(parseIecDuration('T#500ms'), 500);
      expect(parseIecDuration('T#2m'), 120000);
      expect(parseIecDuration('T#1m30s'), 90000);
      expect(parseIecDuration('T#1.5s'), 1500);
      expect(parseIecDuration('TIME#250ms'), 250);
      expect(parseIecDuration('t#3h'), 10800000);
    });
    test('returns null for non-durations', () {
      expect(parseIecDuration('hello'), isNull);
      expect(parseIecDuration('5'), isNull);
      expect(parseIecDuration(''), isNull);
    });
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`cd mobile && flutter test test/import/ld_translate_test.dart`) — fails to compile (`ld_translate.dart` absent).

- [ ] **Step 3: Implement** `mobile/lib/import/ld_translate.dart`

```dart
import '../models/project_model.dart';
import 'import_ir.dart';

/// Result of translating one LD `GraphBody`. `rungs` includes placeholder
/// rungs (for untranslatable components) so program rung numbering matches the
/// source. `translatedRungCount > 0` is the mapper's real-program-vs-stub
/// decision. `instanceTags` are TIMER/COUNTER-typed tags the mapper must add so
/// translated timer/counter blocks have backing state.
class LdTranslation {
  final List<LdRung> rungs;
  final List<ImportWarning> warnings;
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<PlcTag> instanceTags;
  LdTranslation({
    required this.rungs,
    required this.warnings,
    required this.translatedRungCount,
    required this.stubbedRungCount,
    required this.unsupportedBlockTypes,
    required this.stubReasons,
    required this.instanceTags,
  });
}

/// Parses an IEC 61131 duration literal (`T#5s`, `TIME#500ms`, `T#1m30s`,
/// `T#1.5s`) to milliseconds. Case-insensitive. Returns null if [literal] is
/// not a duration. Supported units: d, h, m, s, ms.
int? parseIecDuration(String literal) {
  var s = literal.trim().toLowerCase();
  if (s.startsWith('time#')) {
    s = s.substring(5);
  } else if (s.startsWith('t#')) {
    s = s.substring(2);
  } else {
    return null;
  }
  if (s.isEmpty) return null;
  // Ordered so 'ms' is matched before 'm'.
  final re = RegExp(r'(\d+(?:\.\d+)?)(ms|d|h|m|s)');
  const unitMs = {'d': 86400000.0, 'h': 3600000.0, 'm': 60000.0, 's': 1000.0, 'ms': 1.0};
  double total = 0;
  var matchedLen = 0;
  for (final m in re.allMatches(s)) {
    matchedLen += m.group(0)!.length;
    total += double.parse(m.group(1)!) * unitMs[m.group(2)]!;
  }
  if (matchedLen != s.length || matchedLen == 0) {
    return null; // stray characters -> not a clean duration
  }
  return total.round();
}
```

- [ ] **Step 4: Extend `ImportReport`** in `mobile/lib/import/ir_to_project.dart` (replace lines 7-16):

```dart
class ImportReport {
  final int tagCount;
  final int structCount;
  final int stProgramCount;
  final int graphicalStubCount;
  final List<ImportWarning> warnings;
  // LD-translation reporting (default-safe so existing call sites compile).
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedLdBlockTypes;
  final Map<String, int> ldStubReasons;
  ImportReport({
    required this.tagCount,
    required this.structCount,
    required this.stProgramCount,
    required this.graphicalStubCount,
    required this.warnings,
    this.translatedRungCount = 0,
    this.stubbedRungCount = 0,
    this.unsupportedLdBlockTypes = const {},
    this.ldStubReasons = const {},
  });
}
```

- [ ] **Step 5: Run — expect PASS** (`cd mobile && flutter test test/import/ld_translate_test.dart`), then `cd mobile && flutter analyze` (expect: No issues found). Then full suite `cd mobile && flutter test` — record the count (baseline 2482); expect unchanged +N for the new tests.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/import/ld_translate.dart mobile/lib/import/ir_to_project.dart mobile/test/import/ld_translate_test.dart
git commit -m "feat(import): LD translator foundation — report fields, LdTranslation, duration parser"
```

---

### Task 2: Rung segmentation — connected components after removing rails

**Files:**
- Modify: `mobile/lib/import/ld_translate.dart`
- Test: `mobile/test/import/ld_translate_test.dart`

**Interfaces:**
- Consumes: `GraphBody`, `IrGraphNode`, `IrConnection` (`import_ir.dart`); `parseIecDuration` (Task 1).
- Produces (library-private, exercised through a test-visible entry): `List<LdComponent> segmentRungs(GraphBody body)` where `class LdComponent { final List<IrGraphNode> nodes; final List<IrConnection> edges; final Set<int> leftRailNodeIds; final Set<int> rightRailNodeIds; LdComponent({...}); }`. Components are ordered top-to-bottom (min `y`, then min `x`, then min `localId`).

**Context:** In PLCopen LD every rung hangs off shared `leftPowerRail`/`rightPowerRail` nodes. Removing the rail nodes splits the graph into one connected component per rung. `elementType` values come straight from the XML (`'leftPowerRail'`, `'rightPowerRail'`, `'contact'`, `'coil'`, `'block'`, `'inVariable'`, `'outVariable'`). Connections are directed producer→consumer (`fromLocalId`→`toLocalId`).

- [ ] **Step 1: Write the failing test** (append to `ld_translate_test.dart`)

```dart
import 'package:soft_plc_mobile/import/import_ir.dart';

IrGraphNode _n(int id, String type, {double x = 0, double y = 0, Map<String, String>? a}) =>
    IrGraphNode(localId: id, elementType: type, x: x, y: y, attributes: a ?? const {});
IrConnection _c(int to, int from, {String? toPin}) =>
    IrConnection(toLocalId: to, fromLocalId: from, toPin: toPin);

void mainTask2() {
  group('segmentRungs', () {
    test('two independent rungs -> two components, ordered by y', () {
      // Rung A (y=10): L -> contact1 -> coil2 -> R ; Rung B (y=50): L -> contact3 -> coil4 -> R
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(3, 'contact', y: 50, a: {'variable': 'B'}), _n(4, 'coil', y: 50, a: {'variable': 'D'}),
        _n(1, 'contact', y: 10, a: {'variable': 'A'}), _n(2, 'coil', y: 10, a: {'variable': 'C'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(200, 2),
        _c(3, 100), _c(4, 3), _c(200, 4),
      ]);
      final comps = segmentRungs(body);
      expect(comps, hasLength(2));
      // Ordered by min y: the A/C rung (y=10) first.
      expect(comps[0].nodes.map((n) => n.localId).toSet(), {1, 2});
      expect(comps[1].nodes.map((n) => n.localId).toSet(), {3, 4});
      expect(comps[0].leftRailNodeIds, contains(1));
      expect(comps[0].rightRailNodeIds, contains(2));
    });

    test('shared series path feeding two coils -> one component', () {
      // L -> A -> B -> {C, D}
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}), _n(2, 'contact', a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'C'}), _n(4, 'coil', a: {'variable': 'D'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(3, 2), _c(4, 2), _c(200, 3), _c(200, 4),
      ]);
      final comps = segmentRungs(body);
      expect(comps, hasLength(1));
      expect(comps[0].nodes.map((n) => n.localId).toSet(), {1, 2, 3, 4});
    });
  });
}
```

Wire it into the file's `main()` by calling `mainTask2();` from within `main()` (or merge the groups). Keep the group callable.

- [ ] **Step 2: Run — expect FAIL** (`segmentRungs`/`LdComponent` undefined).

- [ ] **Step 3: Implement** in `ld_translate.dart`

```dart
class LdComponent {
  final List<IrGraphNode> nodes;
  final List<IrConnection> edges;
  final Set<int> leftRailNodeIds;
  final Set<int> rightRailNodeIds;
  LdComponent({
    required this.nodes,
    required this.edges,
    required this.leftRailNodeIds,
    required this.rightRailNodeIds,
  });
}

bool _isLeftRail(String t) => t == 'leftPowerRail';
bool _isRightRail(String t) => t == 'rightPowerRail';

List<LdComponent> segmentRungs(GraphBody body) {
  final byId = {for (final n in body.nodes) n.localId: n};
  final railIds = <int>{
    for (final n in body.nodes)
      if (_isLeftRail(n.elementType) || _isRightRail(n.elementType)) n.localId
  };
  final leftRailIds = {
    for (final n in body.nodes) if (_isLeftRail(n.elementType)) n.localId
  };
  final rightRailIds = {
    for (final n in body.nodes) if (_isRightRail(n.elementType)) n.localId
  };

  // Record rail attachment before removing rails.
  final touchesLeft = <int>{};
  final touchesRight = <int>{};
  for (final e in body.connections) {
    if (leftRailIds.contains(e.fromLocalId)) touchesLeft.add(e.toLocalId);
    if (leftRailIds.contains(e.toLocalId)) touchesLeft.add(e.fromLocalId);
    if (rightRailIds.contains(e.fromLocalId)) touchesRight.add(e.toLocalId);
    if (rightRailIds.contains(e.toLocalId)) touchesRight.add(e.fromLocalId);
  }

  // Undirected adjacency over non-rail nodes.
  final adj = <int, Set<int>>{
    for (final n in body.nodes) if (!railIds.contains(n.localId)) n.localId: <int>{}
  };
  for (final e in body.connections) {
    if (railIds.contains(e.fromLocalId) || railIds.contains(e.toLocalId)) continue;
    if (adj.containsKey(e.fromLocalId) && adj.containsKey(e.toLocalId)) {
      adj[e.fromLocalId]!.add(e.toLocalId);
      adj[e.toLocalId]!.add(e.fromLocalId);
    }
  }

  // Connected components (deterministic: iterate node ids in file order).
  final seen = <int>{};
  final comps = <LdComponent>[];
  for (final n in body.nodes) {
    if (railIds.contains(n.localId) || seen.contains(n.localId)) continue;
    final memberIds = <int>[];
    final stack = [n.localId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      memberIds.add(id);
      for (final m in adj[id] ?? const <int>{}) {
        if (!seen.contains(m)) stack.add(m);
      }
    }
    final memberSet = memberIds.toSet();
    final compNodes = [for (final id in memberIds) byId[id]!];
    final compEdges = [
      for (final e in body.connections)
        if (memberSet.contains(e.fromLocalId) && memberSet.contains(e.toLocalId)) e
    ];
    comps.add(LdComponent(
      nodes: compNodes,
      edges: compEdges,
      leftRailNodeIds: memberSet.intersection(touchesLeft),
      rightRailNodeIds: memberSet.intersection(touchesRight),
    ));
  }

  // Order components top-to-bottom: min y, then min x, then min localId.
  double minY(LdComponent c) => c.nodes.map((n) => n.y).reduce((a, b) => a < b ? a : b);
  double minX(LdComponent c) => c.nodes.map((n) => n.x).reduce((a, b) => a < b ? a : b);
  int minId(LdComponent c) => c.nodes.map((n) => n.localId).reduce((a, b) => a < b ? a : b);
  comps.sort((a, b) {
    final cy = minY(a).compareTo(minY(b));
    if (cy != 0) return cy;
    final cx = minX(a).compareTo(minX(b));
    if (cx != 0) return cx;
    return minId(a).compareTo(minId(b));
  });
  return comps;
}
```

Note: `GraphBody` exposes `connections` (there is no `edges2()`); iterate `body.connections` directly, as above.

- [ ] **Step 4: Run — expect PASS**. Then `flutter analyze` (No issues).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/import/ld_translate.dart mobile/test/import/ld_translate_test.dart
git commit -m "feat(import): LD rung segmentation via connected components"
```

---

### Task 3: Boolean-rung translation (contacts/coils/rails + branches) + stub path

**Files:**
- Modify: `mobile/lib/import/ld_translate.dart`
- Test: `mobile/test/import/ld_translate_test.dart`, `mobile/test/import/ld_translate_exec_test.dart`

**Interfaces:**
- Consumes: `segmentRungs`/`LdComponent` (Task 2); `buildRung`, `BranchSpec`, `colAssignment` from `mobile/lib/models/ld_graph.dart`; `LdNode`, `LdKind`, `LdRung` from `project_model.dart`.
- Produces: `LdTranslation translateLdBody(GraphBody body, {required String pouName})` — Task 3 handles boolean elements (contact/coil/rails) and stubs any component containing a `block`, `inVariable`, `outVariable`, complex topology, or missing coil. Task 4 adds blocks.

**Context — structuring a component into `main` + `branches` for `buildRung`:** `buildRung({required int index, required List<LdNode> main, List<BranchSpec> branches})` builds the rails, series-wires `main`, and wires each `BranchSpec{startIndex, endIndex, nodes}` as a parallel lane spanning `main[startIndex..endIndex]`. It assigns node ids/rows itself. So the translator's job per component is: order the power-flow nodes into a single main series path (rail→…→coil) and express every parallel alternative as a `BranchSpec` over a contiguous main index range. v1 supports only single-level parallel branches; anything else stubs.

**Modifier mapping:** contact `attributes['negated']=='true'` → `'negated'`; else `attributes['edge']=='rising'` → `'rising'`, `'falling'`→`'falling'`; else `'normal'`. Coil: `attributes['storage']=='set'`→`'set'`, `'reset'`→`'reset'`; else `negated`→`'negated'`; else edge→`'rising'`/`'falling'`; else `'normal'`. If BOTH `negated=='true'` AND a non-`none` `edge` are present (unsupported combo), stub the rung.

- [ ] **Step 1: Write the failing structural tests** (append to `ld_translate_test.dart`)

```dart
void mainTask3() {
  LdTranslation t(GraphBody b) => translateLdBody(b, pouName: 'P');

  group('translateLdBody boolean', () {
    test('single series rung: L-[A]-[B]-(C)-R', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'contact', a: {'variable': 'B', 'negated': 'true'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      final rung = r.rungs.single;
      // main line has A, B, C (plus rails L/R added by buildRung).
      final contacts = rung.nodes.where((n) => n.kind == LdKind.contact).toList();
      expect(contacts.map((n) => n.variable), containsAll(['A', 'B']));
      expect(contacts.firstWhere((n) => n.variable == 'B').modifier, 'negated');
      expect(rung.nodes.where((n) => n.kind == LdKind.coil).single.variable, 'C');
      expect(rung.nodes.any((n) => n.kind == LdKind.leftRail), isTrue);
    });

    test('parallel contacts A||B feeding one coil -> one branch lane', () {
      // L->A->C(coil); L->B->C : A and B are parallel into the coil.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', y: 0, a: {'variable': 'A'}),
        _n(2, 'contact', y: 20, a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 100), _c(3, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final rung = r.rungs.single;
      // One node on a branch lane (row > 0).
      expect(rung.nodes.where((n) => n.row > 0).length, 1);
      expect(rung.nodes.where((n) => n.kind == LdKind.contact).map((n) => n.variable),
          containsAll(['A', 'B']));
    });

    test('a component with a block stubs (Task 3 has no block support yet)', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'block', a: {'typeName': 'TON'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.rungs.single.comment, contains('not translated'));
      expect(r.warnings, isNotEmpty);
    });

    test('component with no coil stubs', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
      ], connections: [_c(1, 100)]);
      final r = t(body);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['no-coil'], 1);
    });
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`translateLdBody` undefined).

- [ ] **Step 3: Implement** `translateLdBody` + boolean helpers in `ld_translate.dart`. The core:

```dart
import '../models/ld_graph.dart';

const _kSupportedBlocks = {
  'TON', 'TOF', 'TP', 'CTU', 'CTD', 'CTUD',
  'GT', 'LT', 'GE', 'LE', 'EQ', 'NE',
  'ADD', 'SUB', 'MUL', 'DIV', 'MOVE',
};

class _StubException implements Exception {
  final String reason; // category key for ldStubReasons
  final String detail; // human-readable
  _StubException(this.reason, this.detail);
}

LdTranslation translateLdBody(GraphBody body, {required String pouName}) {
  final comps = segmentRungs(body);
  final rungs = <LdRung>[];
  final warnings = <ImportWarning>[];
  final unsupportedBlocks = <String>{};
  final reasons = <String, int>{};
  final instanceTags = <PlcTag>[];
  var translated = 0;
  var stubbed = 0;

  for (var i = 0; i < comps.length; i++) {
    try {
      final rung = _translateComponent(comps[i], i, instanceTags, unsupportedBlocks);
      rungs.add(rung);
      translated++;
    } on _StubException catch (e) {
      reasons[e.reason] = (reasons[e.reason] ?? 0) + 1;
      warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: 'POU "$pouName" rung ${i + 1}: not translated (${e.detail}).',
      ));
      rungs.add(LdRung(
        rungIndex: i,
        comment: 'Rung not translated on import: ${e.detail}.',
        nodes: [LdNode(id: kLeftRailId, kind: LdKind.leftRail), LdNode(id: kRightRailId, kind: LdKind.rightRail)],
        wires: [LdWire(fromId: kLeftRailId, toId: kRightRailId)],
      ));
      stubbed++;
    }
  }

  return LdTranslation(
    rungs: rungs,
    warnings: warnings,
    translatedRungCount: translated,
    stubbedRungCount: stubbed,
    unsupportedBlockTypes: unsupportedBlocks,
    stubReasons: reasons,
    instanceTags: instanceTags,
  );
}
```

Then `_translateComponent(LdComponent comp, int index, List<PlcTag> instanceTags, Set<String> unsupportedBlocks) → LdRung`. Its Task-3 responsibilities (Task 4 extends the block branch):

1. **Reject unsupported element types up front.** For each node, if `elementType` is `block`, throw for Task 3 (`_StubException('unsupported-block', 'contains a function block')`) — Task 4 replaces this with real handling. If `elementType` is `inVariable`/`outVariable` and not consumed by a block, throw `_StubException('complex-topology', 'in/out variable')` (Task 4 folds these into block operands). Anything not in {`contact`,`coil`,`block`,`inVariable`,`outVariable`} → `_StubException('complex-topology', 'unsupported element <type>')`.
2. **Require ≥1 coil** (`elementType == 'coil'`); else `_StubException('no-coil', 'no output coil')`.
3. **Build the directed power graph** over the component using `comp.edges` (from→to), with the left rail as a virtual source (`comp.leftRailNodeIds`) and right rail as virtual sink (`comp.rightRailNodeIds`). Compute longest-path depth per node (like `colAssignment`) to get the series order.
4. **Derive `main` + `branches`:** the main line is the longest rail-to-coil chain in depth order; each node not on the main line must sit on a single alternative path parallel to a contiguous main segment → one `BranchSpec` with `startIndex`/`endIndex` = the main indices of its divergence/convergence anchors and `nodes` = the branch's ordered nodes. If any node cannot be placed as main or a single-level branch spanning a contiguous main range (i.e. nested/complex), `_StubException('complex-topology', 'branch structure too complex')`.
5. **Map each element to an `LdNode`** (contact/coil + modifier per the mapping above; unsupported modifier combo → `_StubException('unsupported-modifier-combo', ...)`).
6. **`return buildRung(index: index, main: mainNodes, branches: branchSpecs);`**

Provide the full implementation of `_translateComponent` and its helpers (`_depths`, `_mainAndBranches`, `_contactNode`, `_coilNode`) in this step. Keep every helper pure and deterministic (iterate nodes/edges in list order; break ties by `localId`). Reuse `kLeftRailId`/`kRightRailId` and `colAssignment` from `ld_graph.dart` where useful.

> Implementer note: the branch-extraction in step 4 is the crux. Model it as: (a) compute `depth[node]` = longest path from any left-rail source; (b) the main line = nodes on one maximal source→coil path chosen by highest depth then lowest `localId`; (c) for every non-main node, walk its single predecessor/successor chain until it rejoins main nodes `p` (upstream) and `q` (downstream); if the chain is linear (each interior node has exactly one in and one out within the component) and `p`,`q` are both on the main line, emit `BranchSpec(startIndex: mainIndex[p]+1-... )` spanning `[mainIndex[p_after], mainIndex[q_before]]`; otherwise stub. Cover the two structural tests above plus the stub cases. If the exact index math needs adjusting to satisfy the parallel-branch test (one node with `row>0`), adjust the helper — the tests are the oracle.

- [ ] **Step 4: Write a behavioral test** (`mobile/test/import/ld_translate_exec_test.dart`) — build a `PlcProject` from a translated boolean rung, run `executeLdPrograms`, assert output. Use `test/ld_exec_test.dart` as the harness template for constructing the project, `LdExecRuntime`, tags, and the scan call.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';

void main() {
  test('translated series rung executes as AND', () {
    // L-[A]-[B]-(C): C = A AND B.
    IrGraphNode n(int id, String type, {Map<String, String>? a}) =>
        IrGraphNode(localId: id, elementType: type, attributes: a ?? const {});
    IrConnection c(int to, int from) => IrConnection(toLocalId: to, fromLocalId: from);
    final body = GraphBody(nodes: [
      n(100, 'leftPowerRail'), n(200, 'rightPowerRail'),
      n(1, 'contact', a: {'variable': 'A'}),
      n(2, 'contact', a: {'variable': 'B'}),
      n(3, 'coil', a: {'variable': 'C'}),
    ], connections: [c(1, 100), c(2, 1), c(3, 2), c(200, 3)]);
    final tr = translateLdBody(body, pouName: 'P');

    final proj = PlcProject(
      id: 'p', name: 'p', controllerName: 'PLC', programs: [
        PlcProgram(name: 'Main', language: 'LadderLogic', rungs: tr.rungs),
      ], tasks: [], hmis: [], structDefs: [], tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true),
        PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true),
        PlcTag(name: 'C', path: 'C', dataType: 'BOOL', value: false),
      ]);
    final rt = LdExecRuntime();
    executeLdPrograms(proj, 100, rt);
    expect(proj.tags.firstWhere((t) => t.name == 'C').value, true);
    // Flip B -> C false.
    proj.tags.firstWhere((t) => t.name == 'B').value = false;
    executeLdPrograms(proj, 100, rt);
    expect(proj.tags.firstWhere((t) => t.name == 'C').value, false);
  });
}
```

Verify the exact `PlcProgram`/`PlcTag` constructor parameters against `project_model.dart` before finalizing (match required named params; adjust the test to the real signatures — they are the oracle).

- [ ] **Step 5: Run both test files — expect PASS**; `flutter analyze` (No issues); full suite — record count.

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/import/ld_translate.dart mobile/test/import/ld_translate_test.dart mobile/test/import/ld_translate_exec_test.dart
git commit -m "feat(import): translate boolean LD rungs (contacts/coils/branches) + stub path"
```

---

### Task 4: Function blocks (timers/counters/compare/math-MOVE) + operand folding + instance tags + inventory

**Files:**
- Modify: `mobile/lib/import/ld_translate.dart`
- Test: `mobile/test/import/ld_translate_test.dart`, `mobile/test/import/ld_translate_exec_test.dart`

**Interfaces:**
- Consumes: `_translateComponent` (Task 3); `parseIecDuration` (Task 1); `PlcTag` (`project_model.dart`).
- Produces: block handling inside `_translateComponent`; timer/counter instance tags appended to the `instanceTags` list; unsupported `typeName`s added to `unsupportedBlocks`.

**Context — power vs data connections (the pin-identity payoff):** a connection whose `toPin` is a **data** pin (`IN1`,`IN2`,`PT`,`PV`) folds into the target block's operand/preset and does NOT become a wire; a connection into a **power** pin (`IN`,`EN`,`CU`,`CD`,`R`,`LD`, or a null `toPin` into a contact/coil) is a power wire. `inVariable`/`outVariable` never become nodes — an `inVariable` feeding a data pin supplies the operand literal/tag (`attributes['variable']`); an `outVariable` on a block output supplies the destination `variable`.

- [ ] **Step 1: Write failing tests** (append to `ld_translate_test.dart` and the exec test) covering:
  - a `TON` block: `typeName='TON'`, `PT` fed by an `inVariable` with `variable='T#5s'` → an `LdNode` with `kind==block`, `blockType=='TON'`, `presetMs==5000`, `variable` = the block instance name; and an instance tag of `dataType=='TIMER'` appended.
  - a `CTU` block with `PV` literal `10` → `blockType=='CTU'`, and a `COUNTER` instance tag.
  - a compare `GT` block: `IN1` from `inVariable` `Speed`, `IN2` from `inVariable` `100` → `blockType=='GT'`, `operandA=='Speed'`, `operandB=='100'`.
  - a `MOVE` block: source `IN` operand `Src`, output to `outVariable` `Dst` → `blockType=='MOVE'`, `operandA=='Src'`, `variable=='Dst'`.
  - an unsupported `typeName='FANCYFB'` → rung stubbed, `stubReasons['unsupported-block']==1`, `unsupportedBlockTypes` contains `'FANCYFB'`.
  - a behavioral test: translate a TON rung, run enough `executeLdPrograms(proj, dtMs, rt)` scans to exceed the preset, assert the timer's `.DN`/output tag becomes true. (Copy the timer-execution assertion pattern from an existing timer test, e.g. `test/pulse_loop_integration_test.dart` or `test/ld_exec_integration_test.dart`.)

  Write the exact expected values; the `blockType` strings must match the app set (`TON/TOF/TP/CTU/CTD/CTUD/GT/LT/GE/LE/EQ/NE/ADD/SUB/MUL/DIV/MOVE`).

- [ ] **Step 2: Run — expect FAIL** (blocks currently stub).

- [ ] **Step 3: Implement** the block branch in `_translateComponent`:
  - When a node's `elementType == 'block'`: read `typeName = node.attributes['typeName']`. If not in `_kSupportedBlocks`: `unsupportedBlocks.add(typeName ?? '?'); throw _StubException('unsupported-block', 'unsupported block "$typeName"');`.
  - Build the block `LdNode` (`kind: LdKind.block, blockType: typeName`). Resolve **data inputs** by scanning `comp.edges` whose `toLocalId == node.localId` and whose `toPin` is a data pin: `IN1`→`operandA`, `IN2`→`operandB`, `PT`→`presetMs = parseIecDuration(sourceLiteral) ?? throw _StubException('unresolved-operand', 'unparseable preset')`, `PV`→operand/preset per the app's counter field. A data-pin source must resolve to a literal/tag (`inVariable.attributes['variable']`, or a directly-bound value); otherwise `_StubException('unresolved-operand', ...)`.
  - **Instance-backed blocks** (timers `TON/TOF/TP`, counters `CTU/CTD/CTUD`): derive a deterministic instance name (`node.attributes['instanceName']` if present and identifier-safe, else `'${pouName}_fb${node.localId}'`), set the `LdNode.variable` to it, and append a `PlcTag` to `instanceTags` of the app's `TIMER` (timers) or `COUNTER` (counters) structured type — creating it so `ld_exec` can read/write `.ACC`/`.DN`/`.CV`/etc. Confirm the exact app type name and `PlcTag` shape against `project_model.dart`/`system_tags.dart`/`tag_resolver.dart` (`normalizeType('TON', …)` → `TIMER`; use the same structured type the LD editor's timer blocks use). De-dup instance names within the translation.
  - **Power inputs/outputs** (`IN`,`EN`,`CU`,`CD`,`R`,`LD`, block output `Q`) remain power wires: the block `LdNode` sits on the main line between its upstream power source and downstream consumer, exactly like a contact.
  - `inVariable`/`outVariable` nodes are consumed here (folded into operands/destination) and excluded from the main/branch node set.

  Provide the complete block-handling code. If the precise `presetMs`/operand routing for counters needs a different field to satisfy the behavioral test, follow `ld_exec.dart`'s actual counter handling — the exec test is the oracle.

- [ ] **Step 4: Run — expect PASS** (structural + behavioral). `flutter analyze`. Full suite — record count.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/import/ld_translate.dart mobile/test/import/ld_translate_test.dart mobile/test/import/ld_translate_exec_test.dart
git commit -m "feat(import): translate LD function blocks + operand folding + instance tags + inventory"
```

---

### Task 5: Wire into the mapper + report aggregation + update existing tests + docs

**Files:**
- Modify: `mobile/lib/import/ir_to_project.dart` (the POU loop's `GraphBody` branch)
- Modify: `mobile/test/fixtures/plcopen/basic.xml` is unchanged; update expectations in `mobile/test/import/import_xml_flow_test.dart` and any parser/mapper test asserting LD stubs
- Test: `mobile/test/import/ir_to_project_test.dart` (integration)
- Modify: `docs/import/plcopen.md`

**Interfaces:**
- Consumes: `translateLdBody`/`LdTranslation` (Tasks 3-4).
- Produces: real `LadderLogic` programs from translatable LD POUs; aggregated report fields.

**Context:** find the POU loop in `ir_to_project.dart` (grep `for (final pou in ir.pous)` / the `GraphBody` branch that builds the stub). Today it always stubs graphical bodies.

- [ ] **Step 1: Write the failing integration test** (append to `ir_to_project_test.dart`): build an `ImportedProject` in-code (or parse a small PLCopen LD XML via `parsePlcOpen`) with one LD POU containing a translatable series rung and one containing an unsupported block; assert `mapImportedProject` yields a `LadderLogic` `PlcProgram` with real `rungs` for the first, the report's `translatedRungCount >= 1`, `stubbedRungCount >= 1`, and `unsupportedLdBlockTypes` non-empty; assert timer/counter instance tags (if any) appear in `project.tags`. Assert a fully-untranslatable LD POU still counts toward `graphicalStubCount`.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** the hook. In the POU loop's `GraphBody` branch, for `pou.lang == PouLanguage.ld`:
  ```dart
  final tr = translateLdBody(body, pouName: pou.name);
  if (tr.translatedRungCount > 0) {
    // Merge instance tags (sanitize + dedup against `used`, like other tags).
    for (final it in tr.instanceTags) { /* apply _sanitizeIdentifier + used-set dedup, add to tags */ }
    programs.add(PlcProgram(name: pou.name, language: 'LadderLogic', rungs: tr.rungs));
    warnings.addAll(tr.warnings);
    // accumulate translatedRungCount/stubbedRungCount/unsupportedLdBlockTypes/ldStubReasons into locals
  } else {
    // keep existing whole-POU stub; still fold tr.warnings + counts
    stubCount++;
  }
  ```
  Accumulate `translatedRungCount`, `stubbedRungCount`, `unsupportedLdBlockTypes` (union), `ldStubReasons` (summed) across all POUs and pass them to the final `ImportReport(...)`. FBD/SFC POUs and non-graphical bodies are unchanged. Provide the complete edited loop + `ImportReport(...)` construction.

- [ ] **Step 4: Update existing expectations.** `basic.xml`'s `Rung1` LD POU now translates (or stubs per rung) — update `import_xml_flow_test.dart` and any test asserting the old `graphicalStubCount`/stub description for LD. Run those files; adjust assertions to the new reality (a translatable LD rung → real program; keep FBD/SFC stub assertions intact).

- [ ] **Step 5: Update docs** `docs/import/plcopen.md`: move Ladder from "captured but not yet translated" to "supported (with per-rung correctness-first translation; unsupported blocks/topology stub the rung and are listed in the import report)". Keep FBD/SFC in the deferred section.

- [ ] **Step 6: Run — expect PASS**; `flutter analyze`; full suite — record count.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/import/ir_to_project.dart mobile/test/import/ir_to_project_test.dart mobile/test/import/import_xml_flow_test.dart docs/import/plcopen.md
git commit -m "feat(import): map imported LD POUs to real LadderLogic programs"
```

---

### Task 6: Preview surfacing of the inventory + corpus validation

**Files:**
- Modify: `mobile/lib/screens/import_xml_preview.dart`
- Test: `mobile/test/import/import_xml_flow_test.dart` (preview assertion)

**Interfaces:**
- Consumes: `ImportReport.stubbedRungCount`/`unsupportedLdBlockTypes` (Tasks 1,5).

- [ ] **Step 1: Write the failing widget test** — pump `ImportXmlPreview` with an `ImportResult` whose report has `stubbedRungCount: 2, unsupportedLdBlockTypes: {'FANCYFB'}`; assert a visible note like `2 rungs not translated` and `FANCYFB` appears. Use the existing preview widget tests in `import_xml_flow_test.dart` as the harness.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** a compact line in the preview (below the counts line): when `report.stubbedRungCount > 0`, show `"${report.stubbedRungCount} rung(s) not translated"` and, when `report.unsupportedLdBlockTypes.isNotEmpty`, `" — unsupported blocks: ${report.unsupportedLdBlockTypes.join(', ')}"`, styled amber (reuse the warning color already in the widget). Keep it inside the existing scroll view (no overflow at 320).

- [ ] **Step 4: Run — expect PASS**; `flutter analyze`.

- [ ] **Step 5: Corpus validation (exploratory).** Write a temporary harness (like the earlier `tmp_validate_resources_test.dart`, deleted after) that runs the local corpus LD samples (`Resources/Project Exports/PLCopen-TC6/twincat_kamil_LD_Evolution_4.xml`, and any Beremiz POU with an `<LD>` body) through `parsePlcOpen` → `mapImportedProject` and prints per-file translated-vs-stubbed rung counts and the `unsupportedLdBlockTypes` set. Record the results in the commit message / a short note; delete the harness. This is the "run real ladders through it and see" step — outcomes inform the next (custom-FB) workstream, not a hard assertion.

- [ ] **Step 6: Full suite + analyze.** `cd mobile && flutter test` (all pass — record count) and `cd mobile && flutter analyze` (No issues) and `cd mobile && flutter build web --release` (succeeds).

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/import_xml_preview.dart mobile/test/import/import_xml_flow_test.dart
git commit -m "feat(import): surface LD untranslated-rung + unsupported-block inventory in preview"
```

---

## Self-Review

**Spec coverage:** §1 architecture/hook → Tasks 1,5. §2 segmentation → Task 2. §3 element mapping (contacts/coils/rails/branches, blocks, in/out-variable folding, pin power-vs-data) → Tasks 3-4. §4 execution correctness → behavioral tests in Tasks 3-4; reporting (`stubbedRungCount` + inventory) → Tasks 1,5,6; timer/counter instance backing → Task 4; existing-test updates + docs → Task 5; corpus validation → Task 6. Unsupported-construct inventory → Tasks 1,4,6. All spec sections map to a task.

**Placeholder scan:** No stray/scaffold code. The trickiest algorithm (Task 3 branch extraction, Task 4 counter field routing) is specified with the concrete approach + the tests as the oracle, per the codebase's established "tests are the oracle" convention — the implementer writes the final helper against those tests. This is deliberate for the one genuinely graph-shaped algorithm, not vague hand-waving.

**Type consistency:** `LdTranslation` fields (Task 1) are consumed unchanged in Tasks 3-6. `translateLdBody(GraphBody, {required String pouName})` is stable across Tasks 3-5. `ImportReport` new field names (`translatedRungCount`, `stubbedRungCount`, `unsupportedLdBlockTypes`, `ldStubReasons`) match between Task 1 and Tasks 5-6. `buildRung`/`BranchSpec`/`colAssignment`/`kLeftRailId` match `ld_graph.dart`. `LdNode`/`LdKind`/`LdRung`/`LdWire`/`PlcProgram`/`PlcTag` match `project_model.dart`.
