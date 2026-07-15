// Pure tests for SFC-v2 Task 6 structured authoring: alternative branches,
// parallel fork/join creation + extension, nesting, and collapse-on-delete.
//
// These tests assert on MODEL STRUCTURE (transition kinds + toStepIds /
// fromStepIds consistency) and on the HARD invariant that the chart always
// stays parseable — `parseSfc` never throws and never references a step id that
// does not exist.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_edit.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';

// ---- fixtures ---------------------------------------------------------------

/// A linear chart a(init) -> b -> c.
PlcProgram _linear() {
  final p = PlcProgram(name: 'L', language: 'SequentialFunctionChart', rungs: []);
  p.sfcSteps.addAll([
    SfcStep(id: 's0', name: 'a', isInitial: true),
    SfcStep(id: 's1', name: 'b'),
    SfcStep(id: 's2', name: 'c'),
  ]);
  p.sfcTransitions.addAll([
    SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'TRUE'),
    SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'TRUE'),
  ]);
  return p;
}

// ---- invariant assertion ----------------------------------------------------

/// The HARD invariant: parse succeeds (no throw) and every id referenced by a
/// transition resolves to an existing step (no dangling references).
void _assertParseableNoDangling(PlcProgram p) {
  // Must not throw / loop forever.
  final root = parseSfc(p.sfcSteps, p.sfcTransitions);
  expect(root, isNotNull);

  final ids = p.sfcSteps.map((s) => s.id).toSet();
  for (final t in p.sfcTransitions) {
    switch (t.kind) {
      case 'single':
        expect(ids.contains(t.fromStepId), isTrue,
            reason: 'single ${t.id} dangling fromStepId ${t.fromStepId}');
        expect(ids.contains(t.toStepId), isTrue,
            reason: 'single ${t.id} dangling toStepId ${t.toStepId}');
        break;
      case 'parallelFork':
        expect(ids.contains(t.fromStepId), isTrue,
            reason: 'fork ${t.id} dangling fromStepId ${t.fromStepId}');
        expect(t.toStepIds.length >= 2, isTrue,
            reason: 'fork ${t.id} must keep >= 2 heads');
        for (final h in t.toStepIds) {
          expect(ids.contains(h), isTrue,
              reason: 'fork ${t.id} dangling head $h');
        }
        break;
      case 'parallelJoin':
        expect(ids.contains(t.toStepId), isTrue,
            reason: 'join ${t.id} dangling toStepId ${t.toStepId}');
        expect(t.fromStepIds.length >= 2, isTrue,
            reason: 'join ${t.id} must keep >= 2 tails');
        for (final tl in t.fromStepIds) {
          expect(ids.contains(tl), isTrue,
              reason: 'join ${t.id} dangling tail $tl');
        }
        break;
      default:
        fail('unexpected transition kind ${t.kind}');
    }
  }
}

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

SfcTransition _forkOf(PlcProgram p) =>
    p.sfcTransitions.firstWhere((t) => t.kind == 'parallelFork');
SfcTransition _joinOf(PlcProgram p) =>
    p.sfcTransitions.firstWhere((t) => t.kind == 'parallelJoin');

/// True when [stepId] appears as a [StepRegion] INSIDE some [ParRegion] branch
/// of the parsed [root] — i.e. it is reachable within its branch, not stranded
/// as a top-level trailing orphan leaf.
bool _stepInSomeParBranch(SfcRegion root, String stepId) {
  for (final par in _flatten(root).whereType<ParRegion>()) {
    for (final b in par.branches) {
      for (final r in b) {
        final hit = _flatten(r)
            .whereType<StepRegion>()
            .any((s) => s.step.id == stepId);
        if (hit) {
          return true;
        }
      }
    }
  }
  return false;
}

