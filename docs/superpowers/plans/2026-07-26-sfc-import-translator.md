# SFC Import Translator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate imported PLCopen SFC POUs (today whole-POU stubbed) into real, executable native `SequentialFunctionChart` program bodies — the last of the three graphical-import translators.

**Architecture:** The parser extracts each SFC POU into a dedicated typed `SfcBody` IR (steps, transitions-with-conditions, action-associations-with-qualifiers, branch/jump nodes, referenced-ST-body maps). A new pure unit `lib/import/sfc_translate.dart` maps that IR to native steps/transitions: sequences + selection (→ multiple `single`) + parallel (→ `parallelFork`/`parallelJoin`) + jumps, resolving inline + referenced-ST conditions/actions. Whole-POU faithful-or-stub for structure + conditions; unrepresentable actions degrade to a no-op + warning.

**Tech Stack:** Dart (Flutter package `soft_plc_mobile`, in `mobile/`). Pure Dart, no new dependencies. Run all `flutter` commands from `mobile/`; `flutter` is at `/c/flutter/bin/flutter`.

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never-throws** — an untranslatable chart degrades to the whole-POU stub; the pipeline continues. (An internal `_SfcStub` exception is used for control flow and is ALWAYS caught inside `translateSfcBody`.)
- Zero `flutter analyze` warnings (run from `mobile/`).
- **Additive / backward-compatible:** a project with no SFC POUs imports byte-identically. The SFC path fires only on `pou.lang == PouLanguage.sfc`. Existing PLCopen corpus/round-trip tests and the app's own SFC round-trip/exec tests stay green.
- Only N (non-stored) action qualifiers map to `actionSt`; non-N (S/R/P/L/D/…) and unresolved actions degrade to no-op + warning. Multiple N actions on one step concatenate with `\n`, in declaration order.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- **Modify** `mobile/lib/import/import_ir.dart` — new typed `SfcBody` + node/cond/action types.
- **Modify** `mobile/lib/import/plcopen_parser.dart` — route SFC POUs to a new `_sfcBody` builder.
- **Modify** `mobile/lib/import/ir_to_project.dart` — `body is SfcBody` arm (stub in Task 1, translator call in Task 4); report fields.
- **Create** `mobile/lib/import/sfc_translate.dart` — the SFC translator.
- **Modify** `mobile/lib/screens/import_xml_preview.dart` — surface SFC counts.
- **Create/Modify tests** under `mobile/test/import/`.
- **Modify docs** `docs/iec61131/*`, `docs/DEFERRED.md`.

---

### Task 1: Typed `SfcBody` IR + parser `_sfcBody` + behavior-preserving mapper arm

**Files:**
- Modify: `mobile/lib/import/import_ir.dart` (add SFC IR types)
- Modify: `mobile/lib/import/plcopen_parser.dart` (`_pou` routing + new `_sfcBody`)
- Modify: `mobile/lib/import/ir_to_project.dart` (add a `body is SfcBody` whole-POU-stub arm)
- Test: `mobile/test/import/plcopen_parser_test.dart`, `mobile/test/import/sfc_body_test.dart` (create)

**Interfaces:**
- Consumes: existing `PouBody`, `_findElement`, `_descendants`, `_pou`; `ImportedProject`/`ImportedPou`.
- Produces: `SfcBody extends PouBody` with `List<SfcNode> nodes`, `List<SfcEdge> edges`, `List<SfcActionAssoc> actions`, `Map<String,String> refBodies`, `Set<String> graphicalRefs`; supporting types `SfcNode`, `SfcNodeKind`, `SfcEdge`, `SfcCond` (sealed: `SfcCondInline`/`SfcCondRef`/`SfcCondWired`/`SfcCondNone`), `SfcActionAssoc`, `SfcActSource` (sealed: `SfcActInline`/`SfcActRef`). After this task, `parsePlcOpen` yields an `SfcBody` for an SFC POU, and the mapper keeps emitting the same whole-POU SFC stub as before (behavior-preserving).

- [ ] **Step 1: Add the SFC IR types**

Append to `mobile/lib/import/import_ir.dart` (after the existing `GraphBody` class):

```dart
enum SfcNodeKind { step, transition, selDiv, selConv, simDiv, simConv, jump }

/// A transition's condition source.
sealed class SfcCond {}
class SfcCondInline extends SfcCond { final String text; SfcCondInline(this.text); }
class SfcCondRef extends SfcCond { final String name; SfcCondRef(this.name); }
class SfcCondWired extends SfcCond {}
class SfcCondNone extends SfcCond {}

/// A step action's source.
sealed class SfcActSource {}
class SfcActInline extends SfcActSource { final String text; SfcActInline(this.text); }
class SfcActRef extends SfcActSource { final String name; SfcActRef(this.name); }

class SfcActionAssoc {
  final int stepLocalId;
  final String qualifier; // 'N','S','R','P','L','D',...
  final SfcActSource source;
  SfcActionAssoc({required this.stepLocalId, required this.qualifier, required this.source});
}

class SfcNode {
  final int localId;
  final SfcNodeKind kind;
  final double x, y;
  final String name;      // step name / jump targetName / '' otherwise
  final bool initial;     // step only
  final SfcCond? condition; // transition only
  SfcNode({required this.localId, required this.kind, this.x = 0, this.y = 0,
      this.name = '', this.initial = false, this.condition});
}

class SfcEdge {
  final int fromLocalId, toLocalId;
  SfcEdge({required this.fromLocalId, required this.toLocalId});
}

class SfcBody extends PouBody {
  final List<SfcNode> nodes;
  final List<SfcEdge> edges;
  final List<SfcActionAssoc> actions;
  final Map<String, String> refBodies;  // name -> ST source
  final Set<String> graphicalRefs;       // names of referenced graphical (non-ST) bodies
  SfcBody({required this.nodes, required this.edges, required this.actions,
      this.refBodies = const {}, this.graphicalRefs = const {}});
}
```

- [ ] **Step 2: Write the failing parser test**

