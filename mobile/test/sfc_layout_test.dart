import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_layout.dart';

SfcStep _s(String id, {bool init = false}) => SfcStep(id: id, name: id.toUpperCase(), isInitial: init);
SfcTransition _t(String id, String from, String to) =>
    SfcTransition(id: id, fromStepId: from, toStepId: to, conditionSt: 'TRUE');

void main() {
  test('linear chart lays out in flow order with the tail loop as a GOTO', () {
    final steps = [_s('a', init: true), _s('b'), _s('c')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'b', 'c'), _t('t2', 'c', 'a')];
    final rows = layoutSfc(steps, trans);
    expect(rows.map((r) => r.step.id).toList(), ['a', 'b', 'c']);
    // a->b and b->c are inline; c->a loops back to an already-placed step (GOTO).
    expect(rows[0].outgoing.single.inline, isTrue);
    expect(rows[1].outgoing.single.inline, isTrue);
    expect(rows[2].outgoing.single.inline, isFalse); // loop-back GOTO
    expect(rows[2].outgoing.single.target!.id, 'a');
  });

  test('a 2-way branch: first target inline, second is a GOTO', () {
    final steps = [_s('a', init: true), _s('x'), _s('y')];
    final trans = [_t('t0', 'a', 'x'), _t('t1', 'a', 'y')];
    final rows = layoutSfc(steps, trans);
    // a placed first; its first outgoing (->x) inline places x next; ->y GOTO.
    expect(rows.first.step.id, 'a');
    expect(rows.first.outgoing.length, 2);
    expect(rows.first.outgoing[0].inline, isTrue);
    expect(rows.first.outgoing[0].target!.id, 'x');
    expect(rows.first.outgoing[1].inline, isFalse);
    expect(rows.first.outgoing[1].target!.id, 'y');
    // both x and y appear as rows (y is branch-reachable, placed after).
    expect(rows.map((r) => r.step.id).toSet(), {'a', 'x', 'y'});
  });

  test('convergence: two steps target one merge step, placed once', () {
    final steps = [_s('a', init: true), _s('b'), _s('m')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'a', 'm'), _t('t2', 'b', 'm')];
    final rows = layoutSfc(steps, trans);
    expect(rows.where((r) => r.step.id == 'm').length, 1); // placed once
  });

  test('unreachable step lands last; dangling target yields null', () {
    final steps = [_s('a', init: true), _s('b'), _s('orphan')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'b', 'ghost')];
    final rows = layoutSfc(steps, trans);
    expect(rows.last.step.id, 'orphan'); // unreachable, last
    expect(rows[1].outgoing.single.target, isNull); // 'ghost' does not exist
  });

  test('self-loop and mutual loop terminate (cycle-safe)', () {
    final steps = [_s('a', init: true), _s('b')];
    final trans = [_t('t0', 'a', 'b'), _t('t1', 'b', 'a'), _t('t2', 'a', 'a')];
    final rows = layoutSfc(steps, trans); // must not hang
    expect(rows.map((r) => r.step.id).toSet(), {'a', 'b'});
  });
}
