// Tests for the pure SFC region-tree parser (SFC-v2 Task 3).
//
// `parseSfc` turns a well-structured SFC graph (steps + transitions) into a
// tree of regions (Seq / Alt / Par / Step / Trans) for later 2D layout. These
// tests assert on STRUCTURE (region types + field values), never on pixel
// positions, and cover: linear (Seq), alternative (Alt + merge), parallel
// (Par fork/join), nested parallel, loop-back GOTO leaves, cycle safety, and
// graceful degradation of a partly-built chart.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';

// ---- fixture builders -------------------------------------------------------

SfcStep _step(String id, {bool initial = false}) =>
    SfcStep(id: id, name: id, isInitial: initial);

SfcTransition _single(String id, String from, String to) => SfcTransition(
      id: id,
      fromStepId: from,
      toStepId: to,
      conditionSt: '',
      kind: 'single',
    );

SfcTransition _fork(String id, String from, List<String> tos) => SfcTransition(
      id: id,
      fromStepId: from,
      toStepId: '',
      conditionSt: '',
      kind: 'parallelFork',
      toStepIds: tos,
    );

SfcTransition _join(String id, List<String> froms, String to) => SfcTransition(
      id: id,
      fromStepId: '',
      toStepId: to,
      conditionSt: '',
      kind: 'parallelJoin',
      fromStepIds: froms,
    );

// Recursively collect every region in the tree for type-presence checks.
List<SfcRegion> _flatten(SfcRegion r) {
  final out = <SfcRegion>[r];
  if (r is SeqRegion) {
    for (final c in r.items) {
      out.addAll(_flatten(c));
    }
  } else if (r is AltRegion) {
    for (final b in r.branches) {
      for (final c in b) {
        out.addAll(_flatten(c));
      }
    }
  } else if (r is ParRegion) {
    for (final b in r.branches) {
      for (final c in b) {
        out.addAll(_flatten(c));
      }
    }
  }
  return out;
}

