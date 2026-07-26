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

  test('stub emits a warning with pou name and stub detail', () {
    final body = SfcBody(nodes: [
      _step(1, 'Idle', initial: true),
      _trans(2, SfcCondWired()),
      _step(3, 'Run'),
    ], edges: [_e(1, 2), _e(2, 3)], actions: const []);
    final tr = translateSfcBody(body, pouName: 'P');
    expect(tr.translated, isFalse);
    expect(
      tr.warnings.any((w) =>
          w.severity == WarningSeverity.warning &&
          w.message.contains('P') &&
          w.message.contains('not translated') &&
          w.message.contains('graphical transition condition')),
      isTrue,
    );
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
}
