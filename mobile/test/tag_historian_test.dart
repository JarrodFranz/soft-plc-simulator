import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';

class _FakePen implements TrendPenLike {
  @override
  final String tagPath;
  @override
  final int sampleIntervalMs;
  @override
  final String retentionMode; // 'points' | 'time'
  @override
  final int maxPoints;
  @override
  final int windowMs;
  const _FakePen(this.tagPath,
      {this.sampleIntervalMs = 250,
      this.retentionMode = 'time',
      this.maxPoints = 1200,
      this.windowMs = 300000});
}

void main() {
  test('interval gating: does not over-sample a fast scan', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 250)];
    h.syncPens(pens);
    double read(String _) => 1.0;
    h.sample(pens, read, 0);
    h.sample(pens, read, 100);
    h.sample(pens, read, 200);
    expect(h.buffer('A').length, 1, reason: 'only t=0 within the first interval');
    h.sample(pens, read, 250);
    expect(h.buffer('A').length, 2);
    expect(h.buffer('A').last.t, 250);
  });

  test('time retention drops samples older than the window', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 100, retentionMode: 'time', windowMs: 1000)];
    h.syncPens(pens);
    double read(String _) => 5.0;
    for (var t = 0; t <= 1500; t += 100) {
      h.sample(pens, read, t);
    }
    final buf = h.buffer('A');
    expect(buf.first.t, greaterThanOrEqualTo(1500 - 1000));
    expect(buf.every((s) => s.t >= 1500 - 1000), isTrue);
  });

  test('points retention caps the buffer length', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 100, retentionMode: 'points', maxPoints: 3)];
    h.syncPens(pens);
    double read(String _) => 2.0;
    for (var t = 0; t <= 1000; t += 100) {
      h.sample(pens, read, t);
    }
    expect(h.buffer('A').length, 3);
    expect(h.buffer('A').last.t, 1000);
  });

  test('null read appends nothing and never throws', () {
    final h = TagHistorian();
    final pens = [const _FakePen('A', sampleIntervalMs: 100)];
    h.syncPens(pens);
    h.sample(pens, (_) => null, 0);
    h.sample(pens, (_) => null, 100);
    expect(h.buffer('A'), isEmpty);
  });

  test('syncPens adds new buffers, drops removed, keeps unchanged', () {
    final h = TagHistorian();
    const a = _FakePen('A', sampleIntervalMs: 100);
    h.syncPens([a]);
    h.sample([a], (_) => 1.0, 0);
    expect(h.buffer('A').length, 1);
    const b = _FakePen('B', sampleIntervalMs: 100);
    h.syncPens([a, b]); // add B, keep A
    expect(h.buffer('A').length, 1, reason: 'A preserved across sync');
    expect(h.buffer('B'), isEmpty);
    h.syncPens([b]); // drop A
    expect(h.buffer('A'), isEmpty, reason: 'A dropped');
  });

  test('clear empties all buffers', () {
    final h = TagHistorian();
    const a = _FakePen('A', sampleIntervalMs: 100);
    h.syncPens([a]);
    h.sample([a], (_) => 1.0, 0);
    h.clear();
    expect(h.buffer('A'), isEmpty);
  });

  test('buffer of an unknown pen is empty (not null)', () {
    expect(TagHistorian().buffer('nope'), isEmpty);
  });
}