void main() {
  group('parseSfc', () {
    test('linear a->b->c yields a Seq of Step/Trans/Step/Trans/Step', () {
      final steps = [_step('a', initial: true), _step('b'), _step('c')];
      final trans = [_single('t1', 'a', 'b'), _single('t2', 'b', 'c')];

      final root = parseSfc(steps, trans);

      expect(root, isA<SeqRegion>());
      final seq = root as SeqRegion;
      expect(seq.items.length, 5);
      expect(seq.items[0], isA<StepRegion>());
      expect((seq.items[0] as StepRegion).step.id, 'a');
      expect(seq.items[1], isA<TransRegion>());
      expect((seq.items[2] as StepRegion).step.id, 'b');
      expect((seq.items[4] as StepRegion).step.id, 'c');

      // No alternative / parallel anywhere in a linear chart.
      final all = _flatten(root);
      expect(all.whereType<AltRegion>(), isEmpty);
      expect(all.whereType<ParRegion>(), isEmpty);
    });

    test('alternative divergence/convergence yields an Alt with merge', () {
      final steps = [
        _step('a', initial: true),
        _step('x'),
        _step('y'),
        _step('m'),
      ];
      final trans = [
        _single('gA', 'a', 'x'),
        _single('gB', 'a', 'y'),
        _single('xm', 'x', 'm'),
        _single('ym', 'y', 'm'),
      ];

      final root = parseSfc(steps, trans);
      expect(root, isA<SeqRegion>());

      final alt = _flatten(root).whereType<AltRegion>().single;
      expect(alt.head.id, 'a');
      expect(alt.branches.length, 2);
      expect(alt.guards.length, 2);
      expect(alt.guards.map((t) => t.id), containsAll(<String>['gA', 'gB']));
      expect(alt.merge, isNotNull);
      expect(alt.merge!.id, 'm');
    });

    test('parallel fork/join yields a Par with join + after', () {
      final steps = [
        _step('a', initial: true),
        _step('p1'),
        _step('p2'),
        _step('q1'),
        _step('q2'),
        _step('done'),
      ];
      final trans = [
        _fork('f', 'a', ['p1', 'q1']),
        _single('p', 'p1', 'p2'),
        _single('q', 'q1', 'q2'),
        _join('j', ['p2', 'q2'], 'done'),
      ];

      final root = parseSfc(steps, trans);
      final par = _flatten(root).whereType<ParRegion>().single;

      expect(par.fork.id, 'f');
      expect(par.branches.length, 2);
      expect(par.join.id, 'j');
      expect(par.join.toStepId, 'done');
      expect(par.after, isNotNull);
      expect(par.after!.id, 'done');

      // Branch tails p2 / q2 are the last steps inside each branch.
      final branchTailIds = par.branches
          .map((b) => (b.whereType<StepRegion>().last).step.id)
          .toSet();
      expect(branchTailIds, {'p2', 'q2'});
    });

    test('nested parallel: a Par lives inside a branch of the outer Par', () {
      final steps = [
        _step('a', initial: true),
        _step('b1'),
        _step('b2'),
        _step('c1'),
        _step('c2'),
        _step('d1'),
        _step('d2'),
        _step('e1'),
        _step('e2'),
        _step('done'),
      ];
      final trans = [
        _fork('f1', 'a', ['b1', 'c1']),
        _fork('f2', 'b1', ['d1', 'e1']),
        _single('d', 'd1', 'd2'),
        _single('e', 'e1', 'e2'),
        _join('j2', ['d2', 'e2'], 'b2'),
        _single('c', 'c1', 'c2'),
        _join('j1', ['b2', 'c2'], 'done'),
      ];

      final root = parseSfc(steps, trans);
      final pars = _flatten(root).whereType<ParRegion>().toList();
      // Outer + inner = two parallel regions.
      expect(pars.length, 2);

      final outer = pars.firstWhere((p) => p.fork.id == 'f1');
      expect(outer.join.id, 'j1');
      expect(outer.after!.id, 'done');

      // The first branch (from head b1) must itself contain a ParRegion.
      final firstBranch = outer.branches[0];
      final inner = firstBranch.whereType<ParRegion>().single;
      expect(inner.fork.id, 'f2');
      expect(inner.join.id, 'j2');
      expect(inner.after!.id, 'b2');
    });

    test('loop-back edge c->a becomes a GOTO Trans leaf', () {
      final steps = [_step('a', initial: true), _step('b'), _step('c')];
      final trans = [
        _single('t1', 'a', 'b'),
        _single('t2', 'b', 'c'),
        _single('back', 'c', 'a'),
      ];

      final root = parseSfc(steps, trans);
      final gotos =
          _flatten(root).whereType<TransRegion>().where((t) => t.isGoto);
      expect(gotos.length, 1);
      final goto = gotos.single;
      expect(goto.transition.id, 'back');
      expect(goto.target, isNotNull);
      expect(goto.target!.id, 'a');
    });

    test('cycle safety: self-loop and mutual loop terminate', () {
      // Self loop a -> a.
      final selfRoot = parseSfc(
        [_step('a', initial: true)],
        [_single('s', 'a', 'a')],
      );
      final selfGoto =
          _flatten(selfRoot).whereType<TransRegion>().where((t) => t.isGoto);
      expect(selfGoto.length, 1);
      expect(selfGoto.single.target!.id, 'a');

      // Mutual loop a -> b -> a.
      final mutualRoot = parseSfc(
        [_step('a', initial: true), _step('b')],
        [_single('ab', 'a', 'b'), _single('ba', 'b', 'a')],
      );
      final steps = _flatten(mutualRoot).whereType<StepRegion>().map(
            (s) => s.step.id,
          );
      // Each step placed exactly once; the closing edge is a GOTO leaf.
      expect(steps, containsAll(<String>['a', 'b']));
      expect(
        _flatten(mutualRoot).whereType<TransRegion>().where((t) => t.isGoto),
        isNotEmpty,
      );
    });

    test('degrades gracefully: dangling target + disconnected step', () {
      final steps = [
        _step('a', initial: true),
        _step('b'),
        _step('island'), // unreachable
      ];
      final trans = [
        _single('t1', 'a', 'b'),
        _single('t2', 'b', 'ghost'), // target step does not exist
      ];

      // Must not throw / loop forever.
      final root = parseSfc(steps, trans);
      final all = _flatten(root);

      // Dangling transition -> Trans leaf with null target, not a GOTO.
      final dangling = all
          .whereType<TransRegion>()
          .where((t) => t.transition.id == 't2')
          .single;
      expect(dangling.target, isNull);
      expect(dangling.isGoto, isFalse);

      // The disconnected step is still emitted somewhere.
      final placed = all.whereType<StepRegion>().map((s) => s.step.id).toSet();
      expect(placed, containsAll(<String>['a', 'b', 'island']));
    });
  });
}