Create `mobile/test/import/sfc_body_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';

const _kSfcXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="SfcProj"/>
  <types><dataTypes/><pous>
    <pou name="Chart" pouType="program">
      <interface><localVars/></interface>
      <actions>
        <action name="RunAct"><body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Motor := TRUE;</xhtml></ST></body></action>
      </actions>
      <transitions>
        <transition name="ToRun"><body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Start</xhtml></ST></body></transition>
      </transitions>
      <body><SFC>
        <step localId="1" name="Idle" initialStep="true"><position x="0" y="0"/>
          <connectionPointIn><connection refLocalId="3"/></connectionPointIn></step>
        <transition localId="2"><position x="0" y="40"/>
          <connectionPointIn><connection refLocalId="1"/></connectionPointIn>
          <condition><reference name="ToRun"/></condition></transition>
        <step localId="3" name="Run"><position x="0" y="80"/>
          <connectionPointIn><connection refLocalId="2"/></connectionPointIn></step>
        <actionBlock localId="9"><position x="60" y="80"/>
          <connectionPointIn><connection refLocalId="3"/></connectionPointIn>
          <action qualifier="N"><reference name="RunAct"/></action></actionBlock>
      </SFC></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';

void main() {
  test('SFC POU parses into a populated SfcBody', () {
    final ir = parsePlcOpen(_kSfcXml);
    final pou = ir.pous.single;
    expect(pou.lang, PouLanguage.sfc);
    final body = pou.body as SfcBody;

    final steps = body.nodes.where((n) => n.kind == SfcNodeKind.step).toList();
    expect(steps.map((s) => s.name), containsAll(['Idle', 'Run']));
    expect(steps.firstWhere((s) => s.name == 'Idle').initial, isTrue);

    final trans = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.transition);
    expect(trans.condition, isA<SfcCondRef>());
    expect((trans.condition as SfcCondRef).name, 'ToRun');

    // edges: 3->1, 1->2, 2->3 (from each node's connectionPointIn)
    bool hasEdge(int f, int t) => body.edges.any((e) => e.fromLocalId == f && e.toLocalId == t);
    expect(hasEdge(1, 2), isTrue);
    expect(hasEdge(2, 3), isTrue);

    // action association: step 3 (Run) has an N action referencing RunAct
    final act = body.actions.singleWhere((a) => a.stepLocalId == 3);
    expect(act.qualifier, 'N');
    expect(act.source, isA<SfcActRef>());
    expect((act.source as SfcActRef).name, 'RunAct');

    // referenced ST bodies captured
    expect(body.refBodies['RunAct'], 'Motor := TRUE;');
    expect(body.refBodies['ToRun'], 'Start');
    expect(body.graphicalRefs, isEmpty);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/sfc_body_test.dart`
Expected: FAIL — `pou.body` is a `GraphBody`, not `SfcBody` (the `as SfcBody` cast throws).

- [ ] **Step 4: Route SFC POUs to `_sfcBody` in the parser**

In `mobile/lib/import/plcopen_parser.dart`, change the body-routing block in `_pou` (the `else` at ~line 171-174) so SFC gets its own builder. Replace:

```dart
  } else {
    resolvedLang = lang;
    pouBody = _graphBody(langEl, warnings, name);
  }
```

with:

```dart
  } else if (lang == PouLanguage.sfc) {
    resolvedLang = lang;
    pouBody = _sfcBody(langEl, p, warnings, name);
  } else {
    resolvedLang = lang;
    pouBody = _graphBody(langEl, warnings, name);
  }
```

(`p` is the `<pou>` `XmlElement` already in scope in `_pou`.)

- [ ] **Step 5: Implement `_sfcBody` + helpers**

Add to `mobile/lib/import/plcopen_parser.dart` (near `_graphBody`):

```dart
SfcBody _sfcBody(XmlElement? langEl, XmlElement pouEl,
    List<ImportWarning> warnings, String pouName) {
  final nodes = <SfcNode>[];
  final edges = <SfcEdge>[];
  final actions = <SfcActionAssoc>[];

  if (langEl != null) {
    for (final el in langEl.childElements) {
      if (el.name.local == 'actionBlock') {
        _collectSfcActions(el, actions);
        continue; // not a topology node
      }
      final kind = switch (el.name.local) {
        'step' => SfcNodeKind.step,
        'transition' => SfcNodeKind.transition,
        'selectionDivergence' => SfcNodeKind.selDiv,
        'selectionConvergence' => SfcNodeKind.selConv,
        'simultaneousDivergence' => SfcNodeKind.simDiv,
        'simultaneousConvergence' => SfcNodeKind.simConv,
        'jumpStep' => SfcNodeKind.jump,
        'jump' => SfcNodeKind.jump,
        _ => null,
      };
      if (kind == null) continue;
      final localId = int.tryParse(el.getAttribute('localId') ?? '');
      if (localId == null) continue;
      final pos = _findElement(el, 'position');
      final x = double.tryParse(pos?.getAttribute('x') ?? '') ?? 0;
      final y = double.tryParse(pos?.getAttribute('y') ?? '') ?? 0;
      final name = el.getAttribute('name') ?? el.getAttribute('targetName') ?? '';
      final initial =
          (el.getAttribute('initialStep') ?? 'false').toLowerCase() == 'true';
      final cond =
          kind == SfcNodeKind.transition ? _parseSfcCondition(el) : null;
      nodes.add(SfcNode(localId: localId, kind: kind, x: x, y: y, name: name,
          initial: initial, condition: cond));
      // Topology edges: a step/transition/connector's DIRECT connectionPointIn
      // (not descendants — a wired condition's own connectionPointIn must not
      // be read as a topology edge).
      for (final cpi
          in el.childElements.where((e) => e.name.local == 'connectionPointIn')) {
        for (final c in cpi.findElements('connection')) {
          final from = int.tryParse(c.getAttribute('refLocalId') ?? '');
          if (from != null) {
            edges.add(SfcEdge(fromLocalId: from, toLocalId: localId));
          }
        }
      }
    }
  }

  // Referenced local action/transition bodies (siblings of <body> under <pou>).
  final refBodies = <String, String>{};
  final graphicalRefs = <String>{};
  for (final section in pouEl.childElements.where(
      (e) => e.name.local == 'transitions' || e.name.local == 'actions')) {
    final childName =
        section.name.local == 'transitions' ? 'transition' : 'action';
    for (final item
        in section.childElements.where((e) => e.name.local == childName)) {
      final nm = item.getAttribute('name');
      if (nm == null || nm.isEmpty) continue;
      final st = _findElement(item, 'ST') ?? _findElement(item, 'IL');
      if (st != null) {
        refBodies[nm] = st.innerText.trim();
      } else if (_findElement(item, 'LD') != null ||
          _findElement(item, 'FBD') != null ||
          _findElement(item, 'SFC') != null) {
        graphicalRefs.add(nm);
      } else {
        // A named transition may hold its condition inline under <condition>.
        final cond = _findElement(item, 'condition');
        final text = cond?.innerText.trim() ?? '';
        if (text.isNotEmpty) refBodies[nm] = text;
      }
    }
  }

  return SfcBody(nodes: nodes, edges: edges, actions: actions,
      refBodies: refBodies, graphicalRefs: graphicalRefs);
}

/// Parses a `<transition>`'s `<condition>` into an [SfcCond].
SfcCond _parseSfcCondition(XmlElement transEl) {
  final cond = _findElement(transEl, 'condition');
  if (cond == null) return SfcCondNone();
  final ref = _findElement(cond, 'reference');
  final refName = ref?.getAttribute('name');
  if (refName != null && refName.isNotEmpty) return SfcCondRef(refName);
  // A wired condition carries its own connectionPointIn INSIDE <condition>.
  if (_findElement(cond, 'connectionPointIn') != null) return SfcCondWired();
  final inline = _findElement(cond, 'ST') ?? _findElement(cond, 'inline');
  final text = (inline?.innerText ?? cond.innerText).trim();
  return text.isEmpty ? SfcCondNone() : SfcCondInline(text);
}

/// Collects the `<action>`s of an `<actionBlock>` and associates them with the
/// step referenced by the block's direct `connectionPointIn`.
void _collectSfcActions(XmlElement ab, List<SfcActionAssoc> out) {
  int? stepLocalId;
  for (final cpi
      in ab.childElements.where((e) => e.name.local == 'connectionPointIn')) {
    for (final c in cpi.findElements('connection')) {
      stepLocalId = int.tryParse(c.getAttribute('refLocalId') ?? '') ?? stepLocalId;
    }
  }
  if (stepLocalId == null) return; // can't associate -> drop
  for (final act in ab.findElements('action')) {
    final qual = act.getAttribute('qualifier') ?? 'N';
    final ref = _findElement(act, 'reference');
    final refName = ref?.getAttribute('name');
    final SfcActSource source;
    if (refName != null && refName.isNotEmpty) {
      source = SfcActRef(refName);
    } else {
      final st = _findElement(act, 'ST') ?? _findElement(act, 'inline');
      source = SfcActInline((st?.innerText ?? act.innerText).trim());
    }
    out.add(SfcActionAssoc(stepLocalId: stepLocalId, qualifier: qual, source: source));
  }
}
```

