// Tests for the pure 2D SFC region layout (SFC-v2 Task 4).
//
// `layoutSfcRegion` turns a region tree (Task 3) into absolute 2D geometry:
// boxes (step / trans / goto / forkBar / joinBar), connector segments, and an
// overall bounding width/height. These tests assert GEOMETRY INVARIANTS
// (relative position, non-overlap, bounding box, presence of fork/join bars),
// never exact magic pixel values, so the layout metrics can be tuned freely.

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_region.dart';
import 'package:soft_plc_mobile/models/sfc_layout2.dart';

// Metric expectations mirrored from the layout module (tests may know the
// magnitudes; the module keeps them as named consts).
const double _stepW = 140;
const double _branchGap = 32;

// ---- fixture builders (same shape as sfc_region_test) -----------------------

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

// ---- helpers ----------------------------------------------------------------

List<SfcBox> _stepsOf(SfcLayout l) =>
    l.boxes.where((b) => b.kind == 'step').toList();

bool _rectsOverlap(SfcBox a, SfcBox b) {
  final sepX = a.x + a.w <= b.x || b.x + b.w <= a.x;
  final sepY = a.y + a.h <= b.y || b.y + b.h <= a.y;
  return !(sepX || sepY);
}

// y-ranges [a0,a1] and [b0,b1] share some extent.
bool _yOverlap(SfcBox a, SfcBox b) =>
    a.y < b.y + b.h && b.y < a.y + a.h;

void _assertNoStepOverlap(SfcLayout l) {
  final steps = _stepsOf(l);
  for (var i = 0; i < steps.length; i++) {
    for (var j = i + 1; j < steps.length; j++) {
      expect(
        _rectsOverlap(steps[i], steps[j]),
        isFalse,
        reason: 'step boxes $i and $j overlap',
      );
    }
  }
}

void _assertBoundsContainAll(SfcLayout l) {
  for (final b in l.boxes) {
    expect(b.x, greaterThanOrEqualTo(-0.001));
    expect(b.y, greaterThanOrEqualTo(-0.001));
    expect(b.x + b.w, lessThanOrEqualTo(l.width + 0.001));
    expect(b.y + b.h, lessThanOrEqualTo(l.height + 0.001));
  }
}

void main() {
  group('layoutSfcRegion', () {
    test('linear: step boxes stack vertically (increasing y, same x)', () {
      final steps = [_step('a', initial: true), _step('b'), _step('c')];
      final trans = [_single('t1', 'a', 'b'), _single('t2', 'b', 'c')];
      final layout = layoutSfcRegion(parseSfc(steps, trans));

      final stepBoxes = _stepsOf(layout);
      expect(stepBoxes.length, 3);

      // Sort by vertical position and verify strictly increasing y + same x.
      stepBoxes.sort((p, q) => p.y.compareTo(q.y));
      for (var i = 1; i < stepBoxes.length; i++) {
        expect(stepBoxes[i].y, greaterThan(stepBoxes[i - 1].y));
        expect(stepBoxes[i].x, closeTo(stepBoxes[i - 1].x, 0.001));
      }

      // Connectors present linking the boxes; bounds contain everything.
      expect(layout.conns, isNotEmpty);
      _assertBoundsContainAll(layout);
      _assertNoStepOverlap(layout);
    });

    test('alternative: branch step boxes are side-by-side and converge', () {
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
      final layout = layoutSfcRegion(parseSfc(steps, trans));

      SfcBox boxFor(String id) =>
          _stepsOf(layout).firstWhere((b) => b.step!.id == id);

      final bx = boxFor('x');
      final by = boxFor('y');

      // Side-by-side: different x, overlapping vertical extent.
      expect((bx.x - by.x).abs(), greaterThan(1.0));
      expect(_yOverlap(bx, by), isTrue);

      // Convergence: two connectors terminate at the SAME point (the merge
      // funnel) — distinctive to an alternative region.
      var sharedEndpoint = false;
      for (var i = 0; i < layout.conns.length; i++) {
        for (var j = i + 1; j < layout.conns.length; j++) {
          final a = layout.conns[i];
          final b = layout.conns[j];
          if ((a.x2 - b.x2).abs() < 0.001 && (a.y2 - b.y2).abs() < 0.001) {
            sharedEndpoint = true;
          }
        }
      }
      expect(sharedEndpoint, isTrue, reason: 'no convergence connector');

      _assertBoundsContainAll(layout);
      _assertNoStepOverlap(layout);
    });

    test('parallel: fork/join bars span two side-by-side branch columns', () {
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
      final layout = layoutSfcRegion(parseSfc(steps, trans));

      final forks = layout.boxes.where((b) => b.kind == 'forkBar').toList();
      final joins = layout.boxes.where((b) => b.kind == 'joinBar').toList();
      expect(forks.length, 1);
      expect(joins.length, 1);

      final fork = forks.single;
      final join = joins.single;
      // Fork above join.
      expect(fork.y, lessThan(join.y));

      SfcBox boxFor(String id) =>
          _stepsOf(layout).firstWhere((b) => b.step!.id == id);
      final p1 = boxFor('p1');
      final q1 = boxFor('q1');

      // Two side-by-side branch columns.
      expect((p1.x - q1.x).abs(), greaterThan(1.0));
      expect(_yOverlap(p1, q1), isTrue);

      // Both bars span the horizontal extent of the branch boxes.
      final minBranchLeft = [p1.x, q1.x].reduce((a, b) => a < b ? a : b);
      final maxBranchRight =
          [p1.x + p1.w, q1.x + q1.w].reduce((a, b) => a > b ? a : b);
      for (final bar in [fork, join]) {
        expect(bar.x, lessThanOrEqualTo(minBranchLeft + 0.001));
        expect(bar.x + bar.w, greaterThanOrEqualTo(maxBranchRight - 0.001));
      }

      // Double-line connectors exist for the parallel fork/join.
      expect(layout.conns.any((c) => c.doubleBar), isTrue);

      _assertBoundsContainAll(layout);
      _assertNoStepOverlap(layout);
    });

    test('nested parallel: inner branch column width >= its content', () {
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
      final layout = layoutSfcRegion(parseSfc(steps, trans));

      final forks = layout.boxes.where((b) => b.kind == 'forkBar').toList();
      final joins = layout.boxes.where((b) => b.kind == 'joinBar').toList();
      expect(forks.length, 2, reason: 'outer + inner fork bars');
      expect(joins.length, 2, reason: 'outer + inner join bars');

      // The narrower (inner) fork bar must still be wide enough for its two
      // single-step branch columns plus the column gap.
      forks.sort((p, q) => p.w.compareTo(q.w));
      final inner = forks.first;
      final outer = forks.last;
      expect(inner.w, greaterThanOrEqualTo(2 * _stepW + _branchGap - 0.001));
      expect(inner.w, lessThan(outer.w));

      _assertBoundsContainAll(layout);
      _assertNoStepOverlap(layout);
    });

    test('bounds are non-negative and non-empty for a single step', () {
      final layout = layoutSfcRegion(parseSfc([_step('only', initial: true)], []));
      expect(layout.width, greaterThan(0));
      expect(layout.height, greaterThan(0));
      expect(_stepsOf(layout).length, 1);
      _assertBoundsContainAll(layout);
    });
  });
}
