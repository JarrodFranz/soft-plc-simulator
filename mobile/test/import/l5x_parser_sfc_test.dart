// L5X SFC parser units. Fixtures are synthetic and written to the ASSERTED
// <SFCContent> schema of
// docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md §1 — this repo
// contains no SFC-bearing L5X corpus file, so these fixtures ARE the schema
// pin. If a real export disagrees, the fixtures are what changes.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/import/sfc_translate.dart';

/// Wraps `<SFCContent>` children in a minimal L5X document with one
/// `<Routine Name="Seq" Type="SFC">` inside `<Program Name="Main">`.
String _wrap(String sfcChildren) => _wrapRoutine(
    '<Routine Name="Seq" Type="SFC"><SFCContent>$sfcChildren</SFCContent></Routine>');

/// Wraps a whole `<Routine>` element (for fixtures that need two
/// `<SFCContent>` containers, or none at all).
String _wrapRoutine(String routine) => '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Main"><Tags/><Routines>
    $routine
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''';

/// Parses a fixture and returns `(body, allParserWarnings)`.
///
/// EVERY fixture in this file goes through here, because the §8 invariants
/// asserted below must hold for every L5X-built body, not just the malformed
/// ones — an invariant asserted in one named test is an invariant that holds
/// in one named test. It also translates the body, so the poison-mechanism and
/// step-id invariants ride along on every fixture too. Do not bypass it.
(SfcBody, List<ImportWarning>) _build(String xml) {
  final ir = parseL5x(xml);
  final pou = ir.pous.firstWhere((p) => p.name == 'Main_Seq');
  expect(pou.lang, PouLanguage.sfc);
  expect(pou.kind, PouKind.program);
  final body = pou.body as SfcBody;

  // §8 invariant: localId uniqueness across real ids, malformed/duplicate
  // synthetics, branch connectors and the poison node alike. A shared localId
  // makes translateSfcBody's `byId` last-write-wins while stepNodes/succ/pred
  // keep both — a chart that translates cleanly as the WRONG logic.
  expect(body.nodes.map((n) => n.localId).toSet(), hasLength(body.nodes.length),
      reason: 'two SfcNodes share a localId');
  // §8 invariant: the two id ranges PARTITION the body. Every node carrying a
  // REAL id is a step or a transition; every SYNTHESIZED node — the four
  // connector kinds and the poison node — carries a negative id. Stated as a
  // partition rather than as an upper bound, because a bound is satisfied by
  // almost any body and would prove nothing.
  const synthesizedKinds = {
    SfcNodeKind.selDiv,
    SfcNodeKind.selConv,
    SfcNodeKind.simDiv,
    SfcNodeKind.simConv,
  };
  for (final n in body.nodes) {
    if (synthesizedKinds.contains(n.kind) || n.name == '#unrepresentable') {
      expect(n.localId, lessThan(0),
          reason: 'synthesized node (${n.kind}) must never carry a real id');
    } else {
      expect(n.kind == SfcNodeKind.step || n.kind == SfcNodeKind.transition,
          isTrue, reason: 'unexpected node kind ${n.kind}');
      expect(n.localId <= (1 << 31), isTrue,
          reason: 'localId ${n.localId} out of range');
    }
  }
  // §1/§8 invariant: Logix has no jump element, so the builder never emits one.
  expect(body.nodes.any((n) => n.kind == SfcNodeKind.jump), isFalse,
      reason: 'an L5X-built SfcBody must contain no jump node');
  // §1 invariant: Logix has no external action/transition POUs.
  expect(body.refBodies, isEmpty);
  expect(body.graphicalRefs, isEmpty);

  // Recorded resolution 7: the four inlet/outlet KIND causes are unreachable
  // by construction — the classifier derives the trunk role FROM the
  // neighbour's kind. Asserted here rather than in one named test, so EVERY
  // fixture in this file (all 16 emission rows, all 8 shape fixtures, the
  // connector-adjacent and nesting cases) carries the assertion. If this ever
  // fires, the classifier changed and that is the news.
  for (final m in ir.warnings.map((w) => w.message)) {
    expect(m.contains('divergence inlet is a'), isFalse, reason: m);
    expect(m.contains('convergence outlet is a'), isFalse, reason: m);
  }

  final tr = translateSfcBody(body, pouName: 'P');
  if (body.nodes.any((n) => n.name == '#unrepresentable')) {
    // §4 invariant, on EVERY poisoned fixture: the step->step edge scan sits
    // above every warning-emitting statement in `_build`, so a poisoned body
    // yields exactly one message and zero translator infos.
    expect(tr.translated, isFalse, reason: 'a poisoned body must never translate');
    expect(tr.stubReason, 'complex-topology');
    expect(tr.warnings, hasLength(1));
    expect(tr.warnings.single.severity, WarningSeverity.warning);
  }
  if (tr.translated) {
    // §8 invariant: no negative localId ever reaches an SfcStep.id or
    // SfcTransition.id — guards against a program id like `Main_Seq_s-3`.
    // (A poisoned body always stubs, and connector nodes never become steps
    // or transitions, so this holds by construction; it is asserted because
    // "by construction" is exactly the kind of claim that rots.)
    for (final s in tr.steps) {
      expect(s.id.contains('_s-'), isFalse, reason: s.id);
    }
    for (final t in tr.transitions) {
      expect(t.id.contains('_t-'), isFalse, reason: t.id);
    }
  }
  return (body, ir.warnings);
}

/// Convenience: the info-severity messages a fixture produced.
List<String> _infos(List<ImportWarning> ws) => [
      for (final w in ws)
        if (w.severity == WarningSeverity.info) w.message
    ];

/// Convenience: does any info message contain [needle]?
bool _hasInfo(List<ImportWarning> ws, String needle) =>
    _infos(ws).any((m) => m.contains(needle));

SfcNode _nodeAt(SfcBody b, int localId) =>
    b.nodes.firstWhere((n) => n.localId == localId);

/// Projects a body's edges onto `(kindOf(from), kindOf(to))` pairs, sorted.
/// Connector `localId`s are allocation-order dependent and the two `<Branch>`
/// encodings differ in element count, so THIS — not literal IR equality — is
/// what "the two encodings agree" means (§9).
List<String> _edgeKindMultiset(SfcBody b) {
  final kinds = {for (final n in b.nodes) n.localId: n.kind};
  return [
    for (final e in b.edges)
      '${kinds[e.fromLocalId]?.name ?? 'missing'}'
          '->${kinds[e.toLocalId]?.name ?? 'missing'}'
  ]..sort();
}

/// A one-line `<Transition>` with an inline ST condition.
String _t(int id, String name, String cond) =>
    '<Transition ID="$id" Operand="$name"><Condition><STContent>'
    '<Line Number="0"><![CDATA[$cond]]></Line></STContent></Condition></Transition>';

void main() {
  group('L5X SFC: happy paths (§1, §6)', () {
    test('a linear chart becomes 2 steps, 1 transition and 2 edges', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" X="10" Y="20" Operand="Idle" InitialStep="true"/>
        <Transition ID="2" X="10" Y="60" Operand="ToRun">
          <Condition><STContent><Line Number="0"><![CDATA[Start]]></Line></STContent></Condition>
        </Transition>
        <Step ID="3" X="10" Y="100" Operand="Run"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect(body.nodes.map((n) => n.kind),
          [SfcNodeKind.step, SfcNodeKind.transition, SfcNodeKind.step]);
      expect(body.nodes.map((n) => n.localId), [1, 2, 3]);
      expect(_nodeAt(body, 1).name, 'Idle');
      expect(_nodeAt(body, 1).initial, isTrue);
      expect(_nodeAt(body, 1).x, 10);
      expect(_nodeAt(body, 1).y, 20);
      expect(_nodeAt(body, 3).initial, isFalse);
      expect((_nodeAt(body, 2).condition as SfcCondInline).text, 'Start');
      expect(body.edges.map((e) => '${e.fromLocalId}->${e.toLocalId}'),
          ['1->2', '2->3']);
      expect(ws, isEmpty);

      final tr = translateSfcBody(body, pouName: 'Main_Seq');
      expect(tr.translated, isTrue);
      expect(tr.steps.map((s) => s.name), ['Idle', 'Run']);
      expect(tr.transitions.single.kind, 'single');
      expect(tr.transitions.single.fromStepId, 'Main_Seq_s1');
      expect(tr.transitions.single.toStepId, 'Main_Seq_s3');
    });

    test('a step\'s <Action> children become SfcActionAssocs in document order', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="A1" Qualifier="N">
            <Body><STContent><Line Number="0"><![CDATA[Motor := TRUE;]]></Line></STContent></Body>
          </Action>
          <Action ID="12" Operand="A2" Qualifier="N">
            <Body><STContent><Line Number="0"><![CDATA[Lamp := TRUE;]]></Line></STContent></Body>
          </Action>
        </Step>'''));

      expect(body.actions, hasLength(2));
      expect(body.actions.every((a) => a.stepLocalId == 1), isTrue);
      expect(body.actions.map((a) => a.qualifier), ['N', 'N']);
      expect(body.actions.map((a) => (a.source as SfcActInline).text),
          ['Motor := TRUE;', 'Lamp := TRUE;']);

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.steps.single.actionSt, 'Motor := TRUE;\nLamp := TRUE;');
    });

    test('a step with a direct <Body> and no <Action> gets one implicit N action', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Body><STContent>
            <Line Number="0"><![CDATA[Motor := TRUE;]]></Line>
            <Line Number="1"><![CDATA[Lamp := TRUE;]]></Line>
          </STContent></Body>
        </Step>'''));

      expect(body.actions, hasLength(1));
      expect(body.actions.single.qualifier, 'N');
      expect((body.actions.single.source as SfcActInline).text,
          'Motor := TRUE;\nLamp := TRUE;');
    });

    test('a missing Qualifier defaults to N', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="A1">
            <Body><STContent><Line Number="0"><![CDATA[Motor := TRUE;]]></Line></STContent></Body>
          </Action>
        </Step>'''));
      expect(body.actions.single.qualifier, 'N');
    });

    test('condition lines join, trim, and lose a single trailing semicolon', () {
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <Transition ID="2">
          <Condition><STContent>
            <Line Number="0"><![CDATA[  Start AND ]]></Line>
            <Line Number="1"><![CDATA[Ready;  ]]></Line>
          </STContent></Condition>
        </Transition>
        <Step ID="3" Operand="Run"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect((_nodeAt(body, 2).condition as SfcCondInline).text,
          'Start AND\nReady');
    });

    test('an absent condition becomes SfcCondNone (translator stubs it)', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <Transition ID="2"/>
        <Step ID="3" Operand="Run"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect(_nodeAt(body, 2).condition, isA<SfcCondNone>());
      expect(ws, isEmpty); // the verdict belongs to the translator, not the builder
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'unresolved-condition');
      expect(tr.warnings.single.message, contains('transition has no condition'));
    });

    test('a chart with no InitialStep leans on the translator\'s first-step default', () {
      // The builder does not pre-judge this — `no initial step marked` is the
      // translator's inherited info warning, and it must still be reachable
      // from L5X input (§8's inherited table).
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="A"/>
        <Transition ID="2"><Condition><STContent>
          <Line Number="0"><![CDATA[Go]]></Line></STContent></Condition></Transition>
        <Step ID="3" Operand="B"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      expect(body.nodes.every((n) => !n.initial), isTrue);
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.steps.first.isInitial, isTrue);
      expect(
          tr.warnings.any((w) =>
              w.severity == WarningSeverity.info &&
              w.message.contains('no initial step marked — first step used')),
          isTrue);
    });

    test('a missing Operand leaves the name empty (translator synthesizes s<id>)', () {
      final (body, _) = _build(_wrap('<Step ID="7" InitialStep="true"/>'));
      expect(_nodeAt(body, 7).name, '');
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.steps.single.name, 's7');
    });
  });

  group('L5X SFC: the ID gate (§2)', () {
    // The gate's four rejections plus the duplicate rule. Every one of them
    // gets a synthetic NEGATIVE id and poisons the chart, so the POU stubs
    // rather than silently translating with a colliding or missing identity.
    for (final (label, attr, needle) in const [
      ('an absent ID', '', 'malformed ID'),
      ('an unparseable ID', ' ID="abc"', 'malformed ID'),
      ('a negative ID', ' ID="-1"', 'malformed ID'),
      ('an out-of-range ID', ' ID="99999999999"', 'malformed ID'),
    ]) {
      test('$label gets a synthetic negative id and poisons the chart', () {
        final (body, ws) = _build(_wrap('<Step$attr Operand="Idle" InitialStep="true"/>'));
        final step = body.nodes.firstWhere((n) => n.name == 'Idle');
        expect(step.localId, lessThan(0));
        expect(_hasInfo(ws, needle), isTrue, reason: _infos(ws).toString());
        final tr = translateSfcBody(body, pouName: 'P');
        expect(tr.translated, isFalse);
        expect(tr.stubReason, 'complex-topology');
      });
    }

    test('a duplicate ID demotes the LATER claimant and keeps the first\'s links', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="7" Operand="First" InitialStep="true"/>
        <Step ID="7" Operand="Second"/>
        <Transition ID="8">
          <Condition><STContent><Line Number="0"><![CDATA[Go]]></Line></STContent></Condition>
        </Transition>
        <DirectedLink FromID="7" ToID="8"/>'''));

      expect(body.nodes.firstWhere((n) => n.name == 'First').localId, 7);
      expect(body.nodes.firstWhere((n) => n.name == 'Second').localId, lessThan(0));
      expect(body.edges.first.fromLocalId, 7); // the FIRST claimant keeps its links
      expect(_hasInfo(ws, 'duplicate ID'), isTrue, reason: _infos(ws).toString());
      expect(translateSfcBody(body, pouName: 'P').translated, isFalse);
    });

    test('two malformed elements get DISTINCT synthetic ids (uniqueness invariant)', () {
      // The Task 2 fixture adds the branch-connector flavour of this
      // collision; here the point is simply that one descending counter feeds
      // every synthetic id, so two rejects can never share one.
      final (body, _) = _build(_wrap('''
        <Step ID="-1" Operand="Neg" InitialStep="true"/>
        <Step ID="abc" Operand="Bad"/>'''));
      final ids = body.nodes.map((n) => n.localId).toList();
      expect(ids.every((i) => i < 0), isTrue);
      expect(ids.toSet(), hasLength(ids.length)); // also asserted by _build
      expect(translateSfcBody(body, pouName: 'P').translated, isFalse);
    });

    test('an annotation reusing a real element\'s ID is caught, in EITHER order', () {
      // C1. An annotation is not a node, but its id IS dereferenced by pass
      // 2a's annotation-anchor rule — it is the one non-node kind that is.
      // Ungated, a <TextBox ID="1"/> would claim id 1 with no duplicate-ID
      // warning and no poison, and every link naming the real element 1 would
      // then be silently discarded: with the e2e chart's join, `convIn` loses
      // a leg tail, shape validation still passes, and the parallelJoin
      // degrades to a `single` transition that no longer waits — translated,
      // zero warnings, wrong logic.
      const step = '<Step ID="1" Operand="Idle" InitialStep="true"/>';
      const box = '<TextBox ID="1" X="0" Y="0"/>';
      const rest = '''
        <Transition ID="2"><Condition><STContent>
          <Line Number="0"><![CDATA[Go]]></Line></STContent></Condition></Transition>
        <DirectedLink FromID="1" ToID="2"/>''';

      for (final (label, fixture) in [
        ('element first', '$step$box$rest'),
        ('annotation first', '$box$step$rest'),
      ]) {
        final (body, ws) = _build(_wrap(fixture));
        expect(_hasInfo(ws, 'duplicate ID'), isTrue,
            reason: '$label: ${_infos(ws)}');
        expect(body.nodes.any((n) => n.name == '#unrepresentable'), isTrue,
            reason: label);
        final tr = translateSfcBody(body, pouName: 'P');
        expect(tr.translated, isFalse, reason: label);
        expect(tr.stubReason, 'complex-topology', reason: label);
      }

      // Element-first: the annotation is the one demoted, so the real element
      // keeps its id AND its inbound link — nothing was swallowed.
      final (body, _) = _build(_wrap('$step$box$rest'));
      expect(body.edges.any((e) => e.fromLocalId == 1 && e.toLocalId == 2),
          isTrue);
    });

    test('two <SFCContent> containers merge, and a cross-container duplicate is caught', () {
      final (body, ws) = _build(_wrapRoutine('''
        <Routine Name="Seq" Type="SFC">
          <SFCContent><Step ID="1" Operand="A" InitialStep="true"/></SFCContent>
          <SFCContent><Step ID="2" Operand="B"/><Step ID="1" Operand="Dup"/></SFCContent>
        </Routine>'''));

      expect(body.nodes.map((n) => n.name), ['A', 'B', 'Dup', '#unrepresentable']);
      expect(_nodeAt(body, 1).name, 'A');
      expect(_nodeAt(body, 2).name, 'B');
      expect(body.nodes.firstWhere((n) => n.name == 'Dup').localId, lessThan(0));
      expect(_hasInfo(ws, 'duplicate ID'), isTrue);
    });
  });

  group('L5X SFC: links, annotations and the poison node (§2, §4)', () {
    test('a dangling link keeps its edge against a synthetic id and poisons', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <DirectedLink FromID="1" ToID="999"/>'''));

      expect(_hasInfo(ws, 'dangling link'), isTrue, reason: _infos(ws).toString());
      // The edge is KEPT — never silently dropped.
      final e = body.edges.firstWhere((e) => e.fromLocalId == 1);
      expect(e.toLocalId, lessThan(0));
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'complex-topology');
    });

    test('<TextBox>/<Attachment> are dropped and counted, kinds deduped', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <TextBox ID="50" X="0" Y="0"/>
        <TextBox ID="51" X="0" Y="0"/>
        <Attachment ID="52" X="0" Y="0"/>'''));

      expect(body.nodes.map((n) => n.localId), [1]);
      expect(_infos(ws).where((m) => m.contains('element(s) ignored')), hasLength(1));
      expect(_infos(ws).single,
          'Routine "Main_Seq": 3 element(s) ignored (TextBox, Attachment).');
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('an ID-less annotation is dropped and counted WITHOUT poisoning', () {
      // Refinement on the brief: the gate runs on an annotation only when it
      // actually CARRIES an `ID`. An ID-less <TextBox>/<Attachment> can never
      // be named by a <DirectedLink>, so it can never swallow another
      // element's links — the CL-19 shape the gate exists to catch is
      // unreachable, and poisoning a whole chart over it would be a false
      // positive on a purely cosmetic element.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        <TextBox X="0" Y="0"/>
        <Attachment/>'''));

      expect(body.nodes.map((n) => n.localId), [1]);
      expect(body.nodes.any((n) => n.name == '#unrepresentable'), isFalse);
      expect(_hasInfo(ws, 'malformed ID'), isFalse, reason: _infos(ws).toString());
      expect(_infos(ws).single,
          'Routine "Main_Seq": 2 element(s) ignored (TextBox, Attachment).');
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('exactly one poison node is appended no matter how many defects', () {
      final (body, _) = _build(_wrap('''
        <Step ID="abc" Operand="A" InitialStep="true"/>
        <Step ID="xyz" Operand="B"/>
        <DirectedLink FromID="1" ToID="999"/>'''));

      final poison = body.nodes.where((n) => n.name == '#unrepresentable').toList();
      expect(poison, hasLength(1));
      expect(poison.single.kind, SfcNodeKind.step);
      expect(poison.single.localId, lessThan(0));
      expect(
          body.edges.where((e) =>
              e.fromLocalId == poison.single.localId &&
              e.toLocalId == poison.single.localId),
          hasLength(1));
    });
  });

  group('L5X SFC: the routine arm (§7)', () {
    test('parseL5x emits ZERO warning-severity messages for an SFC routine', () {
      // The parser-level `graphical body not yet translated` warning is GONE:
      // the whole-POU verdict belongs to translateSfcBody + the mapper.
      for (final fixture in [
        _wrap('<Step ID="1" Operand="Idle" InitialStep="true"/>'), // translates
        _wrap('<Step ID="abc" Operand="Idle" InitialStep="true"/>'), // stubs
      ]) {
        final ir = parseL5x(fixture);
        expect(ir.warnings.where((w) => w.severity == WarningSeverity.warning),
            isEmpty,
            reason: 'parseL5x must not pre-judge an SFC routine');
      }
    });

    test('a routine with no <SFCContent> yields an EMPTY body, not a poisoned one', () {
      final (body, ws) = _build(
          _wrapRoutine('<Routine Name="Seq" Type="SFC"/>'));
      expect(body.nodes, isEmpty);
      expect(body.edges, isEmpty);
      expect(body.actions, isEmpty);
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'no-initial'); // NOT complex-topology
      expect(tr.warnings.single.message, contains('chart has no steps'));
    });
  });

  group('L5X SFC: branch synthesis — the happy shapes (§3)', () {
    // S0 -> B(legs 11,12) -> legs open with T1/T2, close with T3/T4 -> S5.
    // Trunk links name the BRANCH id, leg links name LEG ids — i.e. the
    // paired encoding's natural shape, in which every branch mixes both forms
    // by construction. (This fixture is also the "both forms in one branch"
    // case of §9: the deleted mixed-convention rule would have poisoned it.)
    const selectionChart = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
      <Transition ID="2" Operand="T1"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="T3"><Condition><STContent><Line Number="0"><![CDATA[C]]></Line></STContent></Condition></Transition>
      <Transition ID="5" Operand="T2"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="T4"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S5"/>
      <DirectedLink FromID="1" ToID="10"/>
      <DirectedLink FromID="11" ToID="2"/>
      <DirectedLink FromID="12" ToID="5"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="11"/>
      <DirectedLink FromID="5" ToID="6"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="12"/>
      <DirectedLink FromID="10" ToID="8"/>''';

    // The same chart with EVERY branch-incident link routed through the
    // <Branch> id — no <Leg> id appears as an endpoint anywhere, and the
    // branch declares no <Leg> children at all.
    const selectionChartBranchIdForm = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Branch ID="10" BranchType="Selection"/>
      <Transition ID="2" Operand="T1"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="T3"><Condition><STContent><Line Number="0"><![CDATA[C]]></Line></STContent></Condition></Transition>
      <Transition ID="5" Operand="T2"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="T4"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S5"/>
      <DirectedLink FromID="1" ToID="10"/>
      <DirectedLink FromID="10" ToID="2"/>
      <DirectedLink FromID="10" ToID="5"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="10"/>
      <DirectedLink FromID="5" ToID="6"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="10"/>
      <DirectedLink FromID="10" ToID="8"/>''';

    // S0 -> T0 -> B(legs 11,12) -> legs open with S1/S2, close with S3/S4
    // -> T5 -> S6. Selection diverges into TRANSITIONS; simultaneous is the
    // mirror and diverges into STEPS — the one fact synthesis must get right.
    const simultaneousChart = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Transition ID="2" Operand="T0"><Condition><STContent><Line Number="0"><![CDATA[G]]></Line></STContent></Condition></Transition>
      <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/><Leg ID="12"/></Branch>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="Ta"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="5" Operand="S3"/>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="Tb"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S4"/>
      <Transition ID="9" Operand="T5"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="13" Operand="S6"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="10"/>
      <DirectedLink FromID="11" ToID="3"/>
      <DirectedLink FromID="12" ToID="6"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="5"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="8"/>
      <DirectedLink FromID="5" ToID="11"/>
      <DirectedLink FromID="8" ToID="12"/>
      <DirectedLink FromID="10" ToID="9"/>
      <DirectedLink FromID="9" ToID="13"/>''';

    // The SIMULTANEOUS mirror of the branch-id form: no <Leg> children at all,
    // every branch-incident link routed through the <Branch> id. Selection and
    // simultaneous swap which kind means "leg" and which means "trunk", so the
    // kind-dominance rule has to be pinned on BOTH branch types — here
    // `10 -> Step` must read as a leg head (divOut) and `Step -> 10` as a leg
    // tail (convIn), which is precisely what the naive direction rule gets
    // backwards.
    const simultaneousChartBranchIdForm = '''
      <Step ID="1" Operand="S0" InitialStep="true"/>
      <Transition ID="2" Operand="T0"><Condition><STContent><Line Number="0"><![CDATA[G]]></Line></STContent></Condition></Transition>
      <Branch ID="10" BranchType="Simultaneous"/>
      <Step ID="3" Operand="S1"/>
      <Transition ID="4" Operand="Ta"><Condition><STContent><Line Number="0"><![CDATA[A]]></Line></STContent></Condition></Transition>
      <Step ID="5" Operand="S3"/>
      <Step ID="6" Operand="S2"/>
      <Transition ID="7" Operand="Tb"><Condition><STContent><Line Number="0"><![CDATA[B]]></Line></STContent></Condition></Transition>
      <Step ID="8" Operand="S4"/>
      <Transition ID="9" Operand="T5"><Condition><STContent><Line Number="0"><![CDATA[D]]></Line></STContent></Condition></Transition>
      <Step ID="13" Operand="S6"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="10"/>
      <DirectedLink FromID="10" ToID="3"/>
      <DirectedLink FromID="10" ToID="6"/>
      <DirectedLink FromID="3" ToID="4"/>
      <DirectedLink FromID="4" ToID="5"/>
      <DirectedLink FromID="6" ToID="7"/>
      <DirectedLink FromID="7" ToID="8"/>
      <DirectedLink FromID="5" ToID="10"/>
      <DirectedLink FromID="8" ToID="10"/>
      <DirectedLink FromID="10" ToID="9"/>
      <DirectedLink FromID="9" ToID="13"/>''';

    test('a paired selection branch emits selDiv+selConv and exactly 6 branch edges', () {
      final (body, ws) = _build(_wrap(selectionChart));

      final div = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.selDiv);
      final conv = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.selConv);
      expect(div.localId, lessThan(0));
      expect(conv.localId, lessThan(0));
      expect(div.localId == conv.localId, isFalse);

      // Connector edges LEAD the list (pass 3 before pass 2b), in
      // divIn / divOut / convIn / convOut order.
      expect(body.edges.take(6).map((e) => '${e.fromLocalId}->${e.toLocalId}'), [
        '1->${div.localId}',
        '${div.localId}->2',
        '${div.localId}->5',
        '4->${conv.localId}',
        '7->${conv.localId}',
        '${conv.localId}->8',
      ]);
      expect(body.edges, hasLength(10)); // 6 branch + 4 intra-leg
      expect(ws, isEmpty);

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
      expect(
          tr.transitions.map((t) => '${t.fromStepId}->${t.toStepId}').toSet(),
          {'P_s1->P_s3', 'P_s3->P_s8', 'P_s1->P_s6', 'P_s6->P_s8'});
    });

    test('a paired simultaneous branch emits simDiv+simConv, a fork and a join', () {
      final (body, ws) = _build(_wrap(simultaneousChart));

      final div = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.simDiv);
      final conv = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.simConv);
      expect(body.edges.take(6).map((e) => '${e.fromLocalId}->${e.toLocalId}'), [
        '2->${div.localId}',
        '${div.localId}->3',
        '${div.localId}->6',
        '5->${conv.localId}',
        '8->${conv.localId}',
        '${conv.localId}->9',
      ]);
      expect(body.edges, hasLength(12)); // 6 branch + 6 ordinary
      expect(ws, isEmpty);

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      final fork = tr.transitions.firstWhere((t) => t.kind == 'parallelFork');
      expect(fork.fromStepId, 'P_s1');
      expect(fork.toStepIds.toSet(), {'P_s3', 'P_s6'});
      final join = tr.transitions.firstWhere((t) => t.kind == 'parallelJoin');
      expect(join.fromStepIds.toSet(), {'P_s5', 'P_s8'});
      expect(join.toStepId, 'P_s13');
      expect(tr.transitions.where((t) => t.kind == 'parallelFork'), hasLength(1));
      expect(tr.transitions.where((t) => t.kind == 'parallelJoin'), hasLength(1));
    });

    test('the leg-id and branch-id encodings produce the same chart', () {
      // NOT literal IR equality: connector ids are allocation-order dependent
      // and the fixtures differ in element count.
      final (legForm, legWs) = _build(_wrap(selectionChart));
      final (branchForm, branchWs) = _build(_wrap(selectionChartBranchIdForm));

      expect(_edgeKindMultiset(branchForm), _edgeKindMultiset(legForm));
      expect(legWs, isEmpty);
      expect(branchWs, isEmpty);

      final a = translateSfcBody(legForm, pouName: 'P');
      final b = translateSfcBody(branchForm, pouName: 'P');
      expect(b.translated, a.translated);
      expect(b.steps.map((s) => '${s.id}|${s.name}|${s.isInitial}'),
          a.steps.map((s) => '${s.id}|${s.name}|${s.isInitial}'));
      expect(
          b.transitions.map((t) =>
              '${t.id}|${t.kind}|${t.fromStepId}|${t.toStepId}|'
              '${t.fromStepIds.join(',')}|${t.toStepIds.join(',')}|${t.conditionSt}'),
          a.transitions.map((t) =>
              '${t.id}|${t.kind}|${t.fromStepId}|${t.toStepId}|'
              '${t.fromStepIds.join(',')}|${t.toStepIds.join(',')}|${t.conditionSt}'));
    });

    test('the leg-id and branch-id encodings agree for SIMULTANEOUS too', () {
      // The selection equivalence test above pins the kind-dominance rule on
      // ONE branch type only, and selection/simultaneous swap which neighbour
      // kind means "leg". A direction-based reading of `<Branch>` endpoints
      // would wire `10 -> S1` as a convergence outlet and `S3 -> 10` as a
      // divergence inlet here — a chart that still passes every shape check,
      // with the fork and the join inverted.
      final (legForm, legWs) = _build(_wrap(simultaneousChart));
      final (branchForm, branchWs) =
          _build(_wrap(simultaneousChartBranchIdForm));

      expect(_edgeKindMultiset(branchForm), _edgeKindMultiset(legForm));
      expect(legWs, isEmpty);
      expect(branchWs, isEmpty);

      final a = translateSfcBody(legForm, pouName: 'P');
      final b = translateSfcBody(branchForm, pouName: 'P');
      expect(a.translated, isTrue);
      expect(b.translated, a.translated);
      expect(b.steps.map((s) => '${s.id}|${s.name}|${s.isInitial}'),
          a.steps.map((s) => '${s.id}|${s.name}|${s.isInitial}'));
      // fromStepIds/toStepIds are in the projection, so this pins the fork and
      // the join — the two things a mis-assigned bucket would swap.
      expect(
          b.transitions.map((t) =>
              '${t.id}|${t.kind}|${t.fromStepId}|${t.toStepId}|'
              '${t.fromStepIds.join(',')}|${t.toStepIds.join(',')}|${t.conditionSt}'),
          a.transitions.map((t) =>
              '${t.id}|${t.kind}|${t.fromStepId}|${t.toStepId}|'
              '${t.fromStepIds.join(',')}|${t.toStepIds.join(',')}|${t.conditionSt}'));
    });

    test('a <Branch> with no <Leg> children at all translates (there is no mode switch)', () {
      // Directly pins the deletion of the "no Leg id => fallback mode" gate.
      final (body, ws) = _build(_wrap(selectionChartBranchIdForm));
      expect(ws, isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('BOTH link forms in one branch translate (the mixed-convention regression)', () {
      // In the paired encoding a branch's TRUNK links must name the <Branch>
      // id while its LEG links name <Leg> ids, so EVERY paired branch mixes
      // both forms by construction. The deleted "mixed convention => poison"
      // rule would have stubbed this — the common case, and the headline
      // fixture of the spec itself. This test exists so that rule can never be
      // reintroduced silently.
      final (body, ws) = _build(_wrap(selectionChart));
      expect(_hasInfo(ws, 'branch shape not representable'), isFalse,
          reason: _infos(ws).toString());
      expect(body.nodes.where((n) => n.name == '#unrepresentable'), isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a diverge-only branch emits the divergence and drops the convergence', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        ${_t(4, 'T2', 'B')}
        <Step ID="5" Operand="S2"/>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="12" ToID="4"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="4" ToID="5"/>'''));

      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), isEmpty);
      expect(ws, isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a converge-only branch emits the convergence and drops the divergence', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S1" InitialStep="true"/>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S2"/>
        ${_t(4, 'T2', 'B')}
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
        <Step ID="5" Operand="S5"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="11"/>
        <DirectedLink FromID="3" ToID="4"/>
        <DirectedLink FromID="4" ToID="12"/>
        <DirectedLink FromID="10" ToID="5"/>'''));

      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), isEmpty);
      expect(ws, isEmpty);
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('loop-back legs are not a special case (ordinary edges + row 2)', () {
      // A leg tail wired to an upstream step instead of back into the branch
      // never touches a branch or leg id, so it is an ordinary edge and the
      // branch's own bits land on the diverge-only row.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        ${_t(4, 'T2', 'B')}
        <Step ID="5" Operand="S2"/>
        ${_t(6, 'BackA', 'C')}
        ${_t(7, 'BackB', 'D')}
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="12" ToID="4"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="4" ToID="5"/>
        <DirectedLink FromID="3" ToID="6"/>
        <DirectedLink FromID="6" ToID="1"/>
        <DirectedLink FromID="5" ToID="7"/>
        <DirectedLink FromID="7" ToID="1"/>'''));

      expect(ws, isEmpty, reason: _infos(ws).toString());
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
      // Both loop-backs land on the initial step.
      expect(
          tr.transitions
              .where((t) => t.toStepId == 'P_s1')
              .map((t) => t.fromStepId)
              .toSet(),
          {'P_s3', 'P_s5'});
    });

    test('a single-leg branch translates as an ordinary linear path', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        ${_t(4, 'T2', 'B')}
        <Step ID="5" Operand="S2"/>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="3" ToID="4"/>
        <DirectedLink FromID="4" ToID="11"/>
        <DirectedLink FromID="10" ToID="5"/>'''));

      expect(ws, isEmpty); // faithful, if pointless — no warning, no stub
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
    });

    test('STEP-SEPARATED nested branches TRANSLATE (nesting per se is supported)', () {
      // The intuitive-but-false claim is "nested branches stub". An inner
      // branch whose inlet is the intervening step is an ordinary selDiv with
      // a single step inflow; upstream/downstreamSteps resolve each transition
      // through exactly ONE connector to exactly one step.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="30" BranchType="Selection"><Leg ID="31"/><Leg ID="32"/></Branch>
        ${_t(20, 'T1', 'A')}
        <Step ID="2" Operand="S1"/>
        <Branch ID="40" BranchType="Selection"><Leg ID="41"/><Leg ID="42"/></Branch>
        ${_t(23, 'T5', 'C')}
        <Step ID="4" Operand="S5"/>
        ${_t(25, 'T7', 'E')}
        ${_t(24, 'T6', 'D')}
        <Step ID="5" Operand="S6"/>
        ${_t(26, 'T8', 'F')}
        <Step ID="6" Operand="S7"/>
        ${_t(27, 'T9', 'G')}
        ${_t(21, 'T2', 'B')}
        <Step ID="3" Operand="S2"/>
        ${_t(22, 'T4', 'H')}
        <Step ID="7" Operand="S9"/>
        <DirectedLink FromID="1" ToID="30"/>
        <DirectedLink FromID="31" ToID="20"/>
        <DirectedLink FromID="32" ToID="21"/>
        <DirectedLink FromID="20" ToID="2"/>
        <DirectedLink FromID="2" ToID="40"/>
        <DirectedLink FromID="41" ToID="23"/>
        <DirectedLink FromID="42" ToID="24"/>
        <DirectedLink FromID="23" ToID="4"/>
        <DirectedLink FromID="24" ToID="5"/>
        <DirectedLink FromID="4" ToID="25"/>
        <DirectedLink FromID="5" ToID="26"/>
        <DirectedLink FromID="25" ToID="41"/>
        <DirectedLink FromID="26" ToID="42"/>
        <DirectedLink FromID="40" ToID="6"/>
        <DirectedLink FromID="6" ToID="27"/>
        <DirectedLink FromID="27" ToID="31"/>
        <DirectedLink FromID="21" ToID="3"/>
        <DirectedLink FromID="3" ToID="22"/>
        <DirectedLink FromID="22" ToID="32"/>
        <DirectedLink FromID="30" ToID="7"/>'''));

      expect(ws, isEmpty);
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(2));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), hasLength(2));
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.transitions, hasLength(8));
      expect(tr.transitions.map((t) => t.kind).toSet(), {'single'});
      expect(
          tr.transitions.every((t) =>
              t.fromStepId.isNotEmpty && t.toStepId.isNotEmpty),
          isTrue);
    });

    test('BranchFlow is read but not trusted: a mismatch warns, the links win', () {
      final (body, ws) = _build(_wrap(
          selectionChart.replaceFirst('BranchType="Selection"',
              'BranchType="Selection" BranchFlow="Diverge"')));

      expect(_hasInfo(ws, 'branch flow mismatch'), isTrue, reason: _infos(ws).toString());
      expect(_hasInfo(ws, 'branch shape not representable'), isFalse);
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv), hasLength(1));
      expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv), hasLength(1));
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a raw ID="-1" can never collide with a branch connector (Critical 2)', () {
      // Without §2's `parsed < 0` gate the step would keep localId -1, which
      // is exactly divId of the first branch: byId is last-write-wins while
      // stepNodes/succ/pred keep BOTH, so the chart would translate cleanly
      // with zero warnings AS THE WRONG LOGIC.
      final (body, ws) = _build(_wrap('''
        <Step ID="-1" Operand="Neg" InitialStep="true"/>
        <Step ID="1" Operand="S0"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        ${_t(2, 'T1', 'A')}
        <Step ID="3" Operand="S1"/>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>'''));

      final neg = body.nodes.firstWhere((n) => n.name == 'Neg');
      final div = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.selDiv);
      expect(neg.localId, lessThan(0));
      expect(neg.localId == div.localId, isFalse);
      expect(_hasInfo(ws, 'malformed ID'), isTrue);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse, reason: 'the gate must make this LOUD');
      expect(tr.stubReason, 'complex-topology');
    });
  });

  group('L5X SFC: the 4-bit emission decision table (§3)', () {
    /// A selection-branch fixture in which each of the four buckets is set
    /// independently, through the BRANCH id — the only form in which every
    /// bit is independently settable.
    String bits(bool divIn, bool divOut, bool convIn, bool convOut) => _wrap('''
      <Step ID="1" Operand="S1" InitialStep="true"/>
      ${_t(2, 'T1', 'A')}
      ${_t(3, 'T2', 'B')}
      <Step ID="4" Operand="S2"/>
      <Branch ID="10" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
      ${divIn ? '<DirectedLink FromID="1" ToID="10"/>' : ''}
      ${divOut ? '<DirectedLink FromID="10" ToID="2"/>' : ''}
      ${convIn ? '<DirectedLink FromID="3" ToID="10"/>' : ''}
      ${convOut ? '<DirectedLink FromID="10" ToID="4"/>' : ''}''');

    // Every one of the 16 combinations is named: 3 well-formed shapes and the
    // 13 defect rows, each with its own cause clause.
    const rows = <(bool, bool, bool, bool, bool, bool, String?)>[
      //div in, div out, conv in, conv out, emit div, emit conv, cause
      (true, true, true, true, true, true, null),
      (true, true, false, false, true, false, null),
      (false, false, true, true, false, true, null),
      (true, true, true, false, true, true, 'convergence has no outlet'),
      (true, true, false, true, true, true, 'convergence has no inlet'),
      (true, false, true, true, true, true, 'divergence has no legs'),
      (false, true, true, true, true, true, 'divergence has no inlet'),
      (true, false, false, false, true, false, 'divergence has no legs'),
      (false, true, false, false, true, false, 'divergence has no inlet'),
      (false, false, true, false, false, true, 'convergence has no outlet'),
      (false, false, false, true, false, true, 'convergence has no inlet'),
      (true, false, true, false, true, true, 'divergence has no legs'),
      (true, false, false, true, true, true, 'divergence has no legs'),
      (false, true, true, false, true, true, 'divergence has no inlet'),
      (false, true, false, true, true, true, 'divergence has no inlet'),
      (false, false, false, false, false, false, 'branch has no links'),
    ];

    for (final r in rows) {
      final (dIn, dOut, cIn, cOut, emitDiv, emitConv, cause) = r;
      test('bits $dIn/$dOut/$cIn/$cOut -> '
          '${cause ?? 'no defect'}', () {
        final (body, ws) = _build(bits(dIn, dOut, cIn, cOut));

        expect(body.nodes.where((n) => n.kind == SfcNodeKind.selDiv),
            hasLength(emitDiv ? 1 : 0));
        expect(body.nodes.where((n) => n.kind == SfcNodeKind.selConv),
            hasLength(emitConv ? 1 : 0));

        final shape = _infos(ws)
            .where((m) => m.contains('branch shape not representable ('))
            .toList();
        if (cause == null) {
          expect(shape, isEmpty, reason: shape.toString());
        } else {
          // A poisoned branch still emits its connectors, so the element
          // count stays honest — but exactly ONE cause is reported.
          expect(shape, hasLength(1));
          expect(shape.single,
              contains('branch shape not representable ($cause)'));
          final tr = translateSfcBody(body, pouName: 'P');
          expect(tr.translated, isFalse);
          expect(tr.stubReason, 'complex-topology');
        }
      });
    }
  });

  group('L5X SFC: branch shape validation and its cause clauses (§3, §8)', () {
    test('a selection leg headed by a step', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Step ID="4" Operand="S2"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="4"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection leg head is a step, expected transition)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a selection leg tailed by a step', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Step ID="4" Operand="S2"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="11"/>
        <DirectedLink FromID="10" ToID="4"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection leg tail is a step, expected transition)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a simultaneous leg headed by a transition', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T0', 'A')}
        ${_t(3, 'T1', 'B')}
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="10"/>
        <DirectedLink FromID="11" ToID="3"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous leg head is a transition, expected step)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a simultaneous leg tailed by a transition', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T0', 'A')}
        ${_t(3, 'T1', 'B')}
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="11"/>
        <DirectedLink FromID="10" ToID="3"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous leg tail is a transition, expected step)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-ins on a selection divergence', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Step ID="5" Operand="S0b"/>
        ${_t(2, 'T1', 'A')}
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="5" ToID="10"/>
        <DirectedLink FromID="10" ToID="2"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection divergence has 2 inlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-outs on a selection convergence', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T1', 'A')}
        <Step ID="4" Operand="S2"/>
        <Step ID="5" Operand="S3"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="10"/>
        <DirectedLink FromID="10" ToID="4"/>
        <DirectedLink FromID="10" ToID="5"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(selection convergence has 2 outlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-ins on a simultaneous divergence', () {
      final (_, ws) = _build(_wrap('''
        ${_t(2, 'T0', 'A')}
        ${_t(3, 'T0b', 'B')}
        <Step ID="4" Operand="S1"/>
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="2" ToID="10"/>
        <DirectedLink FromID="3" ToID="10"/>
        <DirectedLink FromID="10" ToID="4"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous divergence has 2 inlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('two trunk-outs on a simultaneous convergence', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S1" InitialStep="true"/>
        ${_t(2, 'T5', 'A')}
        ${_t(3, 'T5b', 'B')}
        <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="10" ToID="2"/>
        <DirectedLink FromID="10" ToID="3"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(simultaneous convergence has 2 outlets, expected 1)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('connector-adjacent nesting poisons with its own cause', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
        <Branch ID="20" BranchType="Selection"><Leg ID="21"/></Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="11" ToID="20"/>'''));
      expect(
          _hasInfo(ws, 'branch shape not representable '
              '(branch is directly adjacent to another branch)'),
          isTrue,
          reason: _infos(ws).toString());
    });

    test('a <Branch> nested inside a <Leg> is unregistered -> dangling link', () {
      // Pins the §2 recursion policy: pass 1 walks the DIRECT children of each
      // <SFCContent>, plus a <Branch>'s direct <Leg> children, and no further.
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S0" InitialStep="true"/>
        ${_t(2, 'T1', 'A')}
        <Branch ID="10" BranchType="Selection">
          <Leg ID="11"><Branch ID="20" BranchType="Selection"><Leg ID="21"/></Branch></Leg>
          <Leg ID="12"/>
        </Branch>
        <DirectedLink FromID="1" ToID="10"/>
        <DirectedLink FromID="20" ToID="2"/>'''));
      expect(_hasInfo(ws, 'dangling link'), isTrue, reason: _infos(ws).toString());
    });

    test('an unrecognized BranchType poisons and synthesizes nothing', () {
      for (final (attr, shown) in const [
        ('', ''),
        (' BranchType="Parallel"', 'Parallel'),
      ]) {
        final (body, ws) = _build(_wrap('''
          <Step ID="1" Operand="S0" InitialStep="true"/>
          ${_t(2, 'T1', 'A')}
          <Branch ID="10"$attr><Leg ID="11"/></Branch>
          <DirectedLink FromID="1" ToID="10"/>
          <DirectedLink FromID="11" ToID="2"/>'''));

        expect(_hasInfo(ws, 'branch type "$shown"'), isTrue,
            reason: _infos(ws).toString());
        expect(
            body.nodes.any((n) => const [
                  SfcNodeKind.selDiv,
                  SfcNodeKind.selConv,
                  SfcNodeKind.simDiv,
                  SfcNodeKind.simConv
                ].contains(n.kind)),
            isFalse);
        // Links touching it are discarded, NOT reported as dangling: the
        // branch-type breadcrumb is the one actionable cause.
        expect(_hasInfo(ws, 'dangling link'), isFalse);
        expect(translateSfcBody(body, pouName: 'P').translated, isFalse);
      }
    });

    test('the four inlet/outlet KIND causes are unreachable by construction', () {
      // §3's classifier derives the trunk role FROM the neighbour's kind, so
      // divIn/convOut can only ever hold correctly-kinded nodes. The checks
      // exist as defence in depth against a future classifier change.
      //
      // DOCUMENTATION ONLY — the enforcing assertion lives in `_build`, so it
      // rides on every fixture in this file including all 16 emission rows and
      // all 8 shape fixtures. A version of this test that only walked
      // well-formed charts would pass with the kind checks deleted outright,
      // which is why it must not be the only home for the claim.
      final fixtures = <String>[
        _wrap('''
          <Step ID="1" Operand="S0" InitialStep="true"/>
          <Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>
          ${_t(2, 'T1', 'A')}
          <Step ID="3" Operand="S1"/>
          ${_t(4, 'T2', 'B')}
          <Step ID="5" Operand="S2"/>
          <DirectedLink FromID="1" ToID="10"/>
          <DirectedLink FromID="11" ToID="2"/>
          <DirectedLink FromID="2" ToID="3"/>
          <DirectedLink FromID="3" ToID="4"/>
          <DirectedLink FromID="4" ToID="11"/>
          <DirectedLink FromID="10" ToID="5"/>'''),
        _wrap('''
          ${_t(2, 'T0', 'A')}
          <Branch ID="10" BranchType="Simultaneous"><Leg ID="11"/></Branch>
          <Step ID="3" Operand="S1"/>
          ${_t(4, 'T5', 'B')}
          <DirectedLink FromID="2" ToID="10"/>
          <DirectedLink FromID="11" ToID="3"/>
          <DirectedLink FromID="3" ToID="11"/>
          <DirectedLink FromID="10" ToID="4"/>'''),
      ];
      for (final f in fixtures) {
        final (_, ws) = _build(f);
        expect(_infos(ws).any((m) => m.contains('divergence inlet is a')), isFalse);
        expect(_infos(ws).any((m) => m.contains('convergence outlet is a')), isFalse);
      }
    });
  });

  group('L5X SFC: step timing attributes (§5)', () {
    test('a zero or absent Preset is silent — Logix writes Preset="0" everywhere', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true" Preset="0"
              LimitHigh="0" LimitLow="0"/>
        <Step ID="2" Operand="Run"/>'''));
      expect(_hasInfo(ws, 'timing attribute'), isFalse, reason: _infos(ws).toString());
    });

    test('a meaningful Preset/LimitHigh/LimitLow each warn once, naming the step', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Step_003" InitialStep="true"
              Preset="5000" LimitHigh="9000" LimitLow="10"/>'''));

      final timing = _infos(ws).where((m) => m.contains('timing attribute')).toList();
      expect(timing, hasLength(3));
      expect(timing[0],
          'Routine "Main_Seq": SFC step "Step_003" timing attribute Preset '
          'dropped — no native step timer (use STEP_T in a transition condition).');
      expect(timing[1], contains('timing attribute LimitHigh'));
      expect(timing[2], contains('timing attribute LimitLow'));
      // Dropping timing NEVER stubs the chart.
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a *UsesExpr="true" companion makes the attribute meaningful even at 0', () {
      final (_, ws) = _build(_wrap('''
        <Step ID="1" Operand="S" InitialStep="true" Preset="0" PresetUsesExpr="true"/>'''));
      expect(_infos(ws).where((m) => m.contains('timing attribute')), hasLength(1));
    });
  });

  group('L5X SFC: action degrades (§6)', () {
    test('IsBoolean="true" skips the action with a `boolean action` breadcrumb', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="Motor" Qualifier="N" IsBoolean="true"/>
        </Step>'''));

      expect(body.actions, isEmpty);
      expect(_hasInfo(ws, 'boolean action'), isTrue, reason: _infos(ws).toString());
      expect(_hasInfo(ws, 'action has no body'), isFalse); // boolean check wins
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('an action with an absent or whitespace-only body is skipped, loudly', () {
      // Without this the assoc reaches _actionSt, whose `if (s.text.isNotEmpty)`
      // guard drops it WITHOUT a warning — the one silent-loss hole in the
      // action path, and one only the builder can close.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="Empty1" Qualifier="N"/>
          <Action ID="12" Operand="Empty2" Qualifier="N">
            <Body><STContent><Line Number="0"><![CDATA[   ]]></Line></STContent></Body>
          </Action>
        </Step>'''));

      expect(body.actions, isEmpty);
      final noBody = _infos(ws).where((m) => m.contains('action has no body')).toList();
      expect(noBody, hasLength(2));
      expect(noBody[0], contains('"Empty1"'));
      expect(noBody[1], contains('"Empty2"'));
      // A per-action degrade, NOT a poison: an empty action is a
      // documentation stub, not a structural defect.
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('a non-N qualifier is NOT pre-filtered — the translator degrades it', () {
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Run" InitialStep="true">
          <Action ID="11" Operand="A1" Qualifier="S">
            <Body><STContent><Line Number="0"><![CDATA[Motor := TRUE;]]></Line></STContent></Body>
          </Action>
        </Step>'''));

      expect(body.actions.single.qualifier, 'S'); // reaches the translator untouched
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isTrue);
      expect(tr.steps.single.actionSt, '');
      expect(
          tr.warnings.any((w) =>
              w.severity == WarningSeverity.info &&
              w.message.contains('unsupported — action skipped (N only)')),
          isTrue);
    });
  });

  group('L5X SFC: unmappable elements and the poison mechanism (§4)', () {
    for (final tag in const ['Stop', 'SbrRet', 'JSR', 'Frobnicate', 'Leg']) {
      test('<$tag> has no representable equivalent', () {
        final (body, ws) = _build(_wrap('''
          <Step ID="1" Operand="Idle" InitialStep="true"/>
          <$tag ID="9" X="0" Y="0"/>'''));

        expect(
            _infos(ws).any((m) =>
                m.contains('no representable equivalent') &&
                m.contains('<$tag ID="9">')),
            isTrue,
            reason: _infos(ws).toString());
        // Not emitted as a node — the poison flag is what makes it visible.
        expect(body.nodes.where((n) => n.name == '#unrepresentable'), hasLength(1));
        // Poison fires even though the element is on NO path at all.
        final tr = translateSfcBody(body, pouName: 'P');
        expect(tr.translated, isFalse);
        expect(tr.stubReason, 'complex-topology');
      });
    }

    test('a poisoned body produces exactly ONE warning and ZERO translator infos', () {
      // The mechanism's whole guarantee: _build's step->step edge scan sits
      // above every warning-emitting statement, so nothing else gets a word in.
      final (body, _) = _build(_wrap('''
        <Step ID="1" Operand="Idle"/>
        <Step ID="2" Operand="Run">
          <Action ID="21" Operand="A" Qualifier="S">
            <Body><STContent><Line Number="0"><![CDATA[X := 1;]]></Line></STContent></Body>
          </Action>
        </Step>
        <Stop ID="9"/>'''));

      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.translated, isFalse);
      expect(tr.stubReason, 'complex-topology');
      expect(tr.warnings, hasLength(1));
      expect(tr.warnings.single.severity, WarningSeverity.warning);
      expect(tr.warnings.single.message,
          contains('step directly wired to step (missing transition)'));
    });

    test('many defects still produce exactly one poison node', () {
      final (body, _) = _build(_wrap('''
        <Stop ID="9"/>
        <SbrRet ID="8"/>
        <Step ID="abc" Operand="Bad"/>
        <Step ID="1" Operand="A" InitialStep="true"/>
        <Step ID="1" Operand="Dup"/>
        <DirectedLink FromID="1" ToID="777"/>'''));
      expect(body.nodes.where((n) => n.name == '#unrepresentable'), hasLength(1));
    });

    test('the L5X path never reaches the translator\'s PLCopen-only degrades', () {
      // §1: Logix has no external action/transition POUs and no graphically
      // wired condition, so these translator paths are dead for L5X input.
      // Kept in the translator (PLCopen needs them), asserted unreachable here.
      for (final fixture in [
        _wrap('''
          <Step ID="1" Operand="Idle" InitialStep="true">
            <Action ID="11" Operand="A" Qualifier="N">
              <Body><STContent><Line Number="0"><![CDATA[X := 1;]]></Line></STContent></Body>
            </Action>
          </Step>
          ${_t(2, 'T1', 'Go')}
          <Step ID="3" Operand="Run"/>
          <DirectedLink FromID="1" ToID="2"/>
          <DirectedLink FromID="2" ToID="3"/>'''),
      ]) {
        final (body, _) = _build(fixture);
        // Actions are associated by XML NESTING, so stepLocalId is always a
        // real step id — the "unknown step" degrade is structurally
        // unreachable.
        final stepIds = {
          for (final n in body.nodes)
            if (n.kind == SfcNodeKind.step) n.localId
        };
        expect(body.actions.every((a) => stepIds.contains(a.stepLocalId)), isTrue);
        final tr = translateSfcBody(body, pouName: 'P');
        for (final needle in const [
          'action associated with unknown step',
          'not resolvable to ST — skipped',
          'transition references',
          'graphical transition condition',
        ]) {
          expect(tr.warnings.any((w) => w.message.contains(needle)), isFalse,
              reason: needle);
        }
      }
    });
  });

  group('L5X SFC: annotations and empty content (§2, §8)', () {
    test('a link anchored to a <TextBox> is discarded — no warning, no poison', () {
      // Poisoning a chart because it is well commented would be absurd.
      final (body, ws) = _build(_wrap('''
        <Step ID="1" Operand="Idle" InitialStep="true"/>
        ${_t(2, 'T1', 'Go')}
        <Step ID="3" Operand="Run"/>
        <TextBox ID="50" X="0" Y="0"/>
        <DirectedLink FromID="1" ToID="2"/>
        <DirectedLink FromID="2" ToID="3"/>
        <DirectedLink FromID="50" ToID="1"/>'''));

      expect(_hasInfo(ws, 'dangling link'), isFalse, reason: _infos(ws).toString());
      expect(body.nodes.where((n) => n.name == '#unrepresentable'), isEmpty);
      expect(body.edges, hasLength(2));
      expect(translateSfcBody(body, pouName: 'P').translated, isTrue);
    });

    test('an EMPTY <SFCContent/> yields no-initial, not a topology defect', () {
      // Guards against a "when in doubt, poison" drift that would mislabel an
      // empty routine.
      final (body, ws) = _build(_wrap(''));
      expect(body.nodes, isEmpty);
      expect(ws, isEmpty);
      final tr = translateSfcBody(body, pouName: 'P');
      expect(tr.stubReason, 'no-initial');
      expect(tr.warnings.single.message, contains('chart has no steps'));
    });
  });

  group('L5X SFC: §8 warning conformance', () {
    // Every builder-emitted row of §8's table, with its exact assertable
    // substring, reachable from a named fixture. Severity is `info` on ALL of
    // them: builder warnings are breadcrumbs, the verdict belongs to
    // translateSfcBody + the mapper.
    final cases = <(String, String, String)>[
      (
        'annotations',
        '<Step ID="1" Operand="A" InitialStep="true"/><TextBox ID="9"/>',
        'element(s) ignored'
      ),
      (
        'unknown element',
        '<Step ID="1" Operand="A" InitialStep="true"/><Stop ID="9"/>',
        'no representable equivalent'
      ),
      ('malformed id', '<Step ID="abc" Operand="A"/>', 'malformed ID'),
      (
        'duplicate id',
        '<Step ID="1" Operand="A"/><Step ID="1" Operand="B"/>',
        'duplicate ID'
      ),
      (
        'dangling link',
        '<Step ID="1" Operand="A"/><DirectedLink FromID="1" ToID="99"/>',
        'dangling link'
      ),
      (
        'branch type',
        '<Branch ID="10" BranchType="Parallel"><Leg ID="11"/></Branch>',
        'branch type'
      ),
      (
        'branch shape',
        '<Branch ID="10" BranchType="Selection"><Leg ID="11"/></Branch>',
        'branch shape not representable ('
      ),
      (
        'timing attribute',
        '<Step ID="1" Operand="A" InitialStep="true" Preset="5000"/>',
        'timing attribute'
      ),
      (
        'boolean action',
        '<Step ID="1" Operand="A" InitialStep="true">'
            '<Action ID="11" Operand="M" IsBoolean="true"/></Step>',
        'boolean action'
      ),
      (
        'action has no body',
        '<Step ID="1" Operand="A" InitialStep="true">'
            '<Action ID="11" Operand="M"/></Step>',
        'action has no body'
      ),
    ];

    for (final (label, fixture, needle) in cases) {
      test('$label -> info "$needle", prefixed with the owner label', () {
        final (_, ws) = _build(_wrap(fixture));
        final hits = ws
            .where((w) => w.message.contains(needle))
            .toList();
        expect(hits, isNotEmpty, reason: _infos(ws).toString());
        expect(hits.every((w) => w.severity == WarningSeverity.info), isTrue);
        expect(hits.every((w) => w.message.startsWith('Routine "Main_Seq": ')),
            isTrue, reason: hits.map((w) => w.message).toString());
      });
    }
  });

  group('L5X SFC: the double-warning regression (§7)', () {
    // The bug this sub-project fixes: the old parser arm emitted its own
    // warning-severity message on TOP of the translator's and the mapper's —
    // three messages where the PLCopen path emits two.
    const translating = '''
      <Step ID="1" Operand="Idle" InitialStep="true"/>
      <Transition ID="2"><Condition><STContent>
        <Line Number="0"><![CDATA[Start]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="Run"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="3"/>''';
    const stubbing = '''
      <Step ID="1" Operand="Idle" InitialStep="true"/>
      <Stop ID="9"/>''';

    List<ImportWarning> mapAndCollect(String sfcChildren) {
      final ir = parseL5x(_wrap(sfcChildren));
      final res =
          mapImportedProject(ir, projectName: ir.name, projectId: 'sfc_msg');
      return res.report.warnings
          .where((w) => w.message.contains('Main_Seq'))
          .toList();
    }

    test('parseL5x alone emits zero warning-severity messages for the POU', () {
      for (final f in [translating, stubbing]) {
        final ir = parseL5x(_wrap(f));
        expect(
            ir.warnings.where((w) =>
                w.severity == WarningSeverity.warning &&
                w.message.contains('Main_Seq')),
            isEmpty);
      }
    });

    test('a translating SFC routine produces zero warning-severity messages', () {
      expect(
          mapAndCollect(translating)
              .where((w) => w.severity == WarningSeverity.warning),
          isEmpty);
    });

    test('a stubbing SFC routine produces exactly two — translator + mapper', () {
      final loud = mapAndCollect(stubbing)
          .where((w) => w.severity == WarningSeverity.warning)
          .toList();
      expect(loud, hasLength(2), reason: loud.map((w) => w.message).toString());
      expect(loud.any((w) => w.message.contains('not translated (')), isTrue);
      expect(
          loud.any((w) => w.message.contains('graphical body not yet translated')),
          isTrue);
    });
  });
}