- [ ] **Step 6: Run the parser test to verify it passes**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/sfc_body_test.dart`
Expected: PASS.

- [ ] **Step 7: Add a behavior-preserving `body is SfcBody` stub arm in the mapper**

SFC POUs no longer produce a `GraphBody`, so without this arm they would vanish from the program list. In `mobile/lib/import/ir_to_project.dart`, add — immediately BEFORE the `} else if (body is GraphBody) {` arm — an SfcBody arm that reproduces today's whole-POU SFC stub:

```dart
    } else if (body is SfcBody) {
      // SFC whole-POU stub (translator wired in a later task). Unchanged
      // behaviour: an SFC POU imports as a stub SequentialFunctionChart program.
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'POU "${pou.name}" (SequentialFunctionChart): graphical body not '
              'yet translated (${body.nodes.length} elements captured) — re-import '
              'once graphical translation ships.'));
      programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
          description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
      stubCount++;
    } else if (body is GraphBody) {
```

- [ ] **Step 8: Run the import suite (behavior preserved)**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/ && /c/flutter/bin/flutter analyze`
Expected: PASS, no analyzer issues. SFC POUs still import as stub programs (graphicalStubCount unchanged); no existing test regresses.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/import/import_ir.dart mobile/lib/import/plcopen_parser.dart mobile/lib/import/ir_to_project.dart mobile/test/import/sfc_body_test.dart
git commit -m "feat(import): typed SfcBody IR + parser SFC body extraction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: SFC translator core — steps, actions, conditions, single transitions

**Files:**
- Create: `mobile/lib/import/sfc_translate.dart`
- Test: `mobile/test/import/sfc_translate_test.dart` (create)

**Interfaces:**
- Consumes: `SfcBody`/`SfcNode`/`SfcNodeKind`/`SfcEdge`/`SfcCond`(+subtypes)/`SfcActionAssoc`/`SfcActSource`(+subtypes)/`ImportWarning`/`WarningSeverity` (`import_ir.dart`); `SfcStep`/`SfcTransition` (`project_model.dart`).
- Produces:
  ```dart
  class SfcTranslation {
    final List<SfcStep> steps;
    final List<SfcTransition> transitions;
    final bool translated;        // false => caller keeps the whole-POU stub
    final String? stubReason;
    final List<ImportWarning> warnings;
    SfcTranslation({required this.steps, required this.transitions,
      required this.translated, required this.stubReason, required this.warnings});
  }
  SfcTranslation translateSfcBody(SfcBody body, {required String pouName});
  ```
  Task 2 handles linear + selection + jump topologies (all emit `kind:'single'` transitions). A simultaneous divergence/convergence stubs the whole POU here (`complex-topology`); Task 3 adds real fork/join.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/import/sfc_translate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/sfc_translate.dart';

SfcNode _step(int id, String name, {bool initial = false}) =>
    SfcNode(localId: id, kind: SfcNodeKind.step, name: name, initial: initial);
SfcNode _trans(int id, SfcCond cond) =>
    SfcNode(localId: id, kind: SfcNodeKind.transition, condition: cond);
SfcNode _conn(int id, SfcNodeKind kind) => SfcNode(localId: id, kind: kind);
SfcNode _jump(int id, String target) =>
    SfcNode(localId: id, kind: SfcNodeKind.jump, name: target);
SfcEdge _e(int f, int t) => SfcEdge(fromLocalId: f, toLocalId: t);

void main() {
  test('linear 3-step chart -> 3 steps + 2 single transitions', () {
    // Idle -(t2:Start)-> Run -(t4:Done)-> Idle
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondInline('Start')),
      _step(3, 'Run'),
      _trans(4, SfcCondInline('Done')),
    ], edges: [
      _e(1, 2), _e(2, 3), _e(3, 4), _e(4, 1),
    ], actions: [
      SfcActionAssoc(stepLocalId: 3, qualifier: 'N', source: SfcActInline('Motor := TRUE;')),
    ]);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    expect(tr.steps.map((s) => s.name), ['Idle', 'Run']);
    expect(tr.steps.firstWhere((s) => s.name == 'Idle').isInitial, isTrue);
    expect(tr.steps.firstWhere((s) => s.name == 'Run').actionSt, 'Motor := TRUE;');
    expect(tr.transitions, hasLength(2));
    final t1 = tr.transitions.firstWhere((t) => t.conditionSt == 'Start');
    expect(t1.kind, 'single');
    expect(t1.fromStepId, 'P_s1');
    expect(t1.toStepId, 'P_s3');
  });

  test('selection divergence -> multiple single transitions from one step', () {
    // Idle -> selDiv -> {t3:CondA -> A, t5:CondB -> B}
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _conn(2, SfcNodeKind.selDiv),
      _trans(3, SfcCondInline('CondA')),
      _step(4, 'A'),
      _trans(5, SfcCondInline('CondB')),
      _step(6, 'B'),
    ], edges: [
      _e(1, 2), _e(2, 3), _e(2, 5), _e(3, 4), _e(5, 6),
    ], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    final fromIdle = tr.transitions.where((t) => t.fromStepId == 'P_s1').toList();
    expect(fromIdle, hasLength(2));
    expect(fromIdle.map((t) => t.toStepId).toSet(), {'P_s4', 'P_s6'});
    expect(fromIdle.every((t) => t.kind == 'single'), isTrue);
  });

  test('jump resolves to the named step', () {
    // Idle -(t2)-> Run -(t4)-> jump(Idle)
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondInline('Go')),
      _step(3, 'Run'),
      _trans(4, SfcCondInline('Back')),
      _jump(5, 'Idle'),
    ], edges: [
      _e(1, 2), _e(2, 3), _e(3, 4), _e(4, 5),
    ], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    final back = tr.transitions.firstWhere((t) => t.conditionSt == 'Back');
    expect(back.toStepId, 'P_s1'); // jumped to Idle
  });

  test('referenced ST condition + action resolve', () {
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondRef('ToRun')),
      _step(3, 'Run'),
    ], edges: [
      _e(1, 2), _e(2, 3),
    ], actions: [
      SfcActionAssoc(stepLocalId: 3, qualifier: 'N', source: SfcActRef('RunAct')),
    ], refBodies: {'ToRun': 'Start', 'RunAct': 'Motor := TRUE;'});
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    expect(tr.transitions.single.conditionSt, 'Start');
    expect(tr.steps.firstWhere((s) => s.name == 'Run').actionSt, 'Motor := TRUE;');
  });

  test('non-N action qualifier skipped with warning; chart still translates', () {
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondInline('Go')),
      _step(3, 'Run'),
    ], edges: [_e(1, 2), _e(2, 3)], actions: [
      SfcActionAssoc(stepLocalId: 3, qualifier: 'S', source: SfcActInline('Latched := TRUE;')),
    ]);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    expect(tr.steps.firstWhere((s) => s.name == 'Run').actionSt, '');
    expect(tr.warnings.any((w) => w.message.contains('qualifier')), isTrue);
  });

  test('wired condition stubs the whole POU', () {
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondWired()),
      _step(3, 'Run'),
    ], edges: [_e(1, 2), _e(2, 3)], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isFalse);
    expect(tr.stubReason, 'wired-condition');
  });

  test('referenced-but-graphical condition stubs the whole POU', () {
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondRef('GraphCond')),
      _step(3, 'Run'),
    ], edges: [_e(1, 2), _e(2, 3)], actions: const [],
        graphicalRefs: {'GraphCond'});
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isFalse);
    expect(tr.stubReason, 'unresolved-condition');
  });

  test('no steps stubs (no-initial)', () {
    final tr = translateSfcBody(
        SfcBody(nodes: const [], edges: const [], actions: const []),
        pouName: 'P');
    expect(tr.translated, isFalse);
    expect(tr.stubReason, 'no-initial');
  });

  test('no initial marked -> first step made initial + info warning', () {
    final body = SfcBody(nodes: [
      _step(1, 'A'), _trans(2, SfcCondInline('c')), _step(3, 'B'),
    ], edges: [_e(1, 2), _e(2, 3)], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    expect(tr.steps.first.isInitial, isTrue);
    expect(tr.warnings.any((w) => w.message.contains('no initial step')), isTrue);
  });

  test('simultaneous divergence stubs in Task 2 (parallel not yet supported)', () {
    // Idle -(t2)-> simDiv -> {A, B}
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondInline('Go')),
      _conn(3, SfcNodeKind.simDiv),
      _step(4, 'A'),
      _step(5, 'B'),
    ], edges: [_e(1, 2), _e(2, 3), _e(3, 4), _e(3, 5)], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isFalse);
    expect(tr.stubReason, 'complex-topology');
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/sfc_translate_test.dart`
Expected: FAIL — `sfc_translate.dart` / `translateSfcBody` does not exist (compile error).

- [ ] **Step 3: Implement the translator core**

Create `mobile/lib/import/sfc_translate.dart`:

```dart
import '../models/project_model.dart';
import 'import_ir.dart';

