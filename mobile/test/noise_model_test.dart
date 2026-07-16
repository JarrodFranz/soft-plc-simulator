import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/noise_model.dart';

void main() {
  test('uniformNoise endpoints and midpoint', () {
    expect(uniformNoise(0.0, 5.0), -5.0);
    expect(uniformNoise(1.0, 5.0), 5.0);
    expect(uniformNoise(0.5, 5.0), 0.0);
  });

  test('gaussianNoise is deterministic and scales linearly with sigma', () {
    final a = gaussianNoise(0.3, 0.7, 2.0);
    final b = gaussianNoise(0.3, 0.7, 4.0);
    expect(b, closeTo(a * 2, 1e-9));
    // exact value for a fixed (u1,u2,sigma)
    final r = math.sqrt(-2 * math.log(0.3)) * math.cos(2 * math.pi * 0.7) * 2.0;
    expect(gaussianNoise(0.3, 0.7, 2.0), closeTo(r, 1e-9));
  });

  test('gaussianNoise guards u1==0 (finite, no -Inf)', () {
    expect(gaussianNoise(0.0, 0.5, 1.0).isFinite, isTrue);
  });

  test('gaussianNoise sample mean ~0, std ~sigma over a pseudo-sequence', () {
    const n = 4000;
    final samples = <double>[];
    for (var i = 0; i < n; i++) {
      final u1 = (i * 2 + 1) / (2 * n + 1);
      final u2 = (i * 3 + 1) % (2 * n + 1) / (2 * n + 1);
      samples.add(gaussianNoise(u1, u2, 3.0));
    }
    final mean = samples.reduce((a, b) => a + b) / n;
    final variance = samples.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) / n;
    expect(mean.abs(), lessThan(0.4));
    expect(math.sqrt(variance), closeTo(3.0, 0.6));
  });

  test('driftStep is a convex blend, strictly bounded, EMA identities', () {
    expect(driftStep(2.0, 6.0, 1.0), closeTo(6.0, 1e-9)); // alpha=1 -> target
    expect(driftStep(2.0, 6.0, 0.0), closeTo(2.0, 1e-9)); // alpha=0 -> prev
    // sequence with targets in [-A,A] stays in [-A,A]
    const a = 5.0;
    var prev = 0.0;
    for (var i = 0; i < 200; i++) {
      final target = uniformNoise((i * 7 % 100) / 100.0, a); // in [-a,a]
      prev = driftStep(prev, target, 0.1);
      expect(prev, inInclusiveRange(-a, a));
    }
  });

  test('driftAlpha: tau<=0 -> 1.0, monotonic decreasing in tau', () {
    expect(driftAlpha(100, 0), 1.0);
    expect(driftAlpha(100, -5), 1.0);
    final a1 = driftAlpha(100, 1.0);
    final a2 = driftAlpha(100, 10.0);
    expect(a1, greaterThan(a2)); // larger tau -> smaller alpha (slower)
    expect(a1, inInclusiveRange(0.0, 1.0));
  });
}
