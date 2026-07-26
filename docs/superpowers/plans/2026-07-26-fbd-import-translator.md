# FBD Import Translator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate imported PLCopen FBD POUs (today whole-POU stubbed) into real, executable native `FunctionBlockDiagram` program bodies, including custom-FB call routing.

**Architecture:** A new pure unit `lib/import/fbd_translate.dart` segments an imported FBD `GraphBody` into weakly-connected components (each → one native `FbdNetwork`, layout-ordered), maps each `block`/`inVariable`/`outVariable` element to an `FbdBlock`, carries every `IrConnection` through as an `FbdWire`, and degrades any untranslatable component to an empty commented network + warning (faithful-or-stub, per network). The mapper (`ir_to_project.dart`) calls it in place of the current FBD stub, threading the existing custom-FB registry/rename map. A minimal `<expression>` operand fallback is added to the shared parser.

**Tech Stack:** Dart (Flutter package `soft_plc_mobile`, in `mobile/`). Pure Dart, no new dependencies. Run all `flutter` commands from `mobile/`; `flutter` is at `/c/flutter/bin/flutter`.

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never throws** — every untranslatable component degrades to a stubbed (empty commented) network + a warning; the pipeline continues.
- Zero `flutter analyze` warnings (run from `mobile/`).
- **Additive / backward-compatible:** a project with no FBD POUs imports byte-identically. The FBD branch fires only on `pou.lang == PouLanguage.fbd`; the parser's `<expression>` fallback fires only when no `<variable>` child exists. Existing import tests stay green.
- Follows the importer's name discipline: sanitize identifiers, dedup against the growing tag set, avoid `kSystemTagName`, warn on every rename — and propagate an instance-tag rename onto the referencing block(s).
- No new protocol → protocol-logging rule N/A. No new dependency.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- **Create** `mobile/lib/import/graph_segment.dart` — pure `weaklyConnectedComponents` helper shared by LD and FBD segmentation.
- **Create** `mobile/lib/import/fbd_translate.dart` — the FBD translator (`FbdTranslation`, `translateFbdBody`).
- **Modify** `mobile/lib/import/plcopen_parser.dart` — `<expression>` operand fallback + negated-pin flag.
- **Modify** `mobile/lib/import/ld_translate.dart` — `segmentRungs` uses the shared helper (parity refactor).
- **Modify** `mobile/lib/import/ir_to_project.dart` — split out the FBD arm; call `translateFbdBody`; new report fields.
- **Modify** `mobile/lib/screens/import_xml_preview.dart` — surface FBD network counts + unsupported blocks.
- **Create/Modify tests** under `mobile/test/import/`.
- **Modify docs** `docs/iec61131/*`, `docs/DEFERRED.md`.

---

### Task 1: Parser — `<expression>` fallback + negated-pin flag

**Files:**
- Modify: `mobile/lib/import/plcopen_parser.dart` (`_graphBody`, ~lines 190–238)
- Test: `mobile/test/import/plcopen_parser_test.dart`

**Interfaces:**
- Consumes: existing `_graphBody(XmlElement? langEl, List<ImportWarning> warnings, String pouName)`, `IrGraphNode`, `_findElement`.
- Produces: after this task, an `inVariable`/`outVariable` whose bound value lives in `<expression>` (not `<variable>`) has `attributes['variable']` populated from the `<expression>` text; any graph node with a descendant `<variable ... negated="true">` (FBD block input/output pin negation) has `attributes['hasNegatedPin'] == 'true'`.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/import/plcopen_parser_test.dart` (inside `void main()`):

```dart
  test('inVariable/outVariable <expression> populates attributes[variable]', () {
    const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="Expr"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="1"><position x="0" y="0"/><expression>PV</expression>
          <connectionPointOut/></inVariable>
        <outVariable localId="2"><position x="100" y="0"/><expression>CV</expression>
          <connectionPointIn><connection refLocalId="1"/></connectionPointIn></outVariable>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
    final ir = parsePlcOpen(xml);
    final pou = ir.pous.single;
    final body = pou.body as GraphBody;
    final inV = body.nodes.firstWhere((n) => n.localId == 1);
    final outV = body.nodes.firstWhere((n) => n.localId == 2);
    expect(inV.attributes['variable'], 'PV');
    expect(outV.attributes['variable'], 'CV');
  });

  test('<variable> still wins over <expression> when both present', () {
    const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="Both"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="1"><position x="0" y="0"/>
          <variable>WINS</variable><expression>LOSES</expression>
          <connectionPointOut/></inVariable>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
    final ir = parsePlcOpen(xml);
    final n = (ir.pous.single.body as GraphBody).nodes.single;
    expect(n.attributes['variable'], 'WINS');
  });

  test('negated block input pin sets attributes[hasNegatedPin]', () {
    const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="Neg"/>
  <types><dataTypes/><pous>
    <pou name="P" pouType="program">
      <interface><localVars/></interface>
      <body><FBD>
        <inVariable localId="1"><position x="0" y="0"/><expression>A</expression>
          <connectionPointOut/></inVariable>
        <block localId="2" typeName="AND"><position x="60" y="0"/>
          <inputVariables>
            <variable formalParameter="IN1" negated="true">
              <connectionPointIn><connection refLocalId="1"/></connectionPointIn>
            </variable>
          </inputVariables>
          <outputVariables>
            <variable formalParameter="OUT"><connectionPointOut/></variable>
          </outputVariables>
        </block>
      </FBD></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';
    final ir = parsePlcOpen(xml);
    final blk = (ir.pous.single.body as GraphBody).nodes
        .firstWhere((n) => n.localId == 2);
    final inV = (ir.pous.single.body as GraphBody).nodes
        .firstWhere((n) => n.localId == 1);
    expect(blk.attributes['hasNegatedPin'], 'true');
    expect(inV.attributes.containsKey('hasNegatedPin'), isFalse);
  });
```

Confirm the test file already imports `parsePlcOpen` (`package:soft_plc_mobile/import/plcopen_parser.dart`) and the IR types (`package:soft_plc_mobile/import/import_ir.dart`); add the imports if missing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/plcopen_parser_test.dart`
Expected: the three new tests FAIL (`attributes['variable']` is null for `<expression>` nodes; `hasNegatedPin` absent).

- [ ] **Step 3: Implement the parser changes**

In `mobile/lib/import/plcopen_parser.dart`, inside `_graphBody`'s per-element loop, replace the existing `<variable>` extraction block:

```dart
    final varEl = _findElement(el, 'variable');
    if (varEl != null) {
      attrs['variable'] = varEl.innerText.trim();
    }
```

with:

```dart
    final varEl = _findElement(el, 'variable');
    if (varEl != null) {
      attrs['variable'] = varEl.innerText.trim();
    } else {
      // Real TC6 FBD carries an inVariable/outVariable's bound tag or literal
      // inside <expression> (LD contacts/coils use <variable>). Fall back to it
      // so FBD operands resolve; <variable> still wins when both are present.
      final exprEl = _findElement(el, 'expression');
      if (exprEl != null) {
        attrs['variable'] = exprEl.innerText.trim();
      }
    }
    // FBD block pins may be negated on their <inputVariables>/<outputVariables>
    // <variable> wrapper. The app FBD model has no negated-pin concept, so the
    // translator must be able to detect (and stub) it — flag any descendant
    // <variable negated="true">. (A negated <contact>/<coil> carries `negated`
    // on its own element, captured generically above, not here.)
    final hasNegatedPin = el.descendantElements.any(
        (d) => d.name.local == 'variable' && d.getAttribute('negated') == 'true');
    if (hasNegatedPin) {
      attrs['hasNegatedPin'] = 'true';
    }
```

