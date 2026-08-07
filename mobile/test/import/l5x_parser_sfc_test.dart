// L5X SFC parser units. Fixtures are synthetic and written to the ASSERTED
// <SFCContent> schema of
// docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md §1 — this repo
// contains no SFC-bearing L5X corpus file, so these fixtures ARE the schema
// pin. If a real export disagrees, the fixtures are what changes.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
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
}