/// Result of translating one SFC `SfcBody`. `translated == false` tells the
/// mapper to keep today's whole-POU stub; `stubReason` is the `sfcStubReasons`
/// key. SFC is whole-POU faithful-or-stub for structure + conditions; an
/// unrepresentable step action degrades to a no-op + warning (chart still
/// translates). Pure, deterministic, never-throws.
class SfcTranslation {
  final List<SfcStep> steps;
  final List<SfcTransition> transitions;
  final bool translated;
  final String? stubReason;
  final List<ImportWarning> warnings;
  SfcTranslation({required this.steps, required this.transitions,
      required this.translated, required this.stubReason, required this.warnings});
}

/// Internal whole-POU bail-out. Always caught inside [translateSfcBody].
class _SfcStub implements Exception {
  final String reason;
  final String detail;
  _SfcStub(this.reason, this.detail);
}

SfcTranslation translateSfcBody(SfcBody body, {required String pouName}) {
  final warnings = <ImportWarning>[];
  try {
    final built = _build(body, pouName, warnings);
    return SfcTranslation(steps: built.$1, transitions: built.$2,
        translated: true, stubReason: null, warnings: warnings);
  } on _SfcStub catch (e) {
    return SfcTranslation(steps: const [], transitions: const [],
        translated: false, stubReason: e.reason, warnings: warnings);
  }
}