(The `attrs` map is already declared just above as `final attrs = <String, String>{};` and populated from the element's own attributes; these lines add to it before the `nodes.add(IrGraphNode(... attributes: attrs))` call.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/plcopen_parser_test.dart`
Expected: all tests PASS (new + pre-existing).

- [ ] **Step 5: Verify no regressions in the import suite**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/`
Expected: PASS (no existing fixture has a `negated="true"` `<variable>` or a `<variable>`-less `<expression>`, so no snapshot drift).

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/import/plcopen_parser.dart mobile/test/import/plcopen_parser_test.dart
git commit -m "feat(import): parser <expression> operand fallback + negated-pin flag

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Shared connected-components helper + LD `segmentRungs` refactor

**Files:**
- Create: `mobile/lib/import/graph_segment.dart`
- Modify: `mobile/lib/import/ld_translate.dart` (`segmentRungs`, ~lines 906–982)
- Test: `mobile/test/import/graph_segment_test.dart` (create)

**Interfaces:**
- Consumes: `IrGraphNode`, `IrConnection` from `import_ir.dart`.
- Produces:
  ```dart
  List<List<IrGraphNode>> weaklyConnectedComponents(
    List<IrGraphNode> nodes,
    List<IrConnection> connections, {
    Set<int> excludeIds = const {},
  });
  ```
  Weakly-connected components over `nodes` using `connections` as undirected edges, dropping every node in `excludeIds` and any edge touching one. Each component is its member nodes; components are ordered by layout — min-y, then min-x, then min-localId. Deterministic, pure, never throws.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/import/graph_segment_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/graph_segment.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

IrGraphNode _n(int id, {double x = 0, double y = 0}) =>
    IrGraphNode(localId: id, elementType: 'block', x: x, y: y);
IrConnection _e(int from, int to) =>
    IrConnection(fromLocalId: from, toLocalId: to);

void main() {
  test('splits into weakly-connected components, layout-ordered', () {
    // Component X: nodes 1-2 (top, y=0). Component Y: node 3 (below, y=100).
    final nodes = [_n(1, y: 0), _n(2, x: 50, y: 0), _n(3, y: 100)];
    final conns = [_e(1, 2)];
    final comps = weaklyConnectedComponents(nodes, conns);
    expect(comps.length, 2);
    expect(comps[0].map((n) => n.localId).toSet(), {1, 2}); // top first
    expect(comps[1].map((n) => n.localId).toSet(), {3});
  });

  test('excludeIds drops nodes and edges touching them', () {
    // 1 - 99(rail) - 2 : with 99 excluded, 1 and 2 are separate components.
    final nodes = [_n(1, y: 0), _n(99, y: 0), _n(2, y: 0, x: 100)];
    final conns = [_e(1, 99), _e(99, 2)];
    final comps = weaklyConnectedComponents(nodes, conns, excludeIds: {99});
    expect(comps.length, 2);
    expect(comps.expand((c) => c).map((n) => n.localId), isNot(contains(99)));
  });

  test('empty input yields no components', () {
    expect(weaklyConnectedComponents(const [], const []), isEmpty);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/graph_segment_test.dart`
Expected: FAIL — `graph_segment.dart` / `weaklyConnectedComponents` does not exist (compile error).

- [ ] **Step 3: Implement the shared helper**

Create `mobile/lib/import/graph_segment.dart`:

```dart
import 'import_ir.dart';

/// Weakly-connected components of the graph over [nodes], treating each
/// [IrConnection] in [connections] as an undirected edge. Every node whose
/// `localId` is in [excludeIds] is removed first, along with any edge that
/// touches it (this is how LD strips power-rail nodes before segmenting).
///
/// Each returned component is the list of its member nodes. Components are
/// ordered deterministically by layout: ascending min-y, then min-x, then
/// min-localId — the same top-to-bottom, left-to-right reading order the LD
/// and FBD translators assign to rungs/networks. Pure; never throws.
List<List<IrGraphNode>> weaklyConnectedComponents(
  List<IrGraphNode> nodes,
  List<IrConnection> connections, {
  Set<int> excludeIds = const {},
}) {
  final byId = <int, IrGraphNode>{
    for (final n in nodes)
      if (!excludeIds.contains(n.localId)) n.localId: n
  };
  final adj = <int, Set<int>>{for (final id in byId.keys) id: <int>{}};
  for (final e in connections) {
    if (!byId.containsKey(e.fromLocalId) || !byId.containsKey(e.toLocalId)) {
      continue;
    }
    adj[e.fromLocalId]!.add(e.toLocalId);
    adj[e.toLocalId]!.add(e.fromLocalId);
  }

  // Connected components — iterate node ids in input (file) order for
  // determinism, flood-fill each unseen node.
  final seen = <int>{};
  final comps = <List<IrGraphNode>>[];
  for (final n in nodes) {
    if (excludeIds.contains(n.localId) || seen.contains(n.localId)) continue;
    final members = <IrGraphNode>[];
    final stack = <int>[n.localId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      members.add(byId[id]!);
      for (final m in adj[id] ?? const <int>{}) {
        if (!seen.contains(m)) stack.add(m);
      }
    }
    comps.add(members);
  }

  double minY(List<IrGraphNode> c) =>
      c.map((n) => n.y).reduce((a, b) => a < b ? a : b);
  double minX(List<IrGraphNode> c) =>
      c.map((n) => n.x).reduce((a, b) => a < b ? a : b);
  int minId(List<IrGraphNode> c) =>
      c.map((n) => n.localId).reduce((a, b) => a < b ? a : b);
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/graph_segment_test.dart`
Expected: PASS.

- [ ] **Step 5: Refactor LD `segmentRungs` to use the helper**

In `mobile/lib/import/ld_translate.dart`, add the import near the top (with the other imports):

```dart
import 'graph_segment.dart';
```

Replace the body of `segmentRungs` (from the `final byId = ...` line through the final `return comps;`) with a version that delegates component-finding to the helper but keeps LD's rail-attachment bookkeeping. The new body:

```dart
List<LdComponent> segmentRungs(GraphBody body) {
  final byId = {for (final n in body.nodes) n.localId: n};
  final leftRailIds = {
    for (final n in body.nodes) if (_isLeftRail(n.elementType)) n.localId
  };
  final rightRailIds = {
    for (final n in body.nodes) if (_isRightRail(n.elementType)) n.localId
  };
  final railIds = {...leftRailIds, ...rightRailIds};

  // Record rail attachment before the rails are excluded from segmentation.
  final touchesLeft = <int>{};
  final touchesRight = <int>{};
  for (final e in body.connections) {
    if (leftRailIds.contains(e.fromLocalId)) touchesLeft.add(e.toLocalId);
    if (leftRailIds.contains(e.toLocalId)) touchesLeft.add(e.fromLocalId);
    if (rightRailIds.contains(e.fromLocalId)) touchesRight.add(e.toLocalId);
    if (rightRailIds.contains(e.toLocalId)) touchesRight.add(e.fromLocalId);
  }

  // Connected components of the non-rail graph, already layout-ordered.
  final groups =
      weaklyConnectedComponents(body.nodes, body.connections, excludeIds: railIds);

  final comps = <LdComponent>[];
  for (final members in groups) {
    final memberSet = members.map((n) => n.localId).toSet();
    final compEdges = [
      for (final e in body.connections)
        if (memberSet.contains(e.fromLocalId) && memberSet.contains(e.toLocalId)) e
    ];
    comps.add(LdComponent(
      nodes: members,
      edges: compEdges,
      leftRailNodeIds: memberSet.intersection(touchesLeft),
      rightRailNodeIds: memberSet.intersection(touchesRight),
    ));
  }
  return comps;
}
```

Notes for the implementer:
- `byId` is retained only if still referenced elsewhere in `segmentRungs`; in this rewrite it is unused — **delete the `final byId = ...` line** to avoid an "unused local" analyzer warning. (It is a local; other functions have their own.)
- Do NOT change `_isLeftRail`/`_isRightRail` or any other function. The layout ordering the helper applies (min-y, min-x, min-localId) is identical to the sort `segmentRungs` did before, so rung order is preserved.

- [ ] **Step 6: Run the LD translator tests to prove parity**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/ld_translate_test.dart test/import/ld_translate_exec_test.dart test/import/corpus_import_test.dart`
Expected: PASS (byte-for-byte behavior preserved — rung segmentation and ordering unchanged).

- [ ] **Step 7: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/graph_segment.dart mobile/lib/import/ld_translate.dart mobile/test/import/graph_segment_test.dart
git commit -m "refactor(import): shared weaklyConnectedComponents helper (LD + FBD)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: FBD translator core (built-in blocks, operands, wires, faithful-or-stub)

**Files:**
- Create: `mobile/lib/import/fbd_translate.dart`
- Test: `mobile/test/import/fbd_translate_test.dart` (create)

**Interfaces:**
- Consumes: `weaklyConnectedComponents` (Task 2); `IrGraphNode`/`IrConnection`/`GraphBody`/`ImportWarning`/`WarningSeverity` (`import_ir.dart`); `FbdBlock`/`FbdWire`/`FbdNetwork`/`FbDefinition`/`PlcTag`/`PlcProject` (`project_model.dart`); `fbdInputPinsFor`/`fbdOutputPinsFor` (`fbd_pins.dart`); `kFbdBuiltinBlockTypes` (`fbd_pins.dart`).
- Produces:
  ```dart
  class FbdTranslation {
    final List<FbdBlock> blocks;
    final List<FbdWire> wires;
    final List<FbdNetwork> networks;
    final List<PlcTag> instanceTags;
    final int translatedNetworkCount;
    final int stubbedNetworkCount;
    final Set<String> unsupportedBlockTypes;
    final Map<String, int> stubReasons;
    final List<ImportWarning> warnings;
    FbdTranslation({required this.blocks, required this.wires,
      required this.networks, required this.instanceTags,
      required this.translatedNetworkCount, required this.stubbedNetworkCount,
      required this.unsupportedBlockTypes, required this.stubReasons,
      required this.warnings});
  }

  FbdTranslation translateFbdBody(GraphBody body, {
    required String pouName,
    Map<String, FbDefinition> fbRegistry = const {},
    Map<String, String> fbRenameMap = const {},
  });
  ```
  (Task 3 handles built-in blocks only; custom-FB routing is added in Task 4 — until then a `block` whose `typeName` is not a built-in stubs its component as `unsupported-block`.)

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/import/fbd_translate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fbd_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';

IrGraphNode _in(int id, String v, {double x = 0, double y = 0}) => IrGraphNode(
    localId: id, elementType: 'inVariable', x: x, y: y,
    attributes: {'variable': v});
IrGraphNode _out(int id, String v, {double x = 0, double y = 0}) => IrGraphNode(
    localId: id, elementType: 'outVariable', x: x, y: y,
    attributes: {'variable': v});
IrGraphNode _blk(int id, String type,
        {double x = 0, double y = 0, Map<String, String>? attrs}) =>
    IrGraphNode(localId: id, elementType: 'block', x: x, y: y,
        attributes: {'typeName': type, ...?attrs});
IrConnection _c(int from, int to, {String? toPin, String? fromPin}) =>
    IrConnection(fromLocalId: from, toLocalId: to, toPin: toPin, fromPin: fromPin);

void main() {
  test('inVariable literal -> CONST, identifier -> TAG_INPUT; outVariable -> TAG_OUTPUT', () {
    // Component: TAG_INPUT(A) & CONST(5) -> AND -> TAG_OUTPUT(Q)
    final body = GraphBody(nodes: [
      _in(1, 'A', y: 0),
      _in(2, '5', y: 40),
      _blk(3, 'AND', x: 60),
      _out(4, 'Q', x: 120),
    ], connections: [
      _c(1, 3, toPin: 'IN1'),
      _c(2, 3, toPin: 'IN2'),
      _c(3, 4, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);
    expect(tr.networks, hasLength(1));
    final types = {for (final b in tr.blocks) b.type};
    expect(types, containsAll(['TAG_INPUT', 'CONST', 'AND', 'TAG_OUTPUT']));
    final tagIn = tr.blocks.firstWhere((b) => b.type == 'TAG_INPUT');
    expect(tagIn.tagBinding, 'A');
    final constB = tr.blocks.firstWhere((b) => b.type == 'CONST');
    expect(constB.tagBinding, '5');
    final tagOut = tr.blocks.firstWhere((b) => b.type == 'TAG_OUTPUT');
    expect(tagOut.tagBinding, 'Q');
    // All blocks in network 0; three wires carried through.
    expect(tr.blocks.every((b) => b.network == 0), isTrue);
    expect(tr.wires, hasLength(3));
  });

  test('two components -> two layout-ordered networks', () {
    final body = GraphBody(nodes: [
      _in(1, 'A', y: 0), _out(2, 'B', x: 60, y: 0),      // top component
      _in(3, 'C', y: 100), _out(4, 'D', x: 60, y: 100),  // bottom component
    ], connections: [
      _c(1, 2), _c(3, 4),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 2);
    expect(tr.networks, hasLength(2));
    // Top component (y=0) is network 0.
    final net0Bindings = {
      for (final b in tr.blocks) if (b.network == 0) b.tagBinding
    };
    expect(net0Bindings, containsAll(['A', 'B']));
  });

  test('extensible AND inputCount follows the highest wired IN pin', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _in(2, 'B', y: 40), _in(3, 'C', y: 80),
      _blk(4, 'AND', x: 60), _out(5, 'Q', x: 120),
    ], connections: [
      _c(1, 4, toPin: 'IN1'), _c(2, 4, toPin: 'IN2'), _c(3, 4, toPin: 'IN3'),
      _c(4, 5, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 1);
    final and = tr.blocks.firstWhere((b) => b.type == 'AND');
    expect(and.inputCount, 3);
  });

  test('unsupported element (inOutVariable) stubs its network', () {
    final body = GraphBody(nodes: [
      IrGraphNode(localId: 1, elementType: 'inOutVariable',
          attributes: const {'variable': 'X'}),
      _out(2, 'Y', x: 60),
    ], connections: [_c(1, 2)]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unsupported-element'], 1);
    expect(tr.networks.single.comment, contains('not translated'));
    expect(tr.blocks, isEmpty);
    expect(tr.warnings.any((w) => w.severity == WarningSeverity.warning), isTrue);
  });

  test('negated pin stubs its network', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'),
      _blk(2, 'NOT', x: 60, attrs: {'hasNegatedPin': 'true'}),
      _out(3, 'Q', x: 120),
    ], connections: [_c(1, 2, toPin: 'IN'), _c(2, 3, fromPin: 'OUT')]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['negated-pin'], 1);
  });

  test('unknown block type stubs + records inventory', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _blk(2, 'MYSTERY', x: 60), _out(3, 'Q', x: 120),
    ], connections: [_c(1, 2, toPin: 'IN1'), _c(2, 3, fromPin: 'OUT')]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unsupported-block'], 1);
    expect(tr.unsupportedBlockTypes, contains('MYSTERY'));
  });

  test('compound expression operand stubs its network', () {
    final body = GraphBody(nodes: [
      _in(1, 'A + B'), _out(2, 'Q', x: 60),
    ], connections: [_c(1, 2)]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['complex-expression'], 1);
  });

  test('wire to a pin not on the block stubs its network', () {
    final body = GraphBody(nodes: [
      _in(1, 'A'), _blk(2, 'NOT', x: 60), _out(3, 'Q', x: 120),
    ], connections: [
      _c(1, 2, toPin: 'BOGUS'), // NOT has only IN
      _c(2, 3, fromPin: 'OUT'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P');
    expect(tr.stubbedNetworkCount, 1);
    expect(tr.stubReasons['unresolved-pin'], 1);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/fbd_translate_test.dart`
Expected: FAIL — `fbd_translate.dart` does not exist (compile error).

- [ ] **Step 3: Implement the translator core**

Create `mobile/lib/import/fbd_translate.dart`:

```dart
import '../models/project_model.dart';
import '../models/fbd_pins.dart';
import 'graph_segment.dart';
import 'import_ir.dart';

/// Result of translating one FBD `GraphBody` into native `FunctionBlockDiagram`
/// program parts. `networks` includes an empty commented network for every
/// component that could not be translated, so `FbdBlock.network` indices always
/// point at a real header and network numbering matches source order.
/// `translatedNetworkCount > 0` is the mapper's real-program-vs-stub decision.
/// `instanceTags` are struct-typed tags backing custom-FB call blocks (added in
/// the custom-FB routing task).
class FbdTranslation {
  final List<FbdBlock> blocks;
  final List<FbdWire> wires;
  final List<FbdNetwork> networks;
  final List<PlcTag> instanceTags;
  final int translatedNetworkCount;
  final int stubbedNetworkCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<ImportWarning> warnings;
  FbdTranslation({
    required this.blocks,
    required this.wires,
    required this.networks,
    required this.instanceTags,
    required this.translatedNetworkCount,
    required this.stubbedNetworkCount,
    required this.unsupportedBlockTypes,
    required this.stubReasons,
    required this.warnings,
  });
}

/// Thrown internally when a component cannot be translated to a real network.
/// [reason] is the `stubReasons` key; [detail] is a human sentence.
class _FbdStub implements Exception {
  final String reason;
  final String detail;
  _FbdStub(this.reason, this.detail);
}

/// The native parts produced for a single translated component.
class _BuiltComponent {
  final List<FbdBlock> blocks;
  final List<FbdWire> wires;
  final List<PlcTag> instanceTags;
  _BuiltComponent(this.blocks, this.wires, this.instanceTags);
}

/// True when [text] is an FBD `CONST` literal: an integer, a double, or a
/// case-insensitive boolean. Used to split `inVariable` text into CONST vs
/// TAG_INPUT.
bool _isLiteral(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  final up = t.toUpperCase();
  if (up == 'TRUE' || up == 'FALSE') return true;
  return int.tryParse(t) != null || double.tryParse(t) != null;
}

/// True when [text] is a bare IEC identifier (a tag reference), not a literal
/// and not a compound expression.
bool _isIdentifier(String text) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(text.trim());

/// Translates a PLCopen FBD [body] into native `FunctionBlockDiagram` parts.
/// Each weakly-connected component becomes one `FbdNetwork` (layout-ordered);
/// an untranslatable component degrades to an empty commented network + a
/// warning. Never throws.
FbdTranslation translateFbdBody(
  GraphBody body, {
  required String pouName,
  Map<String, FbDefinition> fbRegistry = const {},
  Map<String, String> fbRenameMap = const {},
}) {
  final comps = weaklyConnectedComponents(body.nodes, body.connections);

  final blocks = <FbdBlock>[];
  final wires = <FbdWire>[];
  final networks = <FbdNetwork>[];
  final instanceTags = <PlcTag>[];
  final unsupported = <String>{};
  final reasons = <String, int>{};
  final warnings = <ImportWarning>[];
  final usedInstanceNames = <String>{};
  var translated = 0;
  var stubbed = 0;

  // Scratch project so fbdInputPinsFor/fbdOutputPinsFor can resolve custom-FB
  // pin names (Task 4); harmless for built-ins.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
      fbDefinitions: fbRegistry.values.toList());

  for (var i = 0; i < comps.length; i++) {
    try {
      final built = _translateComponent(comps[i], i, body.connections, pouName,
          scratch, fbRegistry, fbRenameMap, usedInstanceNames, unsupported);
      for (final b in built.blocks) {
        b.network = i;
      }
      blocks.addAll(built.blocks);
      wires.addAll(built.wires);
      instanceTags.addAll(built.instanceTags);
      networks.add(FbdNetwork(comment: ''));
      translated++;
    } on _FbdStub catch (e) {
      reasons[e.reason] = (reasons[e.reason] ?? 0) + 1;
      warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: 'POU "$pouName" network ${i + 1}: not translated (${e.detail}).',
      ));
      networks.add(FbdNetwork(
          comment: 'Network ${i + 1} not translated on import: ${e.detail}.'));
      stubbed++;
    }
  }

  return FbdTranslation(
    blocks: blocks,
    wires: wires,
    networks: networks,
    instanceTags: instanceTags,
    translatedNetworkCount: translated,
    stubbedNetworkCount: stubbed,
    unsupportedBlockTypes: unsupported,
    stubReasons: reasons,
    warnings: warnings,
  );
}

/// Deterministic block id for a node: unique within the POU (localIds are).
String _blockId(String pouName, int localId) => '${pouName}_n$localId';

/// Translates one component's nodes to native blocks + wires, or throws
/// [_FbdStub]. Instance-name dedup reservations are staged in a LOCAL set
/// seeded from [usedInstanceNames] and merged by the caller only on success (a
/// stubbed component frees its reserved names). [unsupported] is mutated
/// eagerly (persistent inventory). `_BuiltComponent.blocks` carry `network = 0`
/// here; the caller stamps the real index.
_BuiltComponent _translateComponent(
  List<IrGraphNode> nodes,
  int index,
  List<IrConnection> allConnections,
  String pouName,
  PlcProject scratch,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  Set<String> usedInstanceNames,
  Set<String> unsupported,
) {
  final memberIds = nodes.map((n) => n.localId).toSet();

  // 1. Reject unsupported element types + negated pins up front.
  for (final n in nodes) {
    switch (n.elementType) {
      case 'block':
      case 'inVariable':
      case 'outVariable':
        break;
      default:
        throw _FbdStub('unsupported-element', 'unsupported element ${n.elementType}');
    }
    if (n.attributes['hasNegatedPin'] == 'true') {
      throw _FbdStub('negated-pin', 'block "${n.attributes['typeName'] ?? '?'}" has a negated pin');
    }
  }

  // Component-local edges (both endpoints inside this component).
  final edges = [
    for (final e in allConnections)
      if (memberIds.contains(e.fromLocalId) && memberIds.contains(e.toLocalId)) e
  ];

  // 2. Build blocks (staged instance-name set).
  final localUsedNames = <String>{...usedInstanceNames};
  final localInstanceTags = <PlcTag>[];
  final blockByLocalId = <int, FbdBlock>{};
  for (final n in nodes) {
    blockByLocalId[n.localId] = _buildBlock(n, edges, pouName, fbRegistry,
        fbRenameMap, localInstanceTags, localUsedNames, unsupported);
  }

  // 3. Build wires + pin-faithfulness gate.
  final wires = <FbdWire>[];
  for (final e in edges) {
    final from = blockByLocalId[e.fromLocalId]!;
    final to = blockByLocalId[e.toLocalId]!;
    final toPin = e.toPin ?? '';
    final fromPin = e.fromPin ?? '';
    _assertPin(scratch, to, toPin, isInput: true);
    _assertPin(scratch, from, fromPin, isInput: false);
    wires.add(FbdWire(
        fromBlockId: from.id, fromPin: fromPin, toBlockId: to.id, toPin: toPin));
  }

  // 4. Gate passed — commit staged names/tags to the caller's sets.
  usedInstanceNames.addAll(localUsedNames);
  return _BuiltComponent(
      blockByLocalId.values.toList(), wires, localInstanceTags);
}

/// Verifies [pin] is on [block]'s resolved input (or output) pin list, allowing
/// an empty pin name only when the block has exactly one pin on that side (the
/// executor's first-pin fallback). Throws [_FbdStub] otherwise.
void _assertPin(PlcProject scratch, FbdBlock block, String pin,
    {required bool isInput}) {
  final pins = isInput
      ? fbdInputPinsFor(scratch, block)
      : fbdOutputPinsFor(scratch, block);
  if (pin.isEmpty) {
    if (pins.length <= 1) return; // single-pin fallback (or a sink/source)
    throw _FbdStub('unresolved-pin',
        'ambiguous ${isInput ? 'input' : 'output'} pin on ${block.type}');
  }
  if (!pins.contains(pin)) {
    throw _FbdStub('unresolved-pin',
        'pin "$pin" not on ${block.type} ${isInput ? 'inputs' : 'outputs'}');
  }
}

/// Builds the native [FbdBlock] for one node, or throws [_FbdStub]. Task 3
/// handles inVariable/outVariable and built-in blocks; the custom-FB branch is
/// added in Task 4.
FbdBlock _buildBlock(
  IrGraphNode node,
  List<IrConnection> edges,
  String pouName,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  List<PlcTag> instanceTags,
  Set<String> usedInstanceNames,
  Set<String> unsupported,
) {
  final id = _blockId(pouName, node.localId);
  if (node.elementType == 'inVariable') {
    final text = node.attributes['variable']?.trim() ?? '';
    if (_isLiteral(text)) {
      return FbdBlock(id: id, type: 'CONST', title: 'CONST', tagBinding: text,
          x: node.x, y: node.y);
    }
    if (_isIdentifier(text)) {
      return FbdBlock(id: id, type: 'TAG_INPUT', title: text, tagBinding: text,
          x: node.x, y: node.y);
    }
    if (text.isEmpty) {
      throw _FbdStub('unresolved-operand', 'empty inVariable');
    }
    throw _FbdStub('complex-expression', 'compound inVariable "$text"');
  }
  if (node.elementType == 'outVariable') {
    final text = node.attributes['variable']?.trim() ?? '';
    if (_isIdentifier(text)) {
      return FbdBlock(id: id, type: 'TAG_OUTPUT', title: text, tagBinding: text,
          x: node.x, y: node.y);
    }
    if (text.isEmpty) {
      throw _FbdStub('unresolved-operand', 'empty outVariable');
    }
    throw _FbdStub('complex-expression', 'compound outVariable "$text"');
  }

  // block
  final typeName = node.attributes['typeName'] ?? '';
  // (Task 4 inserts the custom-FB branch here, BEFORE the built-in check.)
  if (!kFbdBuiltinBlockTypes.contains(typeName)) {
    unsupported.add(typeName.isEmpty ? '?' : typeName);
    throw _FbdStub('unsupported-block', 'unsupported block "$typeName"');
  }
  final block = FbdBlock(id: id, type: typeName, title: typeName,
      x: node.x, y: node.y);
  // Extensible operators (AND/OR/ADD/MUL): inputCount = highest wired IN<n>.
  if (typeName == 'AND' || typeName == 'OR' || typeName == 'ADD' || typeName == 'MUL') {
    var maxPin = 1;
    for (final e in edges) {
      if (e.toLocalId != node.localId) continue;
      final m = RegExp(r'^IN(\d+)$').firstMatch(e.toPin ?? '');
      if (m != null) {
        final n = int.parse(m.group(1)!);
        if (n > maxPin) maxPin = n;
      }
    }
    block.inputCount = maxPin;
  }
  return block;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/fbd_translate_test.dart`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/fbd_translate.dart mobile/test/import/fbd_translate_test.dart
git commit -m "feat(import): FBD translator core (built-in blocks, faithful-or-stub)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Custom-FB call routing in the FBD translator

**Files:**
- Modify: `mobile/lib/import/fbd_translate.dart` (`_buildBlock`)
- Test: `mobile/test/import/fbd_translate_test.dart` (add tests)

**Interfaces:**
- Consumes: `FbDefinition`/`FbVar`/`FbVarDir` (`project_model.dart`); `defaultValueFor` (`tag_resolver.dart`); the `fbRegistry`/`fbRenameMap`/`instanceTags`/`usedInstanceNames` already threaded into `_buildBlock`.
- Produces: an FBD `block` whose `typeName` (after `fbRenameMap`) is a registered custom FB becomes `FbdBlock(type: fbName, tagBinding: <instance>)` plus a struct-typed instance `PlcTag(dataType: fbName)` appended to `instanceTags`; instance names dedup within the translation.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/import/fbd_translate_test.dart`. Add these imports at the top:

```dart
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
```

Add a helper + tests inside `main()`:

```dart
  FbDefinition _scaler() => FbDefinition(name: 'Scaler', vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ], stSource: 'Out := In * Gain;');

  test('FBD custom-FB block routes to instance + struct-typed instance tag', () {
    final body = GraphBody(nodes: [
      _in(1, 'PV'), _in(2, '2.0', y: 40),
      IrGraphNode(localId: 3, elementType: 'block', x: 60,
          attributes: const {'typeName': 'Scaler', 'instanceName': 'S1'}),
      _out(4, 'CV', x: 120),
    ], connections: [
      _c(1, 3, toPin: 'In'), _c(2, 3, toPin: 'Gain'),
      _c(3, 4, fromPin: 'Out'),
    ]);
    final reg = {'Scaler': _scaler()};
    final tr = translateFbdBody(body, pouName: 'P', fbRegistry: reg);
    expect(tr.translatedNetworkCount, 1);
    final fb = tr.blocks.firstWhere((b) => b.type == 'Scaler');
    expect(fb.tagBinding, 'S1');
    final inst = tr.instanceTags.firstWhere((t) => t.name == 'S1');
    expect(inst.dataType, 'Scaler');
    expect(defaultValueFor(
        PlcProject(id: 's', name: 's', controllerName: 'P', programs: [],
            tasks: [], hmis: [], structDefs: [], tags: [],
            fbDefinitions: reg.values.toList()),
        'Scaler', 0) is Map, isTrue);
  });

  test('renamed FB routes via rename map', () {
    final body = GraphBody(nodes: [
      _in(1, 'PV'),
      IrGraphNode(localId: 2, elementType: 'block', x: 60,
          attributes: const {'typeName': 'AND', 'instanceName': 'I1'}),
      _out(3, 'CV', x: 120),
    ], connections: [_c(1, 2, toPin: 'In'), _c(2, 3, fromPin: 'Out')]);
    // Source calls it "AND" but it was renamed to "AND_1" on import.
    final reg = {
      'AND_1': FbDefinition(name: 'AND_1', vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ], stSource: 'Out := In;')
    };
    final tr = translateFbdBody(body, pouName: 'P',
        fbRegistry: reg, fbRenameMap: {'AND': 'AND_1'});
    expect(tr.translatedNetworkCount, 1);
    expect(tr.blocks.any((b) => b.type == 'AND_1'), isTrue);
  });

  test('instance name dedup within a POU', () {
    // Two FB blocks with no instanceName -> deterministic names, deduped.
    final body = GraphBody(nodes: [
      _in(1, 'A'),
      IrGraphNode(localId: 2, elementType: 'block', x: 60,
          attributes: const {'typeName': 'Scaler'}),
      _out(3, 'B', x: 120),
      _in(4, 'C', y: 200),
      IrGraphNode(localId: 5, elementType: 'block', x: 60, y: 200,
          attributes: const {'typeName': 'Scaler'}),
      _out(6, 'D', x: 120, y: 200),
    ], connections: [
      _c(1, 2, toPin: 'In'), _c(2, 3, fromPin: 'Out'),
      _c(4, 5, toPin: 'In'), _c(5, 6, fromPin: 'Out'),
    ]);
    final tr = translateFbdBody(body, pouName: 'P', fbRegistry: {'Scaler': _scaler()});
    final names = tr.instanceTags.map((t) => t.name).toSet();
    expect(names, hasLength(2)); // unique
    expect(tr.blocks.where((b) => b.type == 'Scaler'), hasLength(2));
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/fbd_translate_test.dart`
Expected: the three new tests FAIL — the Scaler block currently hits the `unsupported-block` stub (so its network stubs, `translatedNetworkCount == 0`).

- [ ] **Step 3: Implement the custom-FB branch**

In `mobile/lib/import/fbd_translate.dart`, add the import:

```dart
import '../models/tag_resolver.dart';
```

Replace the `// block` section's comment line `// (Task 4 inserts the custom-FB branch here, BEFORE the built-in check.)` and the built-in check that follows so that the FB branch runs first:

```dart
  // block
  final typeName = node.attributes['typeName'] ?? '';
  // Custom-FB call: a block whose (renamed) type is a registered FB routes to a
  // native FB-instance block (tagBinding = instance) + a struct-typed instance
  // tag, checked BEFORE the built-in allowlist so a user FB is never mistaken
  // for an unknown built-in.
  final effective = fbRenameMap[typeName] ?? typeName;
  final fb = fbRegistry[effective];
  if (fb != null) {
    final instance = _fbInstanceName(node, pouName, usedInstanceNames);
    // Instance tag default resolved against an fb-aware scratch project so
    // defaultValueFor -> lookupComposite -> fbDefinitionFor expands the FB into
    // its struct-typed default (one field per FB var).
    final scratch = PlcProject(
        id: 'scratch', name: 'scratch', controllerName: 'PLC',
        programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
        fbDefinitions: fbRegistry.values.toList());
    instanceTags.add(PlcTag(
      name: instance, path: instance, dataType: effective,
      value: defaultValueFor(scratch, effective, 0), ioType: 'Internal',
    ));
    return FbdBlock(id: id, type: effective, title: effective,
        tagBinding: instance, x: node.x, y: node.y);
  }
  if (!kFbdBuiltinBlockTypes.contains(typeName)) {
    unsupported.add(typeName.isEmpty ? '?' : typeName);
    throw _FbdStub('unsupported-block', 'unsupported block "$typeName"');
  }
```

Add the instance-name helper at the bottom of the file:

```dart
/// Deterministic instance name for a custom-FB call block: the `instanceName`
/// attribute when it is a valid identifier, else `'${pouName}_fb${localId}'`,
/// de-duplicated within a translation via [used] by appending `_2`, `_3`, ...
String _fbInstanceName(IrGraphNode node, String pouName, Set<String> used) {
  final attr = node.attributes['instanceName'];
  final safe = attr != null && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(attr);
  final base = safe ? attr! : '${pouName}_fb${node.localId}';
  var name = base;
  var i = 2;
  while (used.contains(name)) {
    name = '${base}_$i';
    i++;
  }
  used.add(name);
  return name;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/fbd_translate_test.dart`
Expected: PASS (all tests, new + Task-3).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/fbd_translate.dart mobile/test/import/fbd_translate_test.dart
git commit -m "feat(import): route FBD custom-FB call blocks to instances

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Mapper integration + report fields + preview

**Files:**
- Modify: `mobile/lib/import/ir_to_project.dart` (`ImportReport`, the POU loop's FBD arm, the `PlcProject`/`ImportReport` assembly)
- Modify: `mobile/lib/screens/import_xml_preview.dart` (~lines 84–98)
- Test: `mobile/test/import/ir_to_project_test.dart`

**Interfaces:**
- Consumes: `translateFbdBody` + `FbdTranslation` (Task 3/4); `fbRes.registry`/`fbRes.renameMap` (existing `mapImportedFbs` result); the existing `_sanitizeIdentifier`, `used`, `tags`, `kSystemTagName`.
- Produces: `ImportReport` gains `translatedFbdNetworkCount` (int, default 0), `stubbedFbdNetworkCount` (int, default 0), `unsupportedFbdBlockTypes` (`Set<String>`, default `{}`), `fbdStubReasons` (`Map<String,int>`, default `{}`). FBD POUs with ≥1 translated network become real `FunctionBlockDiagram` programs.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/import/ir_to_project_test.dart` (it already imports `ir_to_project.dart`, `import_ir.dart`, `project_model.dart` — add any missing). Build the IR directly (no XML needed):

```dart
  test('FBD POU with a translatable network becomes a real FBD program', () {
    final ir = ImportedProject(
      name: 'FbdProj', types: const [], warnings: const [],
      globalVars: [
        ImportedVar(name: 'A', baseType: 'BOOL', scope: VarScope.global),
        ImportedVar(name: 'Q', baseType: 'BOOL', scope: VarScope.global),
      ],
      pous: [
        ImportedPou(
          name: 'Logic', kind: PouKind.program, lang: PouLanguage.fbd,
          localVars: const [],
          body: GraphBody(nodes: [
            IrGraphNode(localId: 1, elementType: 'inVariable',
                attributes: const {'variable': 'A'}),
            IrGraphNode(localId: 2, elementType: 'block', x: 60,
                attributes: const {'typeName': 'NOT'}),
            IrGraphNode(localId: 3, elementType: 'outVariable', x: 120,
                attributes: const {'variable': 'Q'}),
          ], connections: [
            IrConnection(fromLocalId: 1, toLocalId: 2, toPin: 'IN'),
            IrConnection(fromLocalId: 2, toLocalId: 3, fromPin: 'OUT'),
          ]),
        ),
      ],
    );
    final res = mapImportedProject(ir, projectName: 'FbdProj', projectId: 'x');
    final prog = res.project.programs.firstWhere((p) => p.name == 'Logic');
    expect(prog.language, 'FunctionBlockDiagram');
    expect(prog.fbdBlocks.map((b) => b.type),
        containsAll(['TAG_INPUT', 'NOT', 'TAG_OUTPUT']));
    expect(prog.fbdNetworks, isNotEmpty);
    expect(res.report.translatedFbdNetworkCount, 1);
    expect(res.report.stubbedFbdNetworkCount, 0);
  });

  test('FBD POU with nothing translatable keeps the whole-POU stub', () {
    final ir = ImportedProject(
      name: 'FbdStub', types: const [], warnings: const [], globalVars: const [],
      pous: [
        ImportedPou(
          name: 'Bad', kind: PouKind.program, lang: PouLanguage.fbd,
          localVars: const [],
          body: GraphBody(nodes: [
            IrGraphNode(localId: 1, elementType: 'inOutVariable',
                attributes: const {'variable': 'X'}),
          ], connections: const []),
        ),
      ],
    );
    final res = mapImportedProject(ir, projectName: 'FbdStub', projectId: 'y');
    final prog = res.project.programs.firstWhere((p) => p.name == 'Bad');
    expect(prog.language, 'FunctionBlockDiagram');
    expect(prog.fbdBlocks, isEmpty); // stub program has no blocks
    expect(res.report.translatedFbdNetworkCount, 0);
    expect(res.report.stubbedFbdNetworkCount, 1);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/ir_to_project_test.dart`
Expected: FAIL — `translatedFbdNetworkCount` is not a member of `ImportReport`; the FBD POU still whole-POU stubs (no `fbdBlocks`).

- [ ] **Step 3: Add the report fields**

In `mobile/lib/import/ir_to_project.dart`, extend `ImportReport` (add fields + constructor params, all default-safe):

```dart
  // FBD-translation reporting (default-safe so existing call sites compile).
  final int translatedFbdNetworkCount;
  final int stubbedFbdNetworkCount;
  final Set<String> unsupportedFbdBlockTypes;
  final Map<String, int> fbdStubReasons;
```

and in the constructor parameter list (after `this.importedFbCount = 0,`):

```dart
    this.translatedFbdNetworkCount = 0,
    this.stubbedFbdNetworkCount = 0,
    this.unsupportedFbdBlockTypes = const {},
    this.fbdStubReasons = const {},
```

- [ ] **Step 4: Add the import + accumulators + FBD arm**

Add the import near the top of `ir_to_project.dart`:

```dart
import 'fbd_translate.dart';
```

Add accumulators alongside the LD ones (near `final unsupportedLdBlockTypes = <String>{};`):

```dart
  var translatedFbdNetworkCount = 0;
  var stubbedFbdNetworkCount = 0;
  final unsupportedFbdBlockTypes = <String>{};
  final fbdStubReasons = <String, int>{};
```

Then, in the POU loop, replace the current combined `else if (body is GraphBody)` FBD/SFC arm (the block that computes `lang` via the `switch (pou.lang)` and emits the whole-POU graphical stub) with an FBD-specific arm followed by the unchanged fallback arm:

```dart
    } else if (body is GraphBody && pou.lang == PouLanguage.fbd) {
      final tr = translateFbdBody(body, pouName: pou.name,
          fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);
      translatedFbdNetworkCount += tr.translatedNetworkCount;
      stubbedFbdNetworkCount += tr.stubbedNetworkCount;
      unsupportedFbdBlockTypes.addAll(tr.unsupportedBlockTypes);
      tr.stubReasons.forEach((k, v) {
        fbdStubReasons[k] = (fbdStubReasons[k] ?? 0) + v;
      });
      warnings.addAll(tr.warnings);
      if (tr.translatedNetworkCount > 0) {
        // Merge custom-FB instance tags with the SAME sanitize + dedup + node-
        // retarget loop the LD arm uses, but retargeting FbdBlock.tagBinding.
        // Only blocks whose type is a registered FB may be retargeted (a
        // TAG_INPUT/CONST binding that coincidentally matches must NOT be).
        for (final it in tr.instanceTags) {
          final original = it.name;
          var name = _sanitizeIdentifier(original);
          if (name != original) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Variable "$original" renamed to "$name" (identifier rules).'));
          }
          if (name == kSystemTagName || used.contains(name)) {
            var n = 1;
            while (used.contains('${name}_$n') || '${name}_$n' == kSystemTagName) {
              n++;
            }
            final renamed = '${name}_$n';
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Variable "$name" renamed to "$renamed" (name collision'
                    '${name == kSystemTagName ? '/reserved' : ''}).'));
            name = renamed;
          }
          if (name != original) {
            for (final b in tr.blocks) {
              if (fbRes.registry.containsKey(b.type) && b.tagBinding == original) {
                b.tagBinding = name;
              }
            }
          }
          used.add(name);
          it.name = name;
          it.path = name;
          tags.add(it);
        }
        programs.add(PlcProgram(name: pou.name, language: 'FunctionBlockDiagram',
            fbdBlocks: tr.blocks, fbdWires: tr.wires, fbdNetworks: tr.networks));
      } else {
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (FunctionBlockDiagram): graphical body not yet '
                'translated (${body.nodes.length} elements captured) — re-import once '
                'graphical translation ships.'));
        programs.add(PlcProgram(name: pou.name, language: 'FunctionBlockDiagram',
            description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
        stubCount++;
      }
    } else if (body is GraphBody) {
      // SFC (and any other graphical): unchanged whole-POU stub.
      final lang = switch (pou.lang) {
        PouLanguage.sfc => 'SequentialFunctionChart',
        _ => 'StructuredText',
      };
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'POU "${pou.name}" ($lang): graphical body not yet translated '
              '(${body.nodes.length} elements captured) — re-import once graphical '
              'translation ships.'));
      programs.add(PlcProgram(name: pou.name, language: lang,
          description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
      stubCount++;
    }
```

- [ ] **Step 5: Thread the new fields into the returned `ImportReport`**

In the `return ImportResult(... report: ImportReport(...))` at the end of `mapImportedProject`, add the four new arguments:

```dart
        translatedFbdNetworkCount: translatedFbdNetworkCount,
        stubbedFbdNetworkCount: stubbedFbdNetworkCount,
        unsupportedFbdBlockTypes: unsupportedFbdBlockTypes,
        fbdStubReasons: fbdStubReasons,
```

- [ ] **Step 6: Run the mapper test + full import suite**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/`
Expected: PASS. If `corpus_import_test.dart` asserts on the exact stub warning text or `graphicalStubCount` for the `fbd_block.xml` fixture (whose FBD POU mixes `contact`/`coil` with a block → all one component → stubs on `unsupported-element` → still whole-POU stub), confirm those expectations still hold; the FBD POU count as a graphical stub is unchanged (0 translated networks). Update any assertion that checked the *combined* FBD/SFC warning wording only if it now reads "FunctionBlockDiagram" specifically — the message text is otherwise identical.

- [ ] **Step 7: Surface FBD counts in the preview**

In `mobile/lib/screens/import_xml_preview.dart`, after the `if (report.stubbedRungCount > 0) ...[ ... ]` block and before/near the `importedFbCount` block, add:

```dart
              if (report.translatedFbdNetworkCount > 0 ||
                  report.stubbedFbdNetworkCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'FBD: ${report.translatedFbdNetworkCount} network(s) translated'
                  '${report.stubbedFbdNetworkCount > 0 ? ', ${report.stubbedFbdNetworkCount} stubbed' : ''}'
                  '${report.unsupportedFbdBlockTypes.isNotEmpty ? ' — unsupported blocks: ${report.unsupportedFbdBlockTypes.join(', ')}' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
```

- [ ] **Step 8: Run the widget/flow test + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/import_xml_flow_test.dart && /c/flutter/bin/flutter analyze`
Expected: PASS; no analyzer issues.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/import/ir_to_project.dart mobile/lib/screens/import_xml_preview.dart mobile/test/import/ir_to_project_test.dart
git commit -m "feat(import): wire FBD translator into mapper + report + preview

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end proof + docs + full validation

**Files:**
- Create: `mobile/test/import/import_fbd_e2e_test.dart`
- Modify: `docs/iec61131/` (FBD import notes), `docs/DEFERRED.md`
- (Possibly) Modify: `docs/iec61131/FUNCTION_BLOCKS.md` import note

**Interfaces:**
- Consumes: the full pipeline — `parsePlcOpen` → `mapImportedProject` → `executeFbdPrograms` (`fbd_exec.dart`, `FbdRuntime`), `readPath`/`writePath` (`tag_resolver.dart`).
- Produces: an executable end-to-end proof and up-to-date docs.

- [ ] **Step 1: Write the failing end-to-end test**

Create `mobile/test/import/import_fbd_e2e_test.dart`. It uses `<expression>` operands (proving the Task-1 parser change) and asserts cross-network tag flow + a custom-FB variant:

```dart
// End-to-end proof: a handcrafted-but-spec-faithful PLCopen TC6 FBD POU imports
// as a real, executing FunctionBlockDiagram program. Exercises: <expression>
// operands (Task 1 parser fallback), component-per-network segmentation with a
// tag hop across networks (Task 3), and a custom-FB call routed to an instance
// (Task 4). Pipeline: parsePlcOpen -> mapImportedProject -> executeFbdPrograms.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="FbdE2E"/>
  <types>
    <dataTypes/>
    <pous>
      <pou name="Scaler" pouType="functionBlock">
        <interface>
          <inputVars>
            <variable name="In"><type><REAL/></type></variable>
            <variable name="Gain"><type><REAL/></type></variable>
          </inputVars>
          <outputVars>
            <variable name="Out"><type><REAL/></type></variable>
          </outputVars>
        </interface>
        <body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Out := In * Gain;</xhtml></ST></body>
      </pou>
      <pou name="Logic" pouType="program">
        <interface><localVars/></interface>
        <body><FBD>
          <!-- Network A: Mid := Scaler(In := PV, Gain := 2.0) -->
          <inVariable localId="1"><position x="0" y="0"/><expression>PV</expression>
            <connectionPointOut/></inVariable>
          <inVariable localId="2"><position x="0" y="40"/><expression>2.0</expression>
            <connectionPointOut/></inVariable>
          <block localId="3" typeName="Scaler" instanceName="S1"><position x="60" y="0"/>
            <inputVariables>
              <variable formalParameter="In">
                <connectionPointIn><connection refLocalId="1"/></connectionPointIn></variable>
              <variable formalParameter="Gain">
                <connectionPointIn><connection refLocalId="2"/></connectionPointIn></variable>
            </inputVariables>
            <outputVariables>
              <variable formalParameter="Out"><connectionPointOut/></variable>
            </outputVariables>
          </block>
          <outVariable localId="4"><position x="150" y="0"/><expression>Mid</expression>
            <connectionPointIn><connection refLocalId="3" formalParameter="Out"/></connectionPointIn>
          </outVariable>
          <!-- Network B (below): CV := Mid (reads what network A wrote, same scan) -->
          <inVariable localId="5"><position x="0" y="200"/><expression>Mid</expression>
            <connectionPointOut/></inVariable>
          <outVariable localId="6"><position x="150" y="200"/><expression>CV</expression>
            <connectionPointIn><connection refLocalId="5"/></connectionPointIn>
          </outVariable>
        </FBD></body>
      </pou>
    </pous>
  </types>
  <instances>
    <configurations>
      <configuration name="Config">
        <resource name="Res">
          <globalVars>
            <variable name="PV"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
            <variable name="Mid"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
            <variable name="CV"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
          </globalVars>
        </resource>
      </configuration>
    </configurations>
  </instances>
</project>
''';

void main() {
  test('FBD POU imports as an executing multi-network program with a custom FB', () {
    final ir = parsePlcOpen(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'fbd_e2e');
    final p = res.project;

    // Scaler imported as a native FB; Logic is a real FBD program (not a stub).
    expect(p.fbDefinitions.map((f) => f.name), contains('Scaler'));
    final logic = p.programs.firstWhere((pr) => pr.name == 'Logic');
    expect(logic.language, 'FunctionBlockDiagram');
    expect(logic.fbdBlocks, isNotEmpty);
    expect(res.report.translatedFbdNetworkCount, 2);

    // The FB call routed to an instance tag, struct-typed to the FB.
    final scalerBlock = logic.fbdBlocks.firstWhere((b) => b.type == 'Scaler');
    expect(p.tags.firstWhere((t) => t.name == scalerBlock.tagBinding).dataType, 'Scaler');

    // And it RUNS: PV=10 -> Mid = 10*2 = 20 (network A) -> CV = 20 (network B,
    // reads Mid written by A in the same scan via network ordering).
    writePath(p, 'PV', 10.0);
    final rt = FbdRuntime();
    executeFbdPrograms(p, 100, rt);
    expect(readPath(p, 'Mid'), 20.0);
    expect(readPath(p, 'CV'), 20.0);
  });
}
```

- [ ] **Step 2: Run the e2e test to verify it fails, then passes**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/import_fbd_e2e_test.dart`
Expected: With Tasks 1–5 already committed, this should PASS on first run. If it FAILS, diagnose against the failing assertion (common causes: network ordering — network A must be index 0 because its min-y (0) < network B's (200); the FB instance default requires the fb-aware scratch project in `_buildBlock`). Fix the underlying code (not the test) and re-run until PASS.

- [ ] **Step 3: Update the IEC docs**

In `docs/iec61131/` add/extend the FBD import section (mirror the LD import notes). Include a support matrix:

```markdown
## FBD import (PLCopen → native FunctionBlockDiagram)

Imported FBD POUs translate per **network** (one native network per
weakly-connected component of the diagram, ordered top-to-bottom / left-to-right
by element position). A network translates fully or degrades to an empty network
with an explanatory comment plus a warning (faithful-or-stub).

| Source element | Native mapping |
| --- | --- |
| `<block>` (built-in `AND`/`OR`/`NOT`/`ADD`/…/`TON`/`CTU`/…) | `FbdBlock(type)`; extensible `inputCount` from wired `IN<n>` pins |
| `<block>` (custom FB, ST-bodied) | `FbdBlock(type = FB name, tagBinding = instance)` + struct-typed instance tag |
| `<inVariable>` (identifier) | `TAG_INPUT` bound to the tag |
| `<inVariable>` (literal `5`/`TRUE`) | `CONST` |
| `<outVariable>` (identifier) | `TAG_OUTPUT` bound to the tag |
| operand in `<expression>` | read the same as `<variable>` (identifier/literal only) |

Stubbed (whole network) — with the `stubReasons` key: `inOutVariable` /
`connector` / `continuation` / `label` / `jump` (`unsupported-element`);
negated pins (`negated-pin`); compound `<expression>` (`complex-expression`);
unknown block type (`unsupported-block`); a wire to an unknown pin
(`unresolved-pin`).
```

- [ ] **Step 4: Update `docs/DEFERRED.md`**

- Strike (wrap in `~~`) the "`<expression>`-dialect FB call operands" row (line ~49) — now handled by the parser fallback.
- Strike the "FBD custom-FB call routing" row (line ~41) and the "FBD import translator" row (line ~69) — delivered here; note the delivering feature and the e2e test path (`mobile/test/import/import_fbd_e2e_test.dart`), matching how the IMPORT-FB rows were struck.
- Add new deferred rows under the FBD graphical-translators section: negated FBD pins (NOT-block insertion); `inOutVariable`; `connector`/`continuation` cross-references; `label`/`jump` execution control; compound-expression operands (a small expression→block compiler). Leave "SFC import translator" as the remaining sub-project.

- [ ] **Step 5: Full validation — whole suite + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test`
Expected: entire suite PASS (the pre-change baseline was 2641 passing; this adds tests and must not regress any).

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add mobile/test/import/import_fbd_e2e_test.dart docs/iec61131 docs/DEFERRED.md
git commit -m "test(import): FBD import e2e + docs; strike delivered deferred rows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §1 new unit `fbd_translate.dart` → Tasks 3–4. ✅
- §1.1 shared component segmentation → Task 2. ✅
- §1.2 element→block mapping (block/inVariable/outVariable, CONST/TAG_INPUT/TAG_OUTPUT, custom FB, inputCount) → Tasks 3 (built-ins) + 4 (FB). ✅
- §1.3 wires + pin-faithfulness gate → Task 3 (`_assertPin`). ✅
- §1.4 faithful-or-stub assembly, staged instance names → Task 3. ✅
- §2 mapper integration + report fields → Task 5. ✅
- §3 parser `<expression>` fallback → Task 1. ✅
- §5 preview surfacing → Task 5 (Step 7). ✅
- §6 error handling incl. negated pins → Task 1 (flag) + Task 3 (stub). ✅
- §7 testing (parser, translate unit, custom-FB, e2e, backward-compat) → Tasks 1,3,4,6. ✅
- §8 docs → Task 6. ✅
- §9 deferred rows → Task 6 Step 4. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. The only judgment call ("update any assertion that checked the combined FBD/SFC warning wording", Task 5 Step 6) is a conditional fixup with the exact condition stated, not an open placeholder.

**3. Type consistency:**
- `weaklyConnectedComponents(List<IrGraphNode>, List<IrConnection>, {Set<int> excludeIds})` → `List<List<IrGraphNode>>` — same signature in Task 2 def, LD refactor, and Task 3 call. ✅
- `FbdTranslation` field names (`blocks`/`wires`/`networks`/`instanceTags`/`translatedNetworkCount`/`stubbedNetworkCount`/`unsupportedBlockTypes`/`stubReasons`/`warnings`) — identical in Task 3 def, Task 5 consumer. ✅
- `translateFbdBody(GraphBody, {required String pouName, Map<String,FbDefinition> fbRegistry, Map<String,String> fbRenameMap})` — identical Task 3 def and Task 5 call. ✅
- Report fields `translatedFbdNetworkCount`/`stubbedFbdNetworkCount`/`unsupportedFbdBlockTypes`/`fbdStubReasons` — identical in Task 5 model, mapper, preview, and Task 6 e2e assertions. ✅
- `FbdBlock(id:, type:, title:, tagBinding:, x:, y:)` + `.network`/`.inputCount` setters — matches `project_model.dart`. ✅
- `_FbdStub(reason, detail)` reason keys (`unsupported-element`/`negated-pin`/`unsupported-block`/`unresolved-operand`/`complex-expression`/`unresolved-pin`) — used consistently in Task 3/4 code and Task 3 tests. ✅

All consistent. Plan ready.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-07-26-fbd-import-translator.md`. Six tasks, each an independently testable deliverable, mirroring the LD translator's proven structure.
