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
  });
}