(List<SfcStep>, List<SfcTransition>) _build(
    SfcBody body, String pouName, List<ImportWarning> warnings) {
  final stepNodes = [for (final n in body.nodes) if (n.kind == SfcNodeKind.step) n];
  if (stepNodes.isEmpty) throw _SfcStub('no-initial', 'chart has no steps');

  final byId = {for (final n in body.nodes) n.localId: n};
  final succ = <int, List<int>>{for (final n in body.nodes) n.localId: []};
  final pred = <int, List<int>>{for (final n in body.nodes) n.localId: []};
  for (final e in body.edges) {
    succ[e.fromLocalId]?.add(e.toLocalId);
    pred[e.toLocalId]?.add(e.fromLocalId);
  }

  String stepId(int localId) => '${pouName}_s$localId';
  SfcNode? stepByName(String name) {
    for (final n in stepNodes) {
      if (n.name == name) return n;
    }
    return null;
  }

  // Actions grouped by step.
  final actionsByStep = <int, List<SfcActionAssoc>>{};
  for (final a in body.actions) {
    (actionsByStep[a.stepLocalId] ??= []).add(a);
  }

  // Steps.
  final steps = <SfcStep>[];
  var anyInitial = false;
  for (final s in stepNodes) {
    if (s.initial) anyInitial = true;
    steps.add(SfcStep(
      id: stepId(s.localId),
      name: s.name.isEmpty ? 's${s.localId}' : s.name,
      isInitial: s.initial,
      actionSt: _actionSt(actionsByStep[s.localId] ?? const [], body,
          s.name.isEmpty ? 's${s.localId}' : s.name, warnings),
    ));
  }
  if (!anyInitial) {
    warnings.add(ImportWarning(severity: WarningSeverity.info,
        message: 'SFC POU "$pouName": no initial step marked — first step used.'));
    steps.first.isInitial = true;
  }

  // Upstream/downstream step resolution across transparent connectors.
  // Task 2: step, selDiv (→ its single step source), selConv (→ its single step
  // target), jump (→ named step). simDiv/simConv are parallel branching and
  // stub here (Task 3 adds them).
  List<int> upstreamSteps(int transId) {
    final out = <int>[];
    for (final p in pred[transId] ?? const []) {
      final node = byId[p];
      if (node == null) throw _SfcStub('complex-topology', 'dangling edge');
      switch (node.kind) {
        case SfcNodeKind.step:
          out.add(p);
          break;
        case SfcNodeKind.selDiv:
          for (final pp in pred[p] ?? const []) {
            if (byId[pp]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'selDiv upstream not a step');
            }
            out.add(pp);
          }
          break;
        default:
          throw _SfcStub('complex-topology', 'unsupported transition source');
      }
    }
    return out;
  }

  List<int> downstreamSteps(int transId) {
    final out = <int>[];
    for (final s in succ[transId] ?? const []) {
      final node = byId[s];
      if (node == null) throw _SfcStub('complex-topology', 'dangling edge');
      switch (node.kind) {
        case SfcNodeKind.step:
          out.add(s);
          break;
        case SfcNodeKind.selConv:
          for (final ss in succ[s] ?? const []) {
            if (byId[ss]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'selConv downstream not a step');
            }
            out.add(ss);
          }
          break;
        case SfcNodeKind.jump:
          final target = stepByName(node.name);
          if (target == null) {
            throw _SfcStub('complex-topology', 'jump to unknown step "${node.name}"');
          }
          out.add(target.localId);
          break;
        default:
          throw _SfcStub('complex-topology', 'unsupported transition target');
      }
    }
    return out;
  }

  // Transitions.
  final transitions = <SfcTransition>[];
  for (final t in body.nodes) {
    if (t.kind != SfcNodeKind.transition) continue;
    final cond = _conditionSt(t.condition, body);
    final src = upstreamSteps(t.localId);
    final tgt = downstreamSteps(t.localId);
    if (src.length == 1 && tgt.length == 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: stepId(src.first),
        toStepId: stepId(tgt.first),
        conditionSt: cond,
        kind: 'single',
      ));
    } else {
      throw _SfcStub('complex-topology', 'parallel branching not yet supported');
    }
  }

  return (steps, transitions);
}

/// Resolves a transition's condition to ST, or bails the whole POU.
String _conditionSt(SfcCond? cond, SfcBody body) {
  switch (cond) {
    case SfcCondInline c:
      return c.text;
    case SfcCondRef c:
      final b = body.refBodies[c.name];
      if (b == null || body.graphicalRefs.contains(c.name)) {
        throw _SfcStub('unresolved-condition', 'transition references "${c.name}"');
      }
      return b;
    case SfcCondWired _:
      throw _SfcStub('wired-condition', 'graphical transition condition');
    case SfcCondNone _:
    case null:
      throw _SfcStub('unresolved-condition', 'transition has no condition');
  }
}

/// Resolves a step's N-qualified actions to concatenated ST; non-N and
/// unresolved actions degrade to no-op + warning.
String _actionSt(List<SfcActionAssoc> actions, SfcBody body, String stepName,
    List<ImportWarning> warnings) {
  final parts = <String>[];
  for (final a in actions) {
    if (a.qualifier.toUpperCase() != 'N') {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'SFC step "$stepName": action qualifier "${a.qualifier}" '
              'unsupported — action skipped (N only).'));
      continue;
    }
    switch (a.source) {
      case SfcActInline s:
        if (s.text.isNotEmpty) parts.add(s.text);
        break;
      case SfcActRef s:
        final b = body.refBodies[s.name];
        if (b == null || body.graphicalRefs.contains(s.name)) {
          warnings.add(ImportWarning(severity: WarningSeverity.info,
              message: 'SFC step "$stepName": action "${s.name}" not resolvable '
                  'to ST — skipped.'));
        } else if (b.isNotEmpty) {
          parts.add(b);
        }
        break;
    }
  }
  return parts.join('\n');
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/sfc_translate_test.dart`
Expected: PASS (all tests, including the simultaneous-divergence stub).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/sfc_translate.dart mobile/test/import/sfc_translate_test.dart
git commit -m "feat(import): SFC translator core (linear/selection/jump, faithful-or-stub)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: SFC translator — simultaneous (parallel) divergence/convergence

**Files:**
- Modify: `mobile/lib/import/sfc_translate.dart` (`upstreamSteps`/`downstreamSteps`, transition emission)
- Test: `mobile/test/import/sfc_translate_test.dart` (add tests)

**Interfaces:**
- Consumes: everything from Task 2.
- Produces: a `simultaneousDivergence` (`step→transition→simDiv→[step]…`) → a `kind:'parallelFork'` transition (`fromStepId`=source step, `toStepIds`=branch heads); a `simultaneousConvergence` (`[step]…→simConv→transition→step`) → a `kind:'parallelJoin'` transition (`fromStepIds`=branch tails, `toStepId`=after step). The Task-2 stub test for simultaneous divergence is replaced by real translation.

- [ ] **Step 1: Write the failing tests**

In `mobile/test/import/sfc_translate_test.dart`, DELETE the Task-2 test `'simultaneous divergence stubs in Task 2 (parallel not yet supported)'` and add:

```dart
  test('simultaneous divergence + convergence -> parallelFork + parallelJoin', () {
    // Idle -(t2:Go)-> simDiv -> {A, B} ; {A, B} -> simConv -(t7:Done)-> End
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondInline('Go')),
      _conn(3, SfcNodeKind.simDiv),
      _step(4, 'A'),
      _step(5, 'B'),
      _conn(6, SfcNodeKind.simConv),
      _trans(7, SfcCondInline('Done')),
      _step(8, 'End'),
    ], edges: [
      _e(1, 2), _e(2, 3), _e(3, 4), _e(3, 5),
      _e(4, 6), _e(5, 6), _e(6, 7), _e(7, 8),
    ], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isTrue);
    final fork = tr.transitions.firstWhere((t) => t.kind == 'parallelFork');
    expect(fork.fromStepId, 'P_s1');
    expect(fork.toStepIds.toSet(), {'P_s4', 'P_s5'});
    expect(fork.conditionSt, 'Go');
    final join = tr.transitions.firstWhere((t) => t.kind == 'parallelJoin');
    expect(join.fromStepIds.toSet(), {'P_s4', 'P_s5'});
    expect(join.toStepId, 'P_s8');
    expect(join.conditionSt, 'Done');
  });