void main() {
  group('addParallelBranch', () {
    test('linear -> creates a fork/join pair with 2 consistent branches', () {
      final p = _linear();
      final fork = addParallelBranch(p, 's1');

      expect(fork.kind, 'parallelFork');
      expect(fork.fromStepId, 's1');
      expect(fork.toStepIds.length, 2);

      final join = _joinOf(p);
      // The fork's heads and the join's tails describe the same branch set.
      expect(join.fromStepIds.toSet(), fork.toStepIds.toSet());
      // The linear successor 'c' becomes the post-join step.
      expect(join.toStepId, 's2');
      // The old linear edge s1 -> s2 is gone (fork is now the sole successor).
      expect(
        p.sfcTransitions.any(
            (t) => t.kind == 'single' && t.fromStepId == 's1' && t.toStepId == 's2'),
        isFalse,
      );

      _assertParseableNoDangling(p);

      // The parser sees exactly one parallel region with two branches.
      final par = _flatten(parseSfc(p.sfcSteps, p.sfcTransitions))
          .whereType<ParRegion>()
          .single;
      expect(par.branches.length, 2);
    });

    test('second call on the same anchor adds a THIRD branch', () {
      final p = _linear();
      addParallelBranch(p, 's1');
      addParallelBranch(p, 's1');

      final fork = _forkOf(p);
      final join = _joinOf(p);
      expect(fork.toStepIds.length, 3);
      expect(join.fromStepIds.length, 3);
      expect(join.fromStepIds.toSet(), fork.toStepIds.toSet());

      // Still exactly one fork + one join (extended, not duplicated).
      expect(p.sfcTransitions.where((t) => t.kind == 'parallelFork').length, 1);
      expect(p.sfcTransitions.where((t) => t.kind == 'parallelJoin').length, 1);

      _assertParseableNoDangling(p);

      final par = _flatten(parseSfc(p.sfcSteps, p.sfcTransitions))
          .whereType<ParRegion>()
          .single;
      expect(par.branches.length, 3);
    });

    test('nesting: calling inside a branch nests a second fork/join', () {
      final p = _linear();
      addParallelBranch(p, 's1'); // outer fork/join around s1.

      final outerFork = _forkOf(p);
      final innerAnchor = outerFork.toStepIds.first; // a branch head/tail.

      addParallelBranch(p, innerAnchor); // nest inside the first branch.

      // Two forks + two joins now exist.
      expect(p.sfcTransitions.where((t) => t.kind == 'parallelFork').length, 2);
      expect(p.sfcTransitions.where((t) => t.kind == 'parallelJoin').length, 2);

      _assertParseableNoDangling(p);

      // The inner ParRegion lives INSIDE a branch of the outer ParRegion.
      final root = parseSfc(p.sfcSteps, p.sfcTransitions);
      final pars = _flatten(root).whereType<ParRegion>().toList();
      expect(pars.length, 2);

      final outer = pars.firstWhere((r) => r.fork.id == outerFork.id);
      final inner = pars.firstWhere((r) => r.fork.id != outerFork.id);
      // The inner fork must be reachable only through one of the outer branches.
      final branchHasInner = outer.branches.any(
          (b) => b.whereType<ParRegion>().any((r) => r.fork.id == inner.fork.id));
      expect(branchHasInner, isTrue);
    });
  });

  group('addSfcStepAfter', () {
    test('on a parallel-branch TAIL keeps the step INSIDE the branch', () {
      final p = _linear();
      final fork = addParallelBranch(p, 's1'); // join.fromStepIds == fork heads.
      final tail = fork.toStepIds.first; // b1: a fresh single-step branch tail.

      final join = _joinOf(p);
      expect(join.fromStepIds.contains(tail), isTrue);

      final added = addSfcStepAfter(p, tail); // extend that branch: tail -> added.

      // The join now tracks the NEW tail, not the stale one.
      expect(join.fromStepIds.contains(added.id), isTrue,
          reason: 'join must adopt the new branch tail');
      expect(join.fromStepIds.contains(tail), isFalse,
          reason: 'old tail is no longer a branch tail');

      _assertParseableNoDangling(p);

      // The new step is reachable INSIDE the parallel branch (not orphaned as a
      // stray trailing box).
      final root = parseSfc(p.sfcSteps, p.sfcTransitions);
      expect(_stepInSomeParBranch(root, added.id), isTrue,
          reason: 'new step must live inside the parallel branch');
    });
  });

  group('addAlternativeBranch', () {
    test('adds a second single so the step diverges (>= 2 singles)', () {
      final p = _linear();
      addAlternativeBranch(p, 's1');

      final singlesOut = p.sfcTransitions
          .where((t) => t.kind == 'single' && t.fromStepId == 's1')
          .toList();
      expect(singlesOut.length >= 2, isTrue);

      _assertParseableNoDangling(p);

      // The parser now classifies s1 as an alternative divergence head.
      final alt = _flatten(parseSfc(p.sfcSteps, p.sfcTransitions))
          .whereType<AltRegion>()
          .single;
      expect(alt.head.id, 's1');
      expect(alt.branches.length >= 2, isTrue);
    });

    test('on a parallel-branch TAIL reconverges INSIDE the branch', () {
      final p = _linear();
      final fork = addParallelBranch(p, 's1');
      final tail = fork.toStepIds.first; // b1: branch tail.

      final join = _joinOf(p);
      expect(join.fromStepIds.contains(tail), isTrue);

      final diverge = addAlternativeBranch(p, tail);
      final altStepId = diverge.toStepId; // the alternative arm's step.

      // The branch tail became a divergence head with >= 2 single exits.
      final singlesOut = p.sfcTransitions
          .where((t) => t.kind == 'single' && t.fromStepId == tail)
          .toList();
      expect(singlesOut.length >= 2, isTrue);

      // The join no longer keys on the (now non-tail) anchor; every tail it lists
      // is a real, current tail step.
      expect(join.fromStepIds.contains(tail), isFalse);
      final ids = p.sfcSteps.map((s) => s.id).toSet();
      for (final tl in join.fromStepIds) {
        expect(ids.contains(tl), isTrue);
      }

      _assertParseableNoDangling(p);

      final root = parseSfc(p.sfcSteps, p.sfcTransitions);
      // The alternative arm is reachable inside the parallel branch, and the
      // branch tail is now an alternative divergence head.
      expect(_stepInSomeParBranch(root, altStepId), isTrue);
      final altHeads =
          _flatten(root).whereType<AltRegion>().map((a) => a.head.id).toSet();
      expect(altHeads.contains(tail), isTrue,
          reason: 'the branch tail must parse as an alternative head');
    });
  });

  group('deleteParallelBranch', () {
    test('removing one branch of a 3-way fork keeps a valid fork', () {
      final p = _linear();
      addParallelBranch(p, 's1');
      addParallelBranch(p, 's1'); // 3 branches now.

      final fork = _forkOf(p);
      final victim = fork.toStepIds.first;
      deleteParallelBranch(p, fork.id, victim);

      final forkAfter = _forkOf(p);
      expect(forkAfter.toStepIds.length, 2);
      expect(forkAfter.toStepIds.contains(victim), isFalse);
      expect(p.sfcSteps.any((s) => s.id == victim), isFalse);

      _assertParseableNoDangling(p);
    });

    test('deleting down to one branch COLLAPSES to a plain sequence', () {
      final p = _linear();
      final fork = addParallelBranch(p, 's1'); // 2 branches.
      final heads = List<String>.from(fork.toStepIds);
      final survivor = heads[1];

      deleteParallelBranch(p, fork.id, heads[0]);

      // No parallel structure remains.
      expect(p.sfcTransitions.any((t) => t.kind == 'parallelFork'), isFalse);
      expect(p.sfcTransitions.any((t) => t.kind == 'parallelJoin'), isFalse);

      // The surviving branch is spliced into the sequence: s1 -> survivor -> s2.
      expect(
        p.sfcTransitions.any((t) =>
            t.kind == 'single' && t.fromStepId == 's1' && t.toStepId == survivor),
        isTrue,
      );
      expect(
        p.sfcTransitions.any((t) =>
            t.kind == 'single' && t.fromStepId == survivor && t.toStepId == 's2'),
        isTrue,
      );

      _assertParseableNoDangling(p);

      // The parser now sees a purely linear chart (no Par / Alt).
      final all = _flatten(parseSfc(p.sfcSteps, p.sfcTransitions));
      expect(all.whereType<ParRegion>(), isEmpty);
      expect(all.whereType<AltRegion>(), isEmpty);
    });

    test('deleting a branch that CONTAINS a nested parallel leaves no garbage',
        () {
      final p = _linear();
      final outerFork = addParallelBranch(p, 's1'); // outer fork/join around s1.
      final victim = outerFork.toStepIds[0]; // branch we will nest into + delete.
      final survivor = outerFork.toStepIds[1]; // the sibling that must survive.

      // Nest a second fork/join INSIDE the victim branch.
      addParallelBranch(p, victim);

      // Capture the nested structure's ids so we can assert they are all gone.
      final innerFork = p.sfcTransitions.firstWhere(
          (t) => t.kind == 'parallelFork' && t.fromStepId == victim);
      final outerJoin = p.sfcTransitions.firstWhere((t) =>
          t.kind == 'parallelJoin' && t.fromStepIds.contains(survivor));
      // The victim branch's outer tail is the join tail that is NOT the survivor.
      final victimOuterTail =
          outerJoin.fromStepIds.firstWhere((id) => id != survivor);
      final nestedIds = <String>{...innerFork.toStepIds, victimOuterTail};

      _assertParseableNoDangling(p); // sanity: well-formed before delete.

      deleteParallelBranch(p, outerFork.id, victim);

      // Every nested step (and the victim head) is gone — nothing orphaned.
      final ids = p.sfcSteps.map((s) => s.id).toSet();
      expect(ids.contains(victim), isFalse);
      for (final n in nestedIds) {
        expect(ids.contains(n), isFalse, reason: 'nested id $n must be removed');
      }

      // Collapsed to a plain sequence: no parallel structure remains at all.
      expect(p.sfcTransitions.any((t) => t.kind == 'parallelFork'), isFalse);
      expect(p.sfcTransitions.any((t) => t.kind == 'parallelJoin'), isFalse);

      // The surviving sibling is spliced through to the outer after-step:
      // s1 -> survivor -> s2.
      expect(
        p.sfcTransitions.any((t) =>
            t.kind == 'single' && t.fromStepId == 's1' && t.toStepId == survivor),
        isTrue,
      );
      expect(
        p.sfcTransitions.any((t) =>
            t.kind == 'single' && t.fromStepId == survivor && t.toStepId == 's2'),
        isTrue,
      );

      _assertParseableNoDangling(p);

      // No step is stranded: every remaining step is reachable in the tree.
      final root = parseSfc(p.sfcSteps, p.sfcTransitions);
      final reached = _flatten(root)
          .whereType<StepRegion>()
          .map((s) => s.step.id)
          .toSet();
      expect(reached, ids, reason: 'every remaining step must be reachable');
    });
  });
}