```

- [ ] **Step 2: Run the tests to verify the new one fails**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/sfc_translate_test.dart`
Expected: the new parallel test FAILS (currently `translated == false`, `complex-topology`).

- [ ] **Step 3: Add simDiv/simConv resolution + fork/join emission**

In `mobile/lib/import/sfc_translate.dart`, in `upstreamSteps`, add a `simConv` case before the `default:`:

```dart
        case SfcNodeKind.simConv:
          for (final pp in pred[p] ?? const []) {
            if (byId[pp]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'simConv upstream not a step');
            }
            out.add(pp);
          }
          break;
```

In `downstreamSteps`, add a `simDiv` case before the `default:`:

```dart
        case SfcNodeKind.simDiv:
          for (final ss in succ[s] ?? const []) {
            if (byId[ss]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'simDiv downstream not a step');
            }
            out.add(ss);
          }
          break;
```

Replace the transition-emission `if/else` in `_build` with fork/join handling:

```dart
    if (src.length == 1 && tgt.length == 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: stepId(src.first),
        toStepId: stepId(tgt.first),
        conditionSt: cond,
        kind: 'single',
      ));
    } else if (src.length == 1 && tgt.length > 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: stepId(src.first),
        toStepId: '',
        conditionSt: cond,
        kind: 'parallelFork',
        toStepIds: [for (final s in tgt) stepId(s)],
      ));
    } else if (src.length > 1 && tgt.length == 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: '',
        toStepId: stepId(tgt.first),
        conditionSt: cond,
        kind: 'parallelJoin',
        fromStepIds: [for (final s in src) stepId(s)],
      ));
    } else {
      throw _SfcStub('complex-topology', 'unsupported transition fan-in/out');
    }
```

(`SfcTransition`'s constructor accepts named `toStepIds`/`fromStepIds`; the unused side stays the default empty list, matching how `sfc_exec.dart` reads `parallelFork`/`parallelJoin`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/sfc_translate_test.dart`
Expected: PASS (all tests, including the new parallel test).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/sfc_translate.dart mobile/test/import/sfc_translate_test.dart
git commit -m "feat(import): SFC parallel fork/join translation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Mapper integration + report fields + preview

**Files:**
- Modify: `mobile/lib/import/ir_to_project.dart` (`ImportReport`, the SfcBody arm, the report assembly)
- Modify: `mobile/lib/screens/import_xml_preview.dart`
- Test: `mobile/test/import/ir_to_project_test.dart`

**Interfaces:**
- Consumes: `translateSfcBody` + `SfcTranslation` (Task 2/3).
- Produces: `ImportReport` gains `translatedSfcCount` (int, default 0), `stubbedSfcCount` (int, default 0), `sfcStubReasons` (`Map<String,int>`, default `{}`). SFC POUs with a translatable chart become real `SequentialFunctionChart` programs.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/import/ir_to_project_test.dart` (build the IR directly — no XML):

```dart
  test('SFC POU with a translatable chart becomes a real SFC program', () {
    final ir = ImportedProject(
      name: 'SfcProj', types: const [], warnings: const [],
      globalVars: [
        ImportedVar(name: 'Start', baseType: 'BOOL', scope: VarScope.global),
        ImportedVar(name: 'Motor', baseType: 'BOOL', scope: VarScope.global),
      ],
      pous: [
        ImportedPou(
          name: 'Chart', kind: PouKind.program, lang: PouLanguage.sfc,
          localVars: const [],
          body: SfcBody(nodes: [
            SfcNode(localId: 1, kind: SfcNodeKind.step, name: 'Idle', initial: true),
            SfcNode(localId: 2, kind: SfcNodeKind.transition, condition: SfcCondInline('Start')),
            SfcNode(localId: 3, kind: SfcNodeKind.step, name: 'Run'),
          ], edges: [
            SfcEdge(fromLocalId: 1, toLocalId: 2),
            SfcEdge(fromLocalId: 2, toLocalId: 3),
          ], actions: [
            SfcActionAssoc(stepLocalId: 3, qualifier: 'N', source: SfcActInline('Motor := TRUE;')),
          ]),
        ),
      ],
    );
    final res = mapImportedProject(ir, projectName: 'SfcProj', projectId: 'x');
    final prog = res.project.programs.firstWhere((p) => p.name == 'Chart');
    expect(prog.language, 'SequentialFunctionChart');
    expect(prog.sfcSteps.map((s) => s.name), containsAll(['Idle', 'Run']));
    expect(prog.sfcTransitions, isNotEmpty);
    expect(res.report.translatedSfcCount, 1);
    expect(res.report.stubbedSfcCount, 0);
  });

  test('SFC POU with a wired condition keeps the whole-POU stub', () {
    final ir = ImportedProject(
      name: 'SfcStub', types: const [], warnings: const [], globalVars: const [],
      pous: [
        ImportedPou(
          name: 'Bad', kind: PouKind.program, lang: PouLanguage.sfc,
          localVars: const [],
          body: SfcBody(nodes: [
            SfcNode(localId: 1, kind: SfcNodeKind.step, name: 'Idle', initial: true),
            SfcNode(localId: 2, kind: SfcNodeKind.transition, condition: SfcCondWired()),
            SfcNode(localId: 3, kind: SfcNodeKind.step, name: 'Run'),
          ], edges: [
            SfcEdge(fromLocalId: 1, toLocalId: 2),
            SfcEdge(fromLocalId: 2, toLocalId: 3),
          ], actions: const []),
        ),
      ],
    );
    final res = mapImportedProject(ir, projectName: 'SfcStub', projectId: 'y');
    final prog = res.project.programs.firstWhere((p) => p.name == 'Bad');
    expect(prog.language, 'SequentialFunctionChart');
    expect(prog.sfcSteps, isEmpty); // stub program has no steps
    expect(res.report.translatedSfcCount, 0);
    expect(res.report.stubbedSfcCount, 1);
    expect(res.report.sfcStubReasons['wired-condition'], 1);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/ir_to_project_test.dart`
Expected: FAIL — `translatedSfcCount` not a member of `ImportReport`; the SFC POU still stubs (no `sfcSteps`).

- [ ] **Step 3: Add the report fields**

In `mobile/lib/import/ir_to_project.dart`, extend `ImportReport` — add fields (near the FBD reporting fields):

```dart
  // SFC-translation reporting (default-safe so existing call sites compile).
  final int translatedSfcCount;
  final int stubbedSfcCount;
  final Map<String, int> sfcStubReasons;
```

and constructor parameters (after the FBD ones):

```dart
    this.translatedSfcCount = 0,
    this.stubbedSfcCount = 0,
    this.sfcStubReasons = const {},
```

- [ ] **Step 4: Add accumulators + upgrade the SfcBody arm**

Add accumulators near the FBD ones in `mapImportedProject`:

```dart
  var translatedSfcCount = 0;
  var stubbedSfcCount = 0;
  final sfcStubReasons = <String, int>{};
```

Add the import near the top:

```dart
import 'sfc_translate.dart';
```

Replace the Task-1 `body is SfcBody` stub arm with the translator call:

```dart
    } else if (body is SfcBody) {
      final tr = translateSfcBody(body, pouName: pou.name);
      warnings.addAll(tr.warnings);
      if (tr.translated) {
        programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
            sfcSteps: tr.steps, sfcTransitions: tr.transitions));
        translatedSfcCount++;
      } else {
        final reason = tr.stubReason ?? 'complex-topology';
        sfcStubReasons[reason] = (sfcStubReasons[reason] ?? 0) + 1;
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (SequentialFunctionChart): graphical body not '
                'yet translated (${body.nodes.length} elements captured) — re-import '
                'once graphical translation ships.'));
        programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
            description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
        stubbedSfcCount++;
        stubCount++; // also feeds graphicalStubCount
      }
    } else if (body is GraphBody) {
```

- [ ] **Step 5: Thread the new fields into the returned `ImportReport`**

In the `return ImportResult(... report: ImportReport(...))`, add:

```dart
        translatedSfcCount: translatedSfcCount,
        stubbedSfcCount: stubbedSfcCount,
        sfcStubReasons: sfcStubReasons,
```

- [ ] **Step 6: Run the mapper test + full import suite**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/`
Expected: PASS. (Existing SFC-stub corpus expectations still hold for charts that stub; a fully-translatable SFC in the corpus now becomes a real program — if a corpus test asserted an SFC POU is a stub and that POU is now translatable, update that assertion to reflect the correct new behavior; do not weaken it.)

- [ ] **Step 7: Surface SFC counts in the preview**

In `mobile/lib/screens/import_xml_preview.dart`, after the FBD count block, add:

```dart
              if (report.translatedSfcCount > 0 ||
                  report.stubbedSfcCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'SFC: ${report.translatedSfcCount} chart(s) translated'
                  '${report.stubbedSfcCount > 0 ? ', ${report.stubbedSfcCount} stubbed' : ''}'
                  '${report.sfcStubReasons.isNotEmpty ? ' — reasons: ${report.sfcStubReasons.keys.join(', ')}' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
```

- [ ] **Step 8: Run the flow test + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/import_xml_flow_test.dart && /c/flutter/bin/flutter analyze`
Expected: PASS; no analyzer issues.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/import/ir_to_project.dart mobile/lib/screens/import_xml_preview.dart mobile/test/import/ir_to_project_test.dart
git commit -m "feat(import): wire SFC translator into mapper + report + preview

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: End-to-end proof + docs + full validation

**Files:**
- Create: `mobile/test/import/import_sfc_e2e_test.dart`
- Modify: `docs/iec61131/` (SFC import notes), `docs/DEFERRED.md`

**Interfaces:**
- Consumes: the full pipeline — `parsePlcOpen` → `mapImportedProject` → `executeSfcPrograms` (`sfc_exec.dart`, `SfcRuntime`), `readPath`/`writePath` (`tag_resolver.dart`).
- Produces: an executable end-to-end proof and up-to-date docs; the graphical-translators program is complete.

- [ ] **Step 1: Write the failing end-to-end test**

Create `mobile/test/import/import_sfc_e2e_test.dart`:

```dart
// End-to-end proof: a handcrafted PLCopen SFC POU imports as a real, executing
// SequentialFunctionChart program. Exercises a referenced-ST transition + a
// referenced-ST action, and verifies the scan advances the active step and runs
// the action. Pipeline: parsePlcOpen -> mapImportedProject -> executeSfcPrograms.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="SfcE2E"/>
  <types><dataTypes/><pous>
    <pou name="Chart" pouType="program">
      <interface><localVars/></interface>
      <actions>
        <action name="RunAct"><body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Motor := TRUE;</xhtml></ST></body></action>
      </actions>
      <transitions>
        <transition name="ToRun"><body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Start</xhtml></ST></body></transition>
      </transitions>
      <body><SFC>
        <step localId="1" name="Idle" initialStep="true"><position x="0" y="0"/></step>
        <transition localId="2"><position x="0" y="40"/>
          <connectionPointIn><connection refLocalId="1"/></connectionPointIn>
          <condition><reference name="ToRun"/></condition></transition>
        <step localId="3" name="Run"><position x="0" y="80"/>
          <connectionPointIn><connection refLocalId="2"/></connectionPointIn></step>
        <actionBlock localId="9"><position x="60" y="80"/>
          <connectionPointIn><connection refLocalId="3"/></connectionPointIn>
          <action qualifier="N"><reference name="RunAct"/></action></actionBlock>
      </SFC></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars>
      <variable name="Start"><type><BOOL/></type><initialValue><simpleValue value="FALSE"/></initialValue></variable>
      <variable name="Motor"><type><BOOL/></type><initialValue><simpleValue value="FALSE"/></initialValue></variable>
    </globalVars>
  </resource></configuration></configurations></instances>
</project>
''';

void main() {
  test('SFC POU imports as an executing chart (referenced condition + action)', () {
    final ir = parsePlcOpen(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'sfc_e2e');
    final p = res.project;

    final chart = p.programs.firstWhere((pr) => pr.name == 'Chart');
    expect(chart.language, 'SequentialFunctionChart');
    expect(chart.sfcSteps.map((s) => s.name), containsAll(['Idle', 'Run']));
    expect(res.report.translatedSfcCount, 1);

    final rt = SfcRuntime();
    // Scan 1: Start is false -> stays in Idle; Motor stays false.
    executeSfcPrograms(p, 100, rt);
    expect(rt.active['Chart'], contains(chart.sfcSteps.firstWhere((s) => s.name == 'Idle').id));

    // Set Start; next scan the transition fires -> Run becomes active.
    writePath(p, 'Start', true);
    executeSfcPrograms(p, 100, rt);
    final runId = chart.sfcSteps.firstWhere((s) => s.name == 'Run').id;
    expect(rt.active['Chart'], contains(runId));

    // One more scan: Run is active, its action runs -> Motor := TRUE.
    executeSfcPrograms(p, 100, rt);
    expect(readPath(p, 'Motor'), true);
  });
}
```

- [ ] **Step 2: Run the e2e test to verify it passes**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/import_sfc_e2e_test.dart`
Expected: With Tasks 1–4 merged, PASS. If it FAILS, diagnose against the failing assertion (common causes: the referenced-body capture in `_sfcBody`, the `actionBlock` step association, or the transition-fire timing — `executeSfcPrograms` fires against a start-of-scan snapshot, so a newly-activated step acts the following scan, which is why the test scans once more before checking `Motor`). Fix the underlying library code (not the test) and re-run until PASS.

- [ ] **Step 3: Update the IEC docs**

In `docs/iec61131/` add an SFC import section (mirror the LD/FBD import notes) with a support matrix:

```markdown
## SFC import (PLCopen → native SequentialFunctionChart)

An imported SFC POU translates as a whole: the entire chart (steps, transitions,
conditions, topology) becomes a native chart, or the whole POU stays a stub
(faithful-or-stub). An unrepresentable step **action** degrades to a no-op with a
warning (chart flow is preserved).

| Source | Native mapping |
| --- | --- |
| `<step>` (name, initialStep) | `SfcStep`; N-qualified actions → `actionSt` |
| linear `step→transition→step` | `SfcTransition(kind:'single')` |
| `<selectionDivergence>` | multiple `single` transitions from one step (first-true-wins) |
| `<simultaneousDivergence>` / `<simultaneousConvergence>` | `parallelFork` / `parallelJoin` |
| `<jumpStep targetName>` | `single` transition to the named step |
| transition condition — inline ST / `<reference>` to an ST transition | `conditionSt` |
| step action — inline ST / `<reference>` to an ST action, qualifier N | `actionSt` |

Stubbed (whole POU) — with the `sfcStubReasons` key: a wired transition condition
(`wired-condition`); a condition referencing a graphical/missing body
(`unresolved-condition`); complex/unsupported topology, unknown jump target
(`complex-topology`); a chart with no steps (`no-initial`). Degraded (no-op +
warning): non-N action qualifiers (S/R/P/L/D/…); actions referencing a
graphical/missing body.
```

- [ ] **Step 4: Update `docs/DEFERRED.md`**

- Strike (wrap in `~~`) the "SFC import translator" row, noting delivery by this feature + the e2e test path `mobile/test/import/import_sfc_e2e_test.dart` (match how prior rows were struck). Note that the graphical-translators program (LD/FBD/SFC) is now **complete**.
- Add residual SFC deferred rows: stored/pulse/timed action qualifiers (S/R/P/L/D/SD/DS/SL); graphical (LD/FBD) transition/action bodies; wired transition conditions; action/transition definitions as standalone external POUs (only in-POU `<transitions>`/`<actions>` references resolve).

- [ ] **Step 5: Full validation — whole suite + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test`
Expected: entire suite PASS (the pre-change baseline was 2668 passing; this adds tests and must not regress any — in particular the app's own `sfc_*_test.dart` suite, which does not go through the importer, stays green).

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add mobile/test/import/import_sfc_e2e_test.dart docs/iec61131 docs/DEFERRED.md
git commit -m "test(import): SFC import e2e + docs; strike delivered deferred row

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §1 typed SFC IR → Task 1 Step 1. ✅
- §2 parser `_sfcBody` (steps/transitions/conditions/actions/branches/jumps/refBodies) → Task 1 Steps 4-5. ✅
- §3 translator (steps, actions, conditions, single/selection/jump) → Task 2; parallel fork/join → Task 3. ✅
- §4 mapper `body is SfcBody` arm + report fields → Task 1 (stub) + Task 4 (translator + counts). ✅
- §5 preview surfacing → Task 4 Step 7. ✅
- §6 error handling (wired/unresolved condition, complex-topology, no-initial, non-N action, action-ref-graphical) → Task 2/3 stub reasons + degrade paths; tested. ✅
- §7 testing (parser, translate unit, e2e, backward-compat) → Tasks 1,2,3,5. ✅
- §8 docs → Task 5. ✅
- §9 deferred rows → Task 5 Step 4. ✅

**2. Placeholder scan:** No TBD/TODO. Every code step shows complete code; every command has expected output. The one conditional (Task 4 Step 6: update a corpus assertion only if a now-translatable SFC POU was previously asserted a stub) states its exact condition, not an open placeholder.

**3. Type consistency:**
- `SfcBody{nodes, edges, actions, refBodies, graphicalRefs}`, `SfcNode{localId, kind, x, y, name, initial, condition}`, `SfcEdge{fromLocalId, toLocalId}`, `SfcCond` (sealed 4), `SfcActionAssoc{stepLocalId, qualifier, source}`, `SfcActSource` (sealed 2) — identical across Task 1 (def), Task 1 parser, Task 2 tests/translator, Task 4 mapper test. ✅
- `translateSfcBody(SfcBody, {required String pouName}) -> SfcTranslation{steps, transitions, translated, stubReason, warnings}` — identical Task 2 def, Task 3, Task 4 consumer. ✅
- `SfcStep(id, name, isInitial, actionSt)` + mutable `isInitial`; `SfcTransition(id, fromStepId, toStepId, conditionSt, kind, toStepIds, fromStepIds)` — matches `project_model.dart`; `kind` values `'single'`/`'parallelFork'`/`'parallelJoin'` match `sfc_exec.dart`. ✅
- Report fields `translatedSfcCount`/`stubbedSfcCount`/`sfcStubReasons` — identical in Task 4 model, mapper, preview, and Task 4/5 assertions. ✅
- stubReason keys (`wired-condition`/`unresolved-condition`/`complex-topology`/`no-initial`) — consistent between translator code and tests. ✅

All consistent. Plan ready.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-07-26-sfc-import-translator.md`. Five tasks, each an independently testable deliverable, structured so every task keeps the suite green (Task 1 routes SFC through a behavior-preserving `SfcBody` stub; the translator is built pure in Tasks 2-3 and wired in Task 4).
